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
    ssh = {
      source  = "registry.terraform.io/loafoe/ssh"
      version = "~> 2.7"
    }
    talos = {
      # 0.12 (talos_cluster/talos_machine, a simpler bootstrap+upgrade
      # surface) is still pre-release (rc.0) as of writing -- pinned to
      # the last stable 0.11 line instead. See talos.tf for the
      # machine_secrets/machine_configuration/machine_bootstrap pattern
      # this version requires.
      source  = "siderolabs/talos"
      version = "~> 0.11"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0"
    }
  }
}
