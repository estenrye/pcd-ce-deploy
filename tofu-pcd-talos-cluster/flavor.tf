resource "pcd_compute_flavor" "controlplane" {
  # Flavors are immutable in Nova, so the size is part of the name -- see the
  # worker flavor below.
  name  = "${var.cluster_name}-controlplane-${var.controlplane_flavor.vcpus}c-${var.controlplane_flavor.ram}m"
  vcpus = var.controlplane_flavor.vcpus
  ram   = var.controlplane_flavor.ram
  disk  = var.controlplane_flavor.disk

  lifecycle {
    create_before_destroy = true
  }
}

resource "pcd_compute_flavor" "worker" {
  # Flavors are immutable in Nova, so the size is part of the name: a size
  # change yields a new flavor, which changes the instance's flavor_name.
  name  = "${var.cluster_name}-worker-${var.worker_flavor.vcpus}c-${var.worker_flavor.ram}m"
  vcpus = var.worker_flavor.vcpus
  ram   = var.worker_flavor.ram
  disk  = var.worker_flavor.disk

  lifecycle {
    create_before_destroy = true
  }
}
