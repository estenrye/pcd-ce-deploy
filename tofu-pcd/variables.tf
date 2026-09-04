variable "pcd_auth_url" {
  description = "Keystone v3 auth URL for the PCD management plane."
  type        = string
  default     = "https://pcd.rye.ninja/keystone/v3"
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
  default     = "Home_Lab"
}

variable "onepassword_item_title" {
  description = "Title of the 1Password Login item holding the PCD admin username/password."
  type        = string
  default     = "PCD Community - pcd.rye.ninja"
}

variable "cluster_name" {
  description = "Name of the PCD cluster blueprint and host cluster."
  type        = string
  default     = "pcd-ce-lab"
}

variable "dns_domain_name" {
  description = "Internal DNS domain suffix for VMs (not the du_fqdn)."
  type        = string
  default     = "usmnblm01.rye.ninja."
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

variable "vm_storage" {
  description = "Path on the hypervisor where instance (ephemeral) disks live."
  type        = string
  default     = "/opt/pf9/etc/pf9-cindervolume-base/volumes/nova/instances"
}

# variable "host_id" {
#   description = <<-EOT
#     resmgr UUID of the MS-A2 host, as shown in the PCD UI under
#     Infrastructure > Hosts (click the host — the UUID is in its detail
#     panel/URL).
#   EOT
#   type        = string
# }

variable "host_mgmt_interface" {
  description = "Name of the NIC on the host that carries management traffic (e.g. from `ip a` on the host)."
  type        = string
  default     = "bond0.0"
}

variable "image_library_backend_name" {
  description = "Name of the Glance backend defined in storage_backends_json, and the value pcd_host_cluster_role.storage.backends references."
  type        = string
  default     = "truenas-nfs-glance"
}

variable "image_library_configuration_name" {
  description = "Name of the Glance backend configuration in the PCD cluster blueprint's storage_backends_json."
  type        = string
  default     = "glance"
}

variable "image_library_nfs_export" {
  description = "NFS export backing the Glance (image library) backend, as host:/path. Produced by ../tofu-truenas (see its glance_nfs_export output)."
  type        = string
  default     = "10.45.60.254:/mnt/flash-pool/pcd-ce-glance"
}

variable "image_library_backend_shared_storage" {
  description = "Whether the image library backend uses shared storage."
  type        = bool
  default     = true
}

variable "compute_volumes_backend_name" {
  description = "Name of the compute volumes backend defined in storage_backends_json, and the value pcd_host_cluster_role.storage.backends references."
  type        = string
  default     = "truenas-nfs-nova"
}

variable "compute_volumes_configuration_name" {
  description = "Name of the compute volumes backend configuration in the PCD cluster blueprint's storage_backends_json."
  type        = string
  default     = "nova"
}

variable "compute_volumes_nfs_export" {
  description = "NFS export backing the compute volumes (block storage) backend, as host:/path. Produced by ../tofu-truenas (see its compute_volumes_nfs_export output)."
  type        = string
  default     = "10.45.60.254:/mnt/flash-pool/pcd-ce-nova"
}

variable "compute_volumes_nfs_mount_point_base" {
  description = "Path on the hypervisor where compute volumes (ephemeral) disks live. Must match the path in the PCD cluster blueprint's vm_storage field."
  type        = string
  default     = "/opt/pf9/etc/pf9-cindervolume-base/volumes/nova"
}

variable "image_library_nfs_mount_point_base" {
  description = "Path on the hypervisor where the image library (Glance) backend stores its files."
  type        = string
  default     = "/opt/pf9/etc/pf9-cindervolume-base/volumes/glance"
}

