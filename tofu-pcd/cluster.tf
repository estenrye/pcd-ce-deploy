resource "pcd_cluster" "main" {
  name = var.cluster_name

  auto_resource_rebalancing = {
    enabled = true
    rebalancing_frequency_mins = 20
    rebalancing_strategy = "vm_workload_consolidation"
  }

  vm_high_availability = {
    enabled = false # single host — nowhere to fail a VM over to
  }
}

# The MS-A2 head node, onboarded as the (currently only) hypervisor.
resource "pcd_host_cluster_role" "hypervisor" {
  host_id      = var.host_id_pcd-ce-hyp-01
  role         = "hypervisor"
  host_cluster = pcd_cluster.main.name

  # Blocks until the host reports role_status = ok, so it's actually
  # schedulable by the time `tofu apply` finishes.
  wait_until_converged = true

  depends_on = [pcd_host_config_assignment.pcd-ce-hyp-01]
}

resource "pcd_host_cluster_role" "image_library" {
  host_id = var.host_id_pcd-ce-hyp-01
  role    = "image-library"

  depends_on = [pcd_host_config_assignment.pcd-ce-hyp-01]
}

resource "pcd_host_cluster_role" "storage" {
  host_id  = var.host_id_pcd-ce-hyp-01
  role     = "persistent-storage"
  backends = [var.compute_volumes_backend_name]

  depends_on = [pcd_host_config_assignment.pcd-ce-hyp-01]
}
