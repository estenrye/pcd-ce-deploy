# SMB shares over the scanned-documents data already on the NAS: a
# flash-pool/scanned-documents dataset with hsa, taxes, docs and photos child
# datasets (not managed here). Their NFSv4 ACLs already grant USER 501 full
# control and USER 3001 modify, so the two SMB users below take those UIDs
# and need no ACL changes. Each user's login and UID come from a 1Password
# item.

data "onepassword_item" "smb_hp_scan" {
  vault = var.smb_onepassword_vault
  title = var.smb_hp_scan_item_title
}

data "onepassword_item" "smb_esten" {
  vault = var.smb_onepassword_vault
  title = var.smb_esten_item_title
}

# Custom fields only appear under `section` blocks, so find `uid` by label.
locals {
  smb_hp_scan_uid = tonumber(one([
    for f in flatten([for s in data.onepassword_item.smb_hp_scan.section : s.field]) :
    f.value if f.label == "uid"
  ]))
  smb_esten_uid = tonumber(one([
    for f in flatten([for s in data.onepassword_item.smb_esten.section : s.field]) :
    f.value if f.label == "uid"
  ]))
}

# Members get full control over the application data shares below.
resource "truenas_group" "app_shares" {
  name = "app_shares"
  smb  = true
}

resource "truenas_user" "hp_scan" {
  username  = data.onepassword_item.smb_hp_scan.username
  full_name = "HP scanner"
  password  = data.onepassword_item.smb_hp_scan.password
  uid       = local.smb_hp_scan_uid

  smb          = true
  group_create = true
  groups       = [var.smb_users_group_id]
  home         = "/var/empty"
  shell        = "/usr/sbin/nologin"
}

resource "truenas_user" "esten" {
  username  = data.onepassword_item.smb_esten.username
  full_name = "Esten Rye"
  password  = data.onepassword_item.smb_esten.password
  uid       = local.smb_esten_uid

  smb          = true
  group_create = true
  groups       = [var.smb_users_group_id, tonumber(truenas_group.app_shares.id)]
  home         = "/var/empty"
  shell        = "/usr/sbin/nologin"
}

locals {
  scanned_documents_path = "/mnt/${var.pool_name}/scanned-documents"

  # share name => subdirectory of scanned-documents
  smb_shares = {
    "hsa"        = "hsa"
    "taxes-2026" = "taxes/2026"
    "docs"       = "docs"
    "photos"     = "photos"
  }
}

resource "truenas_share_smb" "scanned" {
  for_each = local.smb_shares

  name    = each.key
  path    = "${local.scanned_documents_path}/${each.value}"
  comment = "Scanned documents: ${each.value}"
  enabled = true

  depends_on = [truenas_service.smb, truenas_user.hp_scan, truenas_user.esten]
}

resource "truenas_service" "smb" {
  service = "cifs"
  enable  = true

  depends_on = [terraform_data.smb_bindip]
}

# Bind the SMB service to its storage-network addresses. The provider's
# truenas_smb_config has no bindip, so this sets it through the REST API
# (PUT /api/v2.0/smb) when var.smb_bind_ips changes. Only bindip is sent. The
# addresses must already be assigned to an interface on the NAS.
resource "terraform_data" "smb_bindip" {
  triggers_replace = var.smb_bind_ips

  provisioner "local-exec" {
    command = <<-EOT
      printf 'header = "Authorization: Bearer %s"\n' "$TRUENAS_API_KEY" |
        curl --fail-with-body --silent --show-error --max-time 60 \
          --config - -X PUT -H 'Content-Type: application/json' \
          --data "$SMB_CONFIG" "$TRUENAS_URL/api/v2.0/smb" > /dev/null
    EOT
    environment = {
      TRUENAS_API_KEY = local.truenas_api_token
      TRUENAS_URL     = var.truenas_url
      SMB_CONFIG      = jsonencode({ bindip = var.smb_bind_ips })
    }
  }

  # Bind before the service starts so it never listens on every interface.
  depends_on = [truenas_user.hp_scan]
}

# Share-level ACL (SMB share permissions, separate from the filesystem ACL).
# Replaces the default "Everyone: Full" entry so only these two users can
# connect. The provider's truenas_share_smb has no ACL support, so this
# calls sharing.smb.setacl (POST /api/v2.0/sharing/smb/setacl) for each share
# once the shares exist, and again when the entries change.
locals {
  # FULL | CHANGE | READ, mirroring the filesystem ACLs (esten: full control,
  # hp-scan: modify).
  smb_share_acl = [
    { uid = local.smb_esten_uid, perm = "FULL" },
    { uid = local.smb_hp_scan_uid, perm = "CHANGE" },
  ]
}

