# Repository storage for Gitea (flux-platform-src applications/gitea) on
# core-infra: one dataset exported over NFSv4 and mounted as a static PV.
#
# Every client user is mapped to the `gitea` NAS user (mapall), so the volume
# is writable by the rootless Gitea image (UID 1000 in the pod) without
# relying on kubelet fsGroup, which does nothing on NFS. The export is limited
# to core-infra's node network rather than the broad nfs_allowed_networks.

resource "truenas_group" "gitea" {
  name = "gitea"
  gid  = var.gitea_gid
}

# Never logs in; the password only satisfies the provider's required field.
resource "random_password" "gitea" {
  length  = 48
  special = false
}

resource "truenas_user" "gitea" {
  username  = "gitea"
  full_name = "Gitea repository storage"
  password  = random_password.gitea.result
  uid       = var.gitea_uid

  group        = tonumber(truenas_group.gitea.id)
  group_create = false
  home         = "/var/empty"
  shell        = "/usr/sbin/nologin"
}

resource "truenas_dataset" "gitea_repos" {
  pool = var.pool_name
  name = var.gitea_repos_dataset_name

  compression = "LZ4"
  atime       = "OFF"
  share_type  = "NFS"
  # Caps the dataset itself (snapshots excluded), so a runaway repository
  # cannot fill the pool. NFS clients see this as the volume size, which is
  # what the capacity check in flux-platform-src measures.
  refquota = var.gitea_repos_quota_gib * 1024 * 1024 * 1024
  comments = "Gitea repositories (core-infra), NFSv4"
}

# New datasets are owned by root.
resource "terraform_data" "gitea_repos_owner" {
  triggers_replace = [truenas_dataset.gitea_repos.id, var.gitea_uid, var.gitea_gid]

  provisioner "local-exec" {
    command = "${path.module}/scripts/chown_path.py"
    environment = {
      TRUENAS_API_KEY = local.truenas_api_token
      TRUENAS_URL     = var.truenas_url
      CHOWN_PATH      = truenas_dataset.gitea_repos.mount_point
      CHOWN_UID       = tostring(var.gitea_uid)
      CHOWN_GID       = tostring(var.gitea_gid)
    }
  }

  depends_on = [truenas_user.gitea]
}

resource "truenas_share_nfs" "gitea_repos" {
  path    = truenas_dataset.gitea_repos.mount_point
  comment = "Gitea repositories (core-infra)"
  enabled = true

  networks = var.gitea_nfs_networks

  mapall_user  = truenas_user.gitea.username
  mapall_group = truenas_group.gitea.name
  security     = ["SYS"]

  depends_on = [truenas_service.nfs, terraform_data.gitea_repos_owner]
}

# Snapshots are the repository backup. Schedules run in the NAS timezone
# (America/Chicago); the daily one runs after gitea-db's 04:00 UTC backup in
# both CST and CDT, so the repositories and the database are captured close
# together.
resource "truenas_snapshot_task" "gitea_repos_hourly" {
  dataset = truenas_dataset.gitea_repos.id

  naming_schema   = "gitea-hourly-%Y-%m-%d_%H-%M"
  lifetime_value  = 2
  lifetime_unit   = "DAY"
  schedule_minute = "0"
  schedule_hour   = "*"
  schedule_dom    = "*"
  schedule_month  = "*"
  schedule_dow    = "*"
  allow_empty     = false
  enabled         = true
}

resource "truenas_snapshot_task" "gitea_repos_daily" {
  dataset = truenas_dataset.gitea_repos.id

  naming_schema   = "gitea-daily-%Y-%m-%d_%H-%M"
  lifetime_value  = 30
  lifetime_unit   = "DAY"
  schedule_minute = "15"
  schedule_hour   = "23"
  schedule_dom    = "*"
  schedule_month  = "*"
  schedule_dow    = "*"
  allow_empty     = false
  enabled         = true
}
