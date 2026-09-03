resource "pcd_blockstorage_volume_type" "image_library" {
  name = "image_library"
  description = "Glance (image library) backend volume type for the PCD cluster."
  is_public = true
  extra_specs = {
    volume_backend_name = var.image_library_backend_name
  }
}

resource "pcd_blockstorage_volume_type" "volume_storage" {
  name = "volume_storage"
  description = "Compute volumes (block storage) backend volume type for the PCD cluster."
  is_public = true
  extra_specs = {
    volume_backend_name = var.compute_volumes_backend_name
  }
}

# PCD supports a single blueprint per region, and the go.pcd.run installer
# (ansible/install-pcd.yml) already created one. Import it before the first
# apply so Tofu adopts the existing blueprint instead of trying to create a
# second one:
#
#   tofu import pcd_cluster_blueprint.main <blueprint_name>
#
# (the blueprint name is the region's cluster name — check the PCD UI under
# Infrastructure > Regions, or run `airctl` on the head node)
resource "pcd_cluster_blueprint" "main" {
  name            = var.cluster_name
  dns_domain_name = var.dns_domain_name

  virtual_networking = {
    enabled       = var.vn_enabled
    underlay_type = var.vn_underlay_type
    vnid_range    = var.vn_id_range
  }

  vm_storage              = "${var.compute_volumes_nfs_mount_point_base}/instances"
  instance_shared_storage = true

  image_library_storage        = "image_library"
  image_library_shared_storage = true

  # STILL BEST-EFFORT: field names below are confirmed against the PCD UI's
  # "Add Volume Backend Configuration" form (Storage Driver=NFS), but the
  # exact wire JSON PCD generates when you submit that form is not — in
  # particular nfs_shares_config's exact path and whether "driver" wants
  # "NFS" or the full cinder.volume.drivers.nfs.NfsDriver class path are
  # still guesses. Preferred path: fill out that form in the UI with
  # Configuration Name = var.cinder_backend_name, save it there, then
  # `tofu import pcd_cluster_blueprint.main <name>` again to pull in the
  # real JSON PCD stored and replace this block with it.
  storage_backends_json = jsonencode({
    (var.image_library_backend_name) = {
      (var.image_library_configuration_name) = {
        config = {
          nas_secure_file_operations  = false
          nas_secure_file_permissions = false
          nfs_mount_point_base        = var.image_library_nfs_mount_point_base
          nfs_mount_points            = var.image_library_nfs_export
          nfs_shares_config           = "/opt/pf9/etc/pf9-cindervolume-base/conf.d/nfs_shares_${var.image_library_configuration_name}"
          nfs_snapshot_support        = true
        },
        driver = "NFS"
      },
    },
    (var.compute_volumes_backend_name) = {
      (var.compute_volumes_configuration_name) = {
        config = {
          nas_secure_file_operations  = false
          nas_secure_file_permissions = false
          nfs_mount_point_base        = var.compute_volumes_nfs_mount_point_base
          nfs_mount_points            = var.compute_volumes_nfs_export
          nfs_shares_config           = "/opt/pf9/etc/pf9-cindervolume-base/conf.d/nfs_shares_${var.compute_volumes_configuration_name}"
          nfs_snapshot_support        = true
        },
        driver = "NFS"
      },
    },
  })
}
