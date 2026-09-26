resource "talos_machine_secrets" "this" {
  talos_version = var.talos_version
}

locals {
  # Config shared by every node, control-plane and worker alike.
  common_machine = {
    # Talos enables DHCPv4 on discovered interfaces by default but
    # NOT DHCPv6 (disabled unless dhcpOptions.ipv6 is set) -- needed
    # here since this network carries no IPv4 subnet at all. "eth0"
    # is the conventional first-NIC name Talos assigns under
    # QEMU/KVM (it doesn't run systemd/udev's predictable-naming
    # scheme); if the node doesn't come up with an address, this is
    # the first thing to check live via `talosctl get links` against
    # its apid in maintenance mode.
    network = {
      # Without nameservers, Talos's host DNS resolver falls back to (or
      # merges in) its own hardcoded public defaults -- confirmed
      # live, 2026-09-16: console log showed it repeatedly trying
      # 8.8.8.8:53, which can only ever fail on this IPv4-less
      # network. Setting this statically overrides that, so the
      # only servers Talos ever queries are the DNS64 resolvers
      # this subnet is built around.
      nameservers = var.dns_nameservers
    }
    # Spegel (https://spegel.dev/docs/getting-started/#talos) serves
    # image layers out of containerd's content store, which Talos
    # discards after unpacking by default. Talos merges *.part files
    # from /etc/cri/conf.d into its generated containerd CRI config.
    files = [
      {
        path    = "/etc/cri/conf.d/20-customization.part"
        op      = "create"
        content = <<-EOT
          [plugins."io.containerd.cri.v1.images"]
            discard_unpacked_layers = false
        EOT
      }
    ]
    # Pin kubelet's advertised node address to the bgp-net subnet,
    # matching the pattern in
    # github.com/siderolabs/contrib's hcloud Terraform example.
    kubelet = {
      nodeIP = {
        validSubnets = [data.pcd_networking_subnet.bgp.cidr]
      }
    }
    # Stop SLAAC from adding a second global address (`...:f816:3eff:...`, derived
    # from the MAC) next to the DHCPv6-assigned one. The kernel prefers the SLAAC
    # address as the source of node-originated traffic, and the "all traffic from
    # cluster members" security-group rule only matches the DHCPv6 (fixed IP)
    # address, so that traffic (Typha, BGP, host-to-pod) is dropped.
    sysctls = {
      "net.ipv6.conf.default.autoconf" = "0"
      "net.ipv6.conf.eth0.autoconf"    = "0"
    }
  }

  # Talos's own defaults here are IPv4 (10.244.0.0/16 /
  # 10.96.0.0/12) regardless of the host network -- confirmed
  # live, 2026-09-17: kube-apiserver refuses to start at all with
  # them on an IPv6-only node ("service IP family \"10.96.0.0/12\"
  # must match public address family"), crash-looping forever
  # with etcd/kubelet otherwise healthy. Pod/service CIDRs are
  # just an internal overlay address space -- any private range
  # works -- but the address *family* has to match the node's.
  # These are cluster-bootstrap-time settings: changing them after
  # etcd has formed needs a full reset, not a live config patch.
  # Workers need them too (kubelet derives its cluster DNS address
  # from the service subnet).
  common_cluster_network = {
    podSubnets     = [var.pod_subnet]
    serviceSubnets = [var.service_subnet]
    cni = {
      name = var.cni_name
    }
  }
}

