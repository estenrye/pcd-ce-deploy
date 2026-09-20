# The bgp-net network, its subnet, and the allow-bgp-icmp security group are
# all owned by ../tofu-pcd-vms (see its terraform.tfvars) -- looked up here
# by name rather than duplicated, so that root must be applied first. The
# group only permits BGP (tcp/179) and ICMPv6 to/from the network's gateway,
# fd97:45c2:b3a1:1179::1, so the node can peer with the UDM-SE.
data "pcd_networking_network" "bgp" {
  name = var.bgp_network_name
}

data "pcd_networking_subnet" "bgp" {
  name       = var.bgp_subnet_name
  network_id = data.pcd_networking_network.bgp.id
}

data "pcd_networking_secgroup" "bgp" {
  name = var.bgp_secgroup_name
}

resource "pcd_networking_port" "controlplane_bgp" {
  name       = "${var.cluster_name}-controlplane-bgp"
  network_id = data.pcd_networking_network.bgp.id

  fixed_ip = [{
    subnet_id = data.pcd_networking_subnet.bgp.id
  }]

  security_group_ids = [data.pcd_networking_secgroup.bgp.id]
}
