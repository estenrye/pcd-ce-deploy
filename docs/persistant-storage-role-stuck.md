# Persistent Storage role stuck applying on pcd-ce-hyp-01

## Summary

The `persistent-storage` role (Cinder volume service, `pf9-cindervolume-base`)
on `pcd-ce-hyp-01` has been failing to converge continuously since
**2026-09-04 09:35 UTC** — over 40 hours as of this investigation
(2026-09-06 ~01:40 UTC). resmgr on the control plane retries the role
application roughly once a minute, forever, because the host never reports a
healthy `pf9-cindervolume-base` app. This is what shows up as the role being
"stuck" in the PCD UI and is why it can't currently be removed/redeployed
cleanly.

**Root cause:** the blueprint's compute-volumes backend (`truenas-nfs-nova`)
had the wrong IP baked in for the TrueNAS NFS server —
`storage_backends_json` in `tofu-pcd/variables.tf` pointed both the
`truenas-nfs-glance` and `truenas-nfs-nova` backends at `10.45.60.254`,
which doesn't answer ARP on the local segment at all. The real TrueNAS
appliance is at **`10.45.0.2`**, which is reachable and serving both NFS
exports correctly (confirmed below). Because the configured host was wrong,
the NFS share never mounted, Cinder's generated config ended up with
`enabled_backends` empty, and the `pf9-cindervold` process refused to
start.

After the IP was corrected and re-applied, a **second, independent**
misconfiguration surfaced (see #6 below): `compute_volumes_configuration_name`
was set to `"nova"`, which collides with a section cinder.conf already
reserves for itself, so every config push failed with
`Section 'nova' already exists`. Both issues are now fixed in
`tofu-pcd/variables.tf` (IP → `10.45.0.2`, configuration name →
`"truenas-nova"`) but **not yet applied**.

## Evidence

### 1. The role's service is crash-failing, not silently hung

```
$ systemctl status pf9-cindervolume-base
× pf9-cindervolume-base.service - Platform9 OpenStack cinder volume
     Active: failed (Result: exit-code) since Sat 2026-09-05 03:21:35 UTC; 22h ago
   Main PID: 322215 (code=exited, status=1/FAILURE)
```

`systemd` gave up restarting it (`Restart=no` in the unit — PF9 relies on its
own agents to manage retries), so it's sitting failed and idle, not actively
crash-looping locally.

### 2. The actual error is in the app log, not the journal

`journalctl` only shows a generic "exited 1"; the real reason is in
`/var/log/pf9/cindervolume-base.log`:

```
2026-09-04 09:35:05.995 ERROR cinder.cmd.volume [-] Configuration for cinder-volume does not specify "enabled_backends". Using DEFAULT section to configure drivers is not supported since Ocata.
```

Repeated on every restart attempt from 2026-09-04 09:35 through
2026-09-05 03:21 (the last attempt).

Confirmed in the live config:

```
$ grep enabled_backends /opt/pf9/etc/pf9-cindervolume-base/conf.d/cinder.conf
enabled_backends =
```

No `[nova]` (or equivalent) backend stanza exists in `cinder.conf` — the
`[nova]` section that *is* present is Cinder's Nova-API auth block, not a
volume backend definition.

### 3. The backend is supposed to be an NFS mount that never happened

`/opt/pf9/etc/pf9-cindervolume-base/volumes/nova` exists, but it's an
**ordinary local directory on the root filesystem**, not a mount:

```
$ mount | grep -i nfs
(nothing)
$ df -h | grep nova
(nothing — not a separate mount)
```

Per this repo's blueprint config (`tofu-pcd/variables.tf`,
`storage_backends_json.truenas-nfs-nova.nova`), that path should be an NFS
mount of `10.45.60.254:/mnt/flash-pool/pcd-ce-nova`.

### 4. The configured IP (`10.45.60.254`) is dead; the real server (`10.45.0.2`) is healthy

```
# from pcd-ce-hyp-01 (automation-user@10.45.60.1)
$ ping -c2 10.45.60.254
100% packet loss
$ ip neigh show 10.45.60.254
10.45.60.254 dev br-tun FAILED

# from the control plane (ubuntu@10.45.45.45)
$ ping -c2 10.45.60.254
100% packet loss
```

ARP resolution failing (not just ICMP being filtered) means nothing answers
`10.45.60.254` on the local L2 segment at all — that address is simply not
in use.

The user confirmed the actual TrueNAS server is at `10.45.0.2`. Verified
from the hypervisor:

```
$ ping -c2 10.45.0.2
0% packet loss

$ rpcinfo -p 10.45.0.2
   program vers proto   port  service
    100000    4   tcp    111  portmapper
    100003    4   tcp   2049  nfs
    ...
```

