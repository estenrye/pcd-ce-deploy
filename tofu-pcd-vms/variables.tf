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
    token — the app must be running, unlocked, and have "Integrate with
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

variable "external_network_inteface_name" {
  description = "Name of the external network interface on the PCD cluster hosts."
  type        = string
  default     = "physnet1"
}

variable "compute_ssh_key_pairs" {
  description = "Map of SSH key pair names to public keys for compute VMs."
  type        = map(string)
  default     = {}
}

variable "compute_flavors" {
  description = "Map of flavor names to their vCPU, RAM, and disk sizes."
  type        = map(object({
    vcpus = number
    ram   = number
    disk  = number
  }))
  default     = {}
}

variable "compute_images" {
  description = "Map of image names to their source URLs for compute VMs."
  type        = map(object({
    container_format = optional(string, "bare")
    disk_format      = optional(string, "qcow2")
    min_disk         = optional(number, 1)
    visibility        = optional(string, "public")
    source_url = string
  }))
  default     = {}
}

variable "security_groups" {
  description = "Map of security groups to create for compute VMs."
  type        = map(object({
    description = string
  }))
  default     = {}
}

variable "security_group_rules" {
  description = "Map of security group rules to create for compute VMs."
  type        = map(object({
    description    = optional(string)
    security_group = string
    direction      = string
    ethertype      = string
    protocol       = string
    port_range_min = optional(number)
    port_range_max = optional(number)
    remote_ip_prefix = optional(string)
  }))
  default     = {}

  validation {
    condition = alltrue([
      for sgr in values(var.security_group_rules) : contains(["IPv4", "IPv6"], sgr.ethertype)
    ])
    error_message = "All security group rule ethertypes must be either 'IPv4' or 'IPv6'."
  }

  validation {
    condition = alltrue([
      for sgr in values(var.security_group_rules) : contains(["ingress", "egress"], sgr.direction)
    ])
    error_message = "All security group rule directions must be either 'ingress' or 'egress'."
  }

  validation {
    condition = alltrue([
      for sgr in values(var.security_group_rules) : (
        sgr.ethertype == "IPv6" && provider::assert-cidr::cidrv6(sgr.remote_ip_prefix) ||
        sgr.ethertype == "IPv4" && provider::assert-cidr::cidrv4(sgr.remote_ip_prefix)
      )
    ])
    error_message = "All security group rule remote_ip_prefix values must be valid IP addresses according to their ethertype."
  }

  validation {
    condition = alltrue([
      for sgr in values(var.security_group_rules) : (
        (sgr.protocol == "tcp" 
          && sgr.port_range_min != null 
          && sgr.port_range_max != null 
          && sgr.port_range_min <= sgr.port_range_max
          && sgr.port_range_min >= 1
          && sgr.port_range_max >= 1
          && sgr.port_range_min <= 65535
          && sgr.port_range_max <= 65535) ||
        (sgr.protocol == "udp"
          && sgr.port_range_min != null
          && sgr.port_range_max != null
          && sgr.port_range_min <= sgr.port_range_max
          && sgr.port_range_min >= 1
          && sgr.port_range_max >= 1
          && sgr.port_range_min <= 65535
          && sgr.port_range_max <= 65535) ||
        (sgr.protocol == "icmp"
          && sgr.port_range_min == null
          && sgr.port_range_max == null
          && sgr.ethertype == "IPv4") ||
        (sgr.protocol == "ipv6-icmp"
          && sgr.port_range_min == null
          && sgr.port_range_max == null
          && sgr.ethertype == "IPv6")
      )
    ])
    error_message = "For TCP and UDP protocols, port_range_min and port_range_max must be specified between 1 and 65535. For ICMP, they must not be specified.  For IPv6 ICMP, the protocol must be 'ipv6-icmp' and ethertype must be 'IPv6'."
  }
}

variable "networks" {
  description = "Map of network names to their configuration for compute VMs."
  type        = map(object({
    description    = optional(string)
    external       = optional(bool, false)
    shared         = optional(bool, false)
    admin_state_up = optional(bool, true)
    tags           = optional(list(string), [])
    segments = optional(list(object({
      network_type     = string
      physical_network = optional(string)
      segmentation_id  = optional(number)
    })), [])
  }))
  default     = {}
}

variable "network_subnets" {
  description = "Map of network subnet configurations for compute VMs."
  type        = map(object({
    network_name    = string
    cidr            = string
    ip_version      = number
    gateway_ip      = optional(string)
    enable_dhcp     = optional(bool, true)
    allocation_pools = optional(list(object({
      start = string
      end   = string
    })), [])
    dns_nameservers = optional(list(string), [])
  }))
  default     = {}
}

variable "compute_instances" {
  description = "Map of compute instance names to their image, flavor, and network configuration."
  type        = map(object({
    image_name  = string
    flavor_name = string
    key_pair    = string
    security_groups = optional(list(string))
    networks     = optional(list(string))
  }))
  default     = {}
}

variable "block_storage_volumes" {
  description = "Map of block storage volume names to their size and type."
  type        = map(object({
    size        = number
    volume_type = string
  }))
  default     = {}
}

variable "compute_volume_attachments" {
  description = "Map of compute instance names to the block storage volumes to attach."
  type        = map(object({
    instance_name = string
    volume_name   = string
  }))
  default     = {}
}