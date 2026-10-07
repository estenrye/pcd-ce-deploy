# Optional Barbican-held AES key for encrypting the cluster's secrets.
#
# The pcd provider only exposes Barbican secrets (no orders API), so Barbican
# can't generate the key itself: the key material is generated here and
# stored as a symmetric secret. It therefore also lives in tofu state
# (sensitive), alongside the Talos machine secrets that already do.
resource "random_bytes" "kms_key" {
  count  = var.create_kms_key ? 1 : 0
  length = var.kms_key_bit_length / 8
}

# Created as the OCCM user (same project as the cluster) rather than the admin
# user: the barbican-kms-plugin authenticates with the OCCM application
# credential and can only read secrets in that project.
resource "pcd_keymanager_secret" "kms_key" {
  provider = pcd.pcd-occm
  count    = var.create_kms_key ? 1 : 0

  name        = coalesce(var.kms_key_name, "${var.cluster_name}-secrets-kms")
  secret_type = "symmetric"
  algorithm   = "aes"
  mode        = "cbc"
  bit_length  = var.kms_key_bit_length

  payload                  = random_bytes.kms_key[0].base64
  payload_content_type     = "application/octet-stream"
  payload_content_encoding = "base64"
}

locals {
  kms_dir = "/var/lib/barbican-kms"
  # The plugin's socket directory is bind-mounted into kube-apiserver; the
  # plugin's credentials (cloud.conf) stay one level up, out of that mount.
  kms_socket_dir = "${local.kms_dir}/run"

  # Control-plane-only Talos patches that make kube-apiserver encrypt Secrets
  # through the Barbican key via KMS v2 (barbican-kms-plugin, a static pod on
  # each control-plane node). Empty-safe: only referenced when
  # var.create_kms_key is true.
  kms_controlplane_patches = !var.create_kms_key ? [] : [
    yamlencode({
      machine = {
        files = [
          {
            # Holds the OCCM application credential; the dir above the
            # apiserver-mounted socket dir.
            path        = "${local.kms_dir}/cloud.conf"
            op          = "create"
            permissions = 420 # 0644: the plugin container reads it
            content     = local.occm_cloud_conf
          },
          {
            # Creates the socket dir so kube-apiserver's hostPath mount
            # exists before the plugin pod does.
            path        = "${local.kms_socket_dir}/.keep"
            op          = "create"
            permissions = 420
            content     = ""
          },
        ]
      }
    }),
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "KubeStaticPodConfig"
      name       = "barbican-kms-plugin"
      pod = {
        apiVersion = "v1"
        kind       = "Pod"
        metadata = {
          name      = "barbican-kms-plugin"
          namespace = "kube-system"
        }
        spec = {
          # Needs to reach Keystone/Barbican before any CNI exists.
          hostNetwork       = true
          priorityClassName = "system-node-critical"
          containers = [{
            name  = "barbican-kms-plugin"
            image = "registry.k8s.io/provider-os/barbican-kms-plugin:${var.kms_plugin_version}"
            # umask 0: kube-apiserver runs as non-root and needs write
            # permission on the socket to connect.
            command = [
              "sh", "-c",
              "umask 000 && exec /bin/barbican-kms-plugin --socketpath=/kms/run/kms.sock --cloud-config=/kms/cloud.conf",
            ]
            volumeMounts = [{ name = "kms", mountPath = "/kms" }]
          }]
          volumes = [{
            name     = "kms"
            hostPath = { path = local.kms_dir }
          }]
        }
      }
    }),
    # Replaces the KubeAPIServerConfig document (see talos.tf) so that the
    # legacy .cluster.apiServer, which can take extraVolumes, is usable.
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "KubeAPIServerConfig"
      "$patch"   = "delete"
    }),
    yamlencode({
      cluster = {
        apiServer = {
          certSANs = [local.cluster_vip]
          extraVolumes = [{
            hostPath  = local.kms_socket_dir
            mountPath = "/var/lib/kms"
          }]
        }
      }
    }),
    # Delete first: patches merge list items, which would leave the
    # generated secretbox provider ahead of kms, so nothing would ever be
    # written with the KMS key.
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "KubeEtcdEncryptionConfig"
      "$patch"   = "delete"
    }),
    # First provider encrypts; the rest only decrypt. Secretbox stays so
    # existing Secrets remain readable; identity covers any unencrypted ones.
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "KubeEtcdEncryptionConfig"
      config = {
        resources = [{
          resources = ["secrets"]
          providers = [
            { kms = {
              apiVersion = "v2"
              name       = "barbican"
              endpoint   = "unix:///var/lib/kms/kms.sock"
              timeout    = "3s"
            } },
            { secretbox = { keys = [{
              name   = "key2"
              secret = talos_machine_secrets.this.machine_secrets.secrets.secretbox_encryption_secret
            }] } },
            { identity = {} },
          ]
        }]
      }
    }),
  ]
}

# Talos writes machine.files at boot only; a live config apply leaves them
# off disk. The barbican-kms-plugin static pod then crash-loops on a missing
# cloud.conf, and kube-apiserver (already pointed at the plugin's socket)
# can't write Secrets. So the control-plane nodes need one reboot after the
# KMS config lands -- the same reason terraform_data.reboot_controlplane
# exists for first boot (see talos.tf).
#
# One resource looping over the nodes, not one per node: a per-node resource
# can't be ordered against its siblings, and rebooting all control planes at
# once would take etcd quorum down. Each node must have its plugin socket
# back before the next one is rebooted.
#
# Re-runs when the files' content or the plugin image changes (the cloud.conf
# embeds the OCCM credential and key ID), so rotating either re-reboots the
# nodes. On a fresh build it's a no-op-ish extra reboot after the first one.
resource "terraform_data" "reboot_controlplane_kms" {
  count = var.create_kms_key ? 1 : 0

  triggers_replace = {
    config = sha256(local.occm_cloud_conf)
    plugin = var.kms_plugin_version
    nodes  = join(",", local.controlplane_addresses)
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      command -v talosctl >/dev/null || { echo "talosctl not found in PATH" >&2; exit 1; }
      cfg=$(mktemp)
      trap 'rm -f "$cfg"' EXIT
      printf '%s' "$TALOSCONFIG_CONTENT" > "$cfg"
      for node in ${join(" ", local.controlplane_addresses)}; do
        echo "rebooting $node"
        talosctl --talosconfig "$cfg" -n "$node" -e "$node" reboot --wait --timeout 10m
        # Wait for the plugin to recreate its socket before touching the next node.
        for _ in $(seq 60); do
          if talosctl --talosconfig "$cfg" -n "$node" -e "$node" ls ${local.kms_socket_dir} 2>/dev/null | grep -q 'kms.sock'; then
            continue 2
          fi
          sleep 5
        done
        echo "kms.sock never appeared on $node" >&2
        exit 1
      done
    EOT
    environment = {
      TALOSCONFIG_CONTENT = nonsensitive(data.talos_client_configuration.this.talos_config)
    }
  }

  depends_on = [
    talos_machine_configuration_apply.controlplane,
    terraform_data.reboot_controlplane,
  ]
}
