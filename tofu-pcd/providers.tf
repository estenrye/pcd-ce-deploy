# Authenticates via the 1Password desktop app (biometric/system unlock)
# rather than a static service account token — see README.md.
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
}
