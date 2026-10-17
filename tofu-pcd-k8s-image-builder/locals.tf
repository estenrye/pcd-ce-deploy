# Latest patch of each minor that doesn't pin one.
data "http" "stable" {
  for_each = { for k, v in var.kubernetes_versions : k => v if v.patch == null }

  url = "https://dl.k8s.io/release/stable-${each.value.minor}.txt"

  lifecycle {
    postcondition {
      condition     = self.status_code == 200 && can(regex("^v${replace(each.value.minor, ".", "\\.")}\\.[0-9]+$", trimspace(self.response_body)))
      error_message = "dl.k8s.io has no stable release for Kubernetes ${each.value.minor}."
    }
  }
}

locals {
  # Short form of an image-builder ref for image names: a full commit SHA
  # is shortened, a tag is used as-is.
  ref_label = { for k, v in var.kubernetes_versions :
    k => (can(regex("^[0-9a-f]{40}$", coalesce(v.image_builder_ref, var.image_builder_ref))) ?
      substr(coalesce(v.image_builder_ref, var.image_builder_ref), 0, 7) :
    coalesce(v.image_builder_ref, var.image_builder_ref))
  }

  # Non-empty extra_packer_vars get a short hash in the name so a build with
  # different variables is a new image instead of being skipped as "exists".
  extra_label = length(var.extra_packer_vars) == 0 ? "" : "-${substr(sha256(jsonencode(var.extra_packer_vars)), 0, 6)}"

  builds = {
    for k, v in var.kubernetes_versions : k => {
      minor  = v.minor
      os     = v.os
      ref    = coalesce(v.image_builder_ref, var.image_builder_ref)
      semver = v.patch != null ? "v${v.patch}" : trimspace(data.http.stable[k].response_body)
    }
  }

  # Everything image-builder needs, per build. Passed with PACKER_VAR_FILES
  # rather than by editing image-builder's own config/*.json. The four
  # kubernetes_* variables are coupled and must agree.
  images = {
    for k, b in local.builds : k => merge(b, {
      name = "${b.os}-kube-${b.semver}-${local.ref_label[k]}${local.extra_label}"
      packer_vars = merge({
        kubernetes_semver      = b.semver
        kubernetes_series      = "v${b.minor}"
        kubernetes_deb_version = "${trimprefix(b.semver, "v")}-${var.kubernetes_deb_revision}"
        kubernetes_rpm_version = trimprefix(b.semver, "v")
        boot_wait              = var.boot_wait
        cpus                   = tostring(var.build_vm.cpus)
        memory                 = tostring(var.build_vm.memory_mb)
      }, var.extra_packer_vars)
    })
  }
}
