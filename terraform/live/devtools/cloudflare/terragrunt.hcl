terraform {
  source = "../../../modules/cloudflare"
}

include "root" {
  path = find_in_parent_folders("root.hcl")
}

# Separate from root.hcl's generated aws provider (which every other unit
# under terraform/live/devtools needs but this one doesn't use) so this is
# the only unit that pulls in the cloudflare provider. Auth comes from the
# CLOUDFLARE_API_TOKEN env var (a scoped token: Zone Read + DNS Write on
# devopstashtiot.page, plus account-level Access Apps and Policies Write for
# the Access application/email-allowlist below) — never written to a file,
# same pattern as the aws_profile-based auth used locally for the other
# three units.
generate "provider_cloudflare" {
  path      = "provider_cloudflare.tf"
  if_exists = "overwrite"
  contents  = <<-EOF
    provider "cloudflare" {}
  EOF
}

locals {
  tunnel_target = "7de872ce-2826-42fb-9aea-325e10e3e5fc.cfargotunnel.com"
}

inputs = {
  cloudflare_account_id = "8ffd35a4fbfb1b5634a99f2c5e7439a0"
  domain_name           = "devopstashtiot.page"

  # Mirrors what's live in the account today (observed via the Cloudflare
  # API and imported into this unit's state) — every subdomain CNAMEs to
  # the devtools-labs tunnel, proxied, ttl=1 (automatic). Add new entries
  # here going forward instead of using the curl steps in the parent
  # CLAUDE.md.
  dns_records = {
    argocd_root = {
      name    = "argocd.devopstashtiot.page"
      type    = "CNAME"
      content = local.tunnel_target
    }
    argocd_wildcard = {
      name    = "*.argocd.devopstashtiot.page"
      type    = "CNAME"
      content = local.tunnel_target
    }
    artifactory = {
      name    = "artifactory.devopstashtiot.page"
      type    = "CNAME"
      content = local.tunnel_target
    }
    bitbucket = {
      name    = "bitbucket.devopstashtiot.page"
      type    = "CNAME"
      content = local.tunnel_target
    }
    confluence = {
      name    = "confluence.devopstashtiot.page"
      type    = "CNAME"
      content = local.tunnel_target
    }
    devops_api = {
      name    = "devops-api.devopstashtiot.page"
      type    = "CNAME"
      content = local.tunnel_target
    }
    grafana = {
      name    = "grafana.devopstashtiot.page"
      type    = "CNAME"
      content = local.tunnel_target
    }
    jira = {
      name    = "jira.devopstashtiot.page"
      type    = "CNAME"
      content = local.tunnel_target
    }
    minio = {
      name    = "minio.devopstashtiot.page"
      type    = "CNAME"
      content = local.tunnel_target
    }
    rhbk = {
      name    = "rhbk.devopstashtiot.page"
      type    = "CNAME"
      content = local.tunnel_target
    }
    sonarqube_root = {
      name    = "sonarqube.devopstashtiot.page"
      type    = "CNAME"
      content = local.tunnel_target
    }
    sonarqube_wildcard = {
      name    = "*.sonarqube.devopstashtiot.page"
      type    = "CNAME"
      content = local.tunnel_target
    }
    woodpecker = {
      name    = "woodpecker.devopstashtiot.page"
      type    = "CNAME"
      content = local.tunnel_target
    }
    woodpecker_wildcard = {
      name    = "*.woodpecker.devopstashtiot.page"
      type    = "CNAME"
      content = local.tunnel_target
    }
    xray = {
      name    = "xray.devopstashtiot.page"
      type    = "CNAME"
      content = local.tunnel_target
    }
  }

  # Cloudflare Access (Zero Trust) — protects every subdomain behind a
  # one-time-email-code login. Mirrors the existing app/policy (imported
  # into this unit's state), which used to be maintained by hand via the
  # "Adding an email to Access" curl PUT in the parent CLAUDE.md. Add/remove
  # emails here instead — this list fully replaces the policy's allowlist on
  # every apply, so leaving someone out here revokes their access.
  access_app_domain  = "*.devopstashtiot.page"
  access_app_name    = "devopstashtiot.page"
  access_policy_name = "Allowed Emails"

  allowed_emails = [
    "netanelzucaim100@gmail.com",
    "hadaskoren00@gmail.com",
    "yrahaty@gmail.com",
    "gulmanm@post.bgu.ac.il",
    "naama3434@gmail.com",
    "jonatan.netanel@gmail.com",
  ]

  # Cloudflare Access service token for GitHub Actions — lets the
  # GitHub<->Bitbucket repo mirror workflow (external to this cluster, so it
  # can't use the CoreDNS-rewrite bypass in-cluster callers use) reach
  # bitbucket.devopstashtiot.page without a human email-OTP login. See
  # main.tf's github_actions service token + the second Access policy.
  github_actions_service_token_name                         = "github-actions-repo-sync"
  github_actions_service_token_client_id_ssm_parameter       = "/devtools/cloudflare/github-actions-service-token-client-id"
  github_actions_service_token_client_secret_ssm_parameter   = "/devtools/cloudflare/github-actions-service-token-client-secret"

  # Read-only visibility into the tunnel that cloudflared already uses in
  # production — see main.tf for why this module looks it up via a `data`
  # source instead of owning it as a `resource`. Its actual credential
  # remains manual, in SSM: /devtools/cloudflare/tunnel-credentials.
  tunnel_id = "7de872ce-2826-42fb-9aea-325e10e3e5fc"

  # Origin CA certificate — fully Terraform-managed (see main.tf). Replaces
  # the certificate originally created by hand via Cloudflare Dashboard >
  # SSL/TLS > Origin Server (see clusters-provision/ingress-nginx's
  # origin-cert-secret.yaml, which consumes the same two SSM paths below via
  # ExternalSecret and picks up the new cert on its next 1h refresh).
  # *.argocd.devopstashtiot.page added 2026-07-21 — the per-consumer ArgoCD wildcard
  # (app/v1/argocd/CLAUDE.md, _build_argocd()) routes straight to argocd-server in-cluster and
  # needs its own Ingress + real TLS to avoid a plaintext downgrade; *.devopstashtiot.page alone
  # doesn't cover a two-level subdomain like netanel.argocd.devopstashtiot.page.
  # *.woodpecker.devopstashtiot.page and *.sonarqube.devopstashtiot.page added the same day,
  # same reasoning, ahead of equivalent per-instance/per-consumer wildcard routing for those
  # two tools.
  origin_cert_hostnames = [
    "devopstashtiot.page",
    "*.devopstashtiot.page",
    "*.argocd.devopstashtiot.page",
    "*.woodpecker.devopstashtiot.page",
    "*.sonarqube.devopstashtiot.page",
  ]
  origin_cert_crt_ssm_parameter = "/devtools/cloudflare/origin-cert-crt"
  origin_cert_key_ssm_parameter = "/devtools/cloudflare/origin-cert-key"
}
