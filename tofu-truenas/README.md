# TrueNAS datasets via OpenTofu

Creates the two ZFS datasets and NFS exports that back PCD CE's Cinder
(block storage) and Glance (image library) backends, using the
[`PjSalty/truenas`](https://registry.terraform.io/providers/PjSalty/truenas/latest/docs)
provider — JSON-RPC 2.0 over WebSocket only, no REST. That matters because
TrueNAS's REST API is deprecated as of 25.04 and is gone entirely in 26; this
avoids building on something scheduled for removal.

Separate state from `../tofu/` (PCD infra) on purpose: TrueNAS and PCD are
different systems with different blast radii, and a bad apply on one
shouldn't touch the other's state.

## What this creates

| Resource | Dataset | Purpose |
|---|---|---|
| `truenas_dataset.cinder` | `flash-pool/pcd-ce-cinder` | Cinder (block storage) NFS backend |
| `truenas_dataset.glance` | `flash-pool/pcd-ce-glance` | Glance (image library) NFS backend |

Plus `truenas_service.nfs` (ensures the NFS service is enabled/running) and a
`truenas_share_nfs` export for each dataset, root-squash mapped to `root`
since PCD's Cinder/Glance services write to these mounts as root.

## Prerequisites

- TrueNAS SCALE 25.10+ reachable over HTTPS.
- An API key: TrueNAS UI → Credentials → Local Users → the account in
  `truenas_username` (default `admin`) → API Keys.
- The NAS's storage-network address — the interface NFS clients actually
  mount, which is **not** assumed to be the same as `truenas_url`'s
  management/API endpoint. On this NAS the two are on separate interfaces;
  see `truenas_nfs_host` below.
- A vault containing an **API Credential** item whose `credential` field
  holds that API key (read directly — no extra field mapping needed).
- The 1Password 8 desktop app, running and unlocked, with **Settings →
  Developer → "Integrate with 1Password CLI"** enabled. Auth to 1Password
  goes through the desktop app's biometric/system unlock rather than a
  static service account token — no `op signin` or token to manage.
- OpenTofu >= 1.6.

## Setup

```sh
cd tofu-truenas
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars: onepassword_account, truenas_url (admin/API), truenas_nfs_host (storage network)

tofu init
tofu plan
tofu apply
```

The first JSON-RPC call each run triggers a biometric/system-unlock prompt
from the desktop app to authorize reading the vault item; no secret ever
sits in your shell environment or history.

## NFS access

`nfs_allowed_networks` (in `variables.tf`) is pinned to the specific hosts
that need to mount these exports — the PCD management VM plus the hosts at
`10.45.60.1-3` — each listed as a single-host CIDR (IPv4 `/32`, IPv6
`/128`). Use single-host masks here, not the network's own `/16`/`/64`:
TrueNAS rejects entries that normalize to the same subnet as "overlapped
subnets", and every host here sits on the same `/16` and `/64`. Add an
entry for any new host that needs access.

## Wiring into PCD

`tofu apply` outputs `cinder_nfs_export` and `glance_nfs_export` as
`host:/mnt/pool/dataset` strings. Those feed PCD's cluster blueprint over in
`../tofu/`:

- `glance_nfs_export` → `pcd_cluster_blueprint.main.image_library_storage`
  (set `image_library_shared_storage = true` alongside it)
- `cinder_nfs_export` → a `nfs` backend entry in
  `pcd_cluster_blueprint.main.storage_backends_json`, and its name added to
  `pcd_host_cluster_role.storage.backends` (currently commented out in
  `../tofu/cluster.tf`, waiting on this)

That wiring isn't done here since it lives in the other project's state.
