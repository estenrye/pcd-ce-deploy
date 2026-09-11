terraform {
  required_version = ">= 1.6"

  required_providers {
    pcd = {
      # Not yet mirrored on registry.opentofu.org, so pinned to the
      # Terraform registry explicitly.
      source  = "registry.terraform.io/platform9/pcd"
      version = "~> 0.1"
    }
    onepassword = {
      source  = "1Password/onepassword"
      version = "~> 3.0"
    }
    assert-cidr = {
      source  = "registry.terraform.io/BehnH/assert"
      version = "0.1.0"
    }
    ssh = {
      source  = "registry.terraform.io/loafoe/ssh"
      version = "~> 2.7"
    }
    null = {
      # Drives the resmgr v1 API's role-settings PUT (designate_mdns_
      # listener.tf) via local-exec -- the pcd provider's own
      # pcd_host_role resource only supports a role's *default* settings
      # (see its own schema description), so there's no native-provider
      # path for this.
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}
