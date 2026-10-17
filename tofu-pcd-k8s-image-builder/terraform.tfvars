onepassword_account    = "ryefamily.1password.com"
onepassword_vault      = "Home_Lab"
onepassword_item_title = "PCD Community - pcd.rye.ninja"
pcd_auth_url           = "https://pcd.rye.ninja/keystone/v3"
pcd_region             = "Infra"
pcd_tenant_name        = "service"
pcd_user_domain_id     = "default"
pcd_project_domain_id  = "default"

builder_ssh_public_key = "ecdsa-sha2-nistp521 AAAAE2VjZHNhLXNoYTItbmlzdHA1MjEAAAAIbmlzdHA1MjEAAACFBABRrM38w/r7E5eHrD5eeQ0tU5sNlpseYO3s0kKKf0tbYIOsGW52ofUBzzx2/3PoAANOX/rZIwk6DmmiQxPizKeF6QCZuHrzknDHNHtg2JNWlsh24zNI9OjX8e+bB1oPE8y/PQPXPA8hrf7RZhU0wb3Ld4I6tOpcdiimlOI4sYmPgITmKA== esten@MacBook-Pro"

# PCD's catalog Glance endpoint is the IPv4 literal 10.45.60.1:9494; the builder is
# IPv6-only, so reach the same server through the local NAT64 prefix.
glance_endpoint_override = "https://[fd97:45c2:b3a1:64:65:0:a2d:3c01]:9494"

# Sized for 3 parallel builds: each is a 4 vCPU / 6 GB nested VM plus ~1 vCPU / 1 GB of
# qemu + packer overhead. Needs the service project's cores quota above ~33 (set to 48).
builder_flavor = {
  vcpus = 16
  ram   = 32768
  disk  = 100
}
build_vm = {
  cpus      = 4
  memory_mb = 6144
}
parallel_builds = 3
