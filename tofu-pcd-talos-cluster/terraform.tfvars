onepassword_account    = "ryefamily.1password.com"
onepassword_vault      = "Home_Lab"
onepassword_item_title = "PCD Community - pcd.rye.ninja"
pcd_hostname           = "pcd.rye.ninja"
pcd_auth_url           = "https://pcd.rye.ninja/keystone/v3"
pcd_ssh_username       = "ubuntu"
pcd_region             = "Infra"
pcd_tenant_name        = "service"
pcd_user_domain_id     = "default"
pcd_project_domain_id  = "default"

# Everything below has a working default in variables.tf (network
# addressing follows ../tofu-pcd-vms/terraform.tfvars's vlan1000-net
# convention, just at VLAN 1001 / fd97:45c2:b3a1:1001::/64) -- override
# here only if this needs to change.
