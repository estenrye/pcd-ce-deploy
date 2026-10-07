# StorageClasses for the Cinder CSI driver (installed via extraManifests in
# talos.tf), modelled on the upstream chart's templates/storageclass.yaml.
# Delivered as Talos inlineManifests next to the Calico objects, so applying
# them needs no Kubernetes API access from tofu.
locals {
  cinder_sc_parameters = {
    for name, sc in var.cinder_storage_classes : name => merge(
      var.cinder_availability_zone != "" ? { availability = var.cinder_availability_zone } : {},
      sc.parameters,
    )
  }

  cinder_storage_classes = {
    for name, sc in var.cinder_storage_classes : name => {
      apiVersion = "storage.k8s.io/v1"
      kind       = "StorageClass"
      metadata = merge(
        { name = name },
        sc.is_default ? { annotations = { "storageclass.kubernetes.io/is-default-class" = "true" } } : {},
      )
      provisioner          = "cinder.csi.openstack.org"
      reclaimPolicy        = sc.reclaim_policy
      allowVolumeExpansion = sc.allow_volume_expansion
      volumeBindingMode    = sc.volume_binding_mode
      # The shared availability zone first, so a class's own parameters can
      # still override it. An empty map is omitted, as in the chart.
      parameters = length(local.cinder_sc_parameters[name]) > 0 ? local.cinder_sc_parameters[name] : null
    }
  }

  # Names are sorted by Talos; these sort after the calico-* ones.
  cinder_inline_manifests = {
    for name, m in local.cinder_storage_classes : "cinder-sc-${name}" => yamlencode({
      for k, v in m : k => v if v != null
    })
  }
}

# Every Talos inline manifest (Calico + Cinder StorageClasses).
locals {
  inline_manifests = merge(local.calico_inline_manifests, local.cinder_inline_manifests)
}
