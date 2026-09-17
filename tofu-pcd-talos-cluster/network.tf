resource "pcd_networking_network" "talos" {
  name           = "${var.cluster_name}-net"
  description    = "IPv6-only VLAN network for the ${var.cluster_name} Talos cluster"
  shared         = false
  external       = false
  admin_state_up = true
  tags           = ["tf-managed"]

  segments = [{
    network_type     = "vlan"
    physical_network = var.physical_network
    segmentation_id  = var.vlan_segmentation_id
  }]
}
