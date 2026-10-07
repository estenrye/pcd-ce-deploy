# --- PCD connection (same shape as ../tofu-pcd-vms/variables.tf) ---

variable "pcd_hostname" {
  description = "Hostname of the PCD management plane."
  type        = string
  default     = null
}

variable "pcd_ssh_username" {
  description = "Username for SSH access to the PCD management plane."
  type        = string
  default     = "ubuntu"
}

variable "pcd_auth_url" {
  description = "Keystone v3 auth URL for the PCD management plane."
  type        = string
  default     = null
}

variable "pcd_region" {
  description = "PCD region to operate in."
  type        = string
  default     = "Infra"
}

variable "pcd_tenant_name" {
  description = "Project (tenant) the admin user is scoped to."
  type        = string
  default     = "service"
}

variable "pcd_user_domain_id" {
  description = "Keystone domain ID the admin user belongs to."
  type        = string
  default     = "default"
}

variable "pcd_project_domain_id" {
  description = "Keystone domain ID of the scoped project."
  type        = string
  default     = "default"
}

variable "onepassword_account" {
  description = <<-EOT
    1Password account name or ID (as shown in the desktop app's sidebar),
    used for desktop-app authentication instead of a service account
    token -- the app must be running, unlocked, and have "Integrate with
    1Password CLI" enabled under Settings > Developer. Can also be left
    unset here and sourced from the OP_ACCOUNT environment variable.
  EOT
  type        = string
  default     = null
}

variable "onepassword_vault" {
  description = "1Password vault UUID (or name) holding the PCD admin credentials."
  type        = string
  default     = null
}

variable "onepassword_item_title" {
  description = "Title of the 1Password Login item holding the PCD admin username/password."
  type        = string
  default     = null
}

variable "onepassword_occm_item_title" {
  description = "Title of the 1Password Login item holding the OpenStack CCM service account credentials."
  type        = string
  default     = null
}

variable "floating_network_subnet_name" {
  description = "Name of the existing subnet on the floating network to allocate floating IPs from."
  type        = string
  default     = null
}

variable "dns_nameservers" {
  description = <<-EOT
    DNS64 resolvers handed out over DHCPv6, so an IPv6-only node can still
    resolve IPv4-only names (synthesized AAAA -> NAT64) for things like
    container registries. Defaults to the same pair already live-verified
    on vlan1000-subnet-v6 in ../tofu-pcd-vms/terraform.tfvars.
  EOT
  type        = list(string)
  default     = ["fd97:45c2:b3a1:64::64", "2606:4700:4700::64"]
}

# --- BGP network (owned by ../tofu-pcd-vms) ---

variable "bgp_network_name" {
  description = "Name of the existing network to attach the node's second NIC to for BGP peering."
  type        = string
  default     = "bgp-net"
}

variable "bgp_subnet_name" {
  description = "Name of the existing subnet on bgp_network_name to allocate the node's BGP-facing address from."
  type        = string
  default     = "bgp-subnet-v6"
}

variable "bgp_secgroup_name" {
  description = "Name of the existing security group applied to the node's bgp-net port."
  type        = string
  default     = "allow-bgp-icmp"
}

# --- Calico (generated manifests; see calico.tf) ---

variable "calico_ip_pools" {
  description = <<-EOT
    Pod IPPools, rendered into both the tigera-operator Installation's
    calicoNetwork.ipPools and an explicit IPPool (allowedUses Workload +
    Tunnel). Every CIDR is also added as an allowed address pair on each node
    port (Neutron port security otherwise drops cross-node pod traffic when the
    CNI routes natively instead of encapsulating -- confirmed live 2026-09-26),
    and allowed through the pod-pool security group rules. This is NOT
    var.pod_subnet, which only tells Kubernetes what to carve node podCIDRs from.
    encapsulation is one of None, IPIP, IPIPCrossSubnet, VXLAN, VXLANCrossSubnet.
  EOT
  type = list(object({
    name          = string
    cidr          = string
    encapsulation = optional(string, "None")
    nat_outgoing  = optional(bool, true)
    block_size    = optional(number, 122)
  }))
  default = [
    {
      name = "pods-v6"
      cidr = "fd00:db8:0:1100::/56"
    },
  ]

  validation {
    condition = alltrue([
      for p in var.calico_ip_pools :
      contains(["None", "IPIP", "IPIPCrossSubnet", "VXLAN", "VXLANCrossSubnet"], p.encapsulation)
    ])
    error_message = "calico_ip_pools[*].encapsulation must be None, IPIP, IPIPCrossSubnet, VXLAN, or VXLANCrossSubnet."
  }
}

variable "calico_node_address_autodetection_v6_cidrs" {
  description = "CIDRs the operator uses to pick each node's IPv6 BGP address (Installation nodeAddressAutodetectionV6.cidrs). Empty (the default) uses the kubelet's NodeInternalIP instead, which is unambiguous here because kubelet's nodeIP is pinned to the bgp-net subnet."
  type        = list(string)
  default     = []
}

variable "calico_bgp" {
  description = <<-EOT
    BGPConfiguration (named "default") plus one BGPPeer per entry in peers.
    service_load_balancer_ips are advertised over BGP and are also added as
    allowed address pairs on each node port, so every range here needs a
    matching calico_load_balancer_pools entry.
  EOT
  type = object({
    as_number                 = number
    node_to_node_mesh_enabled = optional(bool, true)
    log_severity_screen       = optional(string, "Info")
    service_load_balancer_ips = list(string)
    peers = list(object({
      name      = string
      peer_ip   = string
      as_number = number
    }))
  })
  default = {
    as_number = 64514
    service_load_balancer_ips = [
      "fd97:45c2:b3a1:f00::1:0/112",
      "2607:3640:1064:27f::1:0/112",
    ]
    peers = [
      {
        name      = "gateway"
        peer_ip   = "fd97:45c2:b3a1:1179::1"
        as_number = 64512
      },
    ]
  }
}

variable "calico_load_balancer_pools" {
  description = "LoadBalancer-only IPPools (allowedUses LoadBalancer). Retired pools stay declared with disabled = true, because Calico's pool CIDR is immutable."
  type = list(object({
    name     = string
    cidr     = string
    disabled = optional(bool, false)
  }))
  default = [
    {
      name = "lb-internal-routed"
      cidr = "fd97:45c2:b3a1:f00::1:0/112"
    },
    {
      name = "lb-ingress-routed"
      cidr = "2607:3640:1064:27f::1:0/112"
    },
  ]
}

variable "calico_default_deny_policy" {
  description = <<-EOT
    Render the deny-app-policy GlobalNetworkPolicy: deny all ingress and egress
    for pods outside exempt_namespaces except DNS egress to kube-dns. Off by
    default because enabling it on a running cluster cuts off every workload
    in a non-exempt namespace until it gets its own allow policy.
  EOT
  type = object({
    enabled           = optional(bool, false)
    exempt_namespaces = optional(list(string), ["calico-apiserver", "calico-system", "kube-node-lease", "kube-public", "kube-system", "tigera-operator"])
  })
  default = {}
}

# --- Talos cluster shape ---

variable "apid_allowed_prefixes" {
  description = "IPv6 prefixes allowed to reach apid (50000/tcp), in addition to the bgp-net subnet itself. Must include wherever tofu/talosctl runs from: nodes boot into an unauthenticated maintenance API and have their config pushed to them from here."
  type        = list(string)
  default     = ["fd97:45c2:b3a1:101::/64", "fd92:b792:95e:db94::/64"]
}

variable "cluster_name" {
  description = "Talos/Kubernetes cluster name."
  type        = string
  default     = "talos"
}

variable "talos_version" {
  description = "Exact Talos release to boot (e.g. v1.14.0). Drives the Image Factory download and the machine config's contract version -- see talos.tf."
  type        = string
  default     = "v1.14.1"
}

variable "kubernetes_version" {
  description = "Kubernetes version to bootstrap. Keep in sync with the Kubernetes version bundled by talos_version (v1.14.0 bundles v1.37.0)."
  type        = string
  default     = "v1.37.0"
}

variable "calico_version" {
  description = "Calico release (git tag, e.g. v3.31.0) whose manifests/tigera-operator.yaml is added to the cluster's extraManifests."
  type        = string
  default     = "v3.31.0"
}

variable "pod_subnet" {
  description = <<-EOT
    IPv6 CIDR for the in-cluster pod overlay network. Must be IPv6 -- see
    talos.tf's cluster.network config patch for why: kube-apiserver
    refuses to start at all if the service subnet's address family
    doesn't match the node's own (confirmed live, 2026-09-17). Any
    private range works since this is purely an internal overlay; a ULA
    prefix distinct from the bgp-net subnet is used here just to keep node
    addressing and pod addressing visually unambiguous.
  EOT
  type        = string
  default     = "fd10:244::/56"
}

variable "service_subnet" {
  description = "IPv6 CIDR for in-cluster Kubernetes Services. See pod_subnet -- same reasoning, kept smaller (/112) matching the conventional size of the default IPv4 10.96.0.0/12 service range."
  type        = string
  default     = "fd10:96::/112"
}

variable "cni_name" {
  description = <<-EOT
    Talos's cluster.network.cni.name: "flannel" (Talos's own default),
    "custom" (supply your own manifest URLs -- not wired up here), or
    "none" to skip installing any CNI at all. Defaults to "none" here
    on the assumption a bare-minimum cluster is meant to have its real
    CNI (e.g. Cilium) installed deliberately afterward, not Flannel by
    default. With "none", nodes come up Ready but pods that aren't
    host-network (CoreDNS included) stay Pending/ContainerCreating
    until a CNI is applied.
  EOT
  type        = string
  default     = "none"

  validation {
    condition     = contains(["flannel", "custom", "none"], var.cni_name)
    error_message = "cni_name must be \"flannel\", \"custom\", or \"none\"."
  }
}

