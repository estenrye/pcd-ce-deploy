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
  default     = "10.45.0.2"
}

variable "nfs_bind_ips" {
  description = <<-EOT
    Addresses the NFS service binds to (TrueNAS nfs.config bindip). These
    must already be assigned to an interface on the NAS. An empty list
    means all addresses.
  EOT
  type        = list(string)
  default     = ["10.45.0.2", "fd97:45c2:b3a1:100::1000"]
}

variable "truenas_username" {
  description = <<-EOT
    Account the API key belongs to. Sent alongside the key during auth so
    the provider keeps working once TrueNAS 27 removes the legacy
    username-less login call. `auth.me` over the API confirms which
    account a given key belongs to.
  EOT
  type        = string
  default     = "truenas_admin"
}

variable "onepassword_vault" {
  description = "1Password vault UUID (or name) holding the TrueNAS API key."
  type        = string
  default     = "Home_Lab"
}

variable "onepassword_item_title" {
  description = "Title of the 1Password 'API Credential' item whose `api_token` field holds the TrueNAS API key."
  type        = string
  default     = "nas.rye.ninja"
}

variable "cloudflare_onepassword_vault" {
  description = "1Password vault UUID (or name) holding the Cloudflare API token used by the ACME DNS authenticator."
  type        = string
  default     = "core-infra"
}

variable "cloudflare_onepassword_item_title" {
  description = "Title of the 1Password item whose `credential` field holds the Cloudflare API token."
  type        = string
  default     = "cloudflare-api-token"
}

variable "ui_ipv4_addresses" {
  description = "IPv4 addresses the TrueNAS web interface listens on (system.general ui_address)."
  type        = list(string)
  default     = ["10.45.0.2"]
}

variable "ui_ipv6_addresses" {
  description = "IPv6 addresses the TrueNAS web interface listens on (system.general ui_v6address)."
  type        = list(string)
  default     = ["fd97:45c2:b3a1:100::1000"]
}

variable "truenas_timezone" {
  description = "System timezone (IANA name). America/Chicago is US Central time."
  type        = string
  default     = "America/Chicago"
}

variable "pool_name" {
  description = "ZFS pool the datasets are created in."
  type        = string
  default     = "flash-pool"
}

variable "apps_pool" {
  description = "ZFS pool that holds TrueNAS Applications (Docker) data."
  type        = string
  default     = "flash-pool"
}

variable "docker_onepassword_vault" {
  description = "1Password vault UUID (or name) holding the Docker Hub registry credentials."
  type        = string
  default     = "github-actions-docker-multiarch-slsa-releaser"
}

variable "docker_onepassword_item_title" {
  description = "Title of the 1Password login item whose `username` and `password` fields hold the Docker Hub credentials."
  type        = string
  default     = "docker-io-registry-pat-github-actions"
}

variable "docker_registry_name" {
  description = "Name of the registry credential entry in TrueNAS Apps."
  type        = string
  default     = "docker.io"
}

variable "docker_registry_uri" {
  description = "Registry URI the credentials apply to."
  type        = string
  default     = "https://index.docker.io/v1/"
}

variable "smb_bind_ips" {
  description = "Addresses the SMB service binds to (smb.config bindip). Must already be assigned to an interface on the NAS."
  type        = list(string)
  default     = ["10.45.0.6", "fd97:45c2:b3a1:100::1004"]
}

variable "smb_onepassword_vault" {
  description = "1Password vault UUID (or name) holding the SMB user logins."
  type        = string
  default     = "nas.rye.ninja"
}

variable "smb_hp_scan_item_title" {
  description = "Title of the 1Password login item for the hp-scan SMB user (`username` and `password` fields)."
  type        = string
  default     = "SMB User - hp-scan"
}

variable "smb_esten_item_title" {
  description = "Title of the 1Password login item for the esten SMB user (`username` and `password` fields)."
  type        = string
  default     = "SMB User - esten"
}

variable "smb_users_group_id" {
  description = <<-EOT
    TrueNAS database ID (not GID) of the builtin_users group (GID 545).
    TrueNAS adds every SMB user to it automatically, so it has to be listed
    explicitly or the provider sees an unplanned membership. The ID is
    assigned per system; look it up under Credentials > Local Groups or via
    GET /api/v2.0/group?group=builtin_users.
  EOT
  type        = number
  default     = 91
}

variable "printer_host" {
  description = "Address of the HP MFP's embedded web server, used to configure Scan to Network Folder."
  type        = string
  default     = "10.0.2.15"
}

variable "files_esten_nfs_extra_networks" {
  description = <<-EOT
    CIDRs allowed to mount the files-esten NFS export in addition to
    nfs_allowed_networks. Every client of that export acts as esten, so keep
    this list tight. Kept separate so the PCD Nova and Glance exports, which
    share nfs_allowed_networks, are not widened.
  EOT
  type        = list(string)
  default     = ["fd97:45c2:b3a1:101::/64"]
}

variable "nova_dataset_name" {
  description = "Name of the dataset backing the PCD Nova (block storage) NFS backend."
  type        = string
  default     = "pcd-ce-nova"
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
    "10.45.0.0/16",
    "fd97:45c2:b3a1:100::/64"
  ]
}

variable "replication_ssh_public_key" {
  description = "Public half of the KVM host's replication key (/root/.ssh/replication_ed25519 on mf-ms-a2-01), installed as the replication user's authorized key. Get it with `sudo ssh-keygen -y -f /root/.ssh/replication_ed25519`."
  type        = string
}

variable "replication_zfs_prefix" {
  description = "Dataset the replication user may receive into and prune snapshots under. One child zvol per replicated VM disk."
  type        = string
  default     = "flash-pool/replication/mf-ms-a2-01.usmnblm01.rye.ninja/vms"
}
