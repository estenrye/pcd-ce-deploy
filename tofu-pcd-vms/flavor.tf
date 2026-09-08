resource "pcd_compute_flavor" "default" {
  for_each = var.compute_flavors

  name  = each.key
  vcpus = each.value.vcpus
  ram   = each.value.ram
  disk  = each.value.disk
}