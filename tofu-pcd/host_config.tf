# Maps traffic types to NICs on the host. This lab runs everything over a
# single interface (see README.md hardware notes: MS-A2 head node), so every
# traffic type shares host_mgmt_interface.
resource "pcd_host_config" "default" {
  for_each = var.host_configs

  name = each.key
  cluster_name = each.value.cluster_name

  mgmt_interface           = each.value.mgmt_interface
  vm_console_interface     = each.value.vm_console_interface
  tunneling_interface      = each.value.tunneling_interface
  imagelib_interface       = each.value.imagelib_interface
  live_migration_interface = each.value.live_migration_interface
  host_liveness_interface  = each.value.host_liveness_interface

  network_labels = each.value.network_labels
}

resource "pcd_host_config_assignment" "default" {
  for_each = var.host_config_mappings
  host_id        = each.value.id
  host_config_id = pcd_host_config.default[each.value.host_config_name].id
}
