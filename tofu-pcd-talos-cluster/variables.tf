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

# --- Cluster network ---
# Its own VLAN network + IPv6-only dhcpv6-stateful subnet, separate from
# vlan1000-net in ../tofu-pcd-vms. neutron-ml2-guardian (deployed once,
# cluster-wide, by ../tofu-pcd-vms/neutron_ml2_guardian.tf) watches every
# VLAN network on physnet1 and syncs it to the UDM-SE -- NAT66 egress and
# firewall-zone membership -- with no per-network configuration needed
# here. See ../docs/pcd-cd/ipv6.md and
# ../../neutron-ml2-guardian/docs/specs/2026-09-13-neutron-ml2-guardian-design.md.

variable "physical_network" {
  description = "Physical network label (as mapped in the PCD host config's network_labels) to create the cluster's VLAN segment on."
  type        = string
  default     = "physnet1"
}

variable "vlan_segmentation_id" {
  description = "VLAN ID for the cluster network's provider segment. Must not collide with another VLAN network on the same physical_network (vlan1000-net in ../tofu-pcd-vms uses 1000)."
  type        = number
  default     = 1001
}

variable "subnet_cidr" {
  description = "IPv6 ULA CIDR for the cluster subnet. Defaults to a /64 matching vlan_segmentation_id, following ../tofu-pcd-vms/terraform.tfvars's fd97:45c2:b3a1:<vlan-id>::/64 convention."
  type        = string
  default     = "fd97:45c2:b3a1:1001::/64"
}

variable "subnet_gateway_ip" {
  description = "Gateway address within subnet_cidr (the UDM-SE, once neutron-ml2-guardian syncs this network)."
  type        = string
  default     = "fd97:45c2:b3a1:1001::1"
}

variable "subnet_allocation_pool" {
  description = "DHCPv6 allocation range within subnet_cidr."
  type = object({
    start = string
    end   = string
  })
  default = {
    start = "fd97:45c2:b3a1:1001::2"
    end   = "fd97:45c2:b3a1:1001:ffff:ffff:ffff:ffff"
  }
}

variable "nat66_tag" {
  description = <<-EOT
    Subnet tag that marks this IPv6 subnet for NAT66 masquerade egress.
    Must match unifi_ml2_driver's own `nat66_tag` config option (default,
    and the driver's default: "nat66=true") -- an IPv6 subnet without
    this exact tag still gets synced to UniFi and assigned to the
    firewall zone, but never gets a NAT66 policy, which is
    indistinguishable from the outside from total outbound
    unreachability. See network_ipv6_stateful_subnet.tf.
  EOT
  type        = string
  default     = "nat66=true"
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

# --- Talos cluster shape ---

variable "cluster_name" {
  description = "Talos/Kubernetes cluster name."
  type        = string
  default     = "talos"
}

variable "talos_version" {
  description = "Exact Talos release to boot (e.g. v1.14.0). Drives the Image Factory download and the machine config's contract version -- see talos.tf."
  type        = string
  default     = "v1.14.0"
}

variable "kubernetes_version" {
  description = "Kubernetes version to bootstrap. Keep in sync with the Kubernetes version bundled by talos_version (v1.14.0 bundles v1.37.0)."
  type        = string
  default     = "v1.37.0"
}

variable "pod_subnet" {
  description = <<-EOT
    IPv6 CIDR for the in-cluster pod overlay network. Must be IPv6 -- see
    talos.tf's cluster.network config patch for why: kube-apiserver
    refuses to start at all if the service subnet's address family
    doesn't match the node's own (confirmed live, 2026-09-17). Any
    private range works since this is purely an internal overlay; a ULA
    prefix distinct from subnet_cidr is used here just to keep node
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

variable "controlplane_flavor" {
  description = "Compute flavor for the single control-plane node. 2 vCPU / 2GiB is Talos's documented controlplane floor; bumped to 4GiB here since this node also runs workloads (allowSchedulingOnControlPlanes) and 2GiB is known to be tight once etcd + the control-plane static pods + kubelet + CoreDNS are all resident."
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
