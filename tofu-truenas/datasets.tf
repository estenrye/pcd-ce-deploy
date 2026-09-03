resource "truenas_dataset" "nova" {
  pool = var.pool_name
  name = var.nova_dataset_name

  compression = "LZ4"
  atime       = "OFF"
  share_type  = "NFS"
  comments    = "PCD CE Cinder (block storage) NFS backend"
}

resource "truenas_dataset" "glance" {
  pool = var.pool_name
  name = var.glance_dataset_name

  compression = "LZ4"
  atime       = "OFF"
  share_type  = "NFS"
  comments    = "PCD CE Glance (image library) NFS backend"
}
