resource "talos_machine_secrets" "this" {
  talos_version = var.talos_version
}

locals {
  # Config shared by every node, control-plane and worker alike.
  common_machine = {
    # Spegel (https://spegel.dev/docs/getting-started/#talos) serves
    # image layers out of containerd's content store, which Talos
    # discards after unpacking by default. Talos merges *.part files
    # from /etc/cri/conf.d into its generated containerd CRI config.
    files = [
      {
        path    = "/etc/cri/conf.d/20-customization.part"
        op      = "create"
        content = <<-EOT
          [plugins."io.containerd.cri.v1.images"]
            discard_unpacked_layers = false
        EOT
      }
    ]
    # Stop SLAAC from adding a second global address (`...:f816:3eff:...`, derived
    # from the MAC) next to the DHCPv6-assigned one. The kernel prefers the SLAAC
    # address as the source of node-originated traffic, and the "all traffic from
    # cluster members" security-group rule only matches the DHCPv6 (fixed IP)
    # address, so that traffic (Typha, BGP, host-to-pod) is dropped.
    sysctls = {
      "net.ipv6.conf.default.autoconf" = "0"
      "net.ipv6.conf.eth0.autoconf"    = "0"
    }
  }

  # Talos's own defaults here are IPv4 (10.244.0.0/16 /
  # 10.96.0.0/12) regardless of the host network -- confirmed
  # live, 2026-09-17: kube-apiserver refuses to start at all with
  # them on an IPv6-only node ("service IP family \"10.96.0.0/12\"
  # must match public address family"), crash-looping forever
  # with etcd/kubelet otherwise healthy. Pod/service CIDRs are
  # just an internal overlay address space -- any private range
  # works -- but the address *family* has to match the node's.
  # These are cluster-bootstrap-time settings: changing them after
  # etcd has formed needs a full reset, not a live config patch.
  # Workers need them too (kubelet derives its cluster DNS address
  # from the service subnet).
  #
  # This no longer includes `cni.name`: Talos folded CNI selection into
  # whether a KubeFlannelCNIConfig document exists at all (see
  # cni_config_patches) -- there's no longer a field for it here.
  common_cluster_network = {
    podSubnets     = [var.pod_subnet]
    serviceSubnets = [var.service_subnet]
  }

  # Config documents that superseded parts of the legacy v1alpha1 config.
  # Talos now hard-conflicts if the same setting is present both ways (see
  # pkg/machinery/config/types/k8s/{node,network,kubelet,apiserver}.go and
  # types/network/resolver.go's V1Alpha1ConflictValidate upstream), so these
  # replace what used to be common_machine.network.nameservers and
  # common_machine.kubelet, and cluster.network below. Common to every node.
  common_config_patches = [
    # Supersedes `.machine.network.nameservers`. Without nameservers, Talos's
    # host DNS resolver falls back to (or merges in) its own hardcoded public
    # defaults -- confirmed live, 2026-09-16: console log showed it
    # repeatedly trying 8.8.8.8:53, which can only ever fail on this
    # IPv4-less network. Setting this statically overrides that, so the only
    # servers Talos ever queries are the DNS64 resolvers this subnet is
    # built around.
    yamlencode({
      apiVersion  = "v1alpha1"
      kind        = "ResolverConfig"
      nameservers = [for ns in var.dns_nameservers : { address = ns }]
    }),
    # Supersedes `.machine.kubelet.nodeIP` -- pins kubelet's advertised node
    # address to the bgp-net subnet, matching the pattern in
    # github.com/siderolabs/contrib's hcloud Terraform example.
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "KubeNodeConfig"
      nodeIP = {
        validSubnets = [data.pcd_networking_subnet.bgp.cidr]
      }
    }),
    # Supersedes `.cluster.network.{podSubnets,serviceSubnets}`.
    yamlencode(merge({
      apiVersion = "v1alpha1"
      kind       = "KubeNetworkConfig"
    }, local.common_cluster_network)),
    # Still a plain (unmigrated) v1alpha1 field, not a separate document.
    # Sets kubelet's --cloud-provider=external on every node, for
    # openstack-cloud-controller-manager (see
    # openstack-cloud-controller-manger.tf). Nodes register with the
    # node.cloudprovider.kubernetes.io/uninitialized taint (and get properly
    # cloud-initialized by OCCM) only if this is already set at first kubelet
    # registration -- kubelet doesn't retroactively taint an already-existing
    # Node object, and OCCM's node controller treats an untainted node as
    # already-initialized and skips it. Chosen to build this cluster fresh
    # with the flag on from the start, rather than cordon+drain+`kubectl
    # delete node`+rejoin each of the 6 already-running nodes to force
    # re-registration.
    #
    # `manifests` (for auto-deploying the CCM daemonset) is intentionally
    # left unset: Talos only applies it "as part of the bootstrap", and this
    # cluster deploys OCCM itself via the cloud-config Secret + Helm values
    # already built in openstack-cloud-controller-manger.tf.
    yamlencode({
      cluster = {
        externalCloudProvider = {
          enabled = true
        }
        # Fetched and applied by Talos itself during bootstrap (control
        # plane only; workers ignore it). Like `manifests`, it is only
        # applied as part of the bootstrap, not on later config edits.
        extraManifests = [
          "https://raw.githubusercontent.com/projectcalico/calico/${var.calico_version}/manifests/tigera-operator.yaml",
          # OCCM: removes the node.cloudprovider.kubernetes.io/uninitialized
          # taint set by externalCloudProvider above. Its DaemonSet mounts
          # the cloud-config Secret that openstack-cloud-controller-manger.tf
          # creates, and tolerates that taint, so it can start before the
          # Secret exists and simply waits for it.
          "https://raw.githubusercontent.com/kubernetes/cloud-provider-openstack/${var.occm_version}/manifests/controller-manager/cloud-controller-manager-roles.yaml",
          "https://raw.githubusercontent.com/kubernetes/cloud-provider-openstack/${var.occm_version}/manifests/controller-manager/cloud-controller-manager-role-bindings.yaml",
          "https://raw.githubusercontent.com/kubernetes/cloud-provider-openstack/${var.occm_version}/manifests/controller-manager/openstack-cloud-controller-manager-ds.yaml",
          # CSI snapshot support (kubernetes-csi/external-snapshotter): the
          # three snapshot.storage.k8s.io CRDs, then the cluster-wide
          # snapshot-controller (RBAC + Deployment). The Cinder controller's
          # csi-snapshotter sidecar below needs these CRDs to run.
          "https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/${var.external_snapshotter_version}/client/config/crd/snapshot.storage.k8s.io_volumesnapshotclasses.yaml",
          "https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/${var.external_snapshotter_version}/client/config/crd/snapshot.storage.k8s.io_volumesnapshotcontents.yaml",
          "https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/${var.external_snapshotter_version}/client/config/crd/snapshot.storage.k8s.io_volumesnapshots.yaml",
          "https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/${var.external_snapshotter_version}/deploy/kubernetes/snapshot-controller/rbac-snapshot-controller.yaml",
          "https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/${var.external_snapshotter_version}/deploy/kubernetes/snapshot-controller/setup-snapshot-controller.yaml",
          # Cinder CSI: the CSIDriver object, the controller Deployment
          # (attacher/provisioner/snapshotter/resizer sidecars) and the node
          # DaemonSet that formats and mounts the attached volume. Both read
          # the same cloud-config Secret as OCCM. No StorageClass is shipped
          # here.
          "https://raw.githubusercontent.com/kubernetes/cloud-provider-openstack/${var.cinder_csi_version}/manifests/cinder-csi-plugin/csi-cinder-driver.yaml",
          "https://raw.githubusercontent.com/kubernetes/cloud-provider-openstack/${var.cinder_csi_version}/manifests/cinder-csi-plugin/cinder-csi-controllerplugin-rbac.yaml",
          "https://raw.githubusercontent.com/kubernetes/cloud-provider-openstack/${var.cinder_csi_version}/manifests/cinder-csi-plugin/cinder-csi-controllerplugin.yaml",
          "https://raw.githubusercontent.com/kubernetes/cloud-provider-openstack/${var.cinder_csi_version}/manifests/cinder-csi-plugin/cinder-csi-nodeplugin-rbac.yaml",
          "https://raw.githubusercontent.com/kubernetes/cloud-provider-openstack/${var.cinder_csi_version}/manifests/cinder-csi-plugin/cinder-csi-nodeplugin.yaml",
        ]
      }
    }),
  ]

  # var.cni_name used to select `.cluster.network.cni.name`; that field no
  # longer exists. Talos's generated config always includes a
  # KubeFlannelCNIConfig document by default, so "flannel" needs no patch,
  # and anything else (here, the default "none", since this cluster installs
  # its own CNI separately) needs that document explicitly deleted.
  cni_config_patches = var.cni_name == "flannel" ? [] : [
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "KubeFlannelCNIConfig"
      "$patch"   = "delete"
    })
  ]
}

