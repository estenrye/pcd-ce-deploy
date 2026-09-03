terraform {
  required_version = ">= 1.6"

  required_providers {
    truenas = {
      source  = "PjSalty/truenas"
      version = "~> 2.0"
    }
    onepassword = {
      source  = "1Password/onepassword"
      version = "~> 3.0"
    }
  }
}
