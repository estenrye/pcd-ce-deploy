# PCD Day-1 infra via OpenTofu

Onboards the lab's hosts into the already-installed PCD CE management plane
(see `../ansible/install-pcd.yml`) using the
[`platform9/pcd`](https://registry.terraform.io/providers/platform9/pcd/latest/docs)
provider: cluster blueprint, host cluster, host config, and the cluster roles
that turn a bare host into a hypervisor/image-library node.

This is Day-1 infrastructure onboarding, not Day-2 workload config (tenants,
networks, images, flavors) — that's a separate concern the `pcd` provider also
supports but this project doesn't manage yet.

## Prerequisites

- PCD CE installed and reachable at `pcd_auth_url` (default assumes
  `pcd.rye.ninja`, matching `ansible/install-pcd.yml`).
- [OpenTofu](https://opentofu.org/) >= 1.6.
- A [1Password service account](https://developer.1password.com/docs/service-accounts/)
  with read access to a vault containing a **Login** item for the PCD admin
  user (its `username`/`password` fields are read directly — no extra field
  mapping needed).
- The resmgr UUID of each host to onboard (PCD UI → Infrastructure → Hosts →
  click the host) and the name of its management NIC (`ip a` on the host).

## Setup

```sh
export OP_SERVICE_ACCOUNT_TOKEN=$(op read "op://<vault>/<item>/credential")

cd tofu-pcd
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars: onepassword_vault, host_id, host_mgmt_interface,
# cinder_nfs_export, glance_nfs_export (from ../tofu-truenas's outputs)

tofu init
```

## First apply: import the existing blueprint

PCD supports exactly one cluster blueprint per region, and the installer
already created it. Import it so Tofu adopts it instead of trying to create a
duplicate:

```sh
tofu import pcd_cluster_blueprint.main <blueprint_name>
```

Then reconcile `blueprint.tf` against what comes back in
`tofu plan` (in particular `vm_storage` and `virtual_networking`) before
applying — the values in `variables.tf` are lab defaults and may not match
what the installer actually configured.

## Storage backends: unverified

`blueprint.tf` builds `storage_backends_json`'s Cinder NFS entry from
standard upstream Cinder driver keys, since Platform9 doesn't publish this
field's schema. If `pcd_host_cluster_role.storage` (cluster.tf) fails to
converge on apply, don't fight it here — configure the NFS backend once
via the PCD UI (Infrastructure > Region > Blueprint > Storage), then

```sh
tofu import pcd_cluster_blueprint.main <blueprint_name>
```

again to pull in the real JSON PCD generates, and replace the guessed
block in `blueprint.tf` with it.

## Apply

```sh
tofu plan
tofu apply
```

`pcd_host_cluster_role.hypervisor` sets `wait_until_converged = true`, so
`apply` blocks until the host reports healthy (role convergence installs and
configures services on the host and can take several minutes).

## Adding another host

Duplicate the `pcd_host_config`/`pcd_host_config_assignment` pair in
`host_config.tf` and the `pcd_host_cluster_role` resources in `cluster.tf`
for the new host, or turn them into `for_each` over a map of hosts once
there's more than one — not worth the abstraction for a single host today.
