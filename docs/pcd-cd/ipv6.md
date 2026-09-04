# Why PCD CE doesn't expose itself on IPv6 (`::/0`)

## Summary

The `pcd-ce` VM has fully working dual-stack (IPv4 + IPv6) OS-level
networking. The reason PCD CE itself is unreachable over IPv6 has nothing to
do with that — it's because the Platform9 installer (`go.pcd.run` / `airctl`)
bootstraps k3s, Calico, and MetalLB as **IPv4-only, single-stack**. There is
no IPv6-capable Kubernetes Service anywhere in the cluster, so nothing ever
binds to `::` for PCD's ports (443, etc.).

A separate, smaller issue was also found at the OS level: the VM's IPv6
default route in the `main` routing table is currently present only because
of a transient, expiring Router Advertisement route, even though
`accept_ra` is disabled. Once it expires, any process that doesn't use the
ULA/GUA source address explicitly will lose outbound IPv6 connectivity
entirely.

## Environment

- VM: `pcd-ce` (`fd97:45c2:b3a1:100::dead`, `2607:3640:1064:270::dead`,
  `10.45.45.45`), provisioned by [ansible/provision-vm.yml](../../ansible/provision-vm.yml)
  and [ansible/templates/network-config.yml.j2](../../ansible/templates/network-config.yml.j2).
- PCD CE installed via [ansible/install-pcd.yml](../../ansible/install-pcd.yml),
  which runs the upstream `go.pcd.run` installer (`airctl`) — a closed-source
  Platform9 binary not controlled by this repo.

## Investigation

### 1. VM networking is dual-stack and correct

`network-config.yml.j2` gives `eth0` a ULA address (`fd97:...100::dead/64`)
and a GUA address (`2607:3640:1064:270::dead/64`), plus source-based policy
routing so each prefix egresses via its own gateway:

```
0:      from all lookup local
32762:  from fd97:45c2:b3a1:100::/64 lookup 100 proto static
32763:  from 2607:3640:1064:270::/64 lookup 200 proto static
32766:  from all lookup main

table 100: default via fd97:45c2:b3a1:100::1 dev eth0
table 200: default via 2607:3640:1064:270::1 dev eth0
```

Both tables and both addresses are live on the host — the live netplan
config matches the template. Inbound connections addressed to the GUA
address would route replies correctly via table 200.

### 2. k3s was bootstrapped IPv4-only

```
$ ps aux | grep k3s
ExecStart=/opt/pf9/airctl/bin/k3s server --advertise-address=10.45.45.45
  --bind-address=10.45.45.45 --node-ip=10.45.45.45
  --node-external-ip=10.45.45.45 --service-cidr=10.21.0.0/16 ...
```

`--service-cidr` is a single IPv4 range — no dual-stack (`v4,v6`) range was
configured. This is a Kubernetes apiserver-level constraint: without a
dual-stack `--service-cluster-ip-range`, **no Service in the cluster can
ever get an IPv6 ClusterIP**, regardless of what's configured downstream in
MetalLB or the ingress layer.

### 3. Calico's IP pool is IPv4-only

```
$ kubectl get ippools.crd.projectcalico.org -o custom-columns=NAME:.metadata.name,CIDR:.spec.cidr
NAME                  CIDR
default-ipv4-ippool   10.20.0.0/16
```

No IPv6 pod pool exists.

### 4. MetalLB's address pool is IPv4-only

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default
  namespace: metallb-system
spec:
  addresses:
    - 10.45.45.45-10.45.45.45
```

Only the VM's IPv4 address was ever added to the pool — no IPv6 range.

### 5. The PCD ingress Service (`k8sniff`) falls back to IPv4-only

```
$ kubectl get svc k8sniff -n k8sniff -o yaml
spec:
  ipFamilyPolicy: PreferDualStack
  type: LoadBalancer
```

`k8sniff` (the TLS-SNI proxy that fronts the PCD web UI/API on port 443)
*asks* for dual-stack (`PreferDualStack`), but since the cluster has no IPv6
service range at all (see #2), it silently falls back to IPv4-only and only
ever gets `EXTERNAL-IP: 10.45.45.45`.

### 6. Confirmed on the wire — nothing listens on IPv6 for PCD's ports

```
$ sudo ss -tlnp6
LISTEN  [::]:22     sshd
LISTEN  [::1]:6443  k3s apiserver (loopback only)
```

No global IPv6 address has a listener for 443, 6080, 9494, or any other PCD
port.

### 7. `airctl` (the real installer) does support dual-stack — it just wasn't used

`go.pcd.run`/`pcd-run.sh` is a thin wrapper: it sets a handful of env vars
(`IP_ADDRESS`, `POD_CIDR`, `SERVICE_CIDR`, ...) and hands off to `airctl`,
the actual orchestrator binary (`/usr/bin/airctl` on the VM). `airctl
configure --help` shows first-class dual-stack support that the simple CE
install path never exercises:

```
-e, --external-ip4 ip          set the external IPv4 for the DU
-x, --external-ip6 ip          set the external IPv6 for the DU
-4, --ipv4-enabled             set this flag to enable ipv4 network. To enable dual stack
                                networks, set this flag and "ipv6-enabled"
