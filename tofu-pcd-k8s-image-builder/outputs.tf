output "images" {
  description = "Images built (or found already built) by this apply, per kubernetes_versions entry. Look one up with `openstack image show <name>`; images from earlier applies (older patches/refs) stay in Glance and are not listed."
  value = {
    for k, v in local.images : k => {
      name        = v.name
      os          = v.os
      semver      = v.semver
      k8s_version = v.minor
    }
  }
}

output "builder_address" {
  description = "IPv6 address of the builder VM (null when builder_enabled = false)."
  value       = local.builder_address
}

output "builder_instance_id" {
  value = var.builder_enabled ? pcd_compute_instance.builder[0].id : null
}

output "ubuntu_base_image_id" {
  value = pcd_images_image.ubuntu_base.id
}
