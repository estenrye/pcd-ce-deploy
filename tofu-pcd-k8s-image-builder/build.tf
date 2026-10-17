# One terraform_data per image. Re-runs (replaces) only when something that
# changes the image changes: the resolved Kubernetes patch, the OS, the
# image-builder ref or the extra Packer variables. The image name encodes the
# same inputs, and build.sh skips a build whose name already exists in Glance.
#
# Images are deliberately NOT tofu-managed Glance resources: existing PCD-K
# clusters reference them, so a rebuild must add a new image next to the old
# one and `tofu destroy` must leave them alone. Nothing here ever deletes one.
resource "terraform_data" "build" {
  for_each = var.builder_enabled ? local.images : {}

  triggers_replace = {
    name = each.value.name
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      # Packer variables for this build (image-builder's PACKER_VAR_FILES).
      PACKER_VARS = jsonencode(each.value.packer_vars)

      # Credentials for the builder's `openstack image create`. Sent over the
      # ssh channel's stdin (not a command line), and removed by build.sh on
      # exit. They are also in this state file, the same tradeoff the
      # onepassword_item data source already makes for the provider.
      ENV_FILE = <<-EOT
        OS_AUTH_URL=${var.pcd_auth_url}
        OS_IDENTITY_API_VERSION=3
        OS_REGION_NAME=${var.pcd_region}
        OS_USERNAME='${data.onepassword_item.pcd_admin.username}'
        OS_PASSWORD='${data.onepassword_item.pcd_admin.password}'
        OS_PROJECT_NAME=${var.pcd_tenant_name}
        OS_USER_DOMAIN_ID=${var.pcd_user_domain_id}
        OS_PROJECT_DOMAIN_ID=${var.pcd_project_domain_id}
        OS_INTERFACE=${var.glance_interface}
%{ if var.glance_endpoint_override != null ~}
        OS_IMAGE_ENDPOINT_OVERRIDE=${var.glance_endpoint_override}
%{ endif ~}
      EOT

      BUILD_SCRIPT = templatefile("${path.module}/files/build.sh.tftpl", {
        key               = each.key
        image_name        = each.value.name
        os                = each.value.os
        os_version        = "${substr(each.value.os, 7, 2)}.${substr(each.value.os, 9, 2)}"
        semver            = each.value.semver
        minor             = each.value.minor
        visibility        = var.image_visibility
        image_builder_ref = each.value.ref
        default_ref       = var.image_builder_ref
        parallel_builds   = var.parallel_builds
        ssh_wait_minutes  = var.ssh_wait_minutes
      })
    }

    # The build takes over an hour, and a workstation ssh session that long
    # does get dropped (a reset killed one at the end of a successful build).
    # So it runs detached on the builder and this just polls for its exit
    # code, tolerating ssh hiccups. The script's own flock makes a re-run
    # while a build is still going wait for it, then find the image already
    # in Glance.
    command = <<-EOT
      set -euo pipefail
      printf '%s\n' "$PACKER_VARS" | ${local.builder_ssh} 'cat > packer-vars-${each.key}.json'
      printf '%s\n' "$ENV_FILE"    | ${local.builder_ssh} 'umask 077; cat > .build-${each.key}.env'
      printf '%s\n' "$BUILD_SCRIPT" | ${local.builder_ssh} 'cat > build-${each.key}.sh; chmod 755 build-${each.key}.sh'
      ${local.builder_ssh} 'rm -f build-${each.key}.rc; setsid nohup bash -c "./build-${each.key}.sh > build-${each.key}.out 2>&1; echo \$? > build-${each.key}.rc" > /dev/null 2>&1 < /dev/null &'
      while true; do
        sleep 30
        rc=$(${local.builder_ssh} 'cat build-${each.key}.rc 2>/dev/null' 2>/dev/null || true)
        [ -n "$rc" ] && break
      done
      ${local.builder_ssh} 'tail -n 40 build-${each.key}.out' || true
      exit "$rc"
    EOT
  }

  depends_on = [terraform_data.builder_ready]
}
