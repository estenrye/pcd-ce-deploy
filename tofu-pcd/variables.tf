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

variable "cluster_name" {
  description = "Name of the PCD cluster blueprint and host cluster."
  type        = string
  default     = "pcd-ce"
}

variable "dns_domain_name" {
  description = "Internal DNS domain suffix for VMs (not the du_fqdn)."
  type        = string
  default     = "pcd.local."
}

variable "vn_enabled" {
  description = "Whether to enable virtual networking in the PCD cluster blueprint."
  type        = bool
  default     = true
}

variable "vn_underlay_type" {
  description = "VLAN/VNI segmentation type for virtual networking."
  type        = string
  default     = "vlan"
}

variable "vn_id_range" {
  description = "VLAN/VNI segmentation ID range for virtual networking."
  type        = string
  default     = "1000:2000"
}

variable "image_library_backend_name" {
  description = "Name of the Glance backend defined in storage_backends_json, and the value pcd_host_cluster_role.storage.backends references."
  type        = string
  default     = null
}

variable "image_library_configuration_name" {
  description = "Name of the Glance backend configuration in the PCD cluster blueprint's storage_backends_json."
  type        = string
  default     = null
}

variable "compute_volumes_backend_name" {
  description = "Name of the compute volumes backend defined in storage_backends_json, and the value pcd_host_cluster_role.storage.backends references."
  type        = string
  default     = null
}

variable "compute_volumes_configuration_name" {
  description = <<-EOT
    Name of the compute volumes backend configuration in the PCD cluster
    blueprint's storage_backends_json. pf9-cindervolume-config writes this
    name as a top-level section in cinder.conf, so it must not collide with
    a section cinder.conf already reserves for itself (e.g. "nova", which
    is Cinder's own Nova-API auth block) — collision fails config push with
    "Section 'nova' already exists".
  EOT
  type        = string
  default     = null
}

variable "host_configs" {
  description = "Map of host configuration names to their settings."
  type        = map(object({
    cluster_name = string
    mgmt_interface = string
    vm_console_interface     = string
    tunneling_interface      = string
    imagelib_interface       = string
    live_migration_interface = string
    host_liveness_interface  = string
    network_labels = map(string)
  }))
  default     = {}
}

variable "host_config_mappings" {
  description = "Map of host IDs to host configuration names."
  type        = map(object({
    id = string
    host_config_name = string
  }))
  default     = {}
}

variable "host_cluster_hypervisor_role_mappings" {
  description = "Map of host IDs to hypervisor role assignments."
  type        = map(string)
  default     = {}
}

variable "host_cluster_image_library_role_mappings" {
  description = "Map of host IDs to image library role assignments."
  type        = map(string)
  default     = {}
}

variable "host_cluster_storage_role_mappings" {
  description = "Map of host IDs to storage role assignments."
  type        = map(string)
  default     = {}
}

variable "host_cluster_dns_role_mappings" {
  description = "Map of host IDs to DNS role assignments."
  type        = map(string)
  default     = {}
}

variable "storage_backends_json" {
  description = "JSON string describing the storage backends for the PCD cluster blueprint."
  type        = map(map(object({
    config = object({
      nas_secure_file_operations  = bool
      nas_secure_file_permissions = bool
      nfs_mount_point_base        = string
      nfs_mount_points            = string
      nfs_shares_config           = string
      nfs_snapshot_support        = bool
    })
    driver = string
  })))
  default     = {}
}