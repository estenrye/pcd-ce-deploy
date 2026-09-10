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

resource "pcd_host_cluster_role" "hypervisor" {
  for_each = var.host_cluster_hypervisor_role_mappings
  host_id      = pcd_host_config_assignment.default[each.key].host_id
  role         = "hypervisor"
  host_cluster = each.value

  # Blocks until the host reports role_status = ok, so it's actually
  # schedulable by the time `tofu apply` finishes.
  wait_until_converged = false
}

resource "pcd_host_cluster_role" "image_library" {
  for_each = var.host_cluster_image_library_role_mappings
  host_id      = pcd_host_config_assignment.default[each.key].host_id
  role         = "image-library"
}

resource "pcd_host_cluster_role" "storage" {
  for_each = var.host_cluster_storage_role_mappings
  host_id  = pcd_host_config_assignment.default[each.key].host_id
  role     = "persistent-storage"
  backends = [var.compute_volumes_configuration_name, var.image_library_configuration_name]
}

resource "pcd_host_cluster_role" "dns" {
  for_each = var.host_cluster_dns_role_mappings
  host_id  = pcd_host_config_assignment.default[each.key].host_id
  role     = "dns"
}