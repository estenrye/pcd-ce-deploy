onepassword_account = "ryefamily.1password.com"
onepassword_vault = "Home_Lab"
onepassword_item_title = "PCD Community - pcd.rye.ninja"
pcd_auth_url = "https://pcd.rye.ninja/keystone/v3"

cluster_name = "pcd-ce-lab"
dns_domain_name = "usmnblm01.rye.ninja."
vn_enabled = true
vn_underlay_type = "vlan"
vn_id_range = "1000:2000"

image_library_backend_name = "truenas-nfs-glance"
image_library_configuration_name = "truenas-glance"
compute_volumes_backend_name = "truenas-nfs-nova"
compute_volumes_configuration_name = "truenas-nova"

host_configs = {
    hc-pcd-ce-lab = {
        cluster_name = "pcd-ce-lab"
        mgmt_interface = "bond0"
        vm_console_interface = "bond0"
        tunneling_interface = "bond0"
        imagelib_interface = "bond0"
        live_migration_interface = "bond0"
        host_liveness_interface = "bond0"
        network_labels = {
            physnet1 = "bond0"
        }
    }
}

host_config_mappings = {
    "pcd-ce-hyp-01" = {
        id = "c0de6fb7-4ca6-49f4-a3f7-e9799e5e1816"
        host_config_name = "hc-pcd-ce-lab"
    }
}

host_cluster_hypervisor_role_mappings = {
    "pcd-ce-hyp-01" = "pcd-ce-lab"
}

host_cluster_image_library_role_mappings = {
    "pcd-ce-hyp-01" = "pcd-ce-lab"
}

host_cluster_storage_role_mappings = {
    "pcd-ce-hyp-01" = "pcd-ce-lab"
}

host_cluster_dns_role_mappings = {
    "pcd-ce-hyp-01" = "pcd-ce-lab"
}

storage_backends_json = {
    "truenas-nfs-glance" = {
      "truenas-glance" = {
        config = {
          nas_secure_file_operations  = false
          nas_secure_file_permissions = false
          nfs_mount_point_base        = "/opt/pf9/etc/pf9-cindervolume-base/volumes/glance"
          nfs_mount_points            = "10.45.0.2:/mnt/flash-pool/pcd-ce-glance"
          nfs_shares_config           = "/opt/pf9/etc/pf9-cindervolume-base/conf.d/nfs_shares_glance"
          nfs_snapshot_support        = true
        }
        driver = "NFS"
      }
    },
    "truenas-nfs-nova" = {
      "truenas-nova" = {
        config = {
          nas_secure_file_operations  = false
          nas_secure_file_permissions = false
          nfs_mount_point_base        = "/opt/pf9/etc/pf9-cindervolume-base/volumes/nova"
          nfs_mount_points            = "10.45.0.2:/mnt/flash-pool/pcd-ce-nova"
          nfs_shares_config           = "/opt/pf9/etc/pf9-cindervolume-base/conf.d/nfs_shares_nova"
          nfs_snapshot_support        = true
        }
        driver = "NFS"
      }
    }
}

pdns4_credential_items = {
    "https://pdns4-shim.rye.ninja:443" : {
        vault = "controlplane"
        title = "pdns4-shim.rye.ninja"
    }
}

dns_role_pool_configurations = {
    "10.45.60.1" = {
        ssh_username    = "automation-user"
        designate_pools = [
            {
                name        = "default"
                description = "Cloudflare via pdns4-shim and external-dns"
                attributes  = {}
                ns_records  = [
                    {
                        hostname = "ns1.pcd-ce-lab.usmnblm01.rye.ninja."
                        priority = 1
                    }
                ]
                nameservers = [
                    {
                        host = "fd97:45c2:b3a1:f00::9280"
                        port = 53
                    }
                ]
                targets = [
                    {
                        type        = "pdns4"
                        description = "pdns4-shim"
                        masters = [
                            {
                                host = "10.45.0.1"
                                port = 53
                            }
                        ]
                        options = {
                            host         = "10.45.60.1"
                            port         = 53
                            api_endpoint = "https://pdns4-shim.rye.ninja:443"
                            api_token    = "example_token"
                            # rndc_host    = "10.45.60.1"
                            # rndc_port    = 953
                            # rndc_key_file = "/etc/rndc.key"
                        }
                    }
                ]
            }
        ]
    }
}