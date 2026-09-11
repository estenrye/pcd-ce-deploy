# Spec: Unattended virtualized TrueNAS SCALE provisioning in PCD CE

## Goal

Provision TrueNAS SCALE as a guest workload inside PCD CE (i.e. as a Nova
instance via `tofu-pcd-vms`, not a bare-metal box like the lab's existing
`nas.rye.ninja`), with:

1. **Zero human intervention** per instance — no clicking through the
   TUI installer, no console access, no manual first-login wizard.
2. **All pool/dataset/share configuration driven by the JSON-RPC 2.0 /
   WebSocket API** (https://api.truenas.com/v25.10/index.html), using the
   same `PjSalty/truenas` OpenTofu provider already proven in
   `tofu-truenas/` against the physical NAS.

## Non-goals

- Migrating the existing `tofu-truenas/` datasets (Cinder/Glance backends
  on `flash-pool`) onto a virtualized instance — this spec is about
  standing up *new* virtualized TrueNAS servers, for whatever workload
  needs one next (a second Cinder/Glance backend, a test NAS, per-tenant
  storage, etc.). Whether/when to move existing workloads onto one is a
  separate decision.
- Bare-metal/PXE unattended install (the HOSTKEY article's actual
  problem). Virtualized changes the problem shape enough that PXE
  isn't needed at all — see below.
- Automating the *golden image build* itself end-to-end in this pass.
  It's scripted and repeatable (Packer), but still a "build once, reuse
  many" offline step, not something `tofu-pcd-vms apply` does per instance.

## Investigated: does TrueNAS SCALE have cloud-init support for its own OS?

Checked before starting on Phase 1, since the whole plan hinges on *not*
needing it. **Confirmed no** — TrueNAS SCALE has no cloud-init, answer
file, kickstart, or any other unattended-install mechanism for its own
host OS, as of 25.10 (Goldeye), current at time of writing:

- The [25.10 install docs](https://www.truenas.com/docs/scale/25.10/gettingstarted/install/installingscale/)
  describe a fixed, purely interactive TUI sequence (install/upgrade
  choice → drive selection → destructive-install confirmation →
  `truenas_admin` auth method → admin password → UEFI/legacy boot choice)
  with no mention of a kickstart/answer-file/scripted mode at any point.
- iX Systems' own community forums confirm this is a known gap, not an
  oversight in the docs: [Automated install of SCALE? Answerfile
  deployment etc](https://forums.truenas.com/t/automated-install-of-scale-answerfile-deployment-etc/35976)
  and the older [AutoDeployment / Config Answer
  File](https://www.truenas.com/community/threads/autodeployment-config-answer-file.23918/)
  thread are both community members asking for exactly this, with no
  iX staff confirmation that it exists or is planned. No thread found
  claiming it now exists.
- The cloud-init material that *does* turn up in search results (e.g.
  [ak1ra-lab/truenas-vm-helper](https://github.com/ak1ra-lab/truenas-vm-helper),
  the [robertorosario.com](https://blog.robertorosario.com/setting-up-a-vm-on-truenas-scale-using-cloud-init/)
  and [barelybuggy.blog](https://barelybuggy.blog/2023/12/19/truenas-automatic-vm-cloud-init/)
  posts) is all about a completely different thing: using cloud-init to
  provision **guest VMs that run on top of TrueNAS SCALE's own
  KVM/libvirt virtualization feature** (Debian/Ubuntu guests TrueNAS is
  hosting). None of it touches TrueNAS's own first-boot/identity
  configuration — easy to confuse with what this spec needs, since the
  search terms overlap heavily.
- `truenas/middleware`'s `ix-preinit.service` (the only boot-time hook
  that looked promising by name) runs *TrueNAS-authored*
  `initshutdownscript` jobs already stored in its own config DB — it's
  the mechanism for *already-configured* systems to run custom pre-init
  scripts, not an entry point for injecting first-boot config into a
  fresh install. Confirms the DB is still the only real state store,
  consistent with why the HOSTKEY article had to write to
  `freenas-v1.db` directly for its bare-metal case.
- iX's own workaround for fleet deployment, per forum discussion, is the
  same thing this spec already proposes independently: install once,
  image the resulting disk, deploy the image everywhere. (TrueCommand,
  iX's fleet-management product, can also back up/restore a system's
  config — but it's a separate hosted product and doesn't remove the
  need for an initial install, so it isn't a substitute for the golden
  image and wasn't considered further.)

**Conclusion: no changes needed to the plan.** Phase 1 (golden image,
built via Packer, generalized, zero pool state baked in) and Phase 3
(100% of instance-specific config over JSON-RPC/WebSocket) already assumed
this answer rather than depending on cloud-init existing. The "open
question" about cloud-init in the original spec is resolved — remove it
rather than re-verify.

## Why the HOSTKEY approach only partially transfers

The article's hard problem was bare-metal PXE deployment: unique physical
disks per server, no API reachable until the OS is up, and TrueNAS's ISO
installer being interactive-only with no kickstart/answer-file mode. Their
fix was to skip the interactive installer and inject a pre-built system
image directly, then hand-write the SQLite config db (`freenas-v1.db`)
before first boot, since nothing else was reachable yet.

Virtualizing on PCD changes what's hard:

- There's no PXE step. A Nova instance boots directly from a Glance image
  onto a Cinder volume — if that image already *is* an installed, bootable
  TrueNAS SCALE disk, the "installer" problem disappears entirely: build
  it once, boot it as many times as needed.
- Unlike HOSTKEY's bare-metal fleet, every instance here is provisioned
  from the *same* golden image onto virtual disks with predictable device
  paths — no per-server disk-layout logic needed.
- Crucially, **this repo already has a working, non-HOSTKEY-style pattern
  for TrueNAS automation**: `tofu-truenas/` drives an already-running
  TrueNAS purely over its JSON-RPC/WebSocket API via the `PjSalty/truenas`
  Terraform provider — no DB-file surgery. That provider is far more
  capable than what HOSTKEY had available (or needed) for their bare-metal
  case: it has a first-class `truenas_pool` resource (pool create/export/
  import) and a `truenas_disk` data source, which HOSTKEY's approach
  didn't use because pool creation for them happened before the API was
  ever reachable. Here, we can push pool creation itself onto the API too,
  which is exactly what was asked for.

So the plan is: **golden image (build once) + Nova/Cinder provisioning
(repeatable, via `tofu-pcd-vms`) + JSON-RPC bootstrap/config (repeatable,
via a new Tofu project modeled on `tofu-truenas/`)**. No PXE, no DB
injection, no bespoke installer image.

## Architecture

```
┌─────────────────────────┐   one-time    ┌───────────────────────────┐
│ Packer (QEMU builder)   │──────────────▶│ Golden qcow2 image:       │
│ scripted TUI install +  │               │ TrueNAS SCALE installed,  │
│ sysprep (see Phase 1)   │               │ generalized, HTTPS+API up │
└─────────────────────────┘               └─────────────┬─────────────┘
                                                          │ hosted at a URL
                                                          ▼
┌────────────────────────────────────────────────────────────────────┐
│ tofu-pcd-vms  (existing project, extended — Phase 2)                │
│  - pcd_images_image: registers the golden image in Glance           │
│  - pcd_compute_instance: boots the VM (DHCP + Designate DNS,        │
│    reusing external-net/dns_zone.tf already in place)               │
│  - pcd_blockstorage_volume + pcd_compute_volume_attach: blank data  │
│    disks that become the ZFS data pool's vdevs                      │
└─────────────────────────────────┬────────────────────────────────────┘
                                  │ VM's FQDN (from Designate) + volume
                                  │ identifiers, copied into the next
                                  │ project's tfvars (same manual-wiring
                                  │ convention tofu-truenas → tofu-pcd
                                  │ already uses — see its README)
                                  ▼
┌────────────────────────────────────────────────────────────────────┐
│ tofu-truenas-vm  (new project, Phase 3)                             │
│  provider "truenas" { url = "https://<instance>.<dns-zone>" ... }   │
│  - truenas_user / truenas_api_key: rotate bootstrap credentials     │
│  - truenas_disk (data source): identify the attached blank disks    │
│  - truenas_pool: create the data pool from those disks              │
│  - truenas_dataset / truenas_share_nfs / truenas_share_smb / etc.:  │
│    whatever the consuming workload needs                            │
└────────────────────────────────────────────────────────────────────┘
```

Two Tofu projects, not one — same reasoning `tofu-truenas/README.md`
already gives for keeping TrueNAS and PCD state separate: different blast
radii. `tofu-pcd-vms` failing shouldn't touch pool/dataset state, and a bad
`truenas_pool` apply shouldn't touch the VM/network/volume state.

## Phase 1: Golden image build (one-time, offline)

Build target: a qcow2 disk with TrueNAS SCALE installed and **generalized**
— no instance-specific identity baked in, everything instance-specific
applied later over the API.

1. **Automate the install**, don't hand-click it. Use
   [Packer](https://developer.hashicorp.com/packer)'s QEMU builder on the
   same KVM host already used for `ansible/provision-vm.yml` (it already
   has `qemu-kvm`/`libvirt`/`cloud-image-utils` installed). Packer's
   `boot_command` sends scripted keystrokes over the VNC/serial console to
   drive the TUI installer non-interactively — install to the primary
   virtual disk, set a throwaway bootstrap admin password (documented
   here, e.g. `bootstrap-only-rotated-on-first-apply`, never used again
   after Phase 3 runs), no additional pools.
2. **Size the boot disk generously**: TrueNAS SCALE's boot-pool holds
   multiple boot environments (one per update), so undersizing costs you
   update headroom later, not just initial install space. 32 GB minimum,
   64 GB recommended — this becomes the new flavor's/image's `min_disk`.
3. **Generalize before shutdown** (the "sysprep" step):
   - Confirm network is plain DHCP on the primary interface (no static
     config, no hostname baked in beyond a placeholder) — every instance
     picks up its own address/hostname via Neutron DHCP + Designate.
   - Leave the HTTPS management UI/API on its default port, reachable on
     that DHCP'd interface.
   - Do **not** create any data pool in the image — Phase 3 creates it
     per-instance from that instance's own attached (blank) volumes.
   - Confirm the API is reachable pre-shutdown with the bootstrap
     password, as a build-time smoke test (`auth.login_ex` per the
     provider's v2.4.0 changelog note — see Phase 3's version-compat
     callout).
4. **Convert & publish**: `qemu-img convert -O qcow2` the resulting disk,
   host it somewhere `pcd_images_image.image_source_url` can fetch from
   (an internal static file server is enough — no need for anything
   fancier than what `compute_images`/`images.tf` already expects).
5. **Version the build**: tag the artifact with the TrueNAS SCALE version
   baked in (e.g. `truenas-scale-25.10-golden-v1.qcow2`) and keep the
   Packer template in-repo (`packer/truenas-scale/`, alongside
   `tofu-pcd-vms`) so a rebuild for a new SCALE release is a rerun, not
   tribal knowledge.

This is the only step in the whole pipeline that isn't "provision an
instance with no human intervention" — but it happens once per SCALE
version, not once per instance, and it's scripted/repeatable rather than
a one-off manual click-through.

## Phase 2: `tofu-pcd-vms` additions

Everything here follows patterns already in the project (`images.tf`,
`instance.tf`, `variables.tf`) — additions, not a new pattern:

```hcl
compute_images = {
  # ...existing cirros entry...
  "truenas-scale-25-10" = {
    source_url  = "https://<internal-host>/images/truenas-scale-25.10-golden-v1.qcow2"
    min_disk    = 64
  }
}

compute_flavors = {
  "truenas-vm" = {
    vcpus = 4
    ram   = 8192
    disk  = 64   # matches the golden image's boot-pool sizing
  }
}

compute_instances = {
  "vnas-01" = {
    image_name      = "truenas-scale-25-10"
    flavor_name     = "truenas-vm"
    key_pair        = "esten-personal"       # unused by TrueNAS itself, but
                                              # required by the resource today
    security_groups = ["allow-truenas-mgmt"]
    networks        = ["external-net"]
  }
}

block_storage_volumes = {
  "vnas-01-data-1" = { size = 500, volume_type = "volume_storage" }
  "vnas-01-data-2" = { size = 500, volume_type = "volume_storage" }
}

compute_volume_attachments = {
  "vnas-01-data-1-attach" = { instance_name = "vnas-01", volume_name = "vnas-01-data-1" }
  "vnas-01-data-2-attach" = { instance_name = "vnas-01", volume_name = "vnas-01-data-2" }
}
```

New security group needed (`allow-truenas-mgmt`): TCP 443 (web UI + JSON-RPC
WebSocket at `/api/current`) from wherever Tofu itself runs, plus whatever
NFS/SMB/iSCSI ports the eventual consumers of the pool need — scope this
to specific source CIDRs the same way `nfs_allowed_networks` does in
`tofu-truenas/`, not `0.0.0.0/0`.

DNS: `external-net` is already associated with a Designate zone
(`usmnblm01.rye.ninja.`) with `dns_publish_fixed_ip = true`, so
`vnas-01.usmnblm01.rye.ninja` resolves automatically once the instance's
port comes up — this is what Phase 3's `truenas_url` points at. No new DNS
wiring needed.

Note: `pcd_compute_instance` mirrors `terraform-provider-openstack`/
gophercloud, which supports a `user_data` attribute (confirmed present in
the vendored provider binary's schema strings) — but it isn't currently
exposed on `tofu-pcd-vms`'s `pcd_compute_instance` resource or the
`compute_instances` variable, and there's no point wiring it up for this
project: TrueNAS SCALE has no cloud-init support for its own OS (confirmed
above), so `user_data` would never reach anything that consumes it. Phase
3 doing 100% of instance-specific config over the API instead isn't a
fallback for an unconfirmed capability — it's the only mechanism that
exists.

## Phase 3: new `tofu-truenas-vm` project

Modeled directly on `tofu-truenas/`'s existing structure
(`providers.tf`, `variables.tf`, `datasets.tf`, `nfs.tf`, `outputs.tf`),
pointed at the freshly-booted instance instead of the physical NAS:

```hcl
# providers.tf — same 1Password desktop-app pattern as tofu-truenas/
provider "truenas" {
  url      = var.truenas_url        # e.g. "https://vnas-01.usmnblm01.rye.ninja"
  api_key  = data.onepassword_item.truenas_bootstrap_key.credential
  username = var.truenas_username
}
```

```hcl
# pool.tf
data "truenas_disk" "data" {
  for_each = var.data_disk_serials
  serial   = each.value
}

resource "truenas_pool" "data" {
  name = var.pool_name
  topology_json = jsonencode({
    data = [{
      type  = var.pool_vdev_type   # "STRIPE" for a lab, "MIRROR"/"RAIDZ1" for anything real
      disks = [for d in data.truenas_disk.data : d.identifier]
    }]
  })
}

resource "truenas_dataset" "workload" {
  pool = truenas_pool.data.name
  name = var.dataset_name
  compression = "LZ4"
  atime       = "OFF"
}

resource "truenas_share_nfs" "workload" {
  path     = truenas_dataset.workload.mount_point
  networks = var.nfs_allowed_networks
  depends_on = [truenas_service.nfs]
}
```

(`topology_json`'s exact shape and `truenas_disk`'s exact lookup key —
`serial` vs. `identifier` vs. device path — need to be pulled from the
provider's registry docs during implementation; the local vendored copy in
this repo only ships the binary + README, not `docs/resources/*.md`. Check
`registry.terraform.io/providers/PjSalty/truenas/latest/docs/resources/pool`
and `.../data-sources/disk` before writing this file for real.)

### Credential bootstrap & rotation

1. Golden image ships with the throwaway bootstrap password from Phase 1.
2. First `tofu-truenas-vm apply` authenticates with that bootstrap
   credential (stored in 1Password just like every other secret in this
   repo, title e.g. `truenas-vm-bootstrap`), then:
   - `truenas_user` (admin/`truenas_admin` account): sets a freshly
     generated, per-instance password.
   - `truenas_api_key`: issues a scoped API key for this instance,
     written to a 1Password item Tofu itself creates (the `onepassword`
     provider supports the `onepassword_item` *resource*, not just the
     data source used elsewhere in this repo so far).
   - Every subsequent apply re-authenticates with the *new* key, not the
     bootstrap one — matches the "rotate before it becomes tribal secret
     debt" pattern implied by `tofu-truenas/`'s existing 1Password setup.
3. Note the provider's own CHANGELOG (`2.4.0`): set `username` explicitly
   once TrueNAS ships 26/27, since `auth.login_with_api_key` (the
   no-`username` path) is deprecated in 26 and removed in 27. Do this from
   day one here rather than retrofitting it later.

### Readiness gating

Terraform has no native "wait until this HTTPS endpoint answers" resource.
Nova reporting the instance ACTIVE doesn't mean TrueNAS's middleware has
finished its own boot sequence yet (services start well after `login`
would normally appear on a console). Options, in preference order:

1. Let the `truenas` provider's own connection retry/backoff absorb it, if
   it has one — check before adding anything else.
2. If not, a small `null_resource` with a `local-exec` curl/websocket
   polling loop against `${var.truenas_url}/api/current`, gating
   `depends_on` for everything else in this project — same shape as the
   `ssh_resource` retry_delay pattern already used in `tofu-pcd-vms`'s
   `dns_zone.tf`.

## Reusability across multiple instances

`compute_instances`/`block_storage_volumes` in `tofu-pcd-vms` are already
`for_each`-based maps, so a second `vnas-02` is just another map entry.
`tofu-truenas-vm` should follow the same shape once there's a second
instance to manage (a map of instance name → {url, disk serials, pool
config}) rather than the single-instance variables sketched above — but
per `tofu-pcd/README.md`'s own stated philosophy ("not worth the
abstraction for a single host today"), start with one instance's worth of
flat variables and generalize to `for_each` only when a second instance
actually shows up.

## Open questions to validate in the lab before/during implementation

- Exact `truenas_pool` `topology_json` schema and `truenas_disk` lookup
  key (serial vs. device path vs. TrueNAS's own disk `identifier` string)
  — pull from provider docs, confirm against a real attached Cinder
  volume's device path inside a booted guest.
- Whether Cinder-attached virtio-scsi volumes present stable, predictable
  serials across reboots/reattachment (needed for `truenas_disk` lookups
  to stay correct across applies) — `tofu-truenas/README.md`'s NFS-network
  caveats suggest this environment has had subtle addressing gotchas
  before; check rather than assume.
- Minimum viable `compute_flavors` sizing for TrueNAS SCALE under real
  workload (4 vCPU / 8 GB RAM above is a lab-scale guess, not a
  TrueNAS-published minimum — SCALE's docs list higher RAM recommendations
  once ZFS ARC and any apps/VMs on the NAS itself are considered).
- Whether `truenas_pool` on a *virtualized* multi-disk topology
  (MIRROR/RAIDZ across Cinder volumes that may all land on the same
  underlying physical array) provides any real redundancy benefit here,
  versus just protecting against logical/filesystem-level errors — worth
  being explicit with whoever consumes this pool about what failure modes
  it actually covers.

## Phased implementation plan

1. **Packer template** for the golden image (`packer/truenas-scale/`),
   producing a versioned qcow2 artifact + a build-time smoke test that
   confirms JSON-RPC login succeeds with the bootstrap credential.
2. **`tofu-pcd-vms` additions**: image, flavor, security group, one
   instance + attached data volumes (as in Phase 2), applied and confirmed
   reachable (DNS resolves, port 443 answers) before touching Phase 3.
3. **`tofu-truenas-vm` v0**: credential rotation only (`truenas_user`,
   `truenas_api_key`) against the live instance — smallest possible slice
   that proves the JSON-RPC bootstrap loop works end to end.
4. **`tofu-truenas-vm` v1**: add `truenas_pool` + `truenas_disk` — the
   actual "automate pool configuration via the API" requirement.
5. **`tofu-truenas-vm` v2**: datasets/shares for whatever the first real
   consumer needs (NFS to start with, matching the existing
   `tofu-truenas/` pattern; SMB/iSCSI only if a consumer needs them).
6. **Generalize to multiple instances** (`for_each` conversion per the
   "Reusability" section) once a second instance is actually needed.
