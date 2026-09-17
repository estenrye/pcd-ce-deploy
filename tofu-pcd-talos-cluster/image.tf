# No system extensions needed for a bare-minimum cluster, so this
# resolves to Image Factory's well-known "vanilla" schematic ID
# (376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba as of
# this writing) rather than hand-typing it.
resource "talos_image_factory_schematic" "vanilla" {}

data "talos_image_factory_urls" "openstack" {
  talos_version = var.talos_version
  schematic_id  = talos_image_factory_schematic.vanilla.id
  platform      = "openstack"
}

locals {
  # provider 0.11's talos_image_factory_urls has no disk_image_format
  # override (that lands in the still-prerelease 0.12), so
  # urls.disk_image is the OpenStack platform's own default asset --
  # confirmed live to be openstack-$ARCH.raw.xz, an xz-compressed raw
  # disk image (not a tar archive, despite docs.siderolabs.com/talos/v1.9's
  # openstack guide describing a .tar.gz -- that's stale/inaccurate for
  # the current factory.talos.dev). Glance's web-download import stores
  # whatever bytes a URL returns verbatim, with no decompression, so that
  # URL can't be handed to pcd_images_image.image_source_url directly --
  # it's downloaded and decompressed locally instead
  # (terraform_data.talos_image_download, below), and the resulting raw
  # file uploaded via local_file_path.
  talos_image_dir      = "${path.module}/.talos-image"
  talos_image_raw_path = "${local.talos_image_dir}/disk.raw"
}

resource "terraform_data" "talos_image_download" {
  triggers_replace = {
    url = data.talos_image_factory_urls.openstack.urls.disk_image
  }

  provisioner "local-exec" {
    working_dir = path.module
    command     = <<-EOT
      set -euo pipefail
      mkdir -p .talos-image
      if [ ! -s .talos-image/disk.raw ]; then
        curl -fsSL '${data.talos_image_factory_urls.openstack.urls.disk_image}' -o .talos-image/disk.raw.xz
        xz -dkf .talos-image/disk.raw.xz
      fi
    EOT
  }
}

resource "pcd_images_image" "talos" {
  name             = "talos-${var.talos_version}-openstack"
  container_format = "bare"
  disk_format      = "raw"
  local_file_path  = local.talos_image_raw_path
  min_disk_gb      = 5
  visibility       = "private"

  depends_on = [terraform_data.talos_image_download]
}
