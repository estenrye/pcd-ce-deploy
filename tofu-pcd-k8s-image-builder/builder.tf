data "pcd_networking_network" "builder" {
  name = var.builder_network_name
}

data "pcd_networking_subnet" "builder" {
  name       = var.builder_subnet_name
  network_id = data.pcd_networking_network.builder.id
}

resource "pcd_compute_flavor" "builder" {
  name  = var.builder_name
  vcpus = var.builder_flavor.vcpus
  ram   = var.builder_flavor.ram
  disk  = var.builder_flavor.disk
}

resource "pcd_compute_keypair" "builder" {
  name       = var.builder_name
  public_key = var.builder_ssh_public_key
}

resource "pcd_networking_secgroup" "builder" {
  name        = var.builder_name
  description = "SSH and ICMPv6 access to the Kubernetes image builder"
}

resource "pcd_networking_secgroup_rule" "icmpv6_ingress" {
  security_group_id = pcd_networking_secgroup.builder.id
  description       = "Allow ICMPv6 (required for IPv6 path MTU discovery)"
  direction         = "ingress"
  ethertype         = "IPv6"
  protocol          = "ipv6-icmp"
  remote_ip_prefix  = "::/0"
}

resource "pcd_networking_secgroup_rule" "ssh_ingress" {
  for_each = toset(var.builder_ssh_allowed_prefixes)

  security_group_id = pcd_networking_secgroup.builder.id
  description       = "Allow SSH from ${each.value}"
  direction         = "ingress"
  ethertype         = "IPv6"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = each.value
}

# The port is created explicitly so the builder's address is known before
# boot, same pattern as ../tofu-pcd-talos-cluster/instance.tf.
resource "pcd_networking_port" "builder" {
  count = var.builder_enabled ? 1 : 0

  name       = var.builder_name
  network_id = data.pcd_networking_network.builder.id

  fixed_ip = [{
    subnet_id = data.pcd_networking_subnet.builder.id
  }]
}

resource "pcd_networking_port_secgroup_associate" "builder" {
  count = var.builder_enabled ? 1 : 0

  port_id            = pcd_networking_port.builder[0].id
  enforce            = true
  security_group_ids = [pcd_networking_secgroup.builder.id]
}

resource "pcd_compute_instance" "builder" {
  count = var.builder_enabled ? 1 : 0

  name        = var.builder_name
  image_name  = pcd_images_image.ubuntu_base.name
  flavor_name = pcd_compute_flavor.builder.name
  key_pair    = pcd_compute_keypair.builder.name

  network {
    port = pcd_networking_port.builder[0].id
  }

  # IPv6-only networks have no IPv4 metadata endpoint, so cloud-init reads
  # network config, the ssh key and user_data from a config drive. user_data
  # must also be non-empty or the platform drops network_data.json (see the
  # Talos notes in ../tofu-pcd-talos-cluster/instance.tf).
  config_drive = true
  user_data = templatefile("${path.module}/files/cloud-init.yaml.tftpl", {
    image_builder_ref = var.image_builder_ref
    dns64_servers     = var.builder_dns64_servers
    interface         = var.builder_interface_name
    address           = pcd_networking_port.builder[0].all_fixed_ips[0]
    prefix_length     = split("/", data.pcd_networking_subnet.builder.cidr)[1]
  })

  depends_on = [pcd_networking_port_secgroup_associate.builder]
}

locals {
  builder_address = var.builder_enabled ? pcd_networking_port.builder[0].all_fixed_ips[0] : null

  # Plain `ssh` rather than the loafoe/ssh provider: that provider crashes on
  # IPv6 literals (easyssh-proxy 2.0.4 dereferences nil) and hung on a
  # bracketed one. Host keys are not pinned because the builder is rebuilt
  # (new host key, same address) whenever its cloud-init changes. The address
  # is a fixed IP on a private network; authentication is the ssh-agent key.
  builder_ssh = join(" ", [
    "ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null",
    "-o LogLevel=ERROR -o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=20",
    "ubuntu@${local.builder_address}",
  ])
}

# Blocks until cloud-init has installed everything and the environment can
# actually build: /dev/kvm present (nested virtualization) and the build
# sources reachable (NAT64/DNS64 for the IPv4-only ones, e.g. github.com).
resource "terraform_data" "builder_ready" {
  count = var.builder_enabled ? 1 : 0

  triggers_replace = {
    instance = pcd_compute_instance.builder[0].id
    ref      = var.image_builder_ref
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      READY_SCRIPT = <<-EOT
        set -u
        cloud-init status --wait >/dev/null || true
        test -e /var/lib/image-builder-ready || { echo "builder setup did not finish; see /var/log/cloud-init-output.log" >&2; exit 1; }
        test -c /dev/kvm || { echo "/dev/kvm missing: the hypervisor does not expose nested virtualization to this flavor" >&2; exit 1; }
        # Any HTTP status counts as reachable (registry.k8s.io/v2/ answers 401).
        for u in https://github.com https://pkgs.k8s.io https://dl.k8s.io https://registry.k8s.io/v2/; do
          code=$(curl -sS -o /dev/null -w '%%{http_code}' --max-time 20 "$u" || true)
          [ -n "$code" ] && [ "$code" != 000 ] || { echo "builder cannot reach $u (NAT64/DNS64?)" >&2; exit 1; }
        done
        echo ready
      EOT
    }
    command = <<-EOT
      set -euo pipefail
      for i in $(seq 1 90); do ${local.builder_ssh} true 2>/dev/null && break; [ "$i" = 90 ] && { echo "builder never became reachable over ssh" >&2; exit 1; }; sleep 10; done
      printf '%s\n' "$READY_SCRIPT" | ${local.builder_ssh} bash -s
    EOT
  }
}
