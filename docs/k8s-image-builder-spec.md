# Spec: `tofu-pcd-k8s-image-builder` - PCD-K Kubernetes image pipeline

Status: **implemented in `tofu-pcd-k8s-image-builder/`; `tofu validate` and `tofu plan` pass, nothing applied or live-tested.** Deviations from this text: `workstation` upload mode and `parallel_builds` are not implemented (builds serialize on a flock); the builder boots from the flavor's disk instead of a separate volume; `image_builder_ref` defaults to `v0.1.55`, which has `build-qemu-ubuntu-2404` and `pkgs.k8s.io` has 1.37 (checked 2026-10-15). Facts from the PCD docs and the
image-builder book are cited. Everything marked **VERIFY** comes from memory or
inference and must be checked before it is relied on.

## Goal

From one `tofu apply`, produce Glance images that PCD-K (Private Cloud Director
Kubernetes) accepts as node OS images, one per requested Kubernetes minor
version and OS pair. The initial set is Kubernetes **1.32, 1.33, 1.34, 1.35,
1.36, 1.37**, each on Ubuntu 24.04. The OS is part of each entry, so a
version can later be built on more than one OS.

Per the README, the module:

1. Installs an Ubuntu 24.04 base image into Glance.
2. Provisions an Ubuntu 24.04 server from it and configures it as an image build host.
3. Runs `kubernetes-sigs/image-builder` on that host to build one qcow2 per
   version, and registers each in Glance as a PCD-K-compliant image.

## Non-goals

- Talos images. `tofu-pcd-talos-cluster/image.tf` already covers those.
- Creating PCD-K clusters from the images. This module stops at "image is in Glance".
- OSes other than Ubuntu 24.04 in the default set. `os` is a per-entry field, so
  Ubuntu 22.04 can be added later, but only 24.04 is specified and tested.
- Deleting images. Tofu never deletes built images (see "Image retention").
- CVE scanning or boot-testing each image. See "Validation".
- Building the images on the operator's workstation.

## What PCD-K requires of an image