variable "controlplane_count" {
  description = "Number of control-plane nodes. Keep this odd (etcd quorum): 3 tolerates one node down."
  type        = number
  default     = 3

  validation {
    condition     = var.controlplane_count % 2 == 1 && var.controlplane_count >= 1
    error_message = "controlplane_count must be a positive odd number (etcd quorum)."
  }
}

variable "worker_count" {
  description = "Number of dedicated worker nodes."
  type        = number
  default     = 3

  validation {
    condition     = var.worker_count >= 0
    error_message = "worker_count must be >= 0."
  }
}

variable "schedule_on_controlplanes" {
  description = "Whether workloads may run on the control-plane nodes (Talos's cluster.allowSchedulingOnControlPlanes). Off by default now that there are dedicated workers; turn on if worker_count = 0."
  type        = bool
  default     = false

  validation {
    # Talos moved this to a generation-time option
    # (generate.Options.AllowSchedulingOnControlPlanes) that this provider's
    # talos_machine_configuration data source doesn't expose (see talos.tf's
    # common_config_patches). Flipping this to true would need a
    # KubeNodeConfig.taints patch clearing the auto-added control-plane
    # NoSchedule taint instead, which isn't implemented yet -- fail loudly
    # rather than silently ignore the setting.
    condition     = !var.schedule_on_controlplanes
    error_message = "schedule_on_controlplanes = true is not currently wired up in talos.tf; see this variable's comment."
  }
}

