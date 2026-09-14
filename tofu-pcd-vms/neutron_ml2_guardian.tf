# See variables.tf's `neutron_ml2_guardian` doc comment for the full
# rationale. Everything here is gated on that variable being non-null via
# `count`, and there is exactly one guardian deployment per cluster (no
# for_each) -- unlike this file's siblings, "one guardian repairing one
# neutron-server Deployment" isn't a per-network/per-host concern.
#
# Referencing `var.neutron_ml2_guardian`'s fields directly below (not
# through another `!= null ? ... : ...` guard) relies on the standard
# Terraform "optional resource" idiom: with `count = 0`, an instance's
# argument expressions are never evaluated at all, so there's no
# null-attribute-access error to guard against -- only the `count`
# expression itself needs the null check.

data "onepassword_item" "unifi_api_key" {
  count = var.neutron_ml2_guardian != null ? 1 : 0

  vault = var.neutron_ml2_guardian.unifi_api_key_item.vault
  title = var.neutron_ml2_guardian.unifi_api_key_item.title
}

resource "ssh_resource" "neutron_ml2_guardian" {
  count = var.neutron_ml2_guardian != null ? 1 : 0

  host        = var.pcd_hostname
  user        = var.pcd_ssh_username
  agent       = true
  timeout     = "5m"
  retry_delay = "10s"

  # No secret material here -- extraConfigSecretRef only names the Secret
  # created by the `commands` step below, matching the whole reason that
  # option exists (see neutron-ml2-guardian's README/design doc: it was
  # added specifically so a values file never has to carry the real
  # credential).
  # dryRun = false: confirmed working end to end, 2026-09-14 -- a real
  # `openstack network create` against this exact config produced a VLAN
  # that genuinely exists on the real UDM-SE (verified directly via its
  # own API, both create and delete). See
  # ../../neutron-ml2-guardian/docs/specs/2026-09-13-neutron-ml2-guardian-design.md's
  # "Sixth live attempt" writeup for the ten real bugs it took to get
  # here. If this ever needs to come back to a safe/idle state (e.g.
  # after a PCD upgrade behaves unexpectedly), flip this to `true` and
  # `tofu apply` -- the guardian's automated revert removes its whole
  # footprint from neutron-server within seconds, proven live multiple
  # times during that same investigation.
  file {
    destination = "/tmp/neutron-ml2-guardian-values.yaml"
    permissions = "0600"
    content = yamlencode({
      dryRun = false
      ml2Drivers = [
        {
          name                 = "unifi"
          pipPackage           = "unifi-ml2-driver-estenrye"
          importModule         = "unifi_ml2_driver"
          extraConfigSecretRef = "neutron-ml2-unifi-external-config"
        }
      ]
    })
  }

  # The UniFi API key is interpolated directly into this command string,
  # never written to a file on the remote host -- it reaches the cluster
  # only as a Kubernetes Secret (etcd), via a single piped
  # `kubectl create secret ... --dry-run=client -o yaml | kubectl apply
  # -f -` invocation that's create-or-update idempotent. `helm upgrade
  # --install` against the versioned OCI chart needs no local chart
  # checkout on the target host, unlike this project's manual testing
  # earlier (which git-cloned the guardian repo directly) -- the whole
  # point of tagging a release was to make that unnecessary.
  #
  # The Secret key MUST be "unifi.ini", not "unifi.conf" -- confirmed live,
  # 2026-09-14: the guardian's own injection patch hardcodes `subPath:
  # "<driver-name>.ini"` for an extraConfigSecretRef volume (see
  # k8s/mod.rs's comment: "subPath must match the Secret's own key"). A
  # subPath referencing a key the Secret doesn't have makes Kubernetes
  # mount an *empty directory* at that path instead of erroring, which
  # neutron-server then hit as `IsADirectoryError` trying to open its
  # extra config file. The *mounted filename* is free to be `.conf`
  # (that's what oslo.config's --config-dir actually globs by) -- only
  # the Secret's internal key name has to be `.ini`.
  #
  # `port = 443` and `verify_ssl = false` are both required for a real
  # UDM-SE, not optional -- confirmed live: the driver's own default port
  # (8443) is the classic/self-hosted-controller port, and a UDM-SE (a
  # UniFi OS console) proxies everything through its standard HTTPS port
  # instead; `curl`ing 8443 directly returns 404 for every path, 443
  # serves the real API. verify_ssl=false is needed because this device
  # uses a self-signed certificate.
  commands = [
    <<-EOT
      set -euo pipefail

      sudo kubectl create secret generic neutron-ml2-unifi-external-config \
        -n pcd \
        --from-literal=unifi.ini="$(printf '[unifi]\nhost = %s\nport = 443\napikey = %s\nsite = %s\nverify_ssl = false\n%s%s' \
          '${var.neutron_ml2_guardian.unifi_host}' \
          '${data.onepassword_item.unifi_api_key[0].credential}' \
          '${var.neutron_ml2_guardian.unifi_site}' \
          '${var.neutron_ml2_guardian.default_firewall_zone != null ? "default_firewall_zone = ${var.neutron_ml2_guardian.default_firewall_zone}\n" : ""}' \
          '${var.neutron_ml2_guardian.nat66_egress_interface != null ? "nat66_egress_interface = ${var.neutron_ml2_guardian.nat66_egress_interface}\n" : ""}')" \
        --dry-run=client -o yaml | sudo kubectl apply -f -

      sudo helm upgrade --install neutron-ml2-guardian \
        oci://registry-1.docker.io/estenrye/neutron-ml2-guardian-chart \
        --version ${var.neutron_ml2_guardian.chart_version} \
        -n neutron-ml2-guardian --create-namespace \
        -f /tmp/neutron-ml2-guardian-values.yaml \
        --wait --timeout 3m
    EOT
  ]
}
