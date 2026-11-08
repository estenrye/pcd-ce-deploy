# Applications (Docker) storage pool. The truenas provider has no resource
# for docker.config, so this sets the pool through the TrueNAS REST API
# (PUT /api/v2.0/docker, a job) when var.apps_pool changes, then waits for
# the Apps service to come up (the PUT is an async job, so the status reads
# UNCONFIGURED/DEPLOYING for a while first). Choosing the pool creates its ix-apps dataset.
# Only the pool is sent; address pools, registry mirrors and the rest of the
# config are left alone. Drift made in the UI is not detected.
resource "terraform_data" "apps_pool" {
  triggers_replace = var.apps_pool

  # The pool must exist before Apps can use it.
  depends_on = [terraform_data.truenas_general]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    # The key goes to curl on stdin as a config line so it never appears in
    # the process list.
    command = <<-EOT
      set -euo pipefail
      api() {
        printf 'header = "Authorization: Bearer %s"\n' "$TRUENAS_API_KEY" |
          curl --fail-with-body --silent --show-error --max-time 60 \
            --config - -H 'Content-Type: application/json' "$@"
      }
      current=$(api "$TRUENAS_URL/api/v2.0/docker" |
        python3 -c 'import json,sys; print(json.load(sys.stdin)["pool"] or "")')
      if [ "$current" != "$APPS_POOL" ]; then
        api -X PUT --data "{\"pool\": \"$APPS_POOL\"}" "$TRUENAS_URL/api/v2.0/docker" > /dev/null
      fi
      for _ in $(seq 1 60); do
        status=$(api "$TRUENAS_URL/api/v2.0/docker/status" |
          python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')
        case "$status" in
          RUNNING) exit 0 ;;
          STOPPED|CRASHED) echo "Apps status: $status" >&2; exit 1 ;;
        esac
        sleep 5
      done
      echo "timed out waiting for Apps to start (status: $status)" >&2
      exit 1
    EOT
    environment = {
      TRUENAS_API_KEY = local.truenas_api_token
      TRUENAS_URL     = var.truenas_url
      APPS_POOL       = var.apps_pool
    }
  }
}

# Docker Hub credentials for Applications (Apps > Settings > Registry
# credentials), used to pull images with an authenticated, higher rate limit.
# The username and PAT come from a 1Password login item. The provider has no
# resource for app.registry, so this creates the entry, or updates it by name
# if present, through the REST API (/api/v2.0/app/registry) whenever the
# credentials or registry URI change.
data "onepassword_item" "docker_registry" {
  vault = var.docker_onepassword_vault
  title = var.docker_onepassword_item_title
}

resource "terraform_data" "docker_registry" {
  triggers_replace = sensitive([
    var.docker_registry_name,
    var.docker_registry_uri,
    sha256("${data.onepassword_item.docker_registry.username}:${data.onepassword_item.docker_registry.password}"),
  ])

  depends_on = [terraform_data.apps_pool]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      api() {
        printf 'header = "Authorization: Bearer %s"\n' "$TRUENAS_API_KEY" |
          curl --fail-with-body --silent --show-error --max-time 60 \
            --config - -H 'Content-Type: application/json' "$@"
      }
      body=$(python3 -c '
      import json, os
      print(json.dumps({
          "name": os.environ["REGISTRY_NAME"],
          "description": "Managed by OpenTofu",
          "username": os.environ["REGISTRY_USERNAME"],
          "password": os.environ["REGISTRY_PASSWORD"],
          "uri": os.environ["REGISTRY_URI"],
      }))')
      id=$(api "$TRUENAS_URL/api/v2.0/app/registry" | python3 -c '
      import json, os, sys
      name = os.environ["REGISTRY_NAME"]
      print(next((str(r["id"]) for r in json.load(sys.stdin) if r["name"] == name), ""))')
      if [ -n "$id" ]; then
        api -X PUT --data "$body" "$TRUENAS_URL/api/v2.0/app/registry/id/$id" > /dev/null
      else
        api -X POST --data "$body" "$TRUENAS_URL/api/v2.0/app/registry" > /dev/null
      fi
    EOT
    environment = {
      TRUENAS_API_KEY   = local.truenas_api_token
      TRUENAS_URL       = var.truenas_url
      REGISTRY_NAME     = var.docker_registry_name
      REGISTRY_URI      = var.docker_registry_uri
      REGISTRY_USERNAME = data.onepassword_item.docker_registry.username
      REGISTRY_PASSWORD = data.onepassword_item.docker_registry.password
    }
  }
}
