resource "pcd_images_image" "ubuntu_base" {
  name             = var.base_image_name
  container_format = "bare"
  disk_format      = "qcow2"
  image_source_url = var.base_image_url
  min_disk_gb      = 5
  visibility       = "private"
}
