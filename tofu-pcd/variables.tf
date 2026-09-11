variable "pcd_auth_url" {
  description = "Keystone v3 auth URL for the PCD management plane."
  type        = string
  default     = null
}

variable "pcd_region" {
  description = "PCD region to operate in."
  type        = string
  default     = "Infra"
}

variable "pcd_tenant_name" {
  description = "Project (tenant) the admin user is scoped to."
  type        = string
  default     = "service"
}

variable "pcd_user_domain_id" {
  description = "Keystone domain ID the admin user belongs to."
  type        = string
  default     = "default"
}

variable "pcd_project_domain_id" {
  description = "Keystone domain ID of the scoped project."
  type        = string
  default     = "default"
}

variable "onepassword_account" {
  description = <<-EOT
    1Password account name or ID (as shown in the desktop app's sidebar),
    used for desktop-app authentication instead of a service account
    token — the app must be running, unlocked, and have "Integrate with
    1Password CLI" enabled under Settings > Developer. Can also be left
    unset here and sourced from the OP_ACCOUNT environment variable.
  EOT
  type        = string
  default     = null
}

variable "onepassword_vault" {
  description = "1Password vault UUID (or name) holding the PCD admin credentials."
  type        = string
  default     = null
}

variable "onepassword_item_title" {
  description = "Title of the 1Password Login item holding the PCD admin username/password."
  type        = string
  default     = null
}

variable "cluster_name" {
  description = "Name of the PCD cluster blueprint and host cluster."
  type        = string
  default     = "pcd-ce"
}

variable "dns_domain_name" {
  description = "Internal DNS domain suffix for VMs (not the du_fqdn)."
  type        = string
  default     = "pcd.local."
}

variable "vn_enabled" {
  description = "Whether to enable virtual networking in the PCD cluster blueprint."
  type        = bool
  default     = true
}

variable "vn_underlay_type" {
  description = "VLAN/VNI segmentation type for virtual networking."
  type        = string
  default     = "vlan"
}

variable "vn_id_range" {
  description = "VLAN/VNI segmentation ID range for virtual networking."
  type        = string
  default     = "1000:2000"
}

variable "image_library_backend_name" {
  description = "Name of the Glance backend defined in storage_backends_json, and the value pcd_host_cluster_role.storage.backends references."
  type        = string
  default     = null
}

variable "image_library_configuration_name" {
  description = "Name of the Glance backend configuration in the PCD cluster blueprint's storage_backends_json."
  type        = string
  default     = null
}

variable "compute_volumes_backend_name" {
  description = "Name of the compute volumes backend defined in storage_backends_json, and the value pcd_host_cluster_role.storage.backends references."
  type        = string
  default     = null
}

variable "compute_volumes_configuration_name" {
  description = <<-EOT
    Name of the compute volumes backend configuration in the PCD cluster
    blueprint's storage_backends_json. pf9-cindervolume-config writes this
    name as a top-level section in cinder.conf, so it must not collide with
    a section cinder.conf already reserves for itself (e.g. "nova", which
    is Cinder's own Nova-API auth block) — collision fails config push with
    "Section 'nova' already exists".
  EOT
  type        = string
  default     = null
}

variable "host_configs" {
  description = "Map of host configuration names to their settings."
  type        = map(object({
    cluster_name = string
    mgmt_interface = string
    vm_console_interface     = string
    tunneling_interface      = string
    imagelib_interface       = string
    live_migration_interface = string
    host_liveness_interface  = string
    network_labels = map(string)
  }))
  default     = {}
}

variable "host_config_mappings" {
  description = "Map of host IDs to host configuration names."
  type        = map(object({
    id = string
    host_config_name = string
  }))
  default     = {}
}

variable "host_cluster_hypervisor_role_mappings" {
  description = "Map of host IDs to hypervisor role assignments."
  type        = map(string)
  default     = {}
}

variable "host_cluster_image_library_role_mappings" {
  description = "Map of host IDs to image library role assignments."
  type        = map(string)
  default     = {}
}

variable "host_cluster_storage_role_mappings" {
  description = "Map of host IDs to storage role assignments."
  type        = map(string)
  default     = {}
}

variable "host_cluster_dns_role_mappings" {
  description = "Map of host IDs to DNS role assignments."
  type        = map(string)
  default     = {}
}

variable "storage_backends_json" {
  description = "JSON string describing the storage backends for the PCD cluster blueprint."
  type        = map(map(object({
    config = object({
      nas_secure_file_operations  = bool
      nas_secure_file_permissions = bool
      nfs_mount_point_base        = string
      nfs_mount_points            = string
      nfs_shares_config           = string
      nfs_snapshot_support        = bool
    })
    driver = string
  })))
  default     = {}
}

variable "pdns4_credential_items" {
  description = "OnePassword item containing the PDNS4 shim credentials."
  type        = map(object({
    vault = string
    title = string
  }))
  default     = {}
}

variable "dns_role_pool_configurations" {
  description = "Map of host names to their designate pool configurations."
  type        = map(object({
    ssh_username    = string
    designate_pools = list(object({
      name        = string
      description = string
      attributes  = map(string)
      ns_records  = list(object({
        hostname = string
        priority = number
      }))
      nameservers = list(object({
        host = string
        port = number
      }))
      targets = list(object({
        type = string
        description = optional(string)
        masters = list(object({
          host = string
          port = number
        }))
        options = object({
          host = string
          port = number
          api_endpoint = optional(string, null)
          api_token = optional(string, null)
          rndc_host = optional(string, null)
          rndc_port = optional(number, null)
          rndc_key_file = optional(string, null)
        })
      }))

    }))
  }))
  default     = {}

  validation {
    error_message = "All pool configuration ns_records must have valid hostnames that end in a period."
    condition     = alltrue([
      for host, config in var.dns_role_pool_configurations : alltrue([
        for pool in config.designate_pools : alltrue([
          for ns in pool.ns_records : alltrue([
            can(regex(".*\\.$", ns.hostname))
          ])
        ])
      ])
    ])
  }

  validation {
    error_message = "All pool configuration ns_records must have priorities that are greater than 0."
    condition     = alltrue([
      for host, config in var.dns_role_pool_configurations : alltrue([
        for pool in config.designate_pools : alltrue([
          for ns in pool.ns_records : alltrue([
            ns.priority > 0
          ])
        ])
      ])
    ])
  }

  validation {
    error_message = "All pool configuration nameserver hosts must be valid IP addresses."
    condition     = alltrue([
      for host, config in var.dns_role_pool_configurations : alltrue([
        for pool in config.designate_pools : alltrue([
          for ns in pool.nameservers : alltrue([
            provider::assert-cidr::ip(ns.host)
          ])
        ])
      ])
    ])
  }

  validation {
    error_message = "All pool configuration nameserver ports must be valid numbers between 1 and 65535."
    condition     = alltrue([
      for host, config in var.dns_role_pool_configurations : alltrue([
        for pool in config.designate_pools : alltrue([
          for ns in pool.nameservers : alltrue([
            ns.port > 0 && ns.port <= 65535
          ])
        ])
      ])
    ])
  }

  validation {
    error_message = "All pool configuration target masters hosts must be valid ip addresses."
    condition     = alltrue([
      for host, config in var.dns_role_pool_configurations : alltrue([
        for pool in config.designate_pools : alltrue([
          for target in pool.targets : alltrue([
            for master in target.masters : alltrue([
              provider::assert-cidr::ip(master.host)
            ])
          ])
        ])
      ])
    ])
  }

  validation {
    error_message = "All pool configuration targets must have a valid type.  Valid values include [bind9, pdns4]"
    condition     = alltrue([
      for host, config in var.dns_role_pool_configurations : alltrue([
        for pool in config.designate_pools : alltrue([
          for target in pool.targets : alltrue([
            contains(["bind9", "pdns4"], target.type)
          ])
        ])
      ])
    ])
  }
  
  validation {
    error_message = "All pool configuration target masters ports must be valid numbers between 1 and 65535."
    condition     = alltrue([
      for host, config in var.dns_role_pool_configurations : alltrue([
        for pool in config.designate_pools : alltrue([
          for target in pool.targets : alltrue([
            for master in target.masters : alltrue([
              master.port > 0 && master.port <= 65535
            ])
          ])
        ])
      ])
    ])
  }
  
  validation {
    error_message = "All pool configuration targets have a valid port number (1-65535) in options."
    condition     = alltrue([
      for host, config in var.dns_role_pool_configurations : alltrue([
        for pool in config.designate_pools : alltrue([
          for target in pool.targets : alltrue([
            target.options.port != null && target.options.port > 0 && target.options.port <= 65535
          ])
        ])
      ])
    ])
  }

  validation {
    error_message = "All pool configuration bind9 targets have a valid rndc_port number (1-65535) in options."
    condition     = alltrue([
      for host, config in var.dns_role_pool_configurations : alltrue([
        for pool in config.designate_pools : alltrue([
          for target in pool.targets : alltrue([
            target.type != "bind9" || (
              target.options.rndc_port != null &&
              target.options.rndc_port > 0 &&
              target.options.rndc_port <= 65535
            )
          ])
        ])
      ])
    ])
  }

  validation {
    error_message = "All pool configuration targets have only expected options (type=bind9 ==> [host, port, rndc_host, rndc_port, rndc_key_file]) or (type=pdns4 ==> [host, port, api_endpoint, api_token])"
    condition     = alltrue([
      for host, config in var.dns_role_pool_configurations : alltrue([
        for pool in config.designate_pools : alltrue([
          for target in pool.targets : alltrue([
            (
              target.type == "bind9" &&
              target.options.host != null &&
              target.options.port != null &&
              target.options.rndc_host != null &&
              target.options.rndc_port != null &&
              target.options.rndc_key_file != null &&
              target.options.api_endpoint == null &&
              target.options.api_token == null
            ) || (
              target.type == "pdns4" &&
              target.options.host != null &&
              target.options.port != null &&
              target.options.api_endpoint != null &&
              target.options.api_token != null &&
              target.options.rndc_host == null &&
              target.options.rndc_port == null &&
              target.options.rndc_key_file == null
            )
          ])
        ])
      ])
    ])
  }
}

# The `masters`/`nameservers` addresses `dns_role_pool_configurations`
# points at (see `designate_pdns_pool.tf`) are only useful if
# designate-mdns actually listens there. designate-mdns's `[service:mdns]
# listen` setting is *not* durably configurable by editing
# `/opt/pf9/etc/pf9-designate/designate.conf` directly on the host --
# confirmed live: `pf9-hostd` (Platform9's host agent) reverts that file
# back to the `pf9-designate` resmgr role's own stored settings on its own
# reconciliation cycle (observed within roughly 10-90s of a manual edit,
# restarts notwithstanding). The real, durable source of truth is the role
# settings themselves, held server-side in PCD's resmgr and readable/
# writable via its v1 API (`GET`/`PUT
# .../resmgr/v1/hosts/{host_id}/roles/pf9-designate`) -- confirmed live
# that `GET` returns exactly `{"debug": "True", "listen": "0.0.0.0:5354"}`,
# i.e. this *is* the "designate role json" pf9-designate reads its
# overrides from. The `pcd` provider's own `pcd_host_role` resource can't
# express this: its schema has no settings field at all, and its own doc
# comment says role assignment "applies a role's *default* settings" --
# so `designate_mdns_listener.tf` drives this endpoint directly via
# `null_resource`/`local-exec` instead. See
# `../../pdns4-external-dns-rest-http-cr-shim/docs/specs/
# 2026-09-10-axfr-zone-transfer.md`'s 2026-09-11 amendment for the full
# investigation, and that spec's §2.1 for why `listen: "[::]:5354"` (not
# `"0.0.0.0:5354"` plus a specific IPv6 GUA) is the right value: this
# host's `net.ipv6.bindv6only=0` means the IPv6 wildcard already answers
# IPv4 too, so listing both would have two sockets fighting over the same
# IPv4 wildcard address space on port 5354.
variable "designate_role_overrides" {
  description = "Per-host overrides for the pf9-designate resmgr role's settings (e.g. `listen`), keyed the same as `host_config_mappings` so the corresponding host_id can be looked up. Pushed via a direct PUT to resmgr's v1 API -- see this variable's file-level doc comment for why."
  type        = map(map(string))
  default     = {}

  validation {
    error_message = "Every designate_role_overrides key must also be a key in host_config_mappings, so its resmgr host_id can be resolved."
    condition     = alltrue([
      for host in keys(var.designate_role_overrides) : contains(keys(var.host_config_mappings), host)
    ])
  }
}