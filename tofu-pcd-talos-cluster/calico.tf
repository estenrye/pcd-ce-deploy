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

  # Without an APIServer resource the operator can't manage IP pools (the
  # ippools TigeraStatus goes Degraded: "Unable to modify IP pools while
  # Calico API server is unavailable"). It deploys calico-apiserver, which
  # serves the projectcalico.org/v3 API.
  calico_apiserver = {
    apiVersion = "operator.tigera.io/v1"
    kind       = "APIServer"
    metadata   = { name = "default" }
    spec       = {}
  }

  # Has the tigera operator install and manage the Gateway API CRDs and the
  # Envoy-based Calico gateway controller.
  calico_gateway_api = {
    apiVersion = "operator.tigera.io/v1"
    kind       = "GatewayAPI"
    metadata   = { name = "default" }
    spec = {
      gatewayClasses = [for name, gc in var.gateway_classes : merge(
        { name = name },
        gc.envoy_proxy_ref == null ? {} : { envoyProxyRef = gc.envoy_proxy_ref },
        gc.gateway_kind == null ? {} : { gatewayKind = gc.gateway_kind },
      )]
    }
  }

  # Namespace for the EnvoyProxy resources the GatewayClasses reference
  # (var.gateway_classes envoy_proxy_ref); nothing else creates it.
  envoy_gateway_namespace = {
    apiVersion = "v1"
    kind       = "Namespace"
    metadata   = { name = "envoy-gateway-system" }
  }

  envoy_proxies = [
    {
      apiVersion = "gateway.envoyproxy.io/v1alpha1"
      kind       = "EnvoyProxy"
      metadata   = { name = "custom-proxy-config", namespace = "envoy-gateway-system" }
      spec = {
        ipFamily      = "IPv6"
        mergeGateways = true
        provider = {
          type = "Kubernetes"
          kubernetes = {
            envoyDeployment = {
              replicas = 2
              strategy = {
                type          = "RollingUpdate"
                rollingUpdate = { maxSurge = 0, maxUnavailable = 1 }
              }
              pod = {
                affinity = {
                  podAntiAffinity = {
                    requiredDuringSchedulingIgnoredDuringExecution = [{
                      labelSelector = {
                        matchLabels = { "gateway.envoyproxy.io/owning-gatewayclass" = "external-merged" }
                      }
                      topologyKey = "kubernetes.io/hostname"
                    }]
                  }
                }
                tolerations = [{
                  key      = "node-role.kubernetes.io/control-plane"
                  operator = "Exists"
                  effect   = "NoSchedule"
                }]
              }
            },
            envoyService = {
              annotations           = { "projectcalico.org/ipv6pools" = jsonencode([var.envoy_proxy_pools.ingress]) }
              externalTrafficPolicy = "Cluster"
            }
          }
        }
      }
    },
    {
      apiVersion = "gateway.envoyproxy.io/v1alpha1"
      kind       = "EnvoyProxy"
      metadata   = { name = "internal-proxy-config", namespace = "envoy-gateway-system" }
      spec = {
        ipFamily      = "IPv6"
        mergeGateways = true
        provider = {
          type = "Kubernetes"
          kubernetes = {
            envoyDeployment = { replicas = 2 }
            envoyService = {
              annotations           = { "projectcalico.org/ipv6pools" = jsonencode([var.envoy_proxy_pools.internal]) }
              externalTrafficPolicy = "Cluster"
            }
          }
        }
      }
    },
    # Dedicated classes: mergeGateways false gives every Gateway object its own
    # proxy Deployment and Service (and so its own VIP) instead of sharing one
    # per class.
    {
      apiVersion = "gateway.envoyproxy.io/v1alpha1"
      kind       = "EnvoyProxy"
      metadata   = { name = "external-dedicated-proxy-config", namespace = "envoy-gateway-system" }
      spec = {
        ipFamily      = "IPv6"
        mergeGateways = false
        provider = {
          type = "Kubernetes"
          kubernetes = {
            envoyDeployment = { replicas = 2 }
            envoyService = {
              annotations           = { "projectcalico.org/ipv6pools" = jsonencode([var.envoy_proxy_pools.ingress]) }
              externalTrafficPolicy = "Cluster"
            }
          }
        }
      }
    },
    {
      apiVersion = "gateway.envoyproxy.io/v1alpha1"
      kind       = "EnvoyProxy"
      metadata   = { name = "internal-dedicated-proxy-config", namespace = "envoy-gateway-system" }
      spec = {
        ipFamily      = "IPv6"
        mergeGateways = false
        provider = {
          type = "Kubernetes"
          kubernetes = {
            envoyDeployment = { replicas = 2 }
            envoyService = {
              annotations           = { "projectcalico.org/ipv6pools" = jsonencode([var.envoy_proxy_pools.internal]) }
              externalTrafficPolicy = "Cluster"
            }
          }
        }
      }
    },
  ]

  # Talos inline manifest name => rendered YAML. Names are sorted by Talos,
  # so the Installation sorts ahead of the CRD-backed resources.
  calico_inline_manifests = merge(
    { "calico-00-installation" = yamlencode(local.calico_installation) },
    { "calico-05-apiserver" = yamlencode(local.calico_apiserver) },
    { "calico-10-bgp-configuration" = yamlencode(local.calico_bgp_configuration) },
    { for m in local.calico_bgp_peers : "calico-20-bgp-peer-${m.metadata.name}" => yamlencode(m) },
    { for m in local.calico_pod_ip_pools : "calico-30-ippool-${m.metadata.name}" => yamlencode(m) },
    { for m in local.calico_lb_ip_pools : "calico-40-ippool-${m.metadata.name}" => yamlencode(m) },
    { for m in local.calico_default_deny_policy : "calico-50-globalnetworkpolicy-${m.metadata.name}" => yamlencode(m) },
    { "calico-60-gatewayapi" = yamlencode(local.calico_gateway_api) },
    { "calico-65-envoy-gateway-namespace" = yamlencode(local.envoy_gateway_namespace) },
    { for m in local.envoy_proxies : "calico-66-envoyproxy-${m.metadata.name}" => yamlencode(m) },
  )
}