data "talos_machine_configuration" "controlplane" {
  cluster_name       = var.cluster_name
  cluster_endpoint   = local.cluster_endpoint
  machine_type       = "controlplane"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version

  config_patches = [
    yamlencode({
      machine = merge(local.common_machine, {
        network = merge(local.common_machine.network, {
          interfaces = [
            {
              interface = "eth0"
              dhcp      = true
              dhcpOptions = {
                ipv4 = false
                ipv6 = true
              }
              # Talos elects one control-plane node (via etcd) to hold this
              # address and announces it with NDP. The reserved address is
              # pcd_networking_port.vip (an allowed address pair on every
              # control-plane port, see instance.tf).
              vip = {
                ip = local.cluster_vip
              }
            }
          ]
        })
      })
      cluster = {
        allowSchedulingOnControlPlanes = var.schedule_on_controlplanes
        # The endpoint host is added to the API server cert SANs by
        # config generation already; stated explicitly so it can't be lost.
        apiServer = {
          certSANs = [local.cluster_vip]
        }
        network = local.common_cluster_network
      }
    })
  ]
}

data "talos_machine_configuration" "worker" {
  cluster_name       = var.cluster_name
  cluster_endpoint   = local.cluster_endpoint
  machine_type       = "worker"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version

  config_patches = [
    yamlencode({
      machine = merge(local.common_machine, {
        network = merge(local.common_machine.network, {
          interfaces = [
            {
              interface = "eth0"
              dhcp      = true
              dhcpOptions = {
                ipv4 = false
                ipv6 = true
              }
            }
          ]
        })
      })
      cluster = {
        network = local.common_cluster_network
      }
    })
  ]
}

data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  nodes                = local.controlplane_addresses
  endpoints            = local.controlplane_addresses
}

# Instances boot with no user_data, into Talos maintenance mode, and these
# push each node's machine config over apid -- the first time as the
# initial config, afterwards as in-place updates (Talos reboots a node
# only if a change needs it). Editing the config therefore never replaces
# an instance. Each node is addressed directly by its port address, not the
# VIP, which doesn't exist until the controlplane is up.
resource "talos_machine_configuration_apply" "controlplane" {
  count = var.controlplane_count

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.controlplane.machine_configuration
  node                        = local.controlplane_addresses[count.index]
  endpoint                    = local.controlplane_addresses[count.index]

  # Make on-link traffic (including the control-plane VIP holder's) leave from the
  # node's own fixed IP. The VIP is a /128 and wins the kernel's source selection.
  config_patches = [
    yamlencode({
      machine = {
        network = {
          interfaces = [
            {
              interface = "eth0"
              routes = [
                {
                  network = data.pcd_networking_subnet.bgp.cidr
                  source  = local.controlplane_addresses[count.index]
                  metric  = 100
                }
              ]
            }
          ]
        }
      }
    })
  ]

  # The security groups and their apid rule gate 50000/tcp, so the node
  # isn't reachable until they're attached to its port.
  depends_on = [
    pcd_compute_instance.controlplane,
    pcd_networking_port_secgroup_associate.controlplane,
    pcd_networking_secgroup_rule.talos_apid_ingress,
  ]
}

resource "talos_machine_configuration_apply" "worker" {
  count = var.worker_count

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.worker.machine_configuration
  node                        = local.worker_addresses[count.index]
  endpoint                    = local.worker_addresses[count.index]

  # Make on-link traffic (including the control-plane VIP holder's) leave from the
  # node's own fixed IP. The VIP is a /128 and wins the kernel's source selection.
  config_patches = [
    yamlencode({
      machine = {
        network = {
          interfaces = [
            {
              interface = "eth0"
              routes = [
                {
                  network = data.pcd_networking_subnet.bgp.cidr
                  source  = local.worker_addresses[count.index]
                  metric  = 100
                }
              ]
            }
          ]
        }
      }
    })
  ]

  depends_on = [
    pcd_compute_instance.worker,
    pcd_networking_port_secgroup_associate.worker,
    pcd_networking_secgroup_rule.talos_apid_ingress,
  ]
}

