# Existing ACME DNS authenticator (Cloudflare), adopted from the NAS via the
# import block below. Its API token is read from 1Password.
import {
  to = truenas_acme_dns_authenticator.cloudflare
  id = "1"
}

data "onepassword_item" "cloudflare_api_token" {
  vault = var.cloudflare_onepassword_vault
  title = var.cloudflare_onepassword_item_title
}

resource "truenas_acme_dns_authenticator" "cloudflare" {
  name          = "cloudflare"
  authenticator = "cloudflare"

  attributes = {
    api_token = data.onepassword_item.cloudflare_api_token.credential
  }
}
