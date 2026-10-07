# Talos has no SSH/shell access at all -- management is entirely over
# apid (50000/tcp) via talosctl. Rules scoped to what an IPv6-only Talos
# cluster actually needs; etcd/trustd/kubelet are only ever node-to-node so
# they're scoped to the bgp-net subnet (where the whole cluster lives)
# rather than opened to ::/0.
resource "pcd_networking_secgroup" "talos" {
  name        = "${var.cluster_name}-cluster"
  description = "Talos + Kubernetes control-plane access for the ${var.cluster_name} cluster"
}

resource "pcd_networking_secgroup_rule" "icmpv6_ingress" {
  security_group_id = pcd_networking_secgroup.talos.id
  description       = "Allow ICMPv6 (required for IPv6 path MTU discovery)"
  direction         = "ingress"
  ethertype         = "IPv6"
  protocol          = "ipv6-icmp"
  remote_ip_prefix  = "::/0"
}

resource "pcd_networking_secgroup_rule" "kube_apiserver_ingress" {
  security_group_id = pcd_networking_secgroup.talos.id
  description       = "Allow Kubernetes API server access"
  direction         = "ingress"
  ethertype         = "IPv6"
  protocol          = "tcp"
  port_range_min    = 6443
  port_range_max    = 6443
  remote_ip_prefix  = "::/0"
}

# apid also serves Talos's *unauthenticated* maintenance API on a node that
# has no machine config yet (every node, from boot until talos.tf pushes its
# config), so this is restricted to the cluster's own subnet and the
# management prefixes rather than opened to ::/0.
resource "pcd_networking_secgroup_rule" "talos_apid_ingress" {
  for_each = toset(concat([data.pcd_networking_subnet.bgp.cidr], var.apid_allowed_prefixes))

  security_group_id = pcd_networking_secgroup.talos.id
  description       = "Allow talosctl (apid) management access from ${each.value}"
  direction         = "ingress"
  ethertype         = "IPv6"
  protocol          = "tcp"
  port_range_min    = 50000
  port_range_max    = 50000
  remote_ip_prefix  = each.value
}

resource "pcd_networking_secgroup_rule" "talos_trustd_ingress" {
  security_group_id = pcd_networking_secgroup.talos.id
  description       = "Allow trustd (node join/trust) from cluster nodes"
  direction         = "ingress"
  ethertype         = "IPv6"
  protocol          = "tcp"
  port_range_min    = 50001
  port_range_max    = 50001
  remote_ip_prefix  = data.pcd_networking_subnet.bgp.cidr
}

resource "pcd_networking_secgroup_rule" "etcd_ingress" {
  security_group_id = pcd_networking_secgroup.talos.id
  description       = "Allow etcd client/peer traffic from cluster nodes"
  direction         = "ingress"
  ethertype         = "IPv6"
  protocol          = "tcp"
  port_range_min    = 2379
  port_range_max    = 2380
  remote_ip_prefix  = data.pcd_networking_subnet.bgp.cidr
}

resource "pcd_networking_secgroup_rule" "kubelet_ingress" {
  security_group_id = pcd_networking_secgroup.talos.id
  description       = "Allow kubelet API from cluster nodes"
  direction         = "ingress"
  ethertype         = "IPv6"
  protocol          = "tcp"
  port_range_min    = 10250
  port_range_max    = 10250
  remote_ip_prefix  = data.pcd_networking_subnet.bgp.cidr
}

# Kept in its own group (rather than in the cluster group above) so HTTP
# exposure can be attached to or detached from the node independently of the
# Talos/Kubernetes control-plane rules.
resource "pcd_networking_secgroup" "http" {
  name        = "${var.cluster_name}-http"
  description = "Inbound HTTP (80/tcp) to the ${var.cluster_name} cluster"
}

resource "pcd_networking_secgroup_rule" "http_ingress" {
  security_group_id = pcd_networking_secgroup.http.id
  description       = "Allow HTTP (80/tcp)"
  direction         = "ingress"
  ethertype         = "IPv6"
  protocol          = "tcp"
  port_range_min    = 80
  port_range_max    = 80
  remote_ip_prefix  = "::/0"
}

# With more than one node, everything the CNI, Spegel (5001/tcp), and
# Kubernetes need between nodes -- BGP mesh sessions, overlay tunnels,
# health checks, pod-to-pod traffic -- has to be allowed member-to-member.
# Scoped to the group itself rather than the bgp-net subnet so it only
# covers this cluster's nodes.
resource "pcd_networking_secgroup_rule" "cluster_internal_ingress" {
  security_group_id = pcd_networking_secgroup.talos.id
  description       = "Allow all traffic between members of this cluster"
  direction         = "ingress"
  ethertype         = "IPv6"
  remote_group_id   = pcd_networking_secgroup.talos.id
}

# Traffic a control-plane node originates toward a pod on another node (the
# kube-apiserver reaching an aggregated API such as calico-apiserver, for
# instance) can leave with the control-plane VIP as its source address: the
# VIP is a /128 on eth0 and wins the kernel's source selection for
# BGP-learned routes, which the route `source` patch in talos.tf (on-link
# prefix only) doesn't cover. The VIP isn't one of the group's member ports'
# fixed IPs, so the cluster-internal rule above doesn't match it. Confirmed
# live 2026-09-26: SYNs from the VIP holder to a remote pod never arrived.
resource "pcd_networking_secgroup_rule" "vip_ingress" {
  security_group_id = pcd_networking_secgroup.talos.id
  description       = "Allow all traffic sourced from the control-plane VIP"
  direction         = "ingress"
  ethertype         = "IPv6"
  remote_ip_prefix  = "${local.cluster_vip}/128"
}

# Pod-sourced traffic (pod-to-pod across nodes, pod-to-node) carries the
# pod's own IP as its source, which is neither a member port's fixed IP nor
# the VIP, so nothing above matches it. Confirmed live 2026-09-26: with the
# pod pool already in allowed_address_pairs, cross-node pod-to-pod still
# timed out. Security-group rules can't match on destination IP, so this also
# lets pods reach node ports (etcd, apid, kubelet); those are still guarded by
# mTLS, and Calico host endpoint policy is the way to restrict them further.
resource "pcd_networking_secgroup_rule" "pod_pool_ingress" {
  for_each = toset(local.pod_pool_cidrs)

  security_group_id = pcd_networking_secgroup.talos.id
  description       = "Allow all traffic sourced from the pod pool ${each.value}"
  direction         = "ingress"
  ethertype         = "IPv6"
  remote_ip_prefix  = each.value
}
