onepassword_account = "ryefamily.1password.com"
onepassword_vault = "Home_Lab"
onepassword_item_title = "PCD Community - pcd.rye.ninja"
pcd_hostname = "pcd.rye.ninja"
pcd_auth_url = "https://pcd.rye.ninja/keystone/v3"
pcd_ssh_username = "ubuntu"
pcd_region = "Infra"
pcd_tenant_name = "service"
pcd_user_domain_id = "default"
pcd_project_domain_id = "default"

external_network_inteface_name = "physnet1"

compute_ssh_key_pairs = {
    "esten-personal" = "ecdsa-sha2-nistp521 AAAAE2VjZHNhLXNoYTItbmlzdHA1MjEAAAAIbmlzdHA1MjEAAACFBABRrM38w/r7E5eHrD5eeQ0tU5sNlpseYO3s0kKKf0tbYIOsGW52ofUBzzx2/3PoAANOX/rZIwk6DmmiQxPizKeF6QCZuHrzknDHNHtg2JNWlsh24zNI9OjX8e+bB1oPE8y/PQPXPA8hrf7RZhU0wb3Ld4I6tOpcdiimlOI4sYmPgITmKA== esten@MacBook-Pro",
    "esten-platform9" = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDLOOcdudgGgvUIsFxIDY6/uq9daQ7kmvSmRydv8KiqOXSUb5NH3YnnYpqcl7Le8T9U5++I71S5kRSxgsq+CY8ZmdrG522Rxy1/ixl0REKSKexZ7h/iue6ve0WxE9tS7Cj9ubug4/d1l6cFEdIp1KyzPdMRJtW9LB650t/mpe17LBic39XOcHfWdpYqCmW4Wrg9D1nO/mO+Gx1LLwfii770aZ6lHIxsaVj1FwmqKdlQswco10KPfB2WvzBxSaUhV4+xUV2uJ9aXshQPUx49flqiPgwQn7jiQxkOdkGb0X63WJjKCImGn9uJ5ms+3MVoLPeRYucKZvDxqJsYieV1Zy8uDODoqrJHPaXnixVVMZFNtKpvHDYgEoURqE2i+T/zclOdmLcSe5oYtD90/MGcKTuScZaqv5UOYfGK/y9Rqhleofznx6QqHPFVmN8HDgJje8EVwWfob3SbzfP3fYa60OJF0nfjxCBGCHZa8ZFZ47/qmpJsgWHgj6tlaYJw532lG4gCToy22PvTLmn7RQ8eB4IDmJWepezElkeH4KuQoM7o1UEPEdMkbeH1lzALj2sgGd3AnYhJxODLhlRULYdsA/dFp+bApB1YXf64fPg2ksPJdSQ7z/DIAHa1W0u6YhqVHRtaPq5s1zHzFKyDv3SClXGskExlFWz73P8l5nJkEqZfVw== esten@platform9.com",
}

compute_images = {
    "cirros" = {
        container_format = "bare"
        disk_format      = "qcow2"
        min_disk         = 1
        visibility       = "public"
        source_url       = "https://download.cirros-cloud.net/0.6.2/cirros-0.6.2-x86_64-disk.img"
    }
    "ubuntu-noble" = {
        container_format = "bare"
        disk_format      = "qcow2"
        min_disk         = 2
        visibility       = "public"
        source_url       = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
    }
}

compute_flavors = {
    "small" = {
        vcpus = 1
        ram   = 512
        disk  = 5
    }
}

security_groups = {
    "allow-ssh-icmp" = {
        description = "Allow SSH and ICMP traffic."
    }
}

