# Talos has no SSH/shell access at all -- management is entirely over
# apid (50000/tcp) via talosctl. Rules scoped to what an IPv6-only,
# single-node (controlplane + workload) Talos cluster actually needs;
# etcd/trustd/kubelet are only ever node-to-node so they're scoped to the
# cluster's own subnet rather than opened to ::/0.
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

resource "pcd_networking_secgroup_rule" "talos_apid_ingress" {
  security_group_id = pcd_networking_secgroup.talos.id
  description       = "Allow talosctl (apid) management access"
  direction         = "ingress"
  ethertype         = "IPv6"
  protocol          = "tcp"
  port_range_min    = 50000
  port_range_max    = 50000
  remote_ip_prefix  = "::/0"
}

resource "pcd_networking_secgroup_rule" "talos_trustd_ingress" {
  security_group_id = pcd_networking_secgroup.talos.id
  description       = "Allow trustd (node join/trust) from cluster nodes"
  direction         = "ingress"
  ethertype         = "IPv6"
  protocol          = "tcp"
  port_range_min    = 50001
  port_range_max    = 50001
  remote_ip_prefix  = var.subnet_cidr
}

resource "pcd_networking_secgroup_rule" "etcd_ingress" {
  security_group_id = pcd_networking_secgroup.talos.id
  description       = "Allow etcd client/peer traffic from cluster nodes"
  direction         = "ingress"
  ethertype         = "IPv6"
  protocol          = "tcp"
  port_range_min    = 2379
  port_range_max    = 2380
  remote_ip_prefix  = var.subnet_cidr
}

resource "pcd_networking_secgroup_rule" "kubelet_ingress" {
  security_group_id = pcd_networking_secgroup.talos.id
  description       = "Allow kubelet API from cluster nodes"
  direction         = "ingress"
  ethertype         = "IPv6"
  protocol          = "tcp"
  port_range_min    = 10250
  port_range_max    = 10250
  remote_ip_prefix  = var.subnet_cidr
}
