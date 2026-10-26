# Spegel: a stateless cluster-local registry mirror that serves image layers
# from node to node out of containerd's content store. It needs two things
# outside the chart: containerd must keep unpacked layers (the
# CRICustomizationConfig document in common_config_patches, talos.tf), and nodes must
# allow 5001/tcp between members (cluster_internal_ingress, security_group.tf).
#
# Spegel only ships a Helm chart, so the chart is pre-rendered into
# files/spegel.yaml (values in files/spegel-values.yaml) and delivered as a
# Talos inlineManifest like the Calico and Cinder objects: tofu needs no
# Kubernetes API access, and Talos re-applies it when the contents change.
locals {
  spegel_inline_manifests = {
    spegel = file("${path.module}/files/spegel.yaml")
  }
}
