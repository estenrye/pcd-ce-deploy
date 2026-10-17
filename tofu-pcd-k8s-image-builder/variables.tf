# --- PCD connection (same shape as ../tofu-pcd-vms/variables.tf) ---

variable "pcd_auth_url" {
  description = "Keystone v3 auth URL for the PCD management plane."
  type        = string
  default     = null
}

variable "pcd_region" {
  description = "PCD region to operate in."
  type        = string
  default     = "Infra"
}

variable "pcd_tenant_name" {
  description = "Project (tenant) the admin user is scoped to. Images are created in this project."
  type        = string
  default     = "service"
}

variable "pcd_user_domain_id" {
  description = "Keystone domain ID the admin user belongs to."
  type        = string
  default     = "default"
}

variable "pcd_project_domain_id" {
  description = "Keystone domain ID of the scoped project."
  type        = string
  default     = "default"
}

variable "onepassword_account" {
  description = "1Password account name or ID; can instead come from the OP_ACCOUNT environment variable."
  type        = string
  default     = null
}

variable "onepassword_vault" {
  description = "1Password vault UUID (or name) holding the PCD admin credentials."
  type        = string
  default     = null
}

variable "onepassword_item_title" {
  description = "Title of the 1Password Login item holding the PCD admin username/password."
  type        = string
  default     = null
}

# --- What to build ---

variable "kubernetes_versions" {
  description = <<-EOT
    One entry per image to build. The key is a free-form unique id (by
    convention "<minor>-<os>"). `minor` is the Kubernetes minor version
    ("1.32"); it becomes the image's `k8s_version` Glance property, which
    PCD-K requires. `os` is the image-builder OS suffix, i.e. the
    `build-qemu-<os>` make target. `patch` pins the full version ("1.32.9");
    when null, the latest patch of `minor` is resolved from
    https://dl.k8s.io/release/stable-<minor>.txt at plan time.
  EOT
  type = map(object({
    minor = string
    os    = optional(string, "ubuntu-2404")
    patch = optional(string)
    # Overrides var.image_builder_ref for this entry. Needed when the default
    # ref's kubeadm config template is too old for the version: v0.1.55 emits
    # kubeadm.k8s.io/v1beta3, which kubeadm 1.37 rejects.
    image_builder_ref = optional(string)
  }))
  default = {
    "1.32-ubuntu-2404" = { minor = "1.32" }
    "1.33-ubuntu-2404" = { minor = "1.33" }
    "1.34-ubuntu-2404" = { minor = "1.34" }
    "1.35-ubuntu-2404" = { minor = "1.35" }
    "1.36-ubuntu-2404" = { minor = "1.36" }
    # v0.1.55 (the latest tag) writes kubeadm v1beta3 configs, which kubeadm
    # 1.37 rejects; this is a main-branch commit that writes v1beta4.
    "1.37-ubuntu-2404" = { minor = "1.37", image_builder_ref = "fbf953d277424abc9a2f2f92e9b068fe654d4c19" }
  }

  validation {
    condition     = alltrue([for v in values(var.kubernetes_versions) : can(regex("^1\\.[0-9]+$", v.minor))])
    error_message = "Every minor must look like \"1.32\"."
  }

  validation {
    condition     = alltrue([for v in values(var.kubernetes_versions) : contains(["ubuntu-2204", "ubuntu-2404"], v.os)])
    error_message = "os must be ubuntu-2204 or ubuntu-2404 (the OSes PCD-K supports for worker nodes)."
  }

  validation {
    condition = alltrue([
      for v in values(var.kubernetes_versions) :
      v.patch == null ? true : can(regex("^${replace(v.minor, ".", "\\.")}\\.[0-9]+$", v.patch))
    ])
    error_message = "patch must be a full version within its minor, e.g. minor \"1.32\" with patch \"1.32.9\" (no leading v)."
  }

  validation {
    condition     = length(distinct([for v in values(var.kubernetes_versions) : "${v.minor}/${v.os}"])) == length(var.kubernetes_versions)
    error_message = "Each (minor, os) pair may appear only once."
  }
}

variable "image_builder_ref" {
  description = "Default git tag or commit of kubernetes-sigs/image-builder to build with (each kubernetes_versions entry can override it). Pin a tag/SHA, not a branch. v0.1.55 supports Kubernetes 1.32-1.37 (checked 2026-10-15)."
  type        = string
  default     = "v0.1.55"
}

variable "kubernetes_deb_revision" {
  description = "Package revision suffix on pkgs.k8s.io debs (kubernetes_deb_version = <semver>-<revision>)."
  type        = string
  default     = "1.1"
}

variable "extra_packer_vars" {
  description = "Extra image-builder/Packer variables merged into every build's PACKER_VAR_FILES JSON (e.g. crictl_version, containerd_version, proxy settings). A non-empty map changes the image names, so it never collides with images built without it."
  type        = map(string)
  default     = {}
}

variable "build_vm" {
  description = "Size of the nested VM that image-builder's qemu builder installs and provisions each image in. image-builder defaults to 1 vCPU / 2048 MB regardless of how big the builder is, and the install (~28 min) and Ansible provisioning (~35 min) both run in it. memory_mb is in MB. Overridden by extra_packer_vars."
  type = object({
    cpus      = number
    memory_mb = number
  })
  default = {
    cpus      = 1
    memory_mb = 2048
  }
}

