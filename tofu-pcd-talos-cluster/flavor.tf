resource "pcd_compute_flavor" "controlplane" {
  name  = "${var.cluster_name}-controlplane"
  vcpus = var.controlplane_flavor.vcpus
  ram   = var.controlplane_flavor.ram
  disk  = var.controlplane_flavor.disk
}

resource "pcd_compute_flavor" "worker" {
  name  = "${var.cluster_name}-worker"
  vcpus = var.worker_flavor.vcpus
  ram   = var.worker_flavor.ram
  disk  = var.worker_flavor.disk
}
