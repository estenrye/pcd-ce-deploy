resource "talos_machine_secrets" "this" {
  talos_version = var.talos_version
}

data "talos_machine_configuration" "controlplane" {
  cluster_name       = var.cluster_name
  cluster_endpoint   = "https://[${local.controlplane_address}]:6443"
  machine_type       = "controlplane"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version

  config_patches = [
    yamlencode({
      machine = {
        # Talos enables DHCPv4 on discovered interfaces by default but
        # NOT DHCPv6 (disabled unless dhcpOptions.ipv6 is set) -- needed
        # here since this network carries no IPv4 subnet at all. "eth0"
        # is the conventional first-NIC name Talos assigns under
        # QEMU/KVM (it doesn't run systemd/udev's predictable-naming
        # scheme); if the node doesn't come up with an address, this is
        # the first thing to check live via `talosctl get links` against
        # its apid in maintenance mode.
        network = {
          interfaces = [
            {
              interface = "eth0"
              dhcp      = true
              dhcpOptions = {
                ipv4 = false
                ipv6 = true
              }
            },
            # bgp-net (bgp.tf): second NIC, attached after the cluster
            # network in instance.tf. Same dhcpv6-stateful setup as eth0.
            {
              interface = "eth1"
              dhcp      = true
              dhcpOptions = {
                ipv4 = false
                ipv6 = true
              }
            }
          ]
          # Without this, Talos's host DNS resolver falls back to (or
          # merges in) its own hardcoded public defaults -- confirmed
          # live, 2026-09-16: console log showed it repeatedly trying
          # 8.8.8.8:53, which can only ever fail on this IPv4-less
          # network. Setting this statically overrides that, so the
          # only servers Talos ever queries are the DNS64 resolvers
          # this subnet is built around.
          nameservers = var.dns_nameservers
        }
        # Pin kubelet's advertised node address to the cluster subnet,
        # matching the pattern in
        # github.com/siderolabs/contrib's hcloud Terraform example.
        kubelet = {
          nodeIP = {
            validSubnets = [var.subnet_cidr]
          }
        }
      }
      cluster = {
        # Single-node bare minimum: this node is both controlplane and
        # the only place workloads can run.
        allowSchedulingOnControlPlanes = true
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
        network = {
          podSubnets     = [var.pod_subnet]
          serviceSubnets = [var.service_subnet]
          cni = {
            name = var.cni_name
          }
        }
      }
    })
  ]
}

data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  nodes                = [local.controlplane_address]
  endpoints            = [local.controlplane_address]
}

# The machine config above is delivered at boot via instance.tf's
# user_data (config drive), so there's no separate apply step here --
# just bootstrap etcd once the node is up.
resource "talos_machine_bootstrap" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = local.controlplane_address

  depends_on = [pcd_compute_instance.controlplane]
}

# Blocks `tofu apply` from returning "done" until the cluster is actually
# healthy end to end (etcd, kubelet, and core Kubernetes components) --
# not just until the bootstrap API call was accepted.
data "talos_cluster_health" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  control_plane_nodes  = [local.controlplane_address]
  endpoints            = [local.controlplane_address]

  depends_on = [talos_machine_bootstrap.this]
}

# The resource form, not the (deprecated, removal-pending) data source of
# the same name.
resource "talos_cluster_kubeconfig" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = local.controlplane_address

  depends_on = [data.talos_cluster_health.this]
}
