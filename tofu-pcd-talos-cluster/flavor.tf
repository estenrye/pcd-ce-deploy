resource "pcd_compute_flavor" "controlplane" {
  name  = "${var.cluster_name}-controlplane"
  vcpus = var.controlplane_flavor.vcpus
  ram   = var.controlplane_flavor.ram
  disk  = var.controlplane_flavor.disk
}
