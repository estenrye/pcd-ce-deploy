# Authenticates via the 1Password desktop app (biometric/system unlock)
# rather than a static service account token — see README.md.
provider "onepassword" {
  account = var.onepassword_account
}

# A 1Password "API Credential" item holding the TrueNAS API key: its
# `credential` field is read directly below.
data "onepassword_item" "truenas_api_key" {
  vault = var.onepassword_vault
  title = var.onepassword_item_title
}

provider "truenas" {
  url      = var.truenas_url
  api_key  = data.onepassword_item.truenas_api_key.credential
  username = var.truenas_username
}
