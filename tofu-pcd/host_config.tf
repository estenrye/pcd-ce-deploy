# # Maps traffic types to NICs on the host. This lab runs everything over a
# # single interface (see README.md hardware notes: MS-A2 head node), so every
# # traffic type shares host_mgmt_interface.
# resource "pcd_host_config" "main" {
#   name = "hc-${var.cluster_name}"

#   mgmt_interface           = var.host_mgmt_interface
#   vm_console_interface     = var.host_mgmt_interface
#   tunneling_interface      = var.host_mgmt_interface
#   imagelib_interface       = var.host_mgmt_interface
#   live_migration_interface = var.host_mgmt_interface
#   host_liveness_interface  = var.host_mgmt_interface

#   network_labels = {
#     physnet1 = var.host_mgmt_interface
#   }
# }

# resource "pcd_host_config_assignment" "main" {
#   host_id        = var.host_id
#   host_config_id = pcd_host_config.main.id
# }
