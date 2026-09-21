# Created explicitly (rather than letting pcd_compute_instance's `network`
# block create one implicitly) so the assigned IPv6 address is knowable to
# Terraform *before* boot -- data.talos_machine_configuration needs it for
# cluster_endpoint, and it's what the talos provider connects to below.
resource "pcd_networking_port" "controlplane" {
  name       = "${var.cluster_name}-controlplane"
  network_id = data.pcd_networking_network.bgp.id

  fixed_ip = [{
    subnet_id = data.pcd_networking_subnet.bgp.id
  }]

  # Load-balancer VIPs the node announces over BGP. Without these, port
  # security drops traffic the node forwards for/sources from those
  # addresses. Note the unifi_ml2_driver also appends its own SLAAC
  # address pair to this port (see _authorize_slaac_addresses); the
  # provider doesn't refresh this attribute from the server, so tofu
  # won't show that as drift, but the next apply that changes this list
  # sends *only* these entries and the driver re-adds the SLAAC one on
  # its next 5-minute reconcile.
  allowed_address_pairs = [
    for cidr in var.bgp_vip_ranges : {
      ip_address = cidr
    }
  ]

  # No security_group_ids here -- see pcd_networking_port_secgroup_associate.controlplane
  # below. Setting them on the port itself made adding a security group
  # replace the port (new address, new MAC), which changes the machine
  # config's cluster_endpoint and so rebuilds the node.
}

resource "pcd_networking_port_secgroup_associate" "controlplane" {
  port_id = pcd_networking_port.controlplane.id
  enforce = true

  security_group_ids = [
    pcd_networking_secgroup.talos.id,
    pcd_networking_secgroup.http.id,
    data.pcd_networking_secgroup.bgp.id,
  ]
}

locals {
  # The subnet is IPv6-only, so this is the port's sole fixed IP.
  controlplane_address = pcd_networking_port.controlplane.all_fixed_ips[0]
}

resource "pcd_compute_instance" "controlplane" {
  name        = "${var.cluster_name}-controlplane-1"
  image_name  = pcd_images_image.talos.name
  flavor_name = pcd_compute_flavor.controlplane.name

  # No key_pair -- Talos has no SSH/shell, so there's nothing to inject a
  # key into. Management is entirely over apid (talosctl), configured via
  # user_data below.
  #
  # No top-level security_groups -- that argument only takes effect when
  # Nova creates the port itself; ours is pre-created above with its own
  # security_group_ids.
  # The node's only NIC (eth0 inside Talos), on bgp-net.
  network {
    port = pcd_networking_port.controlplane.id
  }

  # Same reason as ../tofu-pcd-vms/terraform.tfvars's workload-vm: this
  # network is IPv6-only, so the IPv4 metadata endpoint isn't reachable --
  # user_data (the Talos machine config) has to arrive via config drive.
  config_drive = true
  user_data    = data.talos_machine_configuration.controlplane.machine_configuration
}