variable "reboot_after_first_config" {
  description = "Reboot each node once after its first machine config is pushed, to drop the SLAAC address the kernel formed during the pre-config maintenance-mode boot (see talos.tf). Needs talosctl on the machine running tofu. Turn off if the SLAAC address is prevented some other way, e.g. an ipv6.autoconf=0 kernel argument in the image."
  type        = bool
  default     = true
}

variable "controlplane_flavor" {
  description = "Compute flavor for each control-plane node. 2 vCPU / 2GiB is Talos's documented controlplane floor; 4GiB here since 2GiB is known to be tight once etcd + the control-plane static pods + kubelet + CoreDNS are all resident."
  type = object({
    vcpus = number
    ram   = number
    disk  = number
  })
  default = {
    vcpus = 2
    ram   = 4096
    disk  = 20
  }
}

variable "worker_flavor" {
  description = "Compute flavor for each worker node."
  type = object({
    vcpus = number
    ram   = number
    disk  = number
  })
  default = {
    vcpus = 2
    ram   = 4096
    disk  = 20
  }
}

# --- Barbican KMS key ---

variable "create_kms_key" {
  description = "Create a Barbican symmetric key for encrypting the cluster's secrets (e.g. Kubernetes secrets at rest via a KMS provider). Its Barbican secret ID is exposed as the kms_key_id output."
  type        = bool
  default     = false
}

