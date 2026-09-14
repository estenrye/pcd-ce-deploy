resource "pcd_networking_router" "vlan1000" {
  name                = "vlan1000-router"
  external_network_id = pcd_networking_network.default["external-net"].id
  enable_snat         = true
}

resource "pcd_networking_router_interface" "vlan1000_v6" {
  router_id = pcd_networking_router.vlan1000.id
  subnet_id = data.pcd_networking_subnet.ipv6_dhcpv6_stateful["vlan1000-subnet-v6"].id
}
