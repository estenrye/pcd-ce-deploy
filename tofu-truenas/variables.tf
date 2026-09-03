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

variable "truenas_url" {
  description = <<-EOT
    Base URL of the TrueNAS SCALE management/API endpoint, e.g.
    https://nas.rye.ninja. HTTPS required. This is the control-plane
    address the WebSocket JSON-RPC connection is made to — NOT necessarily
    where NFS clients reach the exports (see truenas_nfs_host).
  EOT
  type        = string
  default     = "https://nas.rye.ninja"
}

variable "truenas_nfs_host" {
  description = <<-EOT
    Hostname or IP that NFS clients use to mount these exports — the
    storage-network address of flash-pool, which is not necessarily the
    same interface as truenas_url's management/API endpoint. Used to build
    the cinder_nfs_export/glance_nfs_export outputs.
  EOT
  type        = string
  default     = "10.45.60.254"
}

variable "truenas_username" {
  description = <<-EOT
    Account the API key belongs to. Sent alongside the key during auth so
    the provider keeps working once TrueNAS 27 removes the legacy
    username-less login call. `auth.me` over the API confirms which
    account a given key belongs to.
  EOT
  type        = string
  default     = "admin"
}

variable "onepassword_vault" {
  description = "1Password vault UUID (or name) holding the TrueNAS API key."
  type        = string
  default     = "controlplane"
}

variable "onepassword_item_title" {
  description = "Title of the 1Password 'API Credential' item whose `credential` field holds the TrueNAS API key."
  type        = string
  default     = "truenas-api-key"
}

variable "pool_name" {
  description = "ZFS pool the datasets are created in."
  type        = string
  default     = "flash-pool"
}

variable "cinder_dataset_name" {
  description = "Name of the dataset backing the PCD Cinder (block storage) NFS backend."
  type        = string
  default     = "pcd-ce-cinder"
}

variable "glance_dataset_name" {
  description = "Name of the dataset backing the PCD Glance (image library) NFS backend."
  type        = string
  default     = "pcd-ce-glance"
}

variable "nfs_allowed_networks" {
  description = <<-EOT
    CIDRs allowed to mount the NFS exports: the PCD management VM plus
    hosts 10.45.60.1-3, each listed as a single-host CIDR (IPv4 /32, IPv6
    /128) — TrueNAS rejects entries that normalize to the same subnet as
    "overlapped subnets", which a shared /16 or /64 mask would do here
    since all these hosts sit on the same /16 and /64. Add an entry here
    for any new host that needs to mount these backends.
  EOT
  type        = list(string)
  default = [
    "10.45.45.45/32",
    "fd97:45c2:b3a1:100::dead/128",
    "10.45.60.1/32",
    "fd97:45c2:b3a1:100::2001/128",
    "10.45.60.2/32",
    "fd97:45c2:b3a1:100::2002/128",
    "10.45.60.3/32",
    "fd97:45c2:b3a1:100::2003/128"
  ]
}
