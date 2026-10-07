# Stage 1 — run as a PCD admin.
# Creates a dedicated service user for the OpenStack CCM and grants it
# the member role on the project that holds the Talos nodes.



data "pcd_identity_project" "cluster" {
  name = var.pcd_tenant_name
}

data "pcd_identity_role" "member" {
  name = "member"
}

# Only if your Octavia still enforces legacy RBAC policies
# (check `openstack role list` for load-balancer_member).
data "pcd_identity_role" "lb_member" {
  name = "load-balancer_member"
}

resource "random_password" "occm" {
  length  = 40
  special = false
}

resource "pcd_identity_user" "occm" {
  name               = "talos-occm"
  description        = "Service account for openstack-cloud-controller-manager"
  default_project_id = data.pcd_identity_project.cluster.id
  password           = random_password.occm.result
}

resource "pcd_identity_role_assignment" "occm_member" {
  role_id    = data.pcd_identity_role.member.id
  user_id    = pcd_identity_user.occm.id
  project_id = data.pcd_identity_project.cluster.id
}

# Only if your Octavia still enforces legacy RBAC policies
# (check `openstack role list` for load-balancer_member).
resource "pcd_identity_role_assignment" "occm_lb_member" {
  role_id    = data.pcd_identity_role.lb_member.id
  user_id    = pcd_identity_user.occm.id
  project_id = data.pcd_identity_project.cluster.id
}

# The onepassword_item resource requires the vault's UUID, not its name --
# passing the name directly (var.onepassword_vault) causes the provider to
# show a perpetual diff/replace on every plan.
data "onepassword_vault" "home_lab" {
  name = var.onepassword_vault
}

resource "onepassword_item" "occm" {
  vault    = data.onepassword_vault.home_lab.uuid
  title    = "openstack-cloud-controller-manager-service-account"
  category = "login"

  username = pcd_identity_user.occm.name
  password = random_password.occm.result

  section {
    label = "PCD"
    field {
      label = "project_id"
      type  = "STRING"
      value = data.pcd_identity_project.cluster.id
    }
    field {
      label = "auth_url"
      type  = "URL"
      value = var.pcd_auth_url
    }
    field {
      # Stage 2 authenticates by user_id, not user_name + user_domain_id: the
      # pcd provider's Scope-building always falls back to user_domain_id for
      # the *project* scope's domain when project_domain_id is unset
      # (firstNonEmpty(ProjectDomainID, UserDomainID) in its authOptions()),
      # which Gophercloud then rejects as "ProjectID must be supplied alone in
      # a Scope". A user ID is globally unique, so no user_domain_id is needed
      # to authenticate with it, avoiding the bug entirely.
      label = "user_id"
      type  = "STRING"
      value = pcd_identity_user.occm.id
    }
  }
}

output "occm_user_name" { value = pcd_identity_user.occm.name }
output "occm_project_id" { value = data.pcd_identity_project.cluster.id }
output "occm_password" {
  value     = random_password.occm.result
  sensitive = true
}
