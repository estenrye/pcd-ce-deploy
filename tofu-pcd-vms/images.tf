resource "pcd_images_image" "cirros" {
  for_each = var.compute_images
  
  name             = each.key
  container_format = each.value.container_format
  disk_format      = each.value.disk_format
  image_source_url = each.value.source_url
  min_disk_gb      = each.value.min_disk
  visibility       = each.value.visibility
}