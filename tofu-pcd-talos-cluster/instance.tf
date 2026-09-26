# Ports are created explicitly (rather than letting pcd_compute_instance's
# `network` block create them implicitly) so each node's assigned IPv6
# address is knowable to Terraform *before* boot -- talos.tf pushes each
# node's machine config to that address, and the control-plane VIP below
# has to be allowed on every control-plane port.

# The control-plane VIP: an unattached port whose only job is to reserve one
# address on bgp-net so Neutron never hands it to anything else. Talos floats
# the address between control-plane nodes itself (machine.network.interfaces
# [].vip, see talos.tf), and it is the cluster_endpoint everything else --
# workers, kubeconfig -- uses, so the API survives losing any one node.
resource "pcd_networking_port" "vip" {
  name        = "${var.cluster_name}-controlplane-vip"
  description = "Reserved address for the Talos control-plane VIP; not attached to any instance."
  network_id  = data.pcd_networking_network.bgp.id

  fixed_ip = [{
    subnet_id = data.pcd_networking_subnet.bgp.id
  }]
}

resource "pcd_networking_port" "controlplane" {
  count = var.controlplane_count

  name       = "${var.cluster_name}-controlplane-${count.index + 1}"
  network_id = data.pcd_networking_network.bgp.id

  fixed_ip = [{
    subnet_id = data.pcd_networking_subnet.bgp.id
  }]

  # Load-balancer VIPs the node announces over BGP, plus the control-plane
  # VIP that Talos moves between these ports, plus the pod pool (see
  # var.pod_pool_cidrs). Without these, port security drops traffic the node
  # forwards for/sources from those addresses. Note
  # the unifi_ml2_driver also appends its own SLAAC address pair to this
  # port (see _authorize_slaac_addresses); the provider doesn't refresh
  # this attribute from the server, so tofu won't show that as drift, but
  # the next apply that changes this list sends *only* these entries and
  # the driver re-adds the SLAAC one on its next 5-minute reconcile.
  allowed_address_pairs = [
    for ip in concat(var.bgp_vip_ranges, var.pod_pool_cidrs, [pcd_networking_port.vip.all_fixed_ips[0]]) : {
      ip_address = ip
    }
  ]

  # No security_group_ids here -- see pcd_networking_port_secgroup_associate.controlplane
  # below. Setting them on the port itself made adding a security group
  # replace the port (new address, new MAC), which changes the machine
  # config's cluster_endpoint.
}

resource "pcd_networking_port_secgroup_associate" "controlplane" {
  count = var.controlplane_count

  port_id = pcd_networking_port.controlplane[count.index].id
  enforce = true

  security_group_ids = [
    pcd_networking_secgroup.talos.id,
    pcd_networking_secgroup.http.id,
    data.pcd_networking_secgroup.bgp.id,
  ]
}

resource "pcd_networking_port" "worker" {
  count = var.worker_count

  name       = "${var.cluster_name}-worker-${count.index + 1}"
  network_id = data.pcd_networking_network.bgp.id

  fixed_ip = [{
    subnet_id = data.pcd_networking_subnet.bgp.id
  }]

  # Workers announce the load-balancer VIPs over BGP too (Calico advertises
  # service LB IPs from every node), and route pod traffic, so they need the
  # same pairs as the control-plane ports -- minus the control-plane VIP,
  # which never lands here.
  allowed_address_pairs = [
    for cidr in concat(var.bgp_vip_ranges, var.pod_pool_cidrs) : {
      ip_address = cidr
    }
  ]
}

resource "pcd_networking_port_secgroup_associate" "worker" {
  count = var.worker_count

  port_id = pcd_networking_port.worker[count.index].id
  enforce = true

  security_group_ids = [
    pcd_networking_secgroup.talos.id,
    pcd_networking_secgroup.http.id,
    data.pcd_networking_secgroup.bgp.id,
  ]
}

# The nodes' subnet is IPv6-only, so each port's sole fixed IP is its address.
locals {
  controlplane_addresses = [for p in pcd_networking_port.controlplane : p.all_fixed_ips[0]]
  worker_addresses       = [for p in pcd_networking_port.worker : p.all_fixed_ips[0]]
  cluster_vip            = pcd_networking_port.vip.all_fixed_ips[0]
  cluster_endpoint       = "https://[${local.cluster_vip}]:6443"

  # Not a machine config -- see pcd_compute_instance.controlplane.
  maintenance_user_data = "#cloud-config\n"
}

resource "pcd_compute_instance" "controlplane" {
  count = var.controlplane_count

  name        = "${var.cluster_name}-controlplane-${count.index + 1}"
  image_name  = pcd_images_image.talos.name
  flavor_name = pcd_compute_flavor.controlplane.name

  # No key_pair -- Talos has no SSH/shell, so there's nothing to inject a
  # key into. Management is entirely over apid (talosctl).
  #
  # No top-level security_groups -- that argument only takes effect when
  # Nova creates the port itself; ours is pre-created above with its own
  # security_group_ids.
  # The node's only NIC (eth0 inside Talos), on bgp-net.
  network {
    port = pcd_networking_port.controlplane[count.index].id
  }

  # The machine config is pushed over apid by
  # talos_machine_configuration_apply (talos.tf), so reconfiguring never
  # replaces the instance. The config drive is needed because this network
  # is IPv6-only, so the IPv4 metadata endpoint isn't reachable: Talos's
  # OpenStack platform reads network_data.json from it to get the node's
  # address, route and DNS (and DHCPv6) before there is any machine config.
  #
  # user_data must not be empty, though. Confirmed live 2026-09-26 (Talos
  # v1.14.0): with no user_data file, the platform's configFromCD returns
  # ErrNoConfigSource even though it read network_data.json, the network
  # config is then never applied, and Talos falls back to the (unreachable)
  # IPv4 metadata URL forever -- the node boots with only DHCPv4 and no
  # address. A "#cloud-config" body is the platform's own signal for "this
  # is not a machine config" (it returns ErrNoConfigSource for it in
  # Configuration()), so the node applies the drive's network config and
  # then waits in maintenance mode for the real config. Constant, so it
  # never forces replacement.
  config_drive = true
  user_data    = local.maintenance_user_data
}

resource "pcd_compute_instance" "worker" {
  count = var.worker_count

  name        = "${var.cluster_name}-worker-${count.index + 1}"
  image_name  = pcd_images_image.talos.name
  flavor_name = pcd_compute_flavor.worker.name

  network {
    port = pcd_networking_port.worker[count.index].id
  }

  # See pcd_compute_instance.controlplane for why this drive carries a
  # placeholder user_data.
  config_drive = true
  user_data    = local.maintenance_user_data
}
