resource "pcd_networking_secgroup" "default" {
  for_each = var.security_groups
  name        = each.key
  description = each.value.description
}

resource "pcd_networking_secgroup_rule" "default" {
  for_each = var.security_group_rules
  security_group_id = pcd_networking_secgroup.default[each.value.security_group].id
  description       = each.value.description
  direction         = each.value.direction
  ethertype         = each.value.ethertype
  protocol          = each.value.protocol
  port_range_min    = each.value.port_range_min
  port_range_max    = each.value.port_range_max
  remote_ip_prefix  = each.value.remote_ip_prefix
}
