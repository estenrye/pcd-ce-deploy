# HP Color LaserJet MFP "Scan to Network Folder" entries, one per SMB share.
# The printer has no API, so scripts/hp_scan_to_folder.py drives its embedded
# web server (posting the same form the UI does) and then runs the entry's
# connection test, failing the apply if the test fails. It runs again when a
# path, display name or the hp-scan credentials change. Settings the printer
# keeps but this does not manage (file type, paper size, scan quality,
# colour, file prefix) are resubmitted as the printer already has them, and
# no PIN is set. Drift made on the printer is not detected.
locals {
  # Address the printer connects to, the NAS's IPv4 SMB address.
  printer_smb_host = var.smb_bind_ips[0]

  # entry number on the printer => share name; display names as already set.
  printer_folders = {
    "1" = { display_name = "hsa-expenses", share = "hsa" }
    "2" = { display_name = "taxes-2026", share = "taxes-2026" }
    "3" = { display_name = "docs", share = "docs" }
    "4" = { display_name = "photos", share = "photos" }
  }
}

resource "terraform_data" "printer_folder" {
  for_each = local.printer_folders

  triggers_replace = sensitive({
    host         = var.printer_host
    display_name = each.value.display_name
    path         = "\\\\${local.printer_smb_host}\\${each.value.share}"
    credentials  = sha256("${data.onepassword_item.smb_hp_scan.username}:${data.onepassword_item.smb_hp_scan.password}")
  })

  provisioner "local-exec" {
    command = "${path.module}/scripts/hp_scan_to_folder.py"
    environment = {
      PRINTER_HOST = var.printer_host
      ENTRY_NUM    = each.key
      DISPLAY_NAME = each.value.display_name
      FOLDER_PATH  = "\\\\${local.printer_smb_host}\\${each.value.share}"
      SCAN_USER    = data.onepassword_item.smb_hp_scan.username
      SCAN_PASS    = data.onepassword_item.smb_hp_scan.password
    }
  }

  # The shares, their ACLs and the SMB service must be up for the test.
  depends_on = [truenas_share_smb.scanned, terraform_data.smb_share_acl]
}

# Re-test every entry on every apply, without re-saving, so a later breakage
# (changed NAS password, stopped SMB service, wrong path) fails the apply
# instead of going unnoticed until the next change. The timestamp trigger
# makes these show as replaced in every plan.
resource "terraform_data" "printer_folder_test" {
  for_each = local.printer_folders

  triggers_replace = timestamp()

  provisioner "local-exec" {
    command = "${path.module}/scripts/hp_scan_to_folder.py"
    environment = {
      PRINTER_HOST = var.printer_host
      ENTRY_NUM    = each.key
      TEST_ONLY    = "1"
    }
  }

  depends_on = [terraform_data.printer_folder]
}
