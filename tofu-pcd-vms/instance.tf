resource "pcd_compute_instance" "default" {
  for_each = var.compute_instances

  name  = each.key
  image_name  = pcd_images_image.default[each.value.image_name].name
  flavor_name = pcd_compute_flavor.default[each.value.flavor_name].name
  key_pair    = pcd_compute_keypair.default[each.value.key_pair].name
  security_groups = [ for sg in each.value.security_groups : pcd_networking_secgroup.default[sg].name ]
  config_drive = each.value.config_drive

  dynamic "network" {
    for_each = each.value.networks
    content {
      name = network.value
      uuid = pcd_networking_network.default[network.value].id
    }
  }

  # Ports are created implicitly by this resource at instance-boot time, so
  # the network's dns_domain and its subnets' dns_publish_fixed_ip must
  # already be set before that happens - Neutron's external DNS driver
  # skips ports on router:external networks entirely unless a subnet has
  # dns_publish_fixed_ip set, and it only registers a record on port
  # create/update, not retroactively.
  depends_on = [
    ssh_resource.network_dns_zone_association_create,
    ssh_resource.subnet_dns_publish_fixed_ip_enable,
  ]
}

resource "pcd_blockstorage_volume" "default" {
  for_each = var.block_storage_volumes

  name        = each.key
  size        = each.value.size
  volume_type = each.value.volume_type
}

resource "pcd_compute_volume_attach" "default" {
  for_each = var.compute_volume_attachments

  instance_id = pcd_compute_instance.default[each.value.instance_name].id
  volume_id   = pcd_blockstorage_volume.default[each.value.volume_name].id
}