variable "kms_key_name" {
  description = "Name of the Barbican secret. Defaults to \"<cluster_name>-secrets-kms\"."
  type        = string
  default     = null
}

variable "kms_key_bit_length" {
  description = "Bit length of the AES key. 256 gives AES-256."
  type        = number
  default     = 256

  validation {
    condition     = contains([128, 192, 256], var.kms_key_bit_length)
    error_message = "kms_key_bit_length must be 128, 192, or 256."
  }
}

variable "kms_plugin_version" {
  description = "Tag of registry.k8s.io/provider-os/barbican-kms-plugin to run on the control-plane nodes (cloud-provider-openstack release; KMS v2 support is required)."
  type        = string
  default     = "v1.36.0"
}

variable "occm_version" {
  description = "openstack-cloud-controller-manager release (git tag, e.g. v1.36.0) whose manifests/controller-manager/*.yaml are added to the cluster's extraManifests. Pinned rather than master so the DaemonSet image doesn't change underneath a rebuild."
  type        = string
  default     = "v1.36.0"
}

variable "cinder_csi_version" {
  description = "cloud-provider-openstack release (git tag, e.g. v1.36.0) whose manifests/cinder-csi-plugin/*.yaml are added to the cluster's extraManifests."
  type        = string
  default     = "v1.36.0"
}

variable "cinder_storage_classes" {
  description = <<-EOT
    StorageClasses for provisioner cinder.csi.openstack.org, keyed by name.
    The defaults match the upstream cinder-csi-plugin chart (a Delete and a
    Retain class, neither the cluster default, no parameters). At most one
    class should set is_default. parameters are passed straight to the driver
    (e.g. type = "<cinder volume type>", availability = "<az>").
  EOT
  type = map(object({
    reclaim_policy         = string
    is_default             = optional(bool, false)
    allow_volume_expansion = optional(bool, true)
    volume_binding_mode    = optional(string, "Immediate")
    parameters             = optional(map(string), {})
  }))
  default = {
    "csi-cinder-sc-delete" = { reclaim_policy = "Delete" }
    "csi-cinder-sc-retain" = { reclaim_policy = "Retain" }
  }

  validation {
    condition     = length([for sc in values(var.cinder_storage_classes) : sc if sc.is_default]) <= 1
    error_message = "At most one cinder_storage_classes entry may set is_default."
  }
  validation {
    condition     = alltrue([for sc in values(var.cinder_storage_classes) : contains(["Delete", "Retain"], sc.reclaim_policy)])
    error_message = "cinder_storage_classes[*].reclaim_policy must be Delete or Retain."
  }
}

variable "cinder_availability_zone" {
  description = "Cinder availability zone set as the `availability` parameter on every cinder_storage_classes entry. A class can override it through its own parameters. Empty omits the parameter."
  type        = string
  default     = "pcd-ce-lab"
}