data "talos_machine_configuration" "controlplane" {
  cluster_name       = var.cluster_name
  cluster_endpoint   = local.cluster_endpoint
  machine_type       = "controlplane"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version

  config_patches = concat(local.common_config_patches, local.cni_config_patches, [
    # Control plane only: workers ignore inlineManifests anyway. Unlike
    # extraManifests, Talos re-applies these when their contents change.
    yamlencode({
      cluster = {
        inlineManifests = [for name in sort(keys(local.inline_manifests)) : {
          name     = name
          contents = local.inline_manifests[name]
        }]
      }
    }),
    yamlencode({
      machine = merge(local.common_machine, {
        network = {
          interfaces = [
            {
              interface = "eth0"
              dhcp      = true
              dhcpOptions = {
                ipv4 = false
                ipv6 = true
              }
              # Talos elects one control-plane node (via etcd) to hold this
              # address and announces it with NDP. The reserved address is
              # pcd_networking_port.vip (an allowed address pair on every
              # control-plane port, see instance.tf).
              vip = {
                ip = local.cluster_vip
              }
            }
          ]
        }
      })
    }),
    # Supersedes `.cluster.apiServer.certSANs` (renamed certExtraSANs). The
    # endpoint host is added to the API server cert SANs by config
    # generation already; stated explicitly so it can't be lost.
    #
    # allowSchedulingOnControlPlanes has no document-patch equivalent at
    # all: Talos folded it into a generation-time option
    # (generate.Options.AllowSchedulingOnControlPlanes) that this provider's
    # talos_machine_configuration data source doesn't expose. The base
    # generated config already defaults to the same behavior as
    # var.schedule_on_controlplanes = false (a NoSchedule taint via
    # KubeNodeConfig), which is enforced by that variable's validation --
    # see its definition in variables.tf for what flipping it to true would
    # need.
    #
    # With the Barbican KMS key on, this document can't be used: it has no
    # extraVolumes, and the legacy .cluster.apiServer needed for the KMS
    # socket mount hard-conflicts with it. kms.tf deletes the document and
    # sets the same SAN through the legacy field instead.
    ], var.create_kms_key ? local.kms_controlplane_patches : [
    yamlencode({
      apiVersion    = "v1alpha1"
      kind          = "KubeAPIServerConfig"
      certExtraSANs = [local.cluster_vip]
    }),
  ])
}

