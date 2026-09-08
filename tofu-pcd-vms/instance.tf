resource "pcd_compute_instance" "default" {
  for_each = var.compute_instances

  name  = each.key
  image_name  = each.value.image_name
  flavor_name = each.value.flavor_name
  key_pair    = pcd_compute_keypair.default[each.value.key_pair].name
  security_groups = [ for sg in each.value.security_groups : pcd_networking_secgroup.default[sg].name ]

  dynamic "network" {
    for_each = each.value.networks
    content {
      name = network.value
      uuid = pcd_networking_network.default[network.value].id
    }
  }
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
