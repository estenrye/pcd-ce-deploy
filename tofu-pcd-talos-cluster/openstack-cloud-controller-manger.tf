# Stage 2 — run AS the talos-occm user created in stage 1.
# pcd_identity_application_credential always belongs to the *authenticated*
# user, so this stage authenticates as talos-occm, scoped to the cluster
# project. It then renders the Helm values for the OCCM chart.


data "onepassword_item" "occm" {
  vault = var.onepassword_vault
  title = var.onepassword_occm_item_title
}

provider "pcd" {
  alias    = "pcd-occm"
  auth_url = var.pcd_auth_url
  region   = var.pcd_region
  password = data.onepassword_item.occm.password
  # Authenticate by user_id, not user_name + user_domain_id: the pcd
  # provider's Scope-building always falls back to user_domain_id for the
  # *project* scope's domain when project_domain_id is unset, which
  # Gophercloud then rejects as "ProjectID must be supplied alone in a
  # Scope" (see the note on the user_id field in tofu-pcd's onepassword_item
  # resource). A user ID is globally unique, so no domain is needed to
  # identify it, which avoids the bug entirely.
  user_id   = data.onepassword_item.occm.section_map["PCD"].field_map["user_id"].value
  tenant_id = data.onepassword_item.occm.section_map["PCD"].field_map["project_id"].value
}

resource "pcd_identity_application_credential" "occm" {
  provider = pcd.pcd-occm

  name        = "talos-occm"
  description = "openstack-cloud-controller-manager for the Talos cluster"
  # Keystone's implied roles expand "member" -> +"reader" and
  # "load-balancer_member" -> +"load-balancer_observer" server-side; the
  # provider's `roles` attribute reflects the server's expanded set as-is
  # (application_credential_resource.go's flatten()), so all 4 must be listed
  # here or apply fails with "Provider produced inconsistent result after
  # apply" (planned 2 elements, actual 4).
  roles        = ["member", "load-balancer_member", "reader", "load-balancer_observer"]
  unrestricted = false
  # expires_at = "2027-09-27T00:00:00Z"   # optional; rotating means a new cred + secret update
}

data "pcd_networking_subnet" "floating" {
  name = var.floating_network_subnet_name
}

# Helm values for the openstack-cloud-controller-manager chart.
# Contains the secret — keep it out of git.
resource "local_sensitive_file" "occm_values" {
  filename        = "${path.module}/occm-values.yaml"
  file_permission = "0600"
  content = yamlencode({
    cloudConfig = {
      global = {
        "auth-url"                      = var.pcd_auth_url
        region                          = var.pcd_region
        "application-credential-id"     = pcd_identity_application_credential.occm.id
        "application-credential-secret" = pcd_identity_application_credential.occm.secret
      }
      loadBalancer = {
        "lb-provider"         = "ovn"            # PCD ships only the OVN Octavia provider
        "lb-method"           = "SOURCE_IP_PORT" # required with ovn
        "subnet-id"           = data.pcd_networking_subnet.bgp.id
        "floating-network-id" = data.pcd_networking_subnet.floating.network_id
        "create-monitor"      = true
      }
    }
  })
}

# The CCM binary reads cloud.conf directly with gcfg (INI), not the chart's
# `cloudConfig` values block above -- that block only reaches the pod as INI
# via the chart's own Secret template (_helpers.tpl), which secret.create:
# false disables. This reproduces that same INI rendering by hand.
locals {
  occm_cloud_conf = join("\n", compact([
    <<-EOT
    [Global]
    application-credential-id = "${pcd_identity_application_credential.occm.id}"
    application-credential-secret = "${pcd_identity_application_credential.occm.secret}"
    auth-url = "${var.pcd_auth_url}"
    region = "${var.pcd_region}"

    [LoadBalancer]
    create-monitor = "true"
    floating-network-id = "${data.pcd_networking_subnet.floating.network_id}"
    lb-method = "SOURCE_IP_PORT"
    lb-provider = "ovn"
    subnet-id = "${data.pcd_networking_subnet.bgp.id}"
    EOT
    ,
    # Read by barbican-kms-plugin (see kms.tf), which shares this file.
    # OCCM ignores sections it doesn't know.
    var.create_kms_key ? "\n[KeyManager]\nkey-id = \"${pcd_keymanager_secret.kms_key[0].id}\"" : "",
  ]))
}

# Equivalent to:
#   kubectl -n kube-system create secret generic cloud-config --from-file=cloud.conf=./cloud.conf
resource "kubernetes_secret_v1" "cloud_config" {
  metadata {
    name      = "cloud-config"
    namespace = "kube-system"
  }

  data = {
    "cloud.conf" = local.occm_cloud_conf
  }

  depends_on = [
    data.talos_cluster_health.this,
    pcd_compute_instance.controlplane
  ]
}

output "application_credential_id" {
  value = pcd_identity_application_credential.occm.id
}
