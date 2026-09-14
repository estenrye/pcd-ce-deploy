# Spec: Neutron provider networks → UDM-SE UniFi network sync

## Goal

When a `vlan`- or `flat`-type provider network is created/changed/deleted in
PCD/Neutron (via `tofu-pcd-vms`'s `pcd_networking_network`, e.g.
`vlan1000-net` and `external-net` —
[network.tf](../tofu-pcd-vms/network.tf),
[terraform.tfvars](../tofu-pcd-vms/terraform.tfvars)), the matching network
should be created/changed/deleted automatically on the UDM-SE's UniFi
Network Controller, with no manual UI step and no modification to
Neutron/PCD's managed components.

Both segment types are in scope:
- **`vlan`** networks (e.g. `vlan1000-net`, `segmentation_id = 1000`) map to
  a tagged UniFi VLAN network.
- **`flat`** networks (e.g. `external-net`, `physical_network = "physnet1"`,
  no `segmentation_id`) map to the *untagged/native* network on that
  physical network's trunk — see "Investigated: how do flat/external
  networks differ from VLAN networks?" below for why this needs different
  handling, not just a different code path with the same shape.

## Non-goals

- Per-switch-port trunk/tag assignment on UniFi switches beyond what native
  (untagged) network handling for `flat` segments requires (see below).
  This still assumes the physical uplink(s) from the PCD hosts already
  trunk all VLANs; the shim doesn't manage arbitrary per-port profiles.
- Building or owning the shim's Kubernetes deployment inside
  `pcd-ce-deploy` itself — like
  `pdns4-external-dns-rest-http-cr-shim`, the shim is its own repo with its
  own deployment lifecycle; this repo only needs to expose whatever
  connection details Phase 1 discovers.

## Investigated: can this be done with a Neutron ML2 mechanism driver?

**Reopened by direct evidence (see "Phase 1 findings" below) — no longer
rejected.** The initial assumption here was wrong: it assumed
`pf9-neutron-ovn-controller` (a `resmgr`-managed hypervisor-host role) was
the relevant surface, by analogy with the Designate `resmgr`-revert
problem. Direct inspection of the running cluster (see findings below)
shows this was the wrong component entirely — ML2 mechanism drivers load
inside the **`neutron-server` process, which runs as an ordinary Kubernetes
Deployment in PCD's management-plane cluster**, not on the hypervisor
hosts `resmgr` manages. That deployment has no continuous reconciler at
all, which removes the entire objection this section originally raised.

