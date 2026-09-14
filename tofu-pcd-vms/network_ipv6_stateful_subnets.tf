resource "ssh_resource" "ipv6_dhcpv6_stateful_subnet_create" {
  for_each = var.ipv6_dhcpv6_stateful_subnets

  host    = var.pcd_hostname
  user    = var.pcd_ssh_username
  agent   = true
  timeout = "2m"
  retry_delay = "10s"
  when    = "create"

  file {
    destination = "/tmp/ipv6_dhcpv6_stateful_subnet_create_${each.key}.sh"
    content     = <<-EOT
      #!/bin/bash
      set -euo pipefail
      source /root/openstackrc
      openstack subnet show ${each.key} >/dev/null 2>&1 && exit 0
      openstack subnet create ${each.key} --network ${pcd_networking_network.default[each.value.network_name].id} --subnet-range ${each.value.cidr} --ip-version 6 --gateway ${each.value.gateway_ip} --ipv6-ra-mode dhcpv6-stateful --ipv6-address-mode dhcpv6-stateful --dns-publish-fixed-ip ${join(" ", [for p in each.value.allocation_pools : "--allocation-pool start=${p.start},end=${p.end}"])} ${join(" ", [for ns in each.value.dns_nameservers : "--dns-nameserver ${ns}"])}
    EOT
    permissions = "0755"
  }

  commands = [
    "sudo /tmp/ipv6_dhcpv6_stateful_subnet_create_${each.key}.sh",
  ]
}

# Not resource-managed - see the ipv6_dhcpv6_stateful_subnets variable for why.
data "pcd_networking_subnet" "ipv6_dhcpv6_stateful" {
  for_each = var.ipv6_dhcpv6_stateful_subnets

  name       = each.key
  network_id = pcd_networking_network.default[each.value.network_name].id

  depends_on = [ssh_resource.ipv6_dhcpv6_stateful_subnet_create]
}
