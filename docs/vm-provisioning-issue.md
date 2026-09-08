# VM build fails: "Failed to connect to Glance image service"

## Summary

Booting a VM fails every time at the image-fetch step, regardless of which
image is selected:

```
Build of instance bb46f501-fe7f-4728-bd56-b6382cc27f2e aborted: Failed to
connect to Glance image service: Failed to call glance method data with
args ('250e03af-145f-466b-bb49-ea6b4139bfa6',), {} on endpoints
['https://10.45.60.1:9494']
```

The volume step (Cinder) succeeds — this is unrelated to the earlier
persistent-storage/deauth-error incidents, both of which are confirmed
healthy. This is a **new, structural issue**: this PCD deployment has two
independent Glance backends that don't share image data, only image
metadata, and Nova always reads from the one that the image you just
uploaded almost certainly isn't on.

**Root cause:** the Keystone catalog's `glance` service has three endpoint
interfaces that currently point at two *different* Glance deployments:

| Interface | URL | Backing Glance |
|---|---|---|
| `admin` | `https://10.45.60.1:9494` | per-host `pf9-glance-role` on `pcd-ce-hyp-01`, Cinder-backed (image-library role) |
| `public` | `https://pcd.rye.ninja/glance/` | central `glance-api` pod in the k8s management cluster, local-file-backed |
| `internal` | `http://glance-api.pcd.svc.cluster.local:9292/` | same central k8s pod |

Clients (the `openstack` CLI, the PCD UI) default to the **public**
interface for uploads, which lands on the **k8s pod's local filesystem**.
Nova's PF9-patched image client (`nova.image.pf9_glance`) fetches image
*data* from the separate `glance-cluster` (type `image-cluster`) service
instead, which only has an **admin** endpoint — the per-host, Cinder-backed
instance. Both `glance` and `glance-cluster` share the same underlying
MySQL database (so image metadata/listing looks identical and consistent
everywhere), but **image bytes are not replicated between the two
backends**. Any image uploaded through the normal path is therefore
invisible to the backend Nova actually reads from, and every VM build fails
at the same step.

## Evidence

### 1. The image's metadata looks perfectly healthy

```
$ curl -sk -H "X-Auth-Token: $TOKEN" https://10.45.60.1:9494/v2/images/250e03af-145f-466b-bb49-ea6b4139bfa6
{
  "name": "cirros", "status": "active", "size": 21430272,
  "checksum": "c8fc807773e5354afe61636071771906",
  "os_hash_value": "1103b92ce8ad966e41235a4de260deb791ff571670c0342666c8582fbb9caefe6af07ebb11d34f44f8414b609b29c1bdf1d72ffa6faa39c88e8721d09847952b",
  "locations": [
    {"url": "file:///var/lib/glance/images/250e03af-145f-466b-bb49-ea6b4139bfa6", "metadata": {}}
  ]
}
```

