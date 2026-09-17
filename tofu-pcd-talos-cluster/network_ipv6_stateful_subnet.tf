# Neutron treats ipv6_ra_mode/ipv6_address_mode as immutable after
# creation, and neither the pcd_networking_subnet resource nor `openstack
# subnet set` can set them -- so, same as
# ../tofu-pcd-vms/network_ipv6_stateful_subnets.tf, the subnet is created
# directly via `openstack subnet create` over SSH and looked up with a data
# source instead of being resource-managed. dhcpv6-stateful (rather than
# SLAAC) matters here specifically because the control-plane node's address
# is read back (see instance.tf's pcd_networking_port) and fed into the
# Talos provider as `node` -- SLAAC's client-generated address wouldn't be
# knowable to Terraform ahead of time, but a dhcpv6-stateful lease is
# exactly the fixed_ip Neutron already assigned the port.
#
# --tag: confirmed live, 2026-09-16 -- unifi_ml2_driver only creates a
# UniFi NAT66 masquerade policy for a subnet carrying its exact
# `nat66_tag` (default "nat66=true", see networking-unifi's config.py);
# an untagged IPv6 subnet still gets its VLAN synced and assigned to the
# firewall zone every reconcile pass, but silently never gets NAT66
# egress, which reads as total outbound unreachability from the guest
# (DNS/NTP timeouts) with no error anywhere in the driver's own logs.
# vlan1000-subnet-v6 in ../tofu-pcd-vms only has this because it was
# tagged by hand after the fact -- its network_ipv6_stateful_subnets.tf
# doesn't set it either and should probably get this same fix.
resource "ssh_resource" "talos_subnet_create" {
  host        = var.pcd_hostname
  user        = var.pcd_ssh_username
  agent       = true
  timeout     = "2m"
  retry_delay = "10s"
  when        = "create"

  file {
    destination = "/tmp/talos_subnet_create.sh"
    content     = <<-EOT
      #!/bin/bash
      set -euo pipefail
      source /root/openstackrc
      openstack subnet show ${var.cluster_name}-subnet-v6 >/dev/null 2>&1 && exit 0
      openstack subnet create ${var.cluster_name}-subnet-v6 \
        --network ${pcd_networking_network.talos.id} \
        --subnet-range ${var.subnet_cidr} \
        --ip-version 6 \
        --gateway ${var.subnet_gateway_ip} \
        --ipv6-ra-mode dhcpv6-stateful \
        --ipv6-address-mode dhcpv6-stateful \
        --dns-publish-fixed-ip \
        --allocation-pool start=${var.subnet_allocation_pool.start},end=${var.subnet_allocation_pool.end} \
        --tag ${var.nat66_tag} \
        ${join(" ", [for ns in var.dns_nameservers : "--dns-nameserver ${ns}"])}
    EOT
    permissions = "0755"
  }

  commands = [
    "sudo /tmp/talos_subnet_create.sh",
  ]
}

data "pcd_networking_subnet" "talos" {
  name       = "${var.cluster_name}-subnet-v6"
  network_id = pcd_networking_network.talos.id

  depends_on = [ssh_resource.talos_subnet_create]
}