variable "boot_wait" {
  description = "How long Packer waits after starting the nested VM before typing the autoinstall boot command into its bootloader over VNC (image-builder's default is 10s). On a busy builder the nested VM reaches the bootloader later than that and the keystrokes are lost: one VM then hung at early boot and another installed without the autoinstall config, so Packer waited for SSH forever. Not part of image names."
  type        = string
  default     = "30s"
}

variable "ssh_wait_minutes" {
  description = "How long a build may sit in Packer's 'Waiting for SSH' step (OS install plus first boot, normally ~30 min) before it is killed and retried. Packer itself waits 2h and does not notice a dead or misconfigured VM."
  type        = number
  default     = 50
}

variable "parallel_builds" {
  description = "How many images build at the same time on the builder. Size builder_flavor for it: roughly parallel_builds * (build_vm.cpus + 1) vCPUs and parallel_builds * (build_vm.memory_mb + 1024) MB of RAM, plus headroom."
  type        = number
  default     = 1

  validation {
    condition     = var.parallel_builds >= 1 && floor(var.parallel_builds) == var.parallel_builds
    error_message = "parallel_builds must be a whole number >= 1."
  }
}

variable "image_visibility" {
  description = "Glance visibility of built images. PCD-K needs to be able to list them."
  type        = string
  default     = "public"

  validation {
    condition     = contains(["public", "private", "shared", "community"], var.image_visibility)
    error_message = "image_visibility must be public, private, shared or community."
  }
}

variable "glance_endpoint_override" {
  description = "Glance endpoint the builder's openstack CLI uses instead of the one in the Keystone catalog. PCD's catalog entry is the IPv4 literal https://10.45.60.1:9494, which an IPv6-only builder cannot reach; the same server answers through the local NAT64 prefix (10.45.60.1 -> https://[fd97:45c2:b3a1:64:65:0:a2d:3c01]:9494). Null uses the catalog."
  type        = string
  default     = null
}

variable "glance_interface" {
  description = "Keystone endpoint interface the builder's openstack CLI uses to reach Glance. The builder is IPv6-only, so pick the interface whose endpoint it can route to."
  type        = string
  default     = "public"
}

# --- Builder VM ---

variable "builder_enabled" {
  description = "false destroys the builder VM and its port but keeps every image already built. Re-enabling re-runs the dependency install (minutes)."
  type        = bool
  default     = true
}

variable "base_image_name" {
  description = "Name of the Ubuntu 24.04 cloud image created in Glance for the builder VM."
  type        = string
  default     = "ubuntu-24.04-base"
}

variable "base_image_url" {
  description = "Source URL of the Ubuntu 24.04 cloud image."
  type        = string
  default     = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
}

variable "builder_name" {
  description = "Name of the builder instance (also prefixes its flavor, keypair, security group and port)."
  type        = string
  default     = "k8s-image-builder"
}

variable "builder_flavor" {
  description = "Builder VM size. Each qemu build runs a nested VM, so the hypervisor must expose nested virtualization. `disk` holds the image-builder checkout, caches and ~20GB of output per build. `ram` is in MB."
  type = object({
    vcpus = number
    ram   = number
    disk  = number
  })
  default = {
    vcpus = 4
    ram   = 8192
    disk  = 100
  }
}

variable "builder_network_name" {
  description = "Existing network to put the builder on. It must give the builder outbound reach to github.com, pkgs.k8s.io, dl.k8s.io, ubuntu mirrors and container registries (through NAT64/DNS64 if IPv6-only), and be routable from where tofu runs."
  type        = string
  default     = "vlan1000-net"
}

variable "builder_subnet_name" {
  description = "Existing subnet on builder_network_name to allocate the builder's address from."
  type        = string
  default     = "vlan1000-subnet-v6"
}

variable "builder_ssh_public_key" {
  description = "Public key injected for the builder's `ubuntu` user. Its private half must be in the ssh-agent that runs tofu."
  type        = string
  default     = null
}

variable "builder_ssh_allowed_prefixes" {
  description = "IPv6 prefixes allowed to SSH to the builder; must include wherever tofu runs from."
  type        = list(string)
  default     = ["fd97:45c2:b3a1:101::/64", "fd92:b792:95e:db94::/64"]
}

variable "builder_dns64_servers" {
  description = "The only DNS servers the builder uses (replacing the ones the subnet advertises), which must be the local DNS64 that synthesizes into the local NAT64 prefix. The subnet also advertises a public DNS64 whose 64:ff9b::/96 answers cannot reach private IPv4 addresses such as the PCD API. Empty keeps whatever the subnet provides."
  type        = list(string)
  default     = ["fd97:45c2:b3a1:64::64"]
}

variable "builder_interface_name" {
  description = "Name cloud-init gives the builder's NIC (the netplan id). The fixed-address netplan override must use the same id to merge with cloud-init's. ens3 for this flavor/image; check `ip link` if the flavor or machine type changes."
  type        = string
  default     = "ens3"
}