(`showmount -e 10.45.0.2` fails with "Port mapper failure - Program
unavailable" — expected for an NFSv4-only export; TrueNAS doesn't register
the legacy `mountd` RPC program (100005) when only NFSv4 is served, so
`showmount` can't work even though the server is fine.)

Both configured exports mount cleanly at the real address:

```
$ sudo mount -t nfs -o vers=4 10.45.0.2:/mnt/flash-pool/pcd-ce-nova /tmp/nfs-test-nova && ls /tmp/nfs-test-nova
OK
$ sudo mount -t nfs -o vers=4 10.45.0.2:/mnt/flash-pool/pcd-ce-glance /tmp/nfs-test-glance && ls /tmp/nfs-test-glance
OK
```

(test mounts were unmounted and cleaned up afterward). `nfs-common` is
already installed on the hypervisor, so once the blueprint's IP is
corrected and re-applied, the client side needs no further changes.

The same TrueNAS host backs `truenas-nfs-glance` (image-library role) too,
which had the same wrong IP — already fixed in the same edit. That role
doesn't appear to be currently applied to this host (no `pf9-glance*`
service, no `volumes/glance` directory, and `image_library` is absent from
`tofu state list` — only `pcd_host_cluster_role.storage` is present), so
there's nothing further to do for it right now beyond the variable fix.

Note the hypervisor's storage-facing traffic for this test rode `br-tun`
(the OVS tunnel bridge) rather than a plain host NIC — worth being aware of
if NFS throughput/latency ever becomes a concern, but it isn't what caused
this incident.

### 5. This is why resmgr thinks it's permanently mid-apply

resmgr logs (`kubectl logs -n pcd deploy/resmgr` on the control plane) show
a continuous ~60-second retry cycle for `pf9-cindervolume-base` /
`pf9-cindervolume-config` on this host, going back as far as logs are
retained:

```
... Advanced pf9-cindervolume-base role state ... from auth-converging to auth-error
... Advanced pf9-cindervolume-base role state ... from auth-error to pre-auth
... Sending request to backbone to add role pf9-cindervolume-base to c0de6fb7-... 
... Advanced pf9-cindervolume-base role state ... from pre-auth to auth-converging
[BBMASTER] Received: {'opcode': 'status', 'data': {'host_id': 'c0de6fb7-...', 'status': 'failed', ...}}
... Error processing host c0de6fb7-...
(repeat, ~once/minute, indefinitely)
```

resmgr pushes the role config, the host agent starts the service, the
service dies immediately (see #2), the host reports `status: failed` back
up, resmgr flags an error and restarts the cycle from `auth-error`. There is
no terminal "gave up" state — it just retries forever. That endless retry is
what the PCD UI surfaces as the role being stuck applying.

`tofu state list` shows `pcd_host_cluster_role.storage["pcd-ce-hyp-01"]` is
already recorded as created in Terraform state — the original `tofu apply`
returned successfully (this resource doesn't set
`wait_until_converged`, so Tofu didn't block on convergence), and the
platform has been silently retrying in the background ever since.

### 6. Second, independent bug found after fixing the IP: `configuration_name = "nova"` collides with a reserved cinder.conf section

Once the IP fix reached the host (blueprint re-applied), `pf9-cindervolume-config`
immediately hit a *different* fatal error on every convergence attempt:

```
err: Section 'nova' already exists
command: .../pf9-cindervolume-config/config --set-config '{"cinder": {"backends": {"nova": {"volume_driver": "cinder.volume.drivers.nfs.NfsDriver", ...}}}}'
...
session.py ERROR - Exception during apps processing: <class 'pf9app.exceptions.ConfigOperationError'>
session.py INFO - Converge failed
```

Cause: `compute_volumes_configuration_name` was set to `"nova"`, and
`pf9-cindervolume-config` writes that name as a literal top-level section
header in `cinder.conf` for the backend stanza. But `cinder.conf` already
has a `[nova]` section — Cinder's own built-in Nova-API auth block (confirmed
on the host: `grep '^\[' cinder.conf` shows `[nova]` at line 58, containing
`auth_url`/`username`/`password` for Cinder→Nova calls, unrelated to volume
backends). The config tool doesn't handle that name already being taken (no
existence check before creating the section), so it throws
`ConfigOperationError` and convergence fails immediately — a new,
independent failure mode from the wrong-IP issue, not the same bug
resurfacing.

**Fix applied:** renamed the configuration name from `"nova"` to
`"truenas-nova"` in `tofu-pcd/variables.tf` (both the
`compute_volumes_configuration_name` variable and the matching
`storage_backends_json["truenas-nfs-nova"]` map key — they must stay in
sync since `blueprint.tf` looks one up by the other). `"glance"` (the
image-library configuration name) does **not** collide — `cinder.conf` has
no bare `[glance]` section — so it was left as-is. Not yet applied.

