# Calico manifests rendered from var.calico_* (modelled on the flux-rendered
# controlplane cluster's operator.tigera.io Installation plus crd.projectcalico.org
# BGPConfiguration, BGPPeer, IPPool and GlobalNetworkPolicy resources). They are
# delivered as Talos inlineManifests on the control plane, next to the
# tigera-operator manifest in extraManifests (talos.tf). Talos retries a manifest
# that fails to apply, so the CRD-backed kinds settle once the operator has
# installed its CRDs.
locals {
  # One source of truth for what Neutron port security and the security groups
  # must let through: the pod pools and the BGP-advertised VIP ranges.
  pod_pool_cidrs = [for p in var.calico_ip_pools : p.cidr]
  bgp_vip_ranges = var.calico_bgp.service_load_balancer_ips

  calico_ipip_modes = {
    None             = "Never"
    IPIP             = "Always"
    IPIPCrossSubnet  = "CrossSubnet"
    VXLAN            = "Never"
    VXLANCrossSubnet = "Never"
  }
  calico_vxlan_modes = {
    None             = "Never"
    IPIP             = "Never"
    IPIPCrossSubnet  = "Never"
    VXLAN            = "Always"
    VXLANCrossSubnet = "CrossSubnet"
  }

  calico_installation = {
    apiVersion = "operator.tigera.io/v1"
    kind       = "Installation"
    metadata   = { name = "default" }
    spec = {
      calicoNetwork = {
        bgp = "Enabled"
        ipPools = [for p in var.calico_ip_pools : {
          name          = p.name
          cidr          = p.cidr
          encapsulation = p.encapsulation
          natOutgoing   = p.nat_outgoing ? "Enabled" : "Disabled"
          blockSize     = p.block_size
          nodeSelector  = "all()"
        }]
        # jsondecode sidesteps HCL's requirement that both conditional
        # branches share one object type.
        nodeAddressAutodetectionV6 = jsondecode(length(var.calico_node_address_autodetection_v6_cidrs) > 0 ?
          jsonencode({ cidrs = var.calico_node_address_autodetection_v6_cidrs }) :
        jsonencode({ kubernetes = "NodeInternalIP" }))
      }
      controlPlaneNodeSelector = {}
      controlPlaneReplicas     = 2
      controlPlaneTolerations  = []
      imagePullSecrets         = []
      # Two separate switches: flexVolumePath controls the legacy flexvol-driver
      # (a hostPath under /usr/libexec, which is read-only on Talos), while
      # kubeletVolumePluginPath controls the Calico CSI plugin.
      flexVolumePath          = "None"
      kubeletVolumePluginPath = "None"
      kubernetesProvider      = ""
      nonPrivileged           = "Disabled"
    }
  }

  calico_bgp_configuration = {
    apiVersion = "crd.projectcalico.org/v1"
    kind       = "BGPConfiguration"
    metadata   = { name = "default" }
    spec = {
      asNumber               = var.calico_bgp.as_number
      logSeverityScreen      = var.calico_bgp.log_severity_screen
      nodeToNodeMeshEnabled  = var.calico_bgp.node_to_node_mesh_enabled
      serviceLoadBalancerIPs = [for c in var.calico_bgp.service_load_balancer_ips : { cidr = c }]
    }
  }

  calico_bgp_peers = [for peer in var.calico_bgp.peers : {
    apiVersion = "crd.projectcalico.org/v1"
    kind       = "BGPPeer"
    metadata   = { name = peer.name }
    spec = {
      asNumber = peer.as_number
      peerIP   = peer.peer_ip
    }
  }]

  # The operator only passes pool settings through to its own IPPool; the
  # explicit resource pins allowedUses, which the Installation can't express.
  calico_pod_ip_pools = [for p in var.calico_ip_pools : {
    apiVersion = "crd.projectcalico.org/v1"
    kind       = "IPPool"
    metadata   = { name = p.name }
    spec = {
      allowedUses  = ["Workload", "Tunnel"]
      blockSize    = p.block_size
      cidr         = p.cidr
      ipipMode     = local.calico_ipip_modes[p.encapsulation]
      natOutgoing  = p.nat_outgoing
      nodeSelector = "all()"
      vxlanMode    = local.calico_vxlan_modes[p.encapsulation]
    }
  }]

  calico_lb_ip_pools = [for p in var.calico_load_balancer_pools : {
    apiVersion = "crd.projectcalico.org/v1"
    kind       = "IPPool"
    metadata   = { name = p.name }
    spec = {
      allowedUses  = ["LoadBalancer"]
      cidr         = p.cidr
      disabled     = p.disabled
      nodeSelector = "all()"
    }
  }]

  calico_default_deny_policy = [for _ in(var.calico_default_deny_policy.enabled ? [1] : []) : {
    apiVersion = "crd.projectcalico.org/v1"
    kind       = "GlobalNetworkPolicy"
    metadata   = { name = "deny-app-policy" }
    spec = {
      types = ["Ingress", "Egress"]
      # DNS egress to kube-dns is the only traffic allowed out of a
      # non-exempt namespace until it gets its own policy.
      egress = [for proto in ["TCP", "UDP"] : {
        action   = "Allow"
        protocol = proto
        destination = {
          services = { name = "kube-dns", namespace = "kube-system" }
        }
      }]
      namespaceSelector = "kubernetes.io/metadata.name not in {${join(", ", [for ns in var.calico_default_deny_policy.exempt_namespaces : "\"${ns}\""])}}"
    }
  }]

  # Talos inline manifest name => rendered YAML. Names are sorted by Talos,
  # so the Installation sorts ahead of the CRD-backed resources.
  calico_inline_manifests = merge(
    { "calico-00-installation" = yamlencode(local.calico_installation) },
    { "calico-10-bgp-configuration" = yamlencode(local.calico_bgp_configuration) },
    { for m in local.calico_bgp_peers : "calico-20-bgp-peer-${m.metadata.name}" => yamlencode(m) },
    { for m in local.calico_pod_ip_pools : "calico-30-ippool-${m.metadata.name}" => yamlencode(m) },
    { for m in local.calico_lb_ip_pools : "calico-40-ippool-${m.metadata.name}" => yamlencode(m) },
    { for m in local.calico_default_deny_policy : "calico-50-globalnetworkpolicy-${m.metadata.name}" => yamlencode(m) },
  )
}