data "talos_machine_configuration" "worker" {
  cluster_name       = var.cluster_name
  cluster_endpoint   = local.cluster_endpoint
  machine_type       = "worker"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version

  config_patches = concat(local.common_config_patches, local.cni_config_patches, [
    yamlencode({
      machine = merge(local.common_machine, {
        network = {
          interfaces = [
            {
              interface = "eth0"
              dhcp      = true
              dhcpOptions = {
                ipv4 = false
                ipv6 = true
              }
            }
          ]
        }
      })
    }),
  ])
}

data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  nodes                = local.controlplane_addresses
  endpoints            = local.controlplane_addresses
}

# Instances boot with no user_data, into Talos maintenance mode, and these
# push each node's machine config over apid -- the first time as the
# initial config, afterwards as in-place updates (Talos reboots a node
# only if a change needs it). Editing the config therefore never replaces
# an instance. Each node is addressed directly by its port address, not the
# VIP, which doesn't exist until the controlplane is up.
resource "talos_machine_configuration_apply" "controlplane" {
  count = var.controlplane_count

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.controlplane.machine_configuration
  node                        = local.controlplane_addresses[count.index]
  endpoint                    = local.controlplane_addresses[count.index]

  # Make on-link traffic (including the control-plane VIP holder's) leave from the
  # node's own fixed IP. The VIP is a /128 and wins the kernel's source selection.
  config_patches = [
    yamlencode({
      machine = {
        network = {
          interfaces = [
            {
              interface = "eth0"
              routes = [
                {
                  network = data.pcd_networking_subnet.bgp.cidr
                  source  = local.controlplane_addresses[count.index]
                  metric  = 100
                }
              ]
            }
          ]
        }
      }
    })
  ]

  # The security groups and their apid rule gate 50000/tcp, so the node
  # isn't reachable until they're attached to its port.
  depends_on = [
    pcd_compute_instance.controlplane,
    pcd_networking_port_secgroup_associate.controlplane,
    pcd_networking_secgroup_rule.talos_apid_ingress,
  ]
}

