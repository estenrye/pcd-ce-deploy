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
  # (terraform_data.talos_image_download, below), and the resulting file
  # uploaded via local_file_path.
  #
  # The decompressed raw disk is ~4.4GB but almost entirely zeros (the
  # download is ~230MB), and uploading that over a weak Wi-Fi link took
  # ~1 hour and then failed (nginx in front of Glance answered 408/400
  # when the stream stalled -- 2026-09-21). So the raw file is converted to
  # a compressed qcow2 with qemu-img and *that* is what gets uploaded.
  talos_image_dir        = "${path.module}/.talos-image"
  talos_image_raw_path   = "${local.talos_image_dir}/disk.raw"
  talos_image_qcow2_path = "${local.talos_image_dir}/disk.qcow2"
}

resource "terraform_data" "talos_image_download" {
  triggers_replace = {
    url = data.talos_image_factory_urls.openstack.urls.disk_image
    # Bump when the produced artifact changes so this re-runs.
    format = "qcow2-compressed"
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
      # Always rebuilt when this runs (it only runs on a URL/format change),
      # so a stale qcow2 from an older Talos version can't be uploaded.
      # -c compresses; the zero-filled raw disk shrinks to a few hundred MB.
      qemu-img convert -f raw -O qcow2 -c .talos-image/disk.raw .talos-image/disk.qcow2
    EOT
  }
}

resource "pcd_images_image" "talos" {
  name             = "talos-${var.talos_version}-openstack"
  container_format = "bare"
  disk_format      = "qcow2"
  local_file_path  = local.talos_image_qcow2_path
  min_disk_gb      = 5
  visibility       = "private"

  depends_on = [terraform_data.talos_image_download]
}
