# Created explicitly (rather than letting pcd_compute_instance's `network`
# block create one implicitly) so the assigned IPv6 address is knowable to
# Terraform *before* boot -- data.talos_machine_configuration needs it for
# cluster_endpoint, and it's what the talos provider connects to below.
resource "pcd_networking_port" "controlplane" {
  name       = "${var.cluster_name}-controlplane"
  network_id = pcd_networking_network.talos.id

  fixed_ip = [{
    subnet_id = data.pcd_networking_subnet.talos.id
  }]

  security_group_ids = [pcd_networking_secgroup.talos.id]
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
  network {
    port = pcd_networking_port.controlplane.id
  }

  # Same reason as ../tofu-pcd-vms/terraform.tfvars's workload-vm: this
  # network is IPv6-only, so the IPv4 metadata endpoint isn't reachable --
  # user_data (the Talos machine config) has to arrive via config drive.
  config_drive = true
  user_data    = data.talos_machine_configuration.controlplane.machine_configuration

  depends_on = [ssh_resource.talos_subnet_create]
}