resource "talos_machine_configuration_apply" "worker" {
  count = var.worker_count

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.worker.machine_configuration
  node                        = local.worker_addresses[count.index]
  endpoint                    = local.worker_addresses[count.index]

  # Make on-link traffic (including the control-plane VIP holder's) leave from the
  # node's own fixed IP. The VIP is a /128 and wins the kernel's source selection.
  config_patches = [
    yamlencode({
      machine = {
        network = {
          interfaces = [
            {
              interface = "eth0"
              routes = [
                {
                  network = data.pcd_networking_subnet.bgp.cidr
                  source  = local.worker_addresses[count.index]
                  metric  = 100
                }
              ]
            }
          ]
        }
      }
    })
  ]

  depends_on = [
    pcd_compute_instance.worker,
    pcd_networking_port_secgroup_associate.worker,
    pcd_networking_secgroup_rule.talos_apid_ingress,
  ]
}

locals {
  # Reboots the node in $NODE once its first config is live, then waits for
  # apid to answer again. Shared by the control-plane and worker reboots.
  #
  # Output is captured into variables rather than piped to `grep -q`: under
  # pipefail grep exits on the first match, the writer dies of SIGPIPE, and
  # the pipeline reports failure even though the text matched.
  reboot_node_script = <<-EOT
    set -euo pipefail
    command -v talosctl >/dev/null || { echo "talosctl not found in PATH" >&2; exit 1; }
    cfg=$(mktemp)
    trap 'rm -f "$cfg"' EXIT
    printf '%s' "$TALOSCONFIG_CONTENT" > "$cfg"
    node="$NODE"
    tctl() { talosctl --talosconfig "$cfg" -n "$node" -e "$node" "$@"; }

    # The apply call returns as soon as the config is accepted, while the
    # node is still provisioning (EPHEMERAL partition, config persist). A
    # reboot in that window comes back in maintenance mode with no config.
    # An authenticated call only works once the config is live, and
    # EPHEMERAL being ready means first-boot provisioning is done.
    settled=0
    for _ in $(seq 60); do
      if tctl version >/dev/null 2>&1; then
        vol=$(tctl get volumestatus EPHEMERAL -o yaml 2>/dev/null || true)
        if grep -q 'phase: ready' <<<"$vol"; then
          settled=1
          break
        fi
      fi
      sleep 5
    done
    [ "$settled" = 1 ] || { echo "$node never finished first-boot provisioning" >&2; exit 1; }
    sleep 10

    # No --wait: it also waits for the Kubernetes API, which can't come up
    # until talos_machine_bootstrap runs, and that depends on the control
    # plane reboots. Wait for apid to go down and come back instead.
    tctl reboot --wait=false
    for _ in $(seq 60); do
      tctl version >/dev/null 2>&1 || break
      sleep 2
    done
    for _ in $(seq 120); do
      if tctl version >/dev/null 2>&1; then
        exit 0
      fi
      sleep 5
    done
    echo "$node did not come back after reboot" >&2
    exit 1
  EOT
}

