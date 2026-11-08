# Authenticates via the 1Password desktop app (biometric/system unlock)
# rather than a static service account token — see README.md.
provider "onepassword" {
  account = var.onepassword_account
}

# A 1Password item holding the TrueNAS API key in a field labelled
# `api_token`. Custom fields are only exposed under `section` blocks (an
# unnamed section for fields outside any named one), so look the field up
# by label across all sections.
data "onepassword_item" "truenas_api_key" {
  vault = var.onepassword_vault
  title = var.onepassword_item_title
}

locals {
  truenas_api_token = one([
    for f in flatten([for s in data.onepassword_item.truenas_api_key.section : s.field]) :
    f.value if f.label == "api_token"
  ])
}

provider "truenas" {
  url      = var.truenas_url
  api_key  = local.truenas_api_token
  username = var.truenas_username
}