security_group_rules = {
    "allow-ssh-v4-ingress" = {
        security_group     = "allow-ssh-icmp"
        description        = "Allow SSH from any IPv4 address"
        direction          = "ingress"
        ethertype          = "IPv4"
        protocol           = "tcp"
        port_range_min     = 22
        port_range_max     = 22
        remote_ip_prefix   = "0.0.0.0/0"
    },
    "allow-icmp-v4-ingress" = {
        security_group     = "allow-ssh-icmp"
        description        = "Allow ICMP from any IPv4 address"
        direction          = "ingress"
        ethertype          = "IPv4"
        protocol           = "icmp"
        remote_ip_prefix   = "0.0.0.0/0"
    },
    "allow-ssh-v6-ingress" = {
        security_group     = "allow-ssh-icmp"
        description        = "Allow SSH from any IPv6 address"
        direction          = "ingress"
        ethertype          = "IPv6"
        protocol           = "tcp"
        port_range_min     = 22
        port_range_max     = 22
        remote_ip_prefix   = "::/0"
    },
    "allow-icmp-v6-ingress" = {
        security_group     = "allow-ssh-icmp"
        description        = "Allow ICMP from any IPv6 address"
        direction          = "ingress"
        ethertype          = "IPv6"
        protocol           = "ipv6-icmp"
        remote_ip_prefix   = "::/0"
    }
}

networks = {
    "external-net" = {
        description    = "External network for the PCD cluster"
        shared         = true
        external       = true
        tags           = ["external", "tf-managed"]
        admin_state_up = true
        segments       = [{
            network_type     = "flat"
            physical_network = "physnet1"
        }]
    }
    "vlan1000-net" = {
        description    = "Self-service VLAN 1000 network, routed off external-net"
        shared         = false
        external       = false
        tags           = ["tf-managed"]
        admin_state_up = true
        segments       = [{
            network_type     = "vlan"
            physical_network = "physnet1"
            segmentation_id  = 1000
        }]
    }
}

ipv6_dhcpv6_stateful_subnets = {
    "vlan1000-subnet-v6" = {
        network_name     = "vlan1000-net"
        cidr             = "fd97:45c2:b3a1:1000::/64"
        gateway_ip       = "fd97:45c2:b3a1:1000::1"
        allocation_pools = [{
            start = "fd97:45c2:b3a1:1000::2"
            end   = "fd97:45c2:b3a1:1000:ffff:ffff:ffff:ffff"
        }]
        dns_nameservers  = ["fd97:45c2:b3a1:64::64", "2606:4700:4700::64"]
    }
}

network_subnets = {
    "external-subnet-v4" = {
        network_name     = "external-net"
        cidr             = "10.45.0.0/16"
        ip_version       = 4
        gateway_ip       = "10.45.0.1"
        enable_dhcp      = true
        allocation_pools = [{
            start = "10.45.70.1"
            end   = "10.45.140.255"
        }]
        dns_nameservers  = ["1.1.1.1", "8.8.8.8"]
        dns_publish_fixed_ip = true
    },
    "external-subnet-v6" = {
        network_name     = "external-net"
        cidr             = "fd97:45c2:b3a1:100::/64"
        ip_version       = 6
        gateway_ip       = "fd97:45c2:b3a1:100::1"
        enable_dhcp      = true
        allocation_pools = [{
            start = "fd97:45c2:b3a1:100:7777::1"
            end   = "fd97:45c2:b3a1:100:7777::ffff"
        }]
        dns_nameservers  = ["fd97:45c2:b3a1:64::64", "2606:4700:4700::64"]
        dns_publish_fixed_ip = true
    },
}

compute_instances = {
    "workload-vm" = {
        image_name      = "ubuntu-noble"
        flavor_name     = "small"
        key_pair        = "esten-personal"
        security_groups = ["allow-ssh-icmp"]
        networks        = ["vlan1000-net"]
        # vlan1000-net is IPv6-only, so the IPv4 metadata endpoint isn't
        # reachable - cloud-init needs the config drive to get its SSH key.
        config_drive    = true
    }
}

block_storage_volumes = {
  "workload-data" = {
    size        = 1
    volume_type = "volume_storage"
  }
}

compute_volume_attachments = {
  "workload-vm-data" = {
    instance_name = "workload-vm"
    volume_name   = "workload-data"
  }
}

dns_zones = {
    "usmnblm01.rye.ninja." = {
        email = "operations@example.com"
    }
}

network_dns_zone_associations = {
    "external-net" = {
        dns_zone_name = "usmnblm01.rye.ninja."
    }
}

neutron_ml2_guardian = {
    chart_version = "0.1.1"
    unifi_api_key_item = {
        vault = "controlplane"
        title = "unifi-os-xnetworksegment"
    }
    unifi_host = "10.45.0.1"
    unifi_site = "default"
}
