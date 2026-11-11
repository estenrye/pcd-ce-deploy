# Receive side of the KVM host's nightly zvol replication
# (flux-platform-src providers/kvm/scripts/zfs-replicate-vms.sh): the host
# connects over SSH as `replication` with a dedicated key and runs `zfs` on
# the NAS through sudo. The receiving datasets under
# flash-pool/replication/<host>/vms already exist and are not managed here.
#
# Why sudo rather than `zfs allow`: nothing in the API or provider can set ZFS
# delegations, and a delegated `destroy` lets the account destroy whole datasets.
# The sudoers rules below pin each command to the replication tree: receive
# into it, send from it (restore), list its snapshots, and destroy snapshots
# (never datasets) in it.

locals {
  replication_user = "replication"
  replication_sudo_commands = [
    "/usr/sbin/zfs list -H -t snapshot -o name -s creation -d 1 ${var.replication_zfs_prefix}/*",
    "/usr/sbin/zfs list -H -t snapshot -o name -d 1 ${var.replication_zfs_prefix}/*",
    "/usr/sbin/zfs recv -uF ${var.replication_zfs_prefix}/*",
    # Restore path: a replaced KVM host pulls its zvols back.
    "/usr/sbin/zfs send ${var.replication_zfs_prefix}/*",
    "/usr/sbin/zfs send * ${var.replication_zfs_prefix}/*",
    "/usr/sbin/zfs destroy -r ${var.replication_zfs_prefix}/*@*",
  ]
}

# Home for the user's ~/.ssh/authorized_keys. TrueNAS writes sshpubkey there,
# so it needs a real directory (not /var/empty).
resource "truenas_dataset" "replication_home" {
  pool = var.pool_name
  name = "replication-home"

  compression = "LZ4"
  atime       = "OFF"
  comments    = "Home directory of the replication user"
}

# SSH logins are key-only, so this password is never used; it only satisfies
# the provider's required `password` field.
resource "random_password" "replication" {
  length  = 48
  special = false
}

resource "truenas_user" "replication" {
  username  = local.replication_user
  full_name = "ZFS replication (mf-ms-a2-01)"
  password  = random_password.replication.result

  group_create = true
  home         = truenas_dataset.replication_home.mount_point
  # ssh runs `zfs ...` through the login shell, so it cannot be nologin.
  shell     = "/usr/bin/bash"
  sshpubkey = var.replication_ssh_public_key
}

# truenas_user exposes sudo_commands (which needs a password) but not
# sudo_commands_nopasswd, so set that through the API.
resource "terraform_data" "replication_sudo" {
  triggers_replace = [truenas_user.replication.id, local.replication_sudo_commands]

  provisioner "local-exec" {
    command = "${path.module}/scripts/set_sudo_nopasswd.py"
    environment = {
      TRUENAS_API_KEY = local.truenas_api_token
      TRUENAS_URL     = var.truenas_url
      USERNAME        = local.replication_user
      SUDO_COMMANDS   = jsonencode(local.replication_sudo_commands)
    }
  }

  depends_on = [truenas_user.replication]
}

# The SSH service was stopped and password login was on. Key-only, no
# forwarding: the only SSH account that matters here is `replication`.
resource "truenas_ssh_config" "this" {
  tcpport      = 22
  passwordauth = false
  kerberosauth = false
  tcpfwd       = false
  compression  = false
}

resource "truenas_service" "ssh" {
  service = "ssh"
  enable  = true

  depends_on = [truenas_ssh_config.this, truenas_user.replication, terraform_data.replication_sudo]
}
