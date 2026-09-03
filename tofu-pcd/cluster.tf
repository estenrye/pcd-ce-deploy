# resource "pcd_cluster" "main" {
#   name = var.cluster_name

#   vm_high_availability = {
#     enabled = false # single host — nowhere to fail a VM over to
#   }
# }

# # The MS-A2 head node, onboarded as the (currently only) hypervisor.
# resource "pcd_host_cluster_role" "hypervisor" {
#   host_id      = var.host_id
#   role         = "hypervisor"
#   host_cluster = pcd_cluster.main.name

#   # Blocks until the host reports role_status = ok, so it's actually
#   # schedulable by the time `tofu apply` finishes.
#   wait_until_converged = true

#   depends_on = [pcd_host_config_assignment.main]
# }

# resource "pcd_host_cluster_role" "image_library" {
#   host_id = var.host_id
#   role    = "image-library"

#   depends_on = [pcd_host_config_assignment.main]
# }

# resource "pcd_host_cluster_role" "storage" {
#   host_id  = var.host_id
#   role     = "persistent-storage"
#   backends = [var.cinder_backend_name]

#   depends_on = [pcd_host_config_assignment.main]
# }
