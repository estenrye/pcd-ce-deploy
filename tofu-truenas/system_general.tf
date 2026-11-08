# System > General (GUI and localization). The truenas provider has no
# resource for system.general, so this applies the settings through the
# TrueNAS REST API (PUT /api/v2.0/system/general, deprecated but present in
# 25.10) whenever the desired values change. Only the fields below are sent;
# the rest of the config (ports, TLS protocols, UI certificate, ...) is left
# alone. Drift made in the UI is not detected until these values change.
#
# Note the web UI restarts when the listen addresses change.
locals {
  truenas_general = {
    ui_address       = var.ui_ipv4_addresses
    ui_v6address     = var.ui_ipv6_addresses
    ui_httpsredirect = true
    ui_consolemsg    = true
    usage_collection = false
    timezone         = var.truenas_timezone
  }
}

resource "terraform_data" "truenas_general" {
  triggers_replace = local.truenas_general

  provisioner "local-exec" {
    # The key goes to curl on stdin as a config line so it never appears in
    # the process list.
    command = <<-EOT
      printf 'header = "Authorization: Bearer %s"\n' "$TRUENAS_API_KEY" |
        curl --fail-with-body --silent --show-error --max-time 60 \
          --config - -X PUT -H 'Content-Type: application/json' \
          --data "$TRUENAS_GENERAL" \
          "$TRUENAS_URL/api/v2.0/system/general" > /dev/null
    EOT
    environment = {
      TRUENAS_API_KEY = local.truenas_api_token
      TRUENAS_URL     = var.truenas_url
      TRUENAS_GENERAL = jsonencode(local.truenas_general)
    }
  }
}
