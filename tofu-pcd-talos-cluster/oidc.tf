# API server JWT authentication (flux-platform-src ADR 30). Uses the structured
# AuthenticationConfiguration (stable since Kubernetes 1.34) through Talos's
# KubeAuthenticationConfig document, one `jwt` entry per var.oidc_issuers item.
# The anonymous block below keeps Talos's default (health endpoints only).
# RBAC for the
# groups is in flux-platform-src (clusters/core-infra/resources/
# rbac.kubernetes-groups.yaml).
#
# Talos passes --authentication-config only when the new-style
# KubeAPIServerConfig document is in use (its UseAuthenticationConfig() returns
# true; the legacy .cluster.apiServer returns false, which is why
# `talosctl get apiserverconfig` showed useAuthenticationConfig: false with the
# old KMS patch). talos.tf therefore always emits that document, and kms.tf
# keeps the KMS socket under /var/log/audit/kube, which kube-apiserver already
# mounts, so no extraVolumes are needed. Rollout steps:
# flux-platform-src docs/runbooks/kubernetes-api-oidc-rollout.md.
locals {
  oidc_controlplane_patches = !var.enable_oidc_auth || length(var.oidc_issuers) == 0 ? [] : [
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "KubeAuthenticationConfig"
      configuration = {
        apiVersion = "apiserver.config.k8s.io/v1"
        kind       = "AuthenticationConfiguration"
        # Must be explicit: this document replaces Talos's default one, and
        # with neither this block nor --anonymous-auth Kubernetes enables
        # anonymous authentication on every path (seen live: 403 instead of
        # 401 on /api/v1/namespaces). Same as Talos's default: health
        # endpoints only.
        anonymous = {
          enabled = true
          conditions = [
            { path = "/livez" },
            { path = "/readyz" },
            { path = "/healthz" },
          ]
        }
        jwt = [for i in var.oidc_issuers : {
          issuer = merge(
            {
              url                 = i.url
              audiences           = i.audiences
              audienceMatchPolicy = "MatchAny"
            },
            i.discovery_url == null ? {} : { discoveryURL = i.discovery_url },
            i.certificate_authority == null ? {} : { certificateAuthority = i.certificate_authority },
          )
          claimValidationRules = i.claim_validation_rules
          claimMappings = {
            username = i.username.claim != null ? {
              claim  = i.username.claim
              prefix = i.username.prefix
              } : {
              expression = i.username.expression
            }
            groups = i.groups.claim != null ? {
              claim  = i.groups.claim
              prefix = i.groups.prefix
              } : {
              expression = i.groups.expression
            }
          }
          userValidationRules = concat(
            [
              {
                expression = "!user.username.startsWith('system:')"
                message    = "username cannot use the reserved system: prefix"
              },
              {
                expression = "user.groups.all(group, !group.startsWith('system:'))"
                message    = "groups cannot use the reserved system: prefix"
              },
            ],
            i.user_validation_rules,
          )
        }]
      }
    }),
  ]
}
