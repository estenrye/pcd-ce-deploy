# One tainted worker with unprivileged user namespaces enabled, for testing
# rootless Docker-in-Docker (flux-platform-src applications/gitea-runner).
# Talos sets user.max_user_namespaces = 0; only this node raises it, so the
# attack-surface change stays off the regular workers. Pods land here only if
# they tolerate the taint and select the label.
#
# Mirrors the worker resources in instance.tf and talos.tf, under separate
# names so the regular workers are untouched. Remove it with
# rootless_test_node_enabled = false.

locals {
  rootless_test_count = var.rootless_test_node_enabled ? 1 : 0
}

resource "pcd_networking_port" "rootless_test" {
  count = local.rootless_test_count

  name       = "${var.cluster_name}-rootless-test-1"
  network_id = data.pcd_networking_network.bgp.id

  fixed_ip = [{
    subnet_id = data.pcd_networking_subnet.bgp.id
  }]

  allowed_address_pairs = [
    for cidr in concat(local.bgp_vip_ranges, local.pod_pool_cidrs) : {
      ip_address = cidr
    }
  ]
}

resource "pcd_networking_port_secgroup_associate" "rootless_test" {
  count = local.rootless_test_count

  port_id = pcd_networking_port.rootless_test[0].id
  enforce = true

  security_group_ids = [
    pcd_networking_secgroup.talos.id,
    pcd_networking_secgroup.http.id,
    pcd_networking_secgroup.https.id,
    pcd_networking_secgroup.minecraft.id,
    pcd_networking_secgroup.ssh.id,
    pcd_networking_secgroup.dns.id,
    data.pcd_networking_secgroup.bgp.id,
  ]
}

resource "pcd_compute_instance" "rootless_test" {
  count = local.rootless_test_count

  name        = "${var.cluster_name}-rootless-test-1"
  flavor_name = pcd_compute_flavor.worker.name

  block_device {
    source_type           = "image"
    uuid                  = pcd_images_image.talos.id
    destination_type      = "volume"
    boot_index            = 0
    volume_size           = var.worker_flavor.disk
    volume_type           = var.root_volume_type
    delete_on_termination = true
  }

  network {
    port = pcd_networking_port.rootless_test[0].id
  }

  config_drive = true
  user_data    = local.maintenance_user_data
}

locals {
  rootless_test_address = local.rootless_test_count == 1 ? pcd_networking_port.rootless_test[0].all_fixed_ips[0] : null
}

data "talos_machine_configuration" "rootless_test" {
  count = local.rootless_test_count

  cluster_name       = var.cluster_name
  cluster_endpoint   = local.cluster_endpoint
  machine_type       = "worker"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version

  config_patches = concat(local.common_config_patches, local.cni_config_patches, [
    yamlencode({
      machine = merge(local.common_machine, {
        sysctls = merge(local.common_machine.sysctls, {
          "user.max_user_namespaces" = "11255"
        })
        network = {
          interfaces = [
            {
              interface = "eth0"
              dhcp      = true
              dhcpOptions = {
                ipv4 = false
                ipv6 = true
              }
            }
          ]
        }
      })
    }),
    # Talos 1.14 moved node labels and taints out of machine.nodeLabels/nodeTaints.
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "KubeNodeConfig"
      labels = {
        pool = "rootless-test"
      }
      taints = {
        pool = "rootless-test:NoSchedule"
      }
    }),
  ])
}

resource "talos_machine_configuration_apply" "rootless_test" {
  count = local.rootless_test_count

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.rootless_test[0].machine_configuration
  node                        = local.rootless_test_address
  endpoint                    = local.rootless_test_address

  config_patches = [
    yamlencode({
      machine = {
        network = {
          interfaces = [
            {
              interface = "eth0"
              routes = [
                {
                  network = data.pcd_networking_subnet.bgp.cidr
                  source  = local.rootless_test_address
                  metric  = 100
                }
              ]
            }
          ]
        }
      }
    })
  ]

  depends_on = [
    pcd_compute_instance.rootless_test,
    pcd_networking_port_secgroup_associate.rootless_test,
    pcd_networking_secgroup_rule.talos_apid_ingress,
    # The node joins through the API VIP, which exists once the cluster is up.
    data.talos_cluster_health.this,
  ]
}

resource "terraform_data" "reboot_rootless_test" {
  count = var.reboot_after_first_config ? local.rootless_test_count : 0

  triggers_replace = {
    instance = pcd_compute_instance.rootless_test[0].id
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = local.reboot_node_script
    environment = {
      TALOSCONFIG_CONTENT = nonsensitive(data.talos_client_configuration.this.talos_config)
      NODE                = local.rootless_test_address
    }
  }

  depends_on = [talos_machine_configuration_apply.rootless_test]
}
