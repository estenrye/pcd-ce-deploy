data "onepassword_item" "pdns4_shim_creds" {
    for_each = var.pdns4_credential_items
    vault = each.value.vault
    title = each.value.title
}

locals {
  dns_role_pool_configurations = {
    for host, config in var.dns_role_pool_configurations : host => merge(config, {
      designate_pools = [
        for pool in config.designate_pools : merge(pool, {
          targets = [
            for target in pool.targets : merge(target, {
              options = {
                for k, v in merge(
                  target.options,
                  target.type == "pdns4" ? {
                    api_token = data.onepassword_item.pdns4_shim_creds[target.options.api_endpoint].credential
                  } : {}
                ) : k => v if v != null
              }
            })
          ]
        })
      ]
    })
  }
}

resource "ssh_resource" "dns_role_pool_configuration" {
  for_each = local.dns_role_pool_configurations

  host    = each.key
  user    = each.value.ssh_username
  agent   = true
  timeout = "2m"
  retry_delay = "10s"

  file {
    destination = "/tmp/designate_pool.yaml"
    permissions = "0600"
    content     = yamlencode(each.value.designate_pools)
  }

  file {
    destination = "/tmp/dns_role_pool_configuration_${each.key}.sh"
    content     = <<-EOT
      #!/bin/bash
      set -euo pipefail
      designate-manage pool update --delete --file /tmp/designate_pool.yaml
    EOT
    permissions = "0755"
  }
  
  commands = [
    "sudo /tmp/dns_role_pool_configuration_${each.key}.sh",
  ]
}
