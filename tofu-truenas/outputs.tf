output "nova_nfs_export" {
  description = "NFS export path for the Nova backend, for use in PCD's cluster blueprint storage_backends_json."
  value       = "${var.truenas_nfs_host}:${truenas_dataset.nova.mount_point}"
}

output "glance_nfs_export" {
  description = "NFS export path for the Glance (image library) backend, for use in PCD's cluster blueprint image_library_storage."
  value       = "${var.truenas_nfs_host}:${truenas_dataset.glance.mount_point}"
}
