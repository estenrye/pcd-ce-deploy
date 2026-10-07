# Authenticates via the 1Password desktop app (biometric/system unlock)
# rather than a static service account token -- same as ../tofu-pcd-vms.
provider "onepassword" {
  account = var.onepassword_account
}

# A 1Password "Login" item holding the PCD admin credentials: its `username`
# and `password` fields are used directly below.
data "onepassword_item" "pcd_admin" {
  vault = var.onepassword_vault
  title = var.onepassword_item_title
}

provider "pcd" {
  auth_url    = var.pcd_auth_url
  region      = var.pcd_region
  user_name   = data.onepassword_item.pcd_admin.username
  password    = data.onepassword_item.pcd_admin.password
  tenant_name = var.pcd_tenant_name

  user_domain_id    = var.pcd_user_domain_id
  project_domain_id = var.pcd_project_domain_id

  # See ../tofu-pcd-vms/providers.tf -- the glance-cluster endpoint serves a
  # self-signed, per-host cert not in any trust store.
  insecure = true
}

# Stateless: all auth material (client_configuration) is passed explicitly
# into each talos_* resource/data source below, not held by the provider.
provider "talos" {}

# Talos's client cert/key/CA come back base64-encoded (they're meant for
# embedding straight into a kubeconfig file); the kubernetes provider's
# fields want raw PEM instead.
provider "kubernetes" {
  host                   = talos_cluster_kubeconfig.this.kubernetes_client_configuration.host
  client_certificate     = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_certificate)
  client_key             = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_key)
  cluster_ca_certificate = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.ca_certificate)
}