Checksum and hash are populated (Glance computes these during a real data
upload — this wasn't a bare metadata record), `status` is `active`, and
`GET /v2/images?limit=10` against the hypervisor's own endpoint shows this
is the **only** image in the whole deployment. It's not a corrupt/partial
image — it's a normal, fully-uploaded image whose data simply isn't where
Nova is looking.

### 2. `enabled_backends` on the hypervisor's Glance only understands Cinder

```
$ sudo grep -n '^cinder_volume_type\|^enabled_backends\|^default_backend' /etc/glance/glance-api.conf
enabled_backends = cinder:cinder
default_backend = cinder
cinder_volume_type = image_library
```

No `file` store is enabled on this instance at all, so a `file://`
location is meaningless to it — hence the log below.

### 3. `pf9-glance-role`'s own log shows exactly why the fetch fails

```
$ sudo grep 250e03af... /var/log/pf9/glance-api.log
WARNING glance.common.store_utils  Invalid location uri file:///var/lib/glance/images/250e03af-145f-466b-bb49-ea6b4139bfa6
WARNING glance_store.multi_backend  Backend is not set to image, searching all backends based on location URI.
WARNING glance.location  Get image 250e03af-... data failed: Image not found in any configured backend.: glance_store.exceptions.NotFound
ERROR   glance.location  Glance tried all active locations to get data for image 250e03af-... but all have failed.
INFO    eventlet.wsgi.server  "GET /v2/images/250e03af-.../file HTTP/1.0" 204 168
```

That `204` with an empty body is what Nova's `pf9_glance.py` interprets as
"no response, ignoring this host" — and since this is the *only* host in
the `glance-cluster` endpoint list, "ignoring this host" means there are no
hosts left to try, producing the `GlanceConnectionFailed` seen by the user.

Critically: `grep`-ing `glance-api.log` on the hypervisor for the
timestamp the image was actually created (`2026-09-06 04:01:2x`) returns
**zero lines** — the create/upload request never touched this Glance
instance at all.

### 4. The image's real data is sitting in the central k8s Glance pod

```
$ sudo kubectl get pods -A | grep glance
pcd   glance-api-57c6586875-gtvsl   2/2   Running   0   2d18h

$ sudo kubectl exec -n pcd glance-api-57c6586875-gtvsl -c glance-api -- ls -la /var/lib/glance/images/
-rw-r----- 1 glance glance 21430272 Sep  6 04:01 250e03af-145f-466b-bb49-ea6b4139bfa6
-rw-r----- 1 glance glance 21430272 Sep  4 22:42 e3f509a3-5a3c-44ae-8c8d-e1b35164588a
```

The 21,430,272-byte file is exactly the image's registered `size`, timestamped
to the second the image record says it was created. This pod has been
running since the initial install (2d18h) — it's the deployment's original,
default Glance, present before the `image-library` role was ever assigned
to a hypervisor. (The second file, `e3f509a3-...`, predates this incident
and is an orphaned data file from some earlier deleted image — not part of
this issue, but a sign the same split has bitten this environment before.)

### 5. Keystone's own catalog shows the split directly

```
$ curl -sk -H "X-Auth-Token: $TOKEN" https://pcd.rye.ninja/keystone/v3/services
{"name": "glance", "type": "image", "id": "2900abb0da2e4f9a9088cd19e21d905a", ...}
{"name": "glance-cluster", "type": "image-cluster", "id": "ccdf7624a3c94a5ca8fc708d95cd8e5d", "description": "Platform9 Glance On-Host Cluster", ...}

$ curl -sk ... 'https://pcd.rye.ninja/keystone/v3/endpoints?service_id=2900abb0da2e4f9a9088cd19e21d905a'
admin    https://10.45.60.1:9494
public   https://pcd.rye.ninja/glance/
internal http://glance-api.pcd.svc.cluster.local:9292/

$ curl -sk ... 'https://pcd.rye.ninja/keystone/v3/endpoints?service_id=ccdf7624a3c94a5ca8fc708d95cd8e5d'
admin    https://10.45.60.1:9494
```

When the `image-library` role was applied to `pcd-ce-hyp-01` (resmgr's
`pf9-glance-role` settings include `update_public_glance_endpoint: true`),
it rewrote only the **`admin`** interface of the `glance` service catalog
entry to point at the new per-host instance, and registered that same host
as the sole endpoint for the separate `glance-cluster`/`image-cluster`
service that Nova's PF9 image client actually queries. It left `public` and
`internal` untouched, still pointing at the original k8s-hosted Glance.
Despite the option's name suggesting it updates the *public* endpoint, in
practice it only touched `admin` — that's the actual bug/gap.

## Why this wasn't visible until now

This is the first VM build attempted since the `image-library` role was
(re-)applied earlier today (see `docs/persistant-storage-role-stuck.md`).
Before that role existed on this host, `glance`'s `public`/`internal`/
`admin` endpoints presumably all pointed at the same k8s-hosted instance,
so uploads and Nova's fetches agreed. Assigning `image-library` introduced
the second (Cinder-backed) instance and split the catalog without anyone
touching `public`/`internal` — a normal, unremarkable-looking role apply
that happens to break every future image upload for VM booting purposes.

## Recommended solution

**Point `public` and `internal` at the same host-level Glance instance as
`admin`,** so upload and consumption always hit the one backend:

```
openstack endpoint set --url https://10.45.60.1:9494 <public-endpoint-id>
openstack endpoint set --url https://10.45.60.1:9494 <internal-endpoint-id>
```

(or the equivalent via the PCD UI / Keystone v3 API directly, since
`openstack` CLI isn't installed on either host here). This makes the
"Platform9 Glance On-Host Cluster" instance the single source of truth for
both control-plane and data-plane image operations, matching the
architecture's evident intent — `glance-cluster` already treats
`10.45.60.1` as the only member.

**Then re-upload the cirros image** (or any image you want to boot from) —
the existing `250e03af-...` record's data lives only in the k8s pod and
can't be migrated in place without direct filesystem access to that pod;
it's simplest to delete and re-create it once the endpoints agree.

## Considered: reconfiguring the central k8s pod instead

Before repointing the catalog, we considered the reverse — making the
central `glance-api` k8s pod itself speak Cinder, so `public`/`internal`
would serve real data without touching the catalog. Ruled out:

- Its config comes from a Helm-managed ConfigMap (`glance-bin`), currently
  setting only `filesystem_store_datadir` — no `enabled_backends` /
  `default_backend` / `cinder_volume_type` at all. A restart alone changes
  nothing; the ConfigMap would need editing first.
- More fundamentally, the pod has **zero capabilities**
  (`CapEff: 0000000000000000`) and none of `iscsiadm`/`multipath`/
  `cinder-rootwrap` are present in the image. The `cinder` glance_store
  driver attaches the backing volume locally via os-brick (iSCSI
  login/mount) before it can read or write bytes — this container is
  architecturally incapable of that, which is almost certainly why PF9
  puts the Cinder-backed image store on a real hypervisor host instead.

A partial alternative (mount the same `truenas-nfs-glance` NFS export into
the pod and use the plain `file` store against it) was also considered —
technically just a ConfigMap edit + restart, no privileged capabilities
needed — but it wouldn't actually unify storage: Cinder wraps image bytes
in a volume, `file` store writes them raw, so `admin` and `public`/
`internal` would still be reading incompatible data, just off the same
physical array. Not pursued.

## Fix applied

Repointed `public` and `internal` to match `admin`, via Keystone's v3 API
(`PATCH /v3/endpoints/{id}`, one call per endpoint, using a token from
`airctl get-creds` — same pattern as the resmgr fixes in the prior
incident):

```
$ curl ... 'https://pcd.rye.ninja/keystone/v3/endpoints?service_id=2900abb0da2e4f9a9088cd19e21d905a'
094018c4c81a40dfbd7c13eaa8fe63ff admin    https://10.45.60.1:9494
8b2f87d23c6d4d9f99e155c1549858ba public   https://pcd.rye.ninja/glance/
c7a9aa04245346e3a0333680f543d530 internal http://glance-api.pcd.svc.cluster.local:9292/

$ curl -X PATCH .../v3/endpoints/8b2f87d23c6d4d9f99e155c1549858ba -d '{"endpoint": {"url": "https://10.45.60.1:9494"}}'
HTTP_STATUS:200
$ curl -X PATCH .../v3/endpoints/c7a9aa04245346e3a0333680f543d530 -d '{"endpoint": {"url": "https://10.45.60.1:9494"}}'
HTTP_STATUS:200
```

Confirmed afterward — all three interfaces agree:

```
admin    https://10.45.60.1:9494
public   https://10.45.60.1:9494
internal https://10.45.60.1:9494
```

Also deleted the orphaned `cirros` image record (`250e03af-...`) via
`DELETE /v2/images/250e03af-145f-466b-bb49-ea6b4139bfa6` (`204`) — its data
was permanently unreachable in the k8s pod and would have kept showing up
as a bootable-looking image that always fails. **Any image you upload from
here forward will go through the same Cinder-backed instance Nova reads
from — re-upload an image and retry the VM build.**

The k8s `glance-api` pod itself was left untouched (no config or workload
change) — only the Keystone catalog entries were edited, and only for the
`glance` (type `image`) service; `glance-cluster` was already correct.

## Update 2026-09-08: root NAT64 issue fixed at the network level; local workaround removed

The `tls: failed to verify certificate` / IPv6-download-reset issues hit
while re-uploading a test image after the fix above traced back to a
separate, deeper bug: the home lab's NAT64/DNS64 appliance
(`fd97:45c2:b3a1:100::64`) shared a VLAN with this hypervisor, and a UniFi
gateway static route to an on-link destination caused an ICMPv6-redirect
hairpin — TCP handshakes completed but data transfer stalled/reset. A
`nat64-route.service` systemd unit (host route straight to the appliance)
was added here as an immediate workaround.

The appliance has since been moved to its own dedicated VLAN in the
broader home-lab platform repo (`flux-platform-src`,
`docs/superpowers/plans/2026-09-06-migrate-nat64-appliance-to-vlan-64.md`),
which fixes the hairpin bug at its actual source — the same class of issue
was hit and fixed the same way once before for an unrelated cluster on
that platform. Confirmed on `pcd-ce-hyp-01`: NAT64 now works correctly via
the plain default route with **no host-level route required at all**
(`curl` to an explicitly DNS64-resolved address returned `HTTP/2 200`).
Removed the now-obsolete `nat64-route.service` and
`/usr/local/sbin/add-nat64-route.sh` from this host — they'd been silently
failing every boot since the appliance moved (`RTNETLINK answers: No route
to host`, pointing at the address's old, now-dead location) and were doing
nothing by the time this was noticed.

## Alternative / longer-term consideration

If this environment is meant to eventually have **multiple** hypervisors
each running their own `image-library`/`glance-cluster` instance (the
plural "endpoints" in the original error message suggests the code path is
built for that), pointing `public`/`internal` at a single host doesn't
scale — you'd want whatever image-distribution mechanism PF9 provides for
multi-host image-library clusters (image sync/replication across
`glance-cluster` members) rather than manually re-pointing the catalog
every time. Worth checking PF9 docs/support for the intended pattern before
adding a second hypervisor, since a single-host lab makes this simpler than
it will be at scale.
