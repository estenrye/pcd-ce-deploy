# Maps traffic types to NICs on the host. This lab runs everything over a
# single interface (see README.md hardware notes: MS-A2 head node), so every
# traffic type shares host_mgmt_interface.
resource "pcd_host_config" "dell_r610" {
  name = "hc-${pcd_cluster_blueprint.main.name}"
  cluster_name = pcd_cluster_blueprint.main.name

  mgmt_interface           = var.host_mgmt_interface
  vm_console_interface     = var.host_mgmt_interface
  tunneling_interface      = var.host_mgmt_interface
  imagelib_interface       = var.host_mgmt_interface
  live_migration_interface = var.host_mgmt_interface
  host_liveness_interface  = var.host_mgmt_interface

  network_labels = {
    physnet1 = var.host_mgmt_interface
  }
}

resource "pcd_host_config_assignment" "pcd-ce-hyp-01" {
  host_id        = var.host_id_pcd-ce-hyp-01
  host_config_id = pcd_host_config.dell_r610.id
}