### 7. Unrelated, minor finding: support-log rotation is misconfigured

`pf9-sidekick`'s periodic support-log collection fails every cycle with
`pam_unix(sudo:auth): conversation failed` / `command not allowed`, because
`pf9`'s sudoers rules don't permit the exact `cp`/`chown` invocations it's
using to rotate `/var/log/{syslog,messages,dmesg}` into `/var/log/pf9/`.
This is cosmetic (it doesn't affect role convergence) but pollutes
`auth.log` — worth a sudoers fix or a PCD bug report if it recurs elsewhere.

## Current state / stability assessment

- `pf9-cindervolume-base` is `failed`/inactive, not crash-looping locally —
  systemd's `Restart=no` means nothing on the host itself is thrashing.
- `pf9-hostagent` and `pf9-sidekick` are both healthy and running normally.
- No disk, LVM, or resource exhaustion issues found. The host has an unused
  local VG (`vg-data`, 5.6T across `sdb`/`sdc`/`sde`) and one fully unused
  raw disk (`sdd`, 238G, no partition/VG) — neither is referenced by the
  current blueprint; they're candidates if you'd rather back
  `compute_volumes` with local storage than NFS.
- The "stuck" state lives entirely in resmgr's server-side retry loop, not
  in anything on the two hosts — there is nothing to kill or reset locally
  to stop it. It will keep retrying every ~60s regardless of host-side
  action, until either the backend becomes valid (role converges) or the
  role is removed via the API/Terraform.
- No local Tofu process is hung and no `.terraform.tfstate.lock` is held;
  it's safe to run `tofu plan`/`apply` from this machine right now.

**Conclusion: the host is in a safe, non-degrading holding pattern.** There
was no local cleanup required to reach a stable state — the instability is
entirely a platform-side retry loop caused by an unreachable backend.

## Recommended next steps

1. ~~Fix the blueprint's compute-volumes backend~~ — **done**:
   `tofu-pcd/variables.tf` now points `truenas-nfs-nova` and
   `truenas-nfs-glance` at `10.45.0.2`, which is verified reachable and
   serving both exports (see evidence above).
2. ~~Fix the `[nova]` section-name collision~~ — **done**:
   `compute_volumes_configuration_name` renamed from `"nova"` to
   `"truenas-nova"` (and the matching `storage_backends_json` key) so
   `pf9-cindervolume-config` stops colliding with Cinder's built-in `[nova]`
   auth section. Neither fix has been applied yet — expect the role to need
   another convergence cycle once it is, and to re-check the log for a
   *third* issue before assuming success, given two independent ones
   already surfaced back-to-back.
3. **Remove the stuck role** — `pcd_host_cluster_role.storage` is already
   commented out in your working copy of `cluster.tf`; running `tofu apply`
   should issue the delete. Since this repo already tracks a related
   Terraform-provider bug (`PCD-9818`: provider fails unrecoverably when
   `wait_until_converged=true` and a role never converges), watch the
   destroy carefully — if it also hangs, that's a new/related provider bug
   worth adding to `docs/bugs.md`.
4. Once the backend is valid, re-add the role
   (`host_cluster_storage_role_mappings`) and confirm convergence with
   `systemctl status pf9-cindervolume-base` and
   `tail -f /var/log/pf9/cindervolume-base.log` on the hypervisor rather
   than relying on the PCD UI, since resmgr's retry loop can otherwise make
   a broken config look identical to "still applying" for a very long time.
5. Optionally fix the `pf9` sudoers rules for support-log rotation (item 7
   above) so `auth.log` stops filling with failed-sudo noise — separate from
   the storage issue but easy to knock out while in here.

## Update 2026-09-06: storage role converged; hypervisor/image-library roles are stuck on a separate, pre-existing problem

The IP and section-name fixes above worked — confirmed on the hypervisor:

```
$ systemctl status pf9-cindervolume-base
Active: active (running) since Sun 2026-09-06 02:07:06 UTC
$ grep enabled_backends cinder.conf
enabled_backends = truenas-nova
$ tail cindervolume-base.log
... Driver initialization completed successfully.
```

While re-applying the `hypervisor` and `image-library` roles via `tofu
apply`, that apply stalled — nothing showed up on the hypervisor because it
never got far enough to push anything. resmgr rejected every attempt:

```
resmgr.exceptions.RoleUpdateConflict: Cannot add role pf9-glance-role to
host c0de6fb7-4ca6-49f4-a3f7-e9799e5e1816 in the current state: deauth-error.
```

Querying resmgr's own API for the host's authoritative role state
(`GET /resmgr/v1/hosts/{host_id}`) confirms this is host-wide, not specific
to image-library:

```json
"roles_status_details": {
  "pf9-cindervolume-base": "applied",
  "pf9-cindervolume-config": "applied",
  "pf9-glance-role": "deauth-error",
  "pf9-ip-discovery": "deauth-error",
  "pf9-neutron-base": "deauth-error",
  "pf9-neutron-ovn-controller": "deauth-error",
  "pf9-neutron-ovn-metadata-agent": "deauth-error",
  "pf9-ostackhost-neutron": "deauth-error"
}
```

Every role belonging to the **hypervisor** role (`pf9-neutron-base`,
`pf9-neutron-ovn-controller`, `pf9-neutron-ovn-metadata-agent`,
`pf9-ostackhost-neutron`, `pf9-ip-discovery`) plus **image-library**
(`pf9-glance-role`) is stuck in `deauth-error`. Only the storage role is
healthy (`applied`). This means a **prior** removal of the hypervisor and
image-library roles (from before this investigation started — `tofu state
list` never showed them, consistent with them having been torn down
already) never finished de-provisioning on the resmgr side and has been
sitting in this broken state ever since, unnoticed until the first attempt
to re-add a role hit it. resmgr's own logs only retain about the last
1.5–21 hours depending on log volume, and the transition into
`deauth-error` predates that window, so the original trigger for the failed
deauth couldn't be recovered from logs — only the current stuck state,
via the API, could be confirmed directly.

**This is a different bug from the NFS/IP and section-name issues above.**
It is not something fixable from either host via SSH — resmgr, not the
hypervisor, is refusing the operation. The `tofu apply` for
hypervisor/image-library will retry against this same rejection forever
(the same failure shape as the original persistent-storage incident, and
the same class of issue tracked as `PCD-9818`) — **it's worth interrupting
that apply** rather than letting it spin, since it cannot succeed on its
own.

I attempted to directly retry the stuck deauth for one role
(`pf9-ip-discovery`) via resmgr's API (`DELETE
/resmgr/v1/hosts/{host_id}/roles/pf9-ip-discovery`, using a token from
`airctl get-creds`) to see if it would clear now that the host is
otherwise healthy, but that mutating call was blocked by this session's
permission guardrails (raw state-changing HTTP calls against live
infrastructure aren't auto-approved, regardless of the admin authorization
already given for this environment). I did not attempt to bypass that.

**Recommended next step:** use the PCD UI (Infrastructure > Hosts >
pcd-ce-hyp-01) to look for a retry/force-remove action on the roles
listed above, or reach out to Platform9 support/file a bug for a host
stuck in `deauth-error` with no way to retry via the standard role-add
path. If you'd like, I can retry the same resmgr API call myself — just
say so explicitly and approve it when prompted, since it needs your
in-the-moment go-ahead rather than the standing authorization already
given for this investigation.

## Update 2026-09-06 (later): resolved — all six stuck roles cleared

At the user's explicit request, retried the deauth for each of the six
stuck roles individually via `DELETE
/resmgr/v1/hosts/{host_id}/roles/{role_name}` (using a Keystone token from
`airctl get-creds`, same pattern as the earlier read-only GET). Each
retry simply needed to be re-issued — no code or config change was
required, meaning whatever originally caused the deauth callbacks to fail
was transient (most likely tangled up with the same storage backend being
broken at the time of the original removal — a `pf9-cindervolume-base`
that couldn't even start may have caused dependent cleanup hooks for the
other roles to fail too). Order was: `pf9-ip-discovery`,
`pf9-glance-role`, `pf9-neutron-base`, `pf9-neutron-ovn-controller`,
`pf9-neutron-ovn-metadata-agent`, `pf9-ostackhost-neutron` — each call
returned `HTTP 200` and the role disappeared from
`roles_status_details` within a few seconds (the last one, briefly showing
`deauth-converging`, cleared within ~20s).

Final state, confirmed via `GET /resmgr/v1/hosts/{host_id}`:

```json
"roles_status_details": {
  "pf9-cindervolume-base": "applied",
  "pf9-cindervolume-config": "applied"
},
"role_status": "ok"
```

The host is now fully clean — only the healthy storage role remains, and
overall `role_status` is `ok` instead of `failed`. **`tofu apply` for the
hypervisor and image-library roles should now succeed** without hitting
the `deauth-error` rejection. Temporary credential/token files created on
the control plane for these API calls (`/root/.auth_body.json`,
`/root/.token_*.json`, `/root/.host_detail*.json`) were deleted after use.