-6, --ipv6-enabled             set this flag to enable ipv6 network. To enable dual stack
                                networks, set this flag and "ipv4-enabled"
-c, --k3s-pod-cidr string      specify the pod CIDR for k3s cluster (default "10.20.0.0/16")
-s, --k3s-service-cidr string  specify the service CIDR for k3s cluster (default "10.21.0.0/16")
```

`ansible/install-pcd.yml` uses the fast CE path (`go.pcd.run` → effectively
`airctl ce start`), which does **not** expose `-4`/`-6`/`--external-ip6` —
those only exist on the lower-level `airctl configure` command. So this
isn't an upstream limitation so much as a install-path choice: the
CE-fast-path installer this repo drives doesn't turn dual-stack on, but the
underlying orchestrator has the plumbing for it. Whether `airctl configure
-d k3s -4 -6 ...` (the CE deployment type, with dual-stack flags added
manually) is actually supported/tested by Platform9 for CE is unverified —
it would need to be tried against a disposable install, not the current
lab.

## Secondary issue: the `main` table's IPv6 default route is a ticking clock

```
$ ip -6 route show table main default
default via fe80::ae8b:a9ff:fe6e:13de dev eth0 proto ra metric 512 expires 1698sec

$ sysctl net.ipv6.conf.eth0.accept_ra
net.ipv6.conf.eth0.accept_ra = 0
```

`accept_ra` is disabled (correct, since routing is meant to be fully static
via `network-config.yml.j2`), but a stale RA-learned default route is still
sitting in the `main` table with an expiry timer. Once it expires, nothing
will replace it, because:

- `network-config.yml.j2` only puts `::/0` routes in tables `100`/`200`,
  gated by source-prefix policy rules.
- Any process that initiates an outbound IPv6 connection without an address
  already bound to the ULA/GUA prefix (i.e. most software doing a normal
  `connect()`) resolves via the `main` table lookup, which will have no
  default route left → `Network unreachable`.

This doesn't affect *inbound* connections to the GUA address (those already
have a source address pinned, so they route via table 200 correctly), but
it will silently break host-originated IPv6 traffic (apt, DNS-01 renewal
checks, etc.) once the RA route times out.

## Root cause, in one sentence

PCD CE's own `k3s`/Calico/MetalLB stack was deployed single-stack IPv4-only
by the CE-fast-path installer this repo drives (`go.pcd.run`), so there is
no IPv6-capable Service anywhere in the cluster for the ingress layer to
advertise on `::/0` — this is independent of, and not fixable by, the
dual-stack OS network config this repo already sets up correctly on the VM.
`airctl` itself has dual-stack flags, but reaching them means bypassing the
CE-fast-path and re-bootstrapping the management cluster (see
"Automation options" below).

## Automation options

### Safe to automate now: fix the `main`-table IPv6 default-route gap — done

Non-destructive, reversible via this repo's Ansible/netplan template. Added
a catch-all IPv6 `routing-policy` rule (no `from` constraint) to
[ansible/templates/network-config.yml.j2](../../ansible/templates/network-config.yml.j2),
pointing at table 200 (the GUA/public gateway) as a fallback for any source
address that doesn't match the ULA or GUA prefixes. This closes the gap
that currently only gets papered over by a soon-to-expire RA-learned route.

Since `provision-vm.yml` only renders this template once, via cloud-init,
at VM creation time, a new playbook —
[ansible/configure-vm-network.yml](../../ansible/configure-vm-network.yml) —
re-renders the same template (wrapped as a real netplan file) and pushes it
to an already-running `pcd_vms` host with `netplan apply`, so future
routing/addressing changes don't require rebuilding the VM. Not yet run
against the live `pcd-ce` host — needs a deliberate `netplan apply`, which
carries a small risk of dropping the SSH session if the rendered config is
wrong, so run it and verify connectivity before relying on it.

### Not safe to automate blindly: reconfiguring PCD CE for dual-stack

`airctl configure -d k3s -4 -6 --external-ip4 10.45.45.45 --external-ip6
2607:3640:1064:270::dead --k3s-pod-cidr <v4-range>,<v6-range>
--k3s-service-cidr <v4-range>,<v6-range> ...` followed by `airctl
delete-cluster` + `airctl create-cluster` + `airctl start` would, in
principle, recreate the management cluster with dual-stack networking. This
is **destructive** — it tears down and recreates the whole k3s management
cluster (and everything running on it: the DU, cert-manager, hostpath
storage, etc.) — and unverified for the CE deployment type. It shouldn't be
scripted or run without an explicit, deliberate decision (ideally tested
against a disposable VM first), since a failed or unsupported dual-stack
reconfigure could leave the lab's PCD install broken with no easy rollback.
