terraform {
  required_version = ">= 1.6"

  required_providers {
    pcd = {
      # Not yet mirrored on registry.opentofu.org, so pinned to the
      # Terraform registry explicitly -- same as ../tofu-pcd-vms.
      source  = "registry.terraform.io/platform9/pcd"
      version = "~> 0.1"
    }
    onepassword = {
      source  = "1Password/onepassword"
      version = "~> 3.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
  }
}
