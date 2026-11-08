resource "truenas_service" "nfs" {
  service = "nfs"
  enable  = true
}

# Restrict the NFS server to listening on the storage-network addresses
# rather than every interface (including the management one).
resource "truenas_nfs_config" "this" {
  bindip = var.nfs_bind_ips

  depends_on = [truenas_service.nfs]
}

# maproot_user/group = root: PCD's Cinder and Glance services write to these
# exports as root inside their own containers. Without root-squash mapped
# away, NFS's default root-squash would leave them unable to create/chown
# volumes and images on the share.
resource "truenas_share_nfs" "nova" {
  path    = truenas_dataset.nova.mount_point
  comment = "PCD CE Nova backend"
  enabled = true

  networks = var.nfs_allowed_networks

  maproot_user  = "root"
  maproot_group = "wheel"

  depends_on = [truenas_service.nfs]
}

resource "truenas_share_nfs" "glance" {
  path    = truenas_dataset.glance.mount_point
  comment = "PCD CE Glance backend"
  enabled = true

  networks = var.nfs_allowed_networks

  maproot_user  = "root"
  maproot_group = "wheel"

  depends_on = [truenas_service.nfs]
}
