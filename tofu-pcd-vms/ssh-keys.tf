resource "pcd_compute_keypair" "default" {
  for_each   = var.compute_ssh_key_pairs
  name       = each.key
  public_key = each.value
}