# One reboot per instance, right after its first config push. A node boots
# into maintenance mode before it has any machine config, and during that
# window the kernel forms a SLAAC address (`...:f816:3eff:...`) next to the
# DHCPv6 one. machine.sysctls (autoconf = 0) stops new SLAAC addresses but
# doesn't remove one that already exists, and the security groups only match
# the DHCPv6 address, so without this the SLAAC one keeps being used as the
# source address until the node next restarts. Rebooting once with the
# config in place clears it.
#
# The Talos provider has no reboot resource, and apply_mode = "reboot" on the
# apply resources above would reboot a node on every later config edit, so
# this shells out to talosctl instead. It is keyed on the instance ID, so it
# runs once for each new instance and never for a config change. Needs
# talosctl on the machine running tofu, with an IPv6 route to the nodes.
#
# On a fresh build the reboots can run in parallel (etcd isn't bootstrapped
# yet). Adding this to an *already running* cluster reboots every existing
# node once, so apply that with `-parallelism=1`: each reboot then finishes
# (apid answering again) before the next starts, instead of taking all three
# control-plane nodes (and etcd quorum) down together.
resource "terraform_data" "reboot_controlplane" {
  count = var.reboot_after_first_config ? var.controlplane_count : 0

  triggers_replace = {
    instance = pcd_compute_instance.controlplane[count.index].id
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = local.reboot_node_script
    environment = {
      TALOSCONFIG_CONTENT = nonsensitive(data.talos_client_configuration.this.talos_config)
      NODE                = local.controlplane_addresses[count.index]
    }
  }

  depends_on = [talos_machine_configuration_apply.controlplane]
}

resource "terraform_data" "reboot_worker" {
  count = var.reboot_after_first_config ? var.worker_count : 0

  triggers_replace = {
    instance = pcd_compute_instance.worker[count.index].id
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = local.reboot_node_script
    environment = {
      TALOSCONFIG_CONTENT = nonsensitive(data.talos_client_configuration.this.talos_config)
      NODE                = local.worker_addresses[count.index]
    }
  }

  depends_on = [talos_machine_configuration_apply.worker]
}

# Bootstrap etcd once, on the first control-plane node. The other
# control-plane nodes join that etcd cluster by themselves once it exists,
# and workers join via the VIP endpoint.
#
# This only runs when the resource is created or explicitly replaced, which
# is what you want: re-bootstrapping a node in a *live* multi-node cluster
# would start a second, separate etcd cluster instead of rejoining the
# first. Replacing a single controlplane node needs only its apply, not a
# new bootstrap.
resource "talos_machine_bootstrap" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = local.controlplane_addresses[0]

  depends_on = [
    talos_machine_configuration_apply.controlplane,
    terraform_data.reboot_controlplane,
  ]
}

# Blocks `tofu apply` from returning "done" until the cluster is actually
# healthy end to end (etcd, kubelet, and core Kubernetes components) --
# not just until the bootstrap API call was accepted.
data "talos_cluster_health" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  control_plane_nodes  = local.controlplane_addresses
  worker_nodes         = local.worker_addresses
  endpoints            = local.controlplane_addresses

  depends_on = [
    talos_machine_bootstrap.this,
    talos_machine_configuration_apply.worker,
    terraform_data.reboot_worker,
    terraform_data.reboot_controlplane_kms,
  ]
}

# The resource form, not the (deprecated, removal-pending) data source of
# the same name.
resource "talos_cluster_kubeconfig" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = local.controlplane_addresses[0]

  depends_on = [data.talos_cluster_health.this]
}
