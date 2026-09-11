# Pushes `var.designate_role_overrides` to PCD resmgr's low-level v1 API
# (`PUT .../resmgr/v1/hosts/{host_id}/roles/{role_name}`) via local-exec,
# since neither Terraform's `pcd` provider nor its `pcd_host_role`
# resource exposes per-role settings -- see `variables.tf`'s doc comment
# on `designate_role_overrides` for the full "why", and
# `../../pdns4-external-dns-rest-http-cr-shim/docs/specs/
# 2026-09-10-axfr-zone-transfer.md`'s 2026-09-11 amendment for how this
# was discovered (editing `/opt/pf9/etc/pf9-designate/designate.conf`
# directly gets silently reverted by `pf9-hostd`; this role-settings PUT
# is what it reverts *to*).
#
# Idempotent in the sense that matters: the PUT always sends the complete
# desired settings dict, so re-running it (e.g. because some other change
# to the role happened out-of-band) always converges back to
# `var.designate_role_overrides`' value rather than merging/drifting.
# Terraform itself only re-runs this resource when its `triggers` change
# (settings content or the resolved host_id), matching how every other
# apply-on-change resource in this project behaves.
#
# Credentials: fetched fresh from 1Password inside the script (`op read`),
# never threaded through Terraform resource attributes/environment --
# those get persisted into state, and the PCD admin password is
# meaningfully more sensitive than e.g. `designate_pdns_pool.tf`'s pdns4
# api_token (which does end up in state today). `-k`/insecure curl calls
# match `providers.tf`'s own `pcd` provider block ("self-signed... not in
# any trust store").
resource "null_resource" "designate_role_settings" {
  for_each = var.designate_role_overrides

  triggers = {
    host_id       = pcd_host_config_assignment.default[each.key].host_id
    settings_json = jsonencode(each.value)
  }

  provisioner "local-exec" {
    environment = {
      KEYSTONE_AUTH_URL      = var.pcd_auth_url
      RESMGR_BASE_URL        = trimsuffix(var.pcd_auth_url, "/keystone/v3")
      PCD_USER_DOMAIN_ID     = var.pcd_user_domain_id
      PCD_PROJECT_DOMAIN_ID  = var.pcd_project_domain_id
      PCD_TENANT_NAME        = var.pcd_tenant_name
      ONEPASSWORD_VAULT      = var.onepassword_vault
      ONEPASSWORD_ITEM_TITLE = var.onepassword_item_title
      ROLE_NAME              = "pf9-designate"
      HOST_ID                = pcd_host_config_assignment.default[each.key].host_id
      SETTINGS_JSON          = jsonencode(each.value)
    }

    command = <<-EOT
      set -euo pipefail

      username=$(op read "op://$ONEPASSWORD_VAULT/$ONEPASSWORD_ITEM_TITLE/username")
      password=$(op read "op://$ONEPASSWORD_VAULT/$ONEPASSWORD_ITEM_TITLE/password")

      auth_body=$(jq -n \
        --arg username "$username" \
        --arg password "$password" \
        --arg domain_id "$PCD_USER_DOMAIN_ID" \
        --arg project "$PCD_TENANT_NAME" \
        --arg project_domain_id "$PCD_PROJECT_DOMAIN_ID" \
        '{auth: {identity: {methods: ["password"], password: {user: {name: $username, domain: {id: $domain_id}, password: $password}}}, scope: {project: {name: $project, domain: {id: $project_domain_id}}}}}')

      token=$(curl -sk -X POST "$KEYSTONE_AUTH_URL/auth/tokens" \
        -H "Content-Type: application/json" \
        -d "$auth_body" \
        -D - -o /dev/null | grep -i "^X-Subject-Token:" | tr -d '\r\n' | awk '{print $2}')

      if [ -z "$token" ]; then
        echo "ERROR: failed to obtain a Keystone token from $KEYSTONE_AUTH_URL" >&2
        exit 1
      fi

      response_file=$(mktemp)
      trap 'rm -f "$response_file"' EXIT

      status=$(curl -sk -o "$response_file" -w "%%{http_code}" -X PUT \
        -H "X-Auth-Token: $token" \
        -H "Content-Type: application/json" \
        -d "$SETTINGS_JSON" \
        "$RESMGR_BASE_URL/resmgr/v1/hosts/$HOST_ID/roles/$ROLE_NAME")

      body=$(cat "$response_file")
      echo "resmgr PUT $ROLE_NAME on $HOST_ID -> HTTP $status: $body"

      if [ "$status" != "200" ]; then
        echo "ERROR: resmgr role-settings PUT failed (HTTP $status)" >&2
        exit 1
      fi
    EOT
  }
}