# One reboot per instance, right after its first config push. A node boots
# into maintenance mode before it has any machine config, and during that
# window the kernel forms a SLAAC address (`...:f816:3eff:...`) next to the
# DHCPv6 one. machine.sysctls (autoconf = 0) stops new SLAAC addresses but
# doesn't remove one that already exists, and the security groups only match
# the DHCPv6 address, so without this the SLAAC one keeps being used as the
# source address until the node next restarts. Rebooting once with the
# config in place clears it.
#
# The Talos provider has no reboot resource, and apply_mode = "reboot" on the
# apply resources above would reboot a node on every later config edit, so
# this shells out to talosctl instead. It is keyed on the instance ID, so it
# runs once for each new instance and never for a config change. Needs
# talosctl on the machine running tofu, with an IPv6 route to the nodes.
#
# On a fresh build the reboots can run in parallel (etcd isn't bootstrapped
# yet). Adding this to an *already running* cluster reboots every existing
# node once, so apply that with `-parallelism=1`: `--wait` then makes each
# reboot finish before the next starts, instead of taking all three
# control-plane nodes (and etcd quorum) down together.
resource "terraform_data" "reboot_controlplane" {
  count = var.reboot_after_first_config ? var.controlplane_count : 0

  triggers_replace = {
    instance = pcd_compute_instance.controlplane[count.index].id
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      command -v talosctl >/dev/null || { echo "talosctl not found in PATH" >&2; exit 1; }
      cfg=$(mktemp)
      trap 'rm -f "$cfg"' EXIT
      printf '%s' "$TALOSCONFIG_CONTENT" > "$cfg"
      talosctl --talosconfig "$cfg" -n ${local.controlplane_addresses[count.index]} -e ${local.controlplane_addresses[count.index]} reboot --wait --timeout 10m
    EOT
    environment = {
      TALOSCONFIG_CONTENT = nonsensitive(data.talos_client_configuration.this.talos_config)
    }
  }

  depends_on = [talos_machine_configuration_apply.controlplane]
}

resource "terraform_data" "reboot_worker" {
  count = var.reboot_after_first_config ? var.worker_count : 0

  triggers_replace = {
    instance = pcd_compute_instance.worker[count.index].id
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      command -v talosctl >/dev/null || { echo "talosctl not found in PATH" >&2; exit 1; }
      cfg=$(mktemp)
      trap 'rm -f "$cfg"' EXIT
      printf '%s' "$TALOSCONFIG_CONTENT" > "$cfg"
      talosctl --talosconfig "$cfg" -n ${local.worker_addresses[count.index]} -e ${local.worker_addresses[count.index]} reboot --wait --timeout 10m
    EOT
    environment = {
      TALOSCONFIG_CONTENT = nonsensitive(data.talos_client_configuration.this.talos_config)
    }
  }

  depends_on = [talos_machine_configuration_apply.worker]
}

# Bootstrap etcd once, on the first control-plane node. The other
# control-plane nodes join that etcd cluster by themselves once it exists,
# and workers join via the VIP endpoint.
#
# This only runs when the resource is created or explicitly replaced, which
# is what you want: re-bootstrapping a node in a *live* multi-node cluster
# would start a second, separate etcd cluster instead of rejoining the
# first. Replacing a single controlplane node needs only its apply, not a
# new bootstrap.
resource "talos_machine_bootstrap" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = local.controlplane_addresses[0]

  depends_on = [
    talos_machine_configuration_apply.controlplane,
    terraform_data.reboot_controlplane,
  ]
}

# Blocks `tofu apply` from returning "done" until the cluster is actually
# healthy end to end (etcd, kubelet, and core Kubernetes components) --
# not just until the bootstrap API call was accepted.
data "talos_cluster_health" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  control_plane_nodes  = local.controlplane_addresses
  worker_nodes         = local.worker_addresses
  endpoints            = local.controlplane_addresses

  depends_on = [
    talos_machine_bootstrap.this,
    talos_machine_configuration_apply.worker,
    terraform_data.reboot_worker,
  ]
}

# The resource form, not the (deprecated, removal-pending) data source of
# the same name.
resource "talos_cluster_kubeconfig" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = local.controlplane_addresses[0]

  depends_on = [data.talos_cluster_health.this]
}