From the [PCD docs](https://docs.platform9.com/private-cloud-director/kubernetes-clusters/kubernetes-operating-system-image-management):

| Requirement | Detail |
|---|---|
| OS | Ubuntu 22.04 or 24.04 |
| Format | qcow2, Cluster API compliant, matching the Kubernetes version deployed |
| Glance property | `k8s_version` = **major.minor only**, e.g. `1.32` (the docs add it by hand in the UI) |
| Build tool | kubernetes-sigs/image-builder, `images/capi`, qemu builder |
| Build host | Ubuntu with nested virtualization; `make deps-qemu` installs deps |
| Host packages | `make jq unzip qemu-kvm libvirt-daemon-system libvirt-clients virtinst cpu-checker libguestfs-tools libosinfo-bin` |

Gaps in the docs: they show only `build-qemu-ubuntu-2204`, give no naming
convention, and give no list of supported versions. **VERIFY** that PCD-K
accepts 1.35, 1.36 and 1.37 (and what it does with a `k8s_version` it does not
know), and that image-builder's `build-qemu-ubuntu-2404` target works for each.

## Architecture

```
workstation (tofu)
  |  1. pcd_images_image.ubuntu_base      Ubuntu 24.04 cloud image -> Glance
  |  2. builder instance (+ port, SG, flavor, keypair, volume)
  |  3. ssh: wait for cloud-init, deps installed
  |  4. per version (for_each): ssh -> make build-qemu-ubuntu-2404
  |  5. per version: upload qcow2 to Glance + set properties
  v
Glance: ubuntu-2404-kube-v1.32.x ... ubuntu-2404-kube-v1.37.x   (each k8s_version=1.xx)
```

Matching sibling modules (`tofu-pcd-vms`, `tofu-pcd-talos-cluster`): a root
configuration with `providers.tf`, `versions.tf`, `variables.tf`, `outputs.tf`.
Providers are `platform9/pcd` (pinned `~> 0.1` to the Terraform registry),
`1Password/onepassword` for the PCD admin credentials, `loafoe/ssh`,
`hashicorp/http`, and `hashicorp/random`.

### File layout

```
tofu-pcd-k8s-image-builder/
  providers.tf versions.tf variables.tf outputs.tf
  base_image.tf        # Ubuntu 24.04 cloud image -> Glance
  builder.tf           # flavor, keypair, SG, port, volume, instance
  locals.tf            # k8s version resolution, image names
  build.tf             # per-version build + upload
  files/
    cloud-init.yaml.tftpl    # installs deps, clones image-builder at pinned ref
    build.sh.tftpl           # one build: writes var file, runs make, uploads
  README.md
```

## Inputs

| Variable | Type | Default | Purpose |
|---|---|---|---|
| `kubernetes_versions` | `map(object)` | the 6 entries below | One entry per image. Key = free-form unique id (convention `"<minor>-<os>"`, e.g. `"1.32-ubuntu-2404"`). Value = `{ minor = string, os = optional(string, "ubuntu-2404"), patch = optional(string) }`. `os` is the suffix of the image-builder target `build-qemu-<os>`. See "Version resolution". |
| `image_builder_ref` | string | a tag or commit SHA | Pinned git ref of kubernetes-sigs/image-builder. Never a branch. |
| `extra_packer_vars` | `map(string)` | `{}` | Merged into the per-build `PACKER_VAR_FILES` JSON (e.g. proxy, `containerd_version`). |
| `ubuntu_base_image_url` | string | Canonical `noble` cloud image | Source for step 1. |
| `builder_flavor` | object | 8 vCPU / 16 GiB | Needs nested virt. |
| `builder_disk_gb` | number | 100 | Boot volume. Each build needs ~20 GB scratch. |
| `builder_network_id` / `builder_security_group_ids` | string / list | - | Must provide **outbound access** (see Risks). |
| `builder_ssh_public_key` | string | - | Key for the tofu ssh provider. |
| `builder_enabled` | bool | `true` | `false` destroys the VM and keeps the images. |
| `image_visibility` | string | `public` | **VERIFY** which visibility PCD-K needs to list it. |
| `parallel_builds` | number | 1 | Builds run in sequence by default (RAM/disk). |
| `upload_mode` | string | `builder` | `builder` or `workstation`. See "Upload". |
| PCD/1Password auth vars | | | Same as `tofu-pcd-talos-cluster/variables.tf`. |

### Version resolution

image-builder needs four coupled variables per build
([docs](https://image-builder.sigs.k8s.io/capi/capi)): `kubernetes_semver`
(`v1.32.9`), `kubernetes_series` (`v1.32`), `kubernetes_deb_version`
(`1.32.9-1.1`), `kubernetes_rpm_version` (`1.32.9`). Also `crictl_version`
(**VERIFY** that it must track the minor).

Default value:

```hcl
kubernetes_versions = {
  "1.32-ubuntu-2404" = { minor = "1.32" }
  "1.33-ubuntu-2404" = { minor = "1.33" }
  "1.34-ubuntu-2404" = { minor = "1.34" }
  "1.35-ubuntu-2404" = { minor = "1.35" }
  "1.36-ubuntu-2404" = { minor = "1.36" }
  "1.37-ubuntu-2404" = { minor = "1.37" }
}
```

- If `patch` is unset, resolve the latest patch at plan time from
  `https://dl.k8s.io/release/stable-<minor>.txt` via `data "http"`.
- If `patch` is set, use it as given, and fail validation if it does not start with `minor`.
- Derive the four variables in `locals.tf`. **VERIFY** the deb revision suffix
  (`-1.1`) against `pkgs.k8s.io` for each version, because it can vary. If it
  does, resolve it from the apt repo `Packages` index instead of hard-coding it.
- Validate that every `minor` matches `^1\.\d+$`, and that no two entries share the same
  `(minor, os)` pair.
- Validate `os` against an allowed list (`ubuntu-2204`, `ubuntu-2404`). **VERIFY** each
  `build-qemu-<os>` target exists in the pinned ref.

Do not edit image-builder's `config/*.json`. Write a generated per-build JSON
file and pass it with `PACKER_VAR_FILES`, as the book recommends (last file wins).

## Resources

1. **Base image**: `pcd_images_image.ubuntu_base`. `disk_format=qcow2`,
   `container_format=bare`, `image_source_url` = Canonical cloud image,
   `visibility=private`. Name `ubuntu-24.04-base`.
2. **Builder**: flavor, keypair, SG (egress all, ingress 22 from the operator range),
   port, boot volume, instance from the base image. Cloud-init (`#cloud-config`,
   never empty, per the config-drive quirk in memory) installs the PCD host
   package list above plus `python3-pip git build-essential`, adds the
   `ubuntu` user to `kvm`, clones `image_builder_ref` into `/opt/image-builder`,
   and runs `make deps-qemu` in `images/capi`. It also installs the `openstack`
   CLI when `upload_mode=builder`. It writes a sentinel file when done.
3. **Readiness**: `data "ssh_resource"` or `terraform_data` polling for the sentinel.
   Fails if `/dev/kvm` is absent (nested virt check, before any build).
4. **Per version** (`for_each = kubernetes_versions`): one `terraform_data.build[key]`
   with `triggers_replace` = `{ semver, os, image_builder_ref, sha256(extra_packer_vars) }`.
   It runs `build.sh` over ssh:
   - skip everything if an image with the target name already exists in Glance;
   - write the var file, then `PACKER_VAR_FILES=... PACKER_LOG=1 make build-qemu-<os>`;
   - locate the qcow2 in `output/<BUILD_NAME>+kube-<semver>/`;
   - `qemu-img convert -c` if it is not already compressed.
5. **Image registration** (see "Upload"). Name: `<os>-kube-v<semver>-<ref>`, e.g. `ubuntu-2404-kube-v1.32.9-<first 7 of image_builder_ref>`.
   Properties: `k8s_version=1.32` (required), plus `os_distro=ubuntu`,
   `os_version=24.04`, `kubernetes_semver`, `image_builder_ref`, `managed_by=tofu-pcd-k8s-image-builder`.
   **VERIFY** that `pcd_images_image` can set arbitrary properties. If not,
   use the `openstack` CLI from the builder (hence `upload_mode=builder` as the default).

### Upload

Memory shows that pushing a multi-GB image from the workstation over weak
Wi-Fi took about an hour and then failed (Glance's nginx returned 408/400
when the stream stalled; see `tofu-pcd-talos-cluster/image.tf`). So:

- **`builder` (default)**: the builder runs `openstack image create` against
  the local Glance endpoint. No bytes cross the workstation. It needs
  credentials on the builder. Pass them only for the duration of the provisioner
  (env vars in the ssh command), never in cloud-init or tofu outputs. Tofu
  has no destroy-time provisioner for images (see "Image retention"). Outputs
  read the image ID back with `openstack image show`.
- **`workstation`**: `scp` the qcow2 down, then `pcd_images_image` with
  `local_file_path` (fully tofu-managed, properties via the provider). Simple but slow.

## Image retention

Built images are **never deleted by tofu**: no destroy-time provisioner, no
`pcd_images_image` that would delete on replace. Existing PCD-K clusters
reference these images, so a rebuild adds a new image next to the old one, and
`tofu destroy` leaves them in Glance. Image names are unique per
`(os, semver, image_builder_ref)`, and a build that finds its name already in
Glance is a no-op. The `k8s_version` property is the same on old and new
images, so PCD-K lists both. Cleanup is manual (`openstack image delete`).
Outputs report the newest image per key (by `created_at`).
With `upload_mode=workstation`, the image is created through a mechanism that
does not delete on replace (**VERIFY**; otherwise use the CLI path).

## Outputs

- `images`: `map(key => { id, name, os, semver, k8s_version })`, newest image per entry
- `builder_ip`, `builder_instance_id` (null when `builder_enabled=false`)
- `ubuntu_base_image_id`

## Behavior

- **Adding a version**: add a map key, apply, and only that build runs.
- **New patch release**: with `patch` unset the data source returns a new semver,
  so the trigger changes and a new image is built under a new name. The old image stays in Glance.
- **Pinning**: set `patch` to freeze a version.
- **Rebuild all**: bump `image_builder_ref` or `extra_packer_vars`.
- **Failure**: `build.sh` uses `set -euo pipefail`, logs to
  `/var/log/image-builder/<ver>.log` on the builder, and tofu surfaces the tail.
  A failed build leaves no Glance image behind (upload happens last).

## Validation

- Plan time: version map keys and patch/minor agreement, `image_visibility` in the allowed set.
- `lifecycle.precondition` that `/dev/kvm` exists on the builder.
- image-builder runs its Goss tests itself during the build, which is the only
  in-image check specified. An optional later phase could boot each image once
  in PCD and check kubelet/containerd versions. Not in scope here.
- Acceptance: for each of the six versions, the image appears in Glance with
  `k8s_version` set, and PCD-K lists it as selectable for the matching version.
  **Not verified until a cluster is created from it.**

## Risks and open questions

1. **IPv4-only sources via NAT64/DNS64.** A NAT64/DNS64 device exists, so the
   builder can sit on an IPv6-only network. The build pulls from `github.com`
   (no AAAA record), `pkgs.k8s.io`, `dl.k8s.io`, container registries and
   `archive.ubuntu.com`. All must work through DNS64. Requirements: the builder's
   network hands out the DNS64 resolver, and the NAT64 prefix is routable from it.
   **The harder part is the nested VM.** Packer's qemu builder uses user-mode
   networking, which NATs the *guest's* IPv4 out through the *builder's* sockets.
   An IPv6-only builder has no IPv4 route, so guest IPv4 traffic fails. It works only
   if the guest uses IPv6 end to end (slirp provides IPv6 and DNS forwarding, so
   DNS64 answers should apply). **VERIFY** early, because the Ubuntu autoinstall,
   Ansible and `apt` steps inside the guest may assume IPv4. Fallbacks, in order:
   (a) point the guest's resolver at the DNS64 server through `extra_packer_vars`;
   (b) give the builder a dual-stack network;
   (c) run an IPv4 proxy reachable over IPv6 and pass `http_proxy` / `https_proxy` through
   image-builder's proxy variables. Phase 1 should test fetching `github.com` and
   `pkgs.k8s.io` from inside a throwaway nested guest.
2. **Image accumulation.** Kept by decision, so Glance grows by one image per
   rebuild. Manual cleanup only.
3. **Nested virtualization.** The PCD hypervisor must expose `vmx`/`svm` to
   guests, and the CPU mode must be `host-passthrough` or similar. **VERIFY**
   on the CE host. Without it, the qemu build is unusably slow, and the
   fallback is image-builder's `openstack` (Packer-on-OpenStack) target, which
   would need a different design.
4. **Version availability.** **VERIFY** that 1.36 and 1.37 exist on
   `pkgs.k8s.io` and in the pinned image-builder ref. Older image-builder refs
   may lack apt repo series for newer minors. A single pinned ref that
   supports all six versions may not exist, and then `image_builder_ref` has to
   become per-version.
5. **Disk space.** Six builds in sequence leave about 6 x 3-8 GB of output;
   clean `output/` after each successful upload.
6. **Image visibility and project.** **VERIFY** which project PCD-K reads
   images from (the existing code uses the `service` tenant).
7. **Secrets.** Admin credentials from 1Password are used by the provider and,
   transiently, by the builder for upload (see Upload). Consider a dedicated
   Keystone application credential instead.
8. **Cost of idle builder.** `builder_enabled=false` after a run avoids it, but
   re-enabling re-runs `make deps-qemu` (minutes).

## Suggested phases

1. Base image + builder + readiness check; confirm `/dev/kvm` and NAT64/DNS64 reachability from a nested guest.
2. One version (1.32) end to end, `upload_mode=workstation` or `builder`, whichever works first.
3. Generalize to the `for_each` map and add the remaining five versions.
4. Create a PCD-K cluster from one image to prove the acceptance criterion.
