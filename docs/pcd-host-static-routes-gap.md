# Gap: PCD has no way to declare persistent host-level static routes

## Summary

Neither `pcd_host_config` nor any other resource in the `platform9/pcd`
Terraform provider (checked via `tofu providers schema`) exposes a way to
add a static route to a hypervisor's own OS routing table. The only
route-shaped resources that exist —`pcd_networking_router_route` and
`pcd_networking_subnet_route` — manage Neutron's tenant-facing SDN routing
(routes VMs see inside their networks), not the routing table the
hypervisor host itself uses for its own control-plane traffic (Cinder,
Glance, image imports, package pulls, etc.).

This is a real operational gap, not just a missing Terraform binding: there
is nothing to bind to, because `host_config`'s scope is limited to
interface-role assignment (`mgmt_interface`, `tunneling_interface`,
`imagelib_interface`, `live_migration_interface`, `host_liveness_interface`,
`vm_console_interface`, `network_labels`, `gpu_pci`) — no `routes` or
`static_routes` field exists to extend.

## Concrete case that surfaced it

Our environment uses a NAT64/DNS64 appliance for IPv4-only egress from an
otherwise IPv6-preferring network (see our internal
`docs/adr/0023-ipv6-only-cluster-ula-nat64.md` and
`docs/runbooks/nat64-appliance-rebuild.md` — not PCD docs, just our own
architecture notes, included here for context). Hosts on the appliance's
local segment need a direct route to its `64:ff9b::/96` NAT64 prefix;
without it, that traffic falls through to the network's default route,
return traffic arrives asymmetrically at the gateway, and its stateful
firewall drops mid-flow packets — TCP handshakes succeed, but data
transfer stalls or resets.

`pcd-ce-hyp-01` sits on that segment and hit exactly this: Glance's
Cinder-backed image import (`pcd_images_image.cirros` fetching
`image_source_url` from `download.cirros-cloud.net`, which redirects to
`github.com` — a host with no AAAA record, so DNS64 synthesizes an address
for it) reset partway through every time, because nothing had ever told
this specific hypervisor about the direct route. See
`docs/vm-provisioning-issue.md` for the full diagnosis of the Glance/Cinder
side of that incident; this document is about the piece PCD itself has no
way to express: the missing host route.

We worked around it with a hand-rolled systemd oneshot
(`/usr/local/sbin/add-nat64-route.sh` + `nat64-route.service`) that polls
for `br-tun` to exist and then runs `ip -6 route replace ...`. This works,
but it's fragile in a PCD-specific way:

- `br-tun` isn't a netplan-managed interface — it's an OVS bridge created
  dynamically by the `pf9-neutron-ovn-controller` role as part of applying
  the `hypervisor` role, with the physical bond enslaved into it after the
  fact. Any host-level networking workaround has to account for that
  bridge not existing yet at boot, and potentially being re-created by
  PF9's own tooling on role re-convergence — ordinary OS-level persistence
  mechanisms (netplan, `/etc/network/interfaces`, plain
  `systemd-networkd-wait-online` ordering) don't reliably survive that.
- This is exactly the kind of thing a real product feature would want to
  own and re-apply on every role convergence, the same way it already
  re-applies interface-role assignments and Cinder backend config — instead
  of us guessing at ordering against a bridge PCD itself creates.

## Suggested enhancement

Add a `routes` (or `static_routes`) list attribute to `pcd_host_config` —
each entry a `{destination, gateway, interface}` triple — applied
declaratively by resmgr/hostagent the same way interface roles and storage
backends are, and re-asserted whenever the underlying bridge/interface is
(re)created. This would cover the NAT64 case here, and more generally any
environment that needs a hypervisor's own control-plane traffic (as
distinct from tenant VM traffic, which Neutron already covers) routed
somewhere non-default — multi-homed management networks, split-horizon
egress, etc.

## Current state

Workaround in place and verified working (see `docs/vm-provisioning-issue.md`
for the before/after test results). Not blocking, but worth PCD product
input on whether a host-level static-route primitive is planned, since the
alternative is every operator in this situation writing their own
systemd unit against undocumented OVS bridge timing.