resource "terraform_data" "smb_share_acl" {
  for_each = local.smb_shares

  triggers_replace = sensitive({
    share = truenas_share_smb.scanned[each.key].name
    acl   = local.smb_share_acl
  })

  provisioner "local-exec" {
    command = <<-EOT
      printf 'header = "Authorization: Bearer %s"\n' "$TRUENAS_API_KEY" |
        curl --fail-with-body --silent --show-error --max-time 60 \
          --config - -X POST -H 'Content-Type: application/json' \
          --data "$SHARE_ACL" "$TRUENAS_URL/api/v2.0/sharing/smb/setacl" > /dev/null
    EOT
    environment = {
      TRUENAS_API_KEY = local.truenas_api_token
      TRUENAS_URL     = var.truenas_url
      SHARE_ACL = jsonencode({
        share_name = truenas_share_smb.scanned[each.key].name
        share_acl = [
          for e in local.smb_share_acl : {
            ae_who_id = { id_type = "USER", id = e.uid }
            ae_perm   = e.perm
            ae_type   = "ALLOWED"
          }
        ]
      })
    }
  }
}

# Shares over application datasets owned by the apps user (UID 568). Members
# of app_shares get full control at the share level; the datasets' filesystem
# ACLs must grant the group the same (see below).
locals {
  # share name => dataset path relative to the pool
  app_smb_shares = {
    "audiobooks" = "audiobooks"
    "music"      = "jellyfin/music"
    "pictures"   = "pictures"
  }
}

resource "truenas_share_smb" "app" {
  for_each = local.app_smb_shares

  name    = each.key
  path    = "/mnt/${var.pool_name}/${each.value}"
  comment = "Application data: ${each.value}"
  enabled = true

  depends_on = [truenas_service.smb]
}

resource "terraform_data" "app_share_acl" {
  for_each = local.app_smb_shares

  depends_on = [terraform_data.app_share_fs_acl]

  triggers_replace = {
    share = truenas_share_smb.app[each.key].name
    gid   = truenas_group.app_shares.gid
  }

  provisioner "local-exec" {
    command = <<-EOT
      printf 'header = "Authorization: Bearer %s"\n' "$TRUENAS_API_KEY" |
        curl --fail-with-body --silent --show-error --max-time 60 \
          --config - -X POST -H 'Content-Type: application/json' \
          --data "$SHARE_ACL" "$TRUENAS_URL/api/v2.0/sharing/smb/setacl" > /dev/null
    EOT
    environment = {
      TRUENAS_API_KEY = local.truenas_api_token
      TRUENAS_URL     = var.truenas_url
      SHARE_ACL = jsonencode({
        share_name = truenas_share_smb.app[each.key].name
        share_acl = [{
          ae_who_id = { id_type = "GROUP", id = truenas_group.app_shares.gid }
          ae_perm   = "FULL"
          ae_type   = "ALLOWED"
        }]
      })
    }
  }
}

# Filesystem ACL: add app_shares FULL_CONTROL (inheriting) to each dataset
# root, keeping every existing entry, and apply it recursively across child
# datasets so existing files and folders get it too. Ownership is left as is.
# Runs once per dataset, and again if the group's GID changes. Files created
# later inherit the entry. Slow on large trees (music has ~900 top-level
# entries).
resource "terraform_data" "app_share_fs_acl" {
  for_each = local.app_smb_shares

  triggers_replace = {
    path = truenas_share_smb.app[each.key].path
    gid  = truenas_group.app_shares.gid
  }

  provisioner "local-exec" {
    command = "${path.module}/scripts/add_group_to_acl.py"
    environment = {
      TRUENAS_API_KEY = local.truenas_api_token
      TRUENAS_URL     = var.truenas_url
      ACL_PATH        = truenas_share_smb.app[each.key].path
      GROUP_GID       = tostring(truenas_group.app_shares.gid)
    }
  }

  # Grant the filesystem permission before the share ACL lets anyone in.
  depends_on = [truenas_group.app_shares]
}

# esten's files (existing dataset, owned by esten), also exported over NFS in
# nfs.tf. Only esten can connect; the dataset's filesystem ACL already gives
# the owner full control.
resource "truenas_share_smb" "files_esten" {
  name    = "files-esten"
  path    = "/mnt/${var.pool_name}/files-esten"
  comment = "esten files"
  enabled = true

  depends_on = [truenas_service.smb]
}

resource "terraform_data" "files_esten_share_acl" {
  triggers_replace = sensitive({
    share = truenas_share_smb.files_esten.name
    uid   = local.smb_esten_uid
  })

  provisioner "local-exec" {
    command = <<-EOT
      printf 'header = "Authorization: Bearer %s"\n' "$TRUENAS_API_KEY" |
        curl --fail-with-body --silent --show-error --max-time 60 \
          --config - -X POST -H 'Content-Type: application/json' \
          --data "$SHARE_ACL" "$TRUENAS_URL/api/v2.0/sharing/smb/setacl" > /dev/null
    EOT
    environment = {
      TRUENAS_API_KEY = local.truenas_api_token
      TRUENAS_URL     = var.truenas_url
      SHARE_ACL = jsonencode({
        share_name = truenas_share_smb.files_esten.name
        share_acl = [{
          ae_who_id = { id_type = "USER", id = local.smb_esten_uid }
          ae_perm   = "FULL"
          ae_type   = "ALLOWED"
        }]
      })
    }
  }
}
