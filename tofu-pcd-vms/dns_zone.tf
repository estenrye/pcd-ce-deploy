resource "pcd_dns_zone" "default" {
  for_each = var.dns_zones

  name        = each.key
  description = each.value.description
  email       = each.value.email
  ttl         = each.value.ttl
  type        = each.value.type
  masters     = each.value.masters
}

resource "ssh_resource" "network_dns_zone_association_create" {
  for_each = var.network_dns_zone_associations

  host    = var.pcd_hostname
  user    = var.pcd_ssh_username
  agent   = true
  timeout = "2m"
  retry_delay = "10s"
  when    = "create"

  file {
    destination = "/tmp/dns_zone_association_create_${each.key}.sh"
    content     = <<-EOT
      #!/bin/bash
      set -euo pipefail
      source /root/openstackrc
      openstack network set --dns-domain ${pcd_dns_zone.default[each.value.dns_zone_name].name} ${pcd_networking_network.default[each.key].id}
    EOT
    permissions = "0755"
  }
  
  commands = [
    "sudo /tmp/dns_zone_association_create_${each.key}.sh",
  ]
}

resource "ssh_resource" "network_dns_zone_association_destroy" {
  for_each = var.network_dns_zone_associations

  host    = var.pcd_hostname
  user    = var.pcd_ssh_username
  agent   = true
  timeout = "2m"
  retry_delay = "10s"
  when    = "destroy"

  file {
    destination = "/tmp/dns_zone_association_destroy_${each.key}.sh"
    content     = <<-EOT
      #!/bin/bash
      set -euo pipefail
      source /root/openstackrc
      openstack network set --dns-domain="" ${pcd_networking_network.default[each.key].id}
    EOT
    permissions = "0755"
  }

  commands = [
    "sudo /tmp/dns_zone_association_destroy_${each.key}.sh",
  ]
}