resource "pcd_networking_network" "default" {
    for_each = var.networks
    name        = each.key
    description = each.value.description
    shared      = each.value.shared
    external    = each.value.external
    admin_state_up = each.value.admin_state_up
    tags        = each.value.tags
    segments = each.value.segments
}

resource "pcd_networking_subnet" "default" {
  for_each = var.network_subnets
  network_id  = pcd_networking_network.default[each.value.network_name].id
  name        = each.key
  cidr        = each.value.cidr
  ip_version  = each.value.ip_version
  gateway_ip  = each.value.gateway_ip
  enable_dhcp = each.value.enable_dhcp

  allocation_pools = each.value.allocation_pools
  dns_nameservers  = each.value.dns_nameservers
}