The standard OpenStack pattern for pushing VLAN config to physical switches
is an ML2 mechanism driver (e.g.
[networking-generic-switch](https://github.com/openstack/networking-generic-switch),
which drives switches over SSH/Netmiko). A purpose-built one already exists
for this exact hardware:
[ubiquiti-community/networking-unifi](https://github.com/ubiquiti-community/networking-unifi)
(PyPI: `unifi-ml2-driver`) — talks to the UniFi local controller API via
`aiounifi`, requires Neutron 13.0.0+/Python 3.12+, and (unlike this spec's
shim proposal) handles **port binding and trunk config** directly: creating
VLANs on UniFi switches and assigning native/tagged VLANs to specific
switch ports. If it works here, it's a more complete solution than the
notification-bus shim below — it closes the flat/native-network open
question for free, and needs no new sibling repo.

Two pieces of prior-art evidence were checked and are worth recording even
though the live-cluster findings below make them less decisive than they
first seemed:

- Platform9's own past attempt at a custom ML2 mechanism driver,
  [openstack-omni](https://github.com/platform9/openstack-omni) (AWS
  integration, now archived/unmaintained since 2019), required copying
  files directly into the Neutron source tree — not how `networking-unifi`
  installs (a normal pip package registering a
  `neutron.ml2.mechanism_drivers` stevedore entry point).
- PCD's own current documentation (the
  [Physical Network](https://docs.platform9.com/private-cloud-director/2026.1/virtualized-networking/physical-network)
  page and the
  [Networking in PCD](https://platform9.com/blog/networking-in-platform9-private-cloud-director-open-flexible-and-powerful/)
  architecture post) documents none of this — it's all operator-facing, no
  mention of custom mechanism drivers either way.

Neither predicted the actual answer; the live cluster did. See "Phase 1
findings" below.

## Investigated: can this be done entirely from Terraform (`local-exec` against the UniFi API)?

Rejected as the primary mechanism, despite being tempting (it would mirror
`designate_mdns_listener.tf`'s `null_resource` + `local-exec` + 1Password
pattern closely). The problem: it only reacts to changes made through this
repo's `tofu apply`, and can't cleanly express deletion (Terraform
`null_resource` destroy provisioners are awkward and easy to get wrong, and
this repo's own `network_ipv6_stateful_subnets.tf` already accepts that
asymmetry for a narrower case). More fundamentally, it's a side channel
around Neutron rather than an integration with it — Neutron never
"knows" this is happening, so anything created via the OpenStack API
directly (not through this repo's Terraform) would never sync.

## Investigated: how do flat/external networks differ from VLAN networks?

`flat` and `vlan` provider networks aren't just "the same sync with a
different tag" — they map to structurally different things on the UniFi
side, and the shim needs to treat them differently:

- **No `segmentation_id`.** A `flat` network has nothing to key a UniFi VLAN
  ID off of. The natural key instead is the Neutron `physical_network` name
  (`physnet1`), which the shim maps to whichever UniFi network is configured
  as the *native/untagged* network on that physical trunk.
- **At most one flat network per `physical_network`.** Neutron itself
  enforces this (a physical network can carry one untagged segment plus any
  number of tagged VLAN segments), so unlike VLAN networks the flat side of
  the mapping is a fixed 1:1 correspondence, not a growing set.
- **Likely already exists.** `external-net` already carries live traffic
  today without this shim's involvement, which means the corresponding
  UniFi network (probably the site's default LAN, `vlan_enabled: false`)
  almost certainly already exists. For `flat` networks the shim's create
  path will likely be a no-op in practice — the meaningful behavior is
  *reconciling attribute drift* (e.g. if `external-net`'s name/description
  changes) and *detecting misconfiguration* (e.g. the native network on the
  relevant UniFi switch port profile doesn't actually match), not creating
  something from scratch.
- **Untagged status is a port-profile property, not just a network
  property.** Whether a given UniFi network is actually the *native*
  (untagged) VLAN on the PCD hosts' uplink port(s) is configured on the
  switch port profile, not solely on the `networkconf` object. Phase 1 needs
  to determine whether the Network Integration API exposes port-profile
  native-network reads/writes, or whether this piece has to stay a
  documented manual prerequisite (native network already set correctly,
  verified once) with the shim only reconciling the `networkconf` object
  itself. This is the one place where "no per-port automation" (a non-goal)
  and "sync flat networks" are in tension — resolve it empirically before
  writing shim code, not by assumption.

## Chosen approach: Neutron's oslo.messaging notification bus

Neutron has no pluggable "backend target" concept for network provisioning
the way Designate has for DNS backends (which is what made the pdns4 shim
possible — implementing a protocol Designate already speaks). What Neutron
*does* have, unmodified, out of the box, is its **oslo.messaging
notification bus**: every lifecycle event (`network.create.end`,
`network.update.end`, `network.delete.end`, each carrying the full resource
payload including `provider:network_type`, `provider:physical_network` and
`provider:segmentation_id`) is published to a RabbitMQ topic exchange
(`control_exchange`, default `neutron`) as a matter of course. This is the
standard OpenStack integration point for exactly this kind of use case:
[`designate-sink`](https://docs.openstack.org/designate/latest/admin/notifications.html)
— a first-party, in-tree OpenStack component — exists solely to consume
Nova/Neutron notifications this same way, with zero modification to either
service. That's the genuine analog to the pdns4 shim's "implement a
protocol the consumer already speaks" approach, applied to Neutron instead
of Designate.

The plan is a new sibling repo, `neutron-network-unifi-shim`, structured
like `pdns4-external-dns-rest-http-cr-shim`, that consumes these
notifications and drives the UDM-SE's official **UniFi Network Integration
API** (API-key auth — the same API `external-dns-unifi-webhook` already
uses for the DNS side, and a much better foundation than the old scraped
session/CSRF controller API).

```
Neutron (network.create/update/delete.end) --oslo.messaging/RabbitMQ--> neutron-network-unifi-shim --HTTPS, UniFi Network Integration API--> UDM-SE VLAN or native network (networkconf)
```

## Phase 1 — Investigation (read-only; do this before designing the shim's consumer)

Mirrors how the Designate `resmgr`-revert behavior was discovered: confirm
real values empirically before building against them.

1. SSH to a PCD host (`var.pcd_hostname` / `var.pcd_ssh_username`, the same
   access already used by `ssh_resource` elsewhere in this repo) and read
   (do not edit) `/opt/pf9/etc/neutron/neutron.conf` for:
   - `[oslo_messaging_notifications]` `driver` — must be an active driver
     (e.g. `messagingv2`), not `noop`, for anything to be published.
   - `[DEFAULT]` `transport_url` — the RabbitMQ connection string
     notifications flow through.
   - `control_exchange` (defaults to `neutron` if unset).
2. With read-only `rabbitmqctl` access, confirm the exchange/queue exist
   (`list_exchanges`, `list_bindings`), then create one throwaway Neutron
   VLAN network (`openstack network create --provider-network-type vlan
   --provider-physical-network physnet1 --provider-segment 1999 test-vlan`)
   and bind a temporary queue to observe the actual notification payload —
   confirming `provider:network_type`/`segmentation_id` are present and
   readable — then delete the test network. Separately, trigger a
   no-op update on the existing `external-net` (e.g. an idempotent
   `openstack network set --description ... external-net`) and capture that
   notification too, to confirm what a `flat` segment's payload looks like
   (no `segmentation_id`, `provider:physical_network` present) without
   touching its live config meaningfully.
3. Confirm network reachability: can a workload in the same Kubernetes
   cluster that runs `pdns4-shim`/ExternalDNS reach this RabbitMQ broker
   directly, or does it require an SSH tunnel / an additional firewall
   allowance on the PCD hosts? This determines whether the shim needs an
   extra sidecar/tunnel component.
4. Open developer.ui.com's Network Integration API docs directly in a
   browser (it's a JS app; automated fetch doesn't render it) to confirm:
   - The exact endpoint(s), request/response schema, and auth header for
     VLAN-backed network create/update/delete — cross-check against
     `external-dns-unifi-webhook`'s Go source for how it authenticates,
     since that project already has this working against a UDM-SE.
   - Whether the API can read/set which UniFi network is the *native
     (untagged) network* on a given switch port profile, needed to resolve
     the flat/external open question above.
5. While investigating, read (don't change) the UDM-SE's current
   `networkconf` for whatever network is presently serving as
   `external-net`'s untagged network, to have a real example payload to
   design the flat-network mapping against.
6. ~~ML2 driver viability check via resmgr role settings~~ — **superseded**,
   see "Phase 1 findings" immediately below. The premise (that ML2 driver
   durability depends on a `resmgr` hypervisor-host role) was wrong; direct
   inspection of the cluster answered this a different way.

## Phase 1 findings (2026-09-13)

Investigated by SSH'ing to `pcd.rye.ninja` (`var.pcd_hostname`) as `ubuntu`
and using read-only `kubectl`/`helm` commands. No config was changed.

**Neutron's control plane is a plain Kubernetes Deployment, not a
`resmgr`-managed host role — and nothing reconciles it.** `neutron-server`
runs as pod `neutron-server-6b4f8f6666-*` in namespace `pcd`, image
`quay.io/platform9/pf9-neutron:2026.4.2-1605`, installed by a one-shot Helm
release (`helm list -A` shows `neutron`, chart `neutron-2026.4.2-156`, still
at **revision 1**, unchanged since the initial install ~10 days ago). The
entire `pcd` namespace (all ~40 OpenStack services, including `resmgr`
itself, which turns out to be *just another pod in this same cluster*) was
installed the same way by a single bootstrap job
(`pcd-kplane`/`du-install-pcd`, chart `kubedu`, status `Completed`). There
is no Flux/ArgoCD/Fleet in this cluster and no active
`HelmChart`/`HelmChartConfig` (k3s's built-in Helm controller) resources —
the only continuously-running thing that looked like it might reconcile
anything, `bork` (namespace `pcd-bork`), turned out from its logs to be a
metrics/inventory aggregator ("pods: refreshing", "consolidate: importing
consolidated metrics" on a ~60s loop) with no evidence of applying Helm
releases or config. **This means the `resmgr`/`pf9-hostd` convergence
behavior that reverted the Designate SSH edits is a hypervisor-host-level
phenomenon that does not apply to this management-plane Kubernetes
cluster at all.** A `helm upgrade` to this `neutron` release should persist
until the next deliberate upgrade (e.g. a PCD version bump reapplying the
`kubedu` umbrella chart) — an ordinary, well-understood Helm concern, not a
live-agent-reverts-you-in-seconds one.

**`mechanism_drivers` is a real, live-confirmed Helm value.**
`helm get values neutron -n pcd -a` shows
`conf.neutron.ml2_conf.ml2.mechanism_drivers: null`; exec'ing into the
running pod and reading the actual rendered
`/etc/neutron/plugins/ml2/ml2_conf.ini` shows the chart's template default
kicks in: `mechanism_drivers = openvswitch,ovn`. `type_drivers` includes
both `flat` and `vlan`, `ml2_type_vlan.network_vlan_ranges = vm-net` (not
`physnet1` as this spec assumed — **`tofu-pcd-vms`'s `physical_network =
"physnet1"` and this chart's configured range name don't match; needs
reconciling before anything using VLAN ranges can work reliably**, a
separate, pre-existing discrepancy this investigation surfaced by
accident). Adding a third mechanism driver (`unifi`, pending confirmation
of `networking-unifi`'s actual registered stevedore name) to that
comma-separated list is a normal `helm upgrade
--reuse-values --set conf.neutron.ml2_conf.ml2.mechanism_drivers=openvswitch\,ovn\,unifi`
— no different in kind from any other Helm-managed OpenStack customization.

**The chart has no `extraInitContainers`/sidecar-injection hook** (grepped
the full rendered values, ~2900 lines — no `extraVolume`, `extraInit`,
`dependency_container`, or similar pattern anywhere). The original plan
here was a **custom container image** (`FROM
quay.io/platform9/pf9-neutron:2026.4.2-1605` + `pip install
unifi-ml2-driver`) with `images.tags.neutron_server` overridden to point at
it. **Superseded on 2026-09-13** — a pinned custom image goes stale the
moment PCD ships a new base `pf9-neutron` image on any upgrade (a version
skew problem in addition to the config-drift problem this whole guardian
design already exists to solve). See "Avoiding a custom image: runtime
driver injection" under Phase 2 below for the replacement approach: install
the driver into a shared volume at pod-start time, against whatever image
PCD currently ships, instead of pinning a rebuilt image at all.

**`oslo_messaging_notifications.driver = noop`, confirmed live** (both in
`helm get values` and in the pod's actual `/etc/neutron/neutron.conf`) —
**this spec's shim, as designed, would receive nothing today.** Enabling it
is also just a Helm value (`driver: messagingv2`), not a code or package
change. The RabbitMQ connection details the shim would need are already
resolvable from the same release: `transport_url =
rabbit://neutron:<redacted — see the `neutron` Helm release's stored
values; do not commit this password anywhere>@broker.pcd.svc.cluster.local:5672/`,
`control_exchange` unset (Neutron's own default, `neutron`, applies). Since
this is an in-cluster Service DNS name (`broker.pcd.svc.cluster.local`),
the shim would need to run inside this same cluster (or reach it via a
tunnel) — it's not reachable as e.g. `pcd.rye.ninja:5672` from outside.

**What this changes:** the ML2 driver route (`networking-unifi`) now looks
like the stronger overall candidate, not a fallback-if-lucky option as
originally framed:
- No reconciliation/durability risk was found (the opposite of what sank
  the SSH-based Designate approach).
- It's less total new work than the shim: a runtime-injection sidecar
  pattern (no image to build/maintain — see below) + a `helm upgrade`,
  versus building and operating an entire new sibling repo.
- It handles port binding/trunk/native-VLAN assignment natively, closing
  this spec's still-open flat/native-network question outright, which the
  shim can only reconcile at the network-object level.
- The notification-bus shim still requires the same kind of Helm-value
  change (`oslo_messaging_notifications.driver`) to even receive events, so
  it's no longer "zero config change" versus the ML2 route either — the gap
  between the two options is narrower than this spec first assumed.

**What's still open before committing to the ML2 route:**
- Confirm `networking-unifi`'s actual registered `neutron.ml2.mechanism_drivers`
  stevedore entry-point name (likely `unifi`, not yet verified against the
  package's own `pyproject.toml`/`setup.cfg`).
- Confirm it coexists with `openvswitch,ovn` as an *additive* driver (like
  `networking-generic-switch` does in ordinary deployments) rather than
  expecting to be the sole driver.
- **Confirmed**: the UDM-SE is the UniFi controller itself (it runs the
  UniFi Network Application locally, self-hosted) — not just an L3 gateway
  adopted by some other controller instance. The USW Pro aggregation switch
  is a device *managed by* that controller, same as any other UniFi
  switch. So `networking-unifi`/the Integration API talks to the UDM-SE
  regardless; the only remaining question is which managed device's
  *ports* get the trunk/native-VLAN assignment (almost certainly the USW
  Pro's uplink port(s) to the PCD hosts, not a port on the UDM-SE itself) —
  a narrower, already-mostly-answered version of the original question.
- Resolve the `physnet1` vs. `vm-net` `network_vlan_ranges` naming mismatch
  found above, independent of which integration approach is chosen.
- **Resolved 2026-09-14**, from the `neutron-ml2-guardian` implementation
  work (see that repo's `docs/specs/2026-09-13-neutron-ml2-guardian-design.md`):
  the UDM-SE's Network Integration API is confirmed reachable and
  authenticating at `10.45.0.1` — `GET
  https://10.45.0.1/proxy/network/integration/v1/sites` with header
  `X-API-KEY: <key>` (from
  `op://controlplane/unifi-os-xnetworksegment/credential`) returned HTTP
  200 with one site, `internalReference: "default"` — verified from both
  the PCD host and from inside a pod's own network namespace in this
  cluster, not just the host. Still open: whether this API exposes
  port-profile native-network read/write (the flat/native-network question
  above), which wasn't tested by this check.

Record further findings as amendments to this spec. Phases 2-3 below are
kept as the fallback/comparison path (and because parts of Phase 1 — the
RabbitMQ connection details, the UniFi API investigation — are shared
prerequisites either way), but the next concrete step is prototyping the
ML2 driver route (a custom `pf9-neutron` image + `helm upgrade`) rather
than starting on a new shim repo.

## Phase 2 — `neutron-network-unifi-shim` (new sibling repo, fallback path)

Same engineering conventions as `pdns4-external-dns-rest-http-cr-shim`:
structured JSON logs (`RUST_LOG`-gated), OTLP export via `OTEL_*` env vars,
Prometheus-style metrics, distroless multi-arch container image, deployed
via matching `deploy/` (plain manifests + Kustomize) and `deploy/helm/`
structures.

Core logic:
1. **AMQP 0.9.1 consumer** against the RabbitMQ `transport_url`/exchange
   found in Phase 1, bound to a durable queue on `notifications.info`.
2. Filter for `network.create.end` / `network.update.end` /
   `network.delete.end` events whose payload includes a `vlan`- or
   `flat`-type provider segment; ignore everything else (e.g. `geneve`/`vxlan`
   tenant overlay networks, which have no physical-network correspondence).
3. **For `vlan` segments**: map `segmentation_id` + network name to a
   tagged UniFi VLAN via the Network Integration API — create if missing,
   update if the name/VLAN ID changed, **delete on `network.delete.end`**.
   Unlike a Terraform-only approach, an event-driven consumer gets real
   delete events for free.
4. **For `flat` segments**: map `physical_network` to the UniFi network
   already serving as that trunk's native/untagged network (per Phase 1's
   findings) — reconcile name/description drift, and log a loud warning
   (not a silent no-op) if no matching native network can be found, rather
   than trying to create one blind. Given the "likely already exists"
   finding above, treat `flat` sync as inherently more conservative than
   `vlan` sync: never delete a `flat` network's UniFi counterpart even on
   `network.delete.end`, since removing the native/untagged network out
   from under a live trunk is a much higher-blast-radius mistake than
   deleting an unused tagged VLAN.
5. **Startup reconciliation pass**: unlike the Designate shim (which
   answers synchronous HTTP calls and therefore can't "miss" anything), an
   AMQP consumer can miss messages while it's down. On boot, list current
   Neutron `vlan`/`flat` provider networks (one authenticated OpenStack API
   call) and current UniFi networks (Integration API), diff, and converge
   once before switching to pure event-driven mode for the rest of its
   runtime.
6. Auth/config via env vars, matching the pdns4-shim style: Neutron/OpenStack
   read-only credentials, UniFi Integration API key, RabbitMQ connection
   string — populated from 1Password-backed secrets the same way this
   repo already does for other credentials, but managed as static
   configuration for the new repo's own deployment, not generated by
   `pcd-ce-deploy`'s Terraform.

## Phase 3 — pcd-ce-deploy changes

Expected to be small: this repo's job is exposing whatever Phase 1
discovers (RabbitMQ connection details, confirmed exchange name) as
documented values / a 1Password item the new shim's deployment references —
not provisioning or managing the shim itself, the same way `pcd-ce-deploy`
doesn't own `pdns4-external-dns-rest-http-cr-shim`'s deployment either.
Concretely: capture the Phase 1 findings as amendments to this spec so the
new repo's setup instructions have a citable source of truth instead of
re-deriving them.

## Phase 2 (ML2 route) — self-healing `neutron-ml2-guardian` controller

Working assumption per direction from 2026-09-13: the ML2 route
(`networking-unifi` + a custom `pf9-neutron` image, per the Phase 1
findings above) is the chosen approach, **and every PCD version upgrade is
assumed to silently revert it** — consistent with how PCD upgrades appear
to work (Phase 1 found the whole `pcd` namespace was installed by a
one-shot imperative `helm install` per subchart, not continuously
reconciled; a future upgrade almost certainly re-runs the `neutron`
subchart with its own baked-in default values, not `--reuse-values`,
which would silently drop both the custom image tag and the added
`mechanism_drivers` entry). Given that, a one-time `helm upgrade` isn't
sufficient — the customization needs an active guardian that detects and
re-applies drift after every future PCD upgrade, indefinitely.

### What "present" means (layered check, not a single signal)

A single check is not enough — each layer catches a failure mode the
others miss:

1. **Injection check** (cheap, first line): the `neutron-server`
   Deployment's pod template has the guardian's injected initContainer
   (by name) and the associated volume/env changes present. A single
   `kubectl get deployment -o json` field read, no exec needed. Replaces
   the earlier "image equals pinned custom image" check now that there's
   no custom image to pin — see "Avoiding a custom image" below.
2. **Config check** (authoritative): exec into a live, `Ready`
   `neutron-server` pod and confirm `mechanism_drivers` in the rendered
   `/etc/neutron/plugins/ml2/ml2_conf.ini` actually includes the UniFi
   driver's stevedore name, *and* that the driver package actually imports
   (e.g. `python3 -c "import unifi_ml2_driver"` inside the pod, or
   equivalent) — catches drift the injection check alone would miss (e.g.
   the initContainer patch is present but its pip-install step silently
   failed).
3. **Health check** (safety, easy to overlook): the pod must actually be
   `Ready` and not crash-looping since the last repair. A driver that's
   textually "present" in config but crashing on load isn't actually
   working, and must be treated as a distinct "degraded" state — not
   "absent" — so the controller doesn't interpret a broken repair as
   "still needs repairing" and retry it forever.

### Avoiding a custom image: runtime driver injection via initContainer

The constraint that makes this necessary: ML2 mechanism drivers are loaded
*in-process* by `neutron-server` via Python stevedore entry points and
called as direct method calls from the ML2 plugin's driver manager — there
is no out-of-process/RPC protocol for them (unlike Designate's HTTP-based
backend targets). So `unifi-ml2-driver` has to be importable on
`neutron-server`'s own `sys.path` when it starts. That doesn't have to mean
"baked into the image at build time," though — it can mean "installed into
a shared volume at pod-start time, against whatever image happens to be
running right now":

- **An injected initContainer**, added to the `neutron-server` Deployment
  by a direct Kubernetes patch (not a Helm value — none exists for this),
  using the **same image reference as the Deployment's own main
  container** (read dynamically from the live pod spec, never hardcoded) —
  so it's automatically correct on any future PCD image bump, with nothing
  for the guardian to track or update. It runs `pip install --no-index
  --find-links=/wheelcache --target=/opt/ml2-plugins unifi-ml2-driver` into
  a shared `emptyDir`.
- **The main `neutron_server` container** gets that same `emptyDir`
  mounted and a `PYTHONPATH` addition pointing at it, so the driver is
  importable when the process starts. `pf9-neutron`'s `neutron-server`
  entrypoint is very likely a standard setuptools `console_scripts` shebang
  script invoking the venv's Python directly (the `find`/`kubectl exec`
  results already located the venv at
  `/var/lib/openstack/lib/python3.10/site-packages`), which should honor
  `PYTHONPATH` normally — **this needs one empirical check against the
  real container before relying on it**; if it doesn't take effect (e.g.
  because of `-S`/isolated-mode invocation), the fallback is mounting the
  emptyDir as a subdirectory *inside* the real site-packages tree plus a
  `.pth` file pointing at it (the standard CPython `site` module mechanism
  for extending `sys.path` without modifying the base install) — more
  invasive, kept as a documented fallback rather than the default plan.
- **`--no-index --find-links=/wheelcache`, not a live `pip install`,** is
  the important detail: it keeps the neutron-server pod's *startup* path
  fully offline. A pod restart is not a rare event (node reboot, OOM,
  rescheduling, an unrelated `helm upgrade`) — making every single one of
  them depend on PyPI being reachable would turn a convenience into a new
  availability risk for a core control-plane service. Instead:
  - The **guardian** — not the initContainer — is responsible for keeping
    `/wheelcache` (a small `ReadWriteMany` volume, e.g. NFS-backed via the
    same TrueNAS backend already used elsewhere in this environment for
    RWX storage) populated and current, on its own schedule, tolerant of
    retry/backoff, off the neutron pod's critical path.
  - Whenever the guardian detects the main container's image (and
    therefore its Python version) has changed, it refreshes the cache by
    running `pip download` for `unifi-ml2-driver` and its dependency
    closure (`aiounifi`, transitively `aiohttp` or similar) using **that
    same current image** (so downloaded wheels match its Python ABI),
    before the initContainer ever needs them.
  - This needs one verification pass on the actual dependency tree: if
    everything is pure-Python (no compiled extensions), a single cached
    wheel set is ABI-independent and safe across any future Python bump
    with no refresh logic needed at all; if anything ships compiled
    wheels, the per-image-version refresh above is required, not optional.
- This removes the custom-image problem entirely: nothing about this
  design references a specific `pf9-neutron` tag anywhere. The guardian's
  job shifts from "keep an image reference current" to "keep a small wheel
  cache current and keep the Deployment patch applied" — both squarely
  within the same reconcile-loop shape already designed below.

### Repair logic

- Read the **currently installed** `neutron` Helm release's chart directly
  out of its own Release Secret in-cluster (via `helm get metadata`/`helm
  pull`-style subprocess calls against the release, per the Rust/CLI
  choice below) — avoids needing network access to any external chart
  repository, and means the controller always re-uses whatever chart
  version PCD's own installer/upgrade most recently applied.
- Compute a **targeted values merge**, not a full replacement: override
  only `conf.neutron.ml2_conf.ml2.mechanism_drivers`, computed as
  *"whatever driver list is currently rendered, plus the UniFi driver if
  it's missing"* rather than a hardcoded string — so a future PCD version
  that changes or extends its own default driver list isn't silently
  clobbered by this controller's repair.
- Apply via `helm upgrade` using the chart pulled above plus the merged
  values.
- **Separately, reapply the Deployment patch** (initContainer + volume +
  `PYTHONPATH`/`.pth` env from the section above) — a raw Kubernetes
  strategic-merge patch, not a Helm value, and *not* preserved by Helm
  upgrades automatically (Helm 3 computes its upgrade patch from its own
  release history, which never included this out-of-band addition, so any
  `helm upgrade` of this release — the guardian's own mechanism_drivers
  fix included — can silently drop it; it must be treated as needing
  reapplication on every repair cycle, not a one-time setup step).
- After the new pod reaches `Ready`, re-run the full "present" check to
  confirm the repair actually took effect — not just that the `helm
  upgrade`/`kubectl patch` calls exited 0 — before declaring success.

### Safety rails

- **Backoff, don't repair-loop.** If a repair is applied but the
  post-repair check keeps failing (e.g. a new base image's Python version
  isn't covered by the current wheel cache yet, or the driver's dependency
  closure turns out not to be pure-Python and needs a per-version refresh
  that hasn't completed), stop retrying every cycle. Surface a loud,
  sustained "degraded" signal instead of repeatedly restarting a broken
  deployment.
- **Least-privilege, single-namespace RBAC.** A `Role` (not `ClusterRole`)
  scoped to the `pcd` namespace only, granting exactly what's needed: read
  on the `neutron-server` Deployment/Pods, read on the Helm release Secrets
  (`sh.helm.release.v1.neutron.*`), create/update on the specific resource
  kinds the `neutron` chart's own templates render (for the
  `mechanism_drivers` `helm upgrade`), **patch on the `neutron-server`
  Deployment specifically** (for the initContainer/volume injection), and
  read/write on the wheel-cache PVC. This is worth calling out plainly:
  this grant is effectively "can run `helm upgrade neutron` and rewrite its
  Deployment's pod spec" — a meaningfully powerful permission that should
  be reviewed and approved deliberately, not treated as routine.
- **Scoped to one release, by name.** Never touch any Helm release other
  than `neutron`.
- **Idempotent.** No `helm upgrade` call at all on a reconcile tick where
  the present-check already passes — avoid unnecessary pod restarts/churn.
- **Observability rides on PCD's own stack.** Expose a Prometheus
  `/metrics` endpoint — the `prometheus` pod already running in the `pcd`
  namespace can scrape it directly, no separate observability stack
  needed. Suggested metrics: `ml2_driver_present` (gauge, 0/1),
  `ml2_driver_repairs_total` (counter), `ml2_driver_repair_failures_total`
  (counter). Structured logs on every reconcile decision (present /
  repaired / degraded-backing-off).

### Deployment shape

- New Helm chart, `neutron-ml2-guardian`, installed into its **own**
  namespace (e.g. `neutron-ml2-guardian`) with a `Role`+`RoleBinding`
  granting only the scoped access above into `pcd` — keeps this
  controller's RBAC footprint auditable separately from `pcd`'s own
  service accounts, rather than running inside `pcd` itself.
- Single-replica Deployment running a periodic reconcile loop.
- A small `ReadWriteMany` PVC for the wheel cache (`/wheelcache`), shared
  between the guardian (writer, refreshes it) and every `neutron-server`
  pod's injected initContainer (reader) — sized generously enough for a
  handful of drivers' dependency closures across a couple of Python
  versions, not large. No image reference to track as a chart value
  anymore, since this route no longer pins one.

### Generalizing: a driver-agnostic ML2 injector, not a UniFi-specific tool

Almost nothing above actually needs to know about UniFi specifically — it
only needs, per driver, a pip package name, the stevedore/`mechanism_drivers`
name it registers, and the top-level module to test-import (pip package
names and import module names frequently differ, e.g. a package named
`foo-ml2-driver` importing as `foo_ml2_driver`). Making that a list turns
this from "the UniFi guardian" into a general-purpose "PCD ML2 driver
injector," reusable for any pip-installable, stevedore-registered Neutron
ML2 driver — `networking-generic-switch`, `networking-unifi`, or anything
else someone points it at — with UniFi simply as the first configured
instance rather than something built into the tool's logic. Concretely,
this reshapes a few of the pieces above from hardcoded to configured:

```yaml
# neutron-ml2-guardian chart values, illustrative
ml2Drivers:
  - name: unifi
    pipPackage: unifi-ml2-driver
    importModule: unifi_ml2_driver
    # Opaque to the guardian — it doesn't parse or understand this, just
    # renders it into a Secret and adds a --config-file for it.
    extraConfigSecretData: |
      [unifi]
      controller_url = https://10.0.0.1
      api_key_secret_ref: unifi-api-key
  - name: genericswitch
    pipPackage: networking-generic-switch
    importModule: networking_generic_switch
    extraConfigSecretData: |
      [genericswitch:leaf1]
      device_type = netmiko_cisco_ios
    soleDriver: false
```

What changes, per piece already designed above:

- **`mechanism_drivers` merge** becomes a set union over all configured
  drivers' `name`s, not one hardcoded addition — still computed against
  "whatever's currently rendered," still additive-only.
- **Wheel cache** gets one subdirectory per driver
  (`/wheelcache/<name>/`), each populated independently by `pip download
  <pipPackage>` against the currently-observed image's Python version.
- **Pure-Python vs. version-pinned detection becomes automatic, not a
  per-driver flag the operator has to supply.** After downloading a
  driver's dependency closure, inspect the wheel filenames' ABI/platform
  tags: `*-none-any.whl` (universal, pure Python) needs no refresh trigger
  ever; anything with a specific Python/ABI/platform tag is tied to the
  exact Python version it was downloaded against and must be refreshed
  whenever the observed image's Python version changes. The guardian
  derives this empirically per package rather than trusting operator input
  that could be wrong or go stale.
- **The initContainer's install step** becomes one `pip install --no-index
  --find-links=/wheelcache/<name> ... ` per configured driver (or a single
  invocation across a merged find-links path), installing the union of all
  configured drivers' packages in one pass.
- **The import check** iterates every configured driver's `importModule`.
- **`extraConfigSecretData`** is the piece that makes this genuinely
  driver-agnostic rather than needing the guardian to understand each
  driver's own settings schema: it's opaque content the guardian just
  writes into a per-driver Secret and mounts as an additional
  `--config-file` on the `neutron-server` process — Neutron already
  natively supports and merges multiple stacked `--config-file` arguments
  (the same mechanism `ml2_conf.ini` itself already relies on), so this
  composes cleanly without the guardian needing any driver-specific logic
  at all. Secrets specifically (not ConfigMaps) because driver config
  commonly includes credentials (a controller API key, switch SSH
  passwords, etc.).
- **`soleDriver` (optional, default `false`)**: most physical-switch/ML2
  add-on drivers (including `networking-generic-switch` and
  `networking-unifi`) are designed to coexist additively alongside
  `openvswitch`/`ovn`, acting only on the ports/networks relevant to them.
  A driver that isn't built that way should set this flag so the guardian
  refuses to combine it with other `soleDriver`-flagged entries and surfaces
  a clear error instead of silently producing a broken `mechanism_drivers`
  list.

This also strengthens the case made in the Jira draft from earlier in this
investigation: a driver-agnostic version of this tool is a genuinely
reusable answer to "PCD has no supported ML2 extension point" — useful to
the broader PCD community, not just this one UniFi integration — and worth
keeping in mind as a candidate for sharing back, independent of whether
that Jira ticket itself goes anywhere.

### Implementation decisions (2026-09-13)

- **Language/tooling: Rust + `kube-rs`, shelling out to the `helm` CLI
  binary** bundled in the container image. Consistent with
  `pdns4-external-dns-rest-http-cr-shim`'s existing stack and with this
  repo's own preference for shelling out to well-tested CLI tools (`helm`,
  `kubectl`, `openstack`) rather than reimplementing their logic against a
  native SDK. Concretely: `kube-rs` for reading the Deployment/Pod/Secret
  state used by the layered "present" check and for `exec`-ing into the
  `neutron-server` pod to read `ml2_conf.ini`; the bundled `helm` binary
  (invoked as a subprocess, output captured and checked, matching how
  `designate_mdns_listener.tf`'s `local-exec` blocks already treat `curl`)
  for the actual repair's `helm upgrade` call. Extracting the currently
  installed chart from the release's Secret can also go through `helm get
  metadata`/`helm pull`-style subprocess calls rather than needing a native
  Helm SDK at all.
- **Repair autonomy: fully automatic.** On detecting drift, the controller
  immediately performs the targeted merge and runs `helm upgrade` without
  waiting for a human trigger. Chosen for fastest recovery in a home-lab
  context; the safety rails above (layered checks, backoff on repeated
  post-repair failure, metrics/logs on every decision) are the guardrails
  in place of a manual-confirm gate.
- **Reconcile interval: 5 minutes**, exposed as a configurable Helm value
  of the `neutron-ml2-guardian` chart (not hardcoded) so it can be tuned
  later without a code change.

## Verification

1. Phase 1's throwaway VLAN test and `external-net` no-op-update test
   confirm notifications actually flow and contain the needed fields for
   both segment types — do this before writing any shim code.
2. Once the shim exists: create a real VLAN network via
   `tofu-pcd-vms/terraform.tfvars`, confirm the matching UniFi VLAN appears
   automatically without any manual UDM-SE step.
3. Update the network's segmentation and confirm the shim converges the
   UniFi side to match.
4. Delete the network and confirm the shim removes the UniFi VLAN.
5. Update `external-net`'s description/name and confirm the shim reconciles
   the corresponding UniFi native network's metadata without touching its
   VLAN/untagged status or deleting anything.
6. Restart the shim after making an out-of-band Neutron network change
   while it was down, and confirm the startup reconciliation pass catches
   up correctly for both segment types.
7. Bring up a VM on the new VLAN and confirm it's reachable/routed correctly
   through the UDM-SE on that VLAN end-to-end.
