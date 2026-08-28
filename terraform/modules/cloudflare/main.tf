locals {
  ssm_tags = {
    Repo      = "devtools-labs"
    Module    = "terraform/modules/cloudflare"
    ManagedBy = "GitOps"
  }
}

resource "cloudflare_zone" "this" {
  account = { id = var.cloudflare_account_id }
  name    = var.domain_name
  type    = "full"
}

resource "cloudflare_dns_record" "this" {
  for_each = var.dns_records

  zone_id = cloudflare_zone.this.id
  name    = each.value.name
  type    = each.value.type
  content = each.value.content
  proxied = each.value.proxied
  ttl     = each.value.ttl
}

# Lets a non-browser client (no interactive email-OTP flow possible) reach
# any *.devopstashtiot.page hostname over plain HTTPS by sending
# CF-Access-Client-Id/CF-Access-Client-Secret headers instead — used by
# developers pushing directly into Bitbucket (`git -c http.extraheader=...
# push https://bitbucket.devopstashtiot.page/...`, combined with Bitbucket's
# own Basic Auth), the sole source of truth for `devops-tashtiot` app repos.
# GitHub is a read-only mirror (branch-protected so only the Woodpecker
# mirror-to-github.yml pipeline in each app repo can write to it) kept in
# sync by that pipeline alone — nothing pushes GitHub -> Bitbucket anymore.
# Same pattern the old github_actions service token used, just for a human
# git client instead of a CI runner. Cloudflare only returns client_secret
# once, at creation — published to SSM below, same as every other
# Cloudflare-issued credential on this platform, rather than left only in
# Terraform state.
#
# IMPORTANT — this token's actual reach is domain-wide, not Bitbucket-
# specific: its non_identity policy below sits on the shared Access
# application whose `domain` is the bare wildcard "*.devopstashtiot.page",
# so it bypasses Access's email-OTP wall for every tool on the platform
# (Jira, ArgoCD, Grafana, MinIO, RHBK, ...), not just Bitbucket. Bitbucket
# push is its current consumer, not the limit of what it can reach — its
# display name (see the live/devtools/cloudflare terragrunt.hcl override)
# is deliberately not just "bitbucket-push" for this reason. Anyone adding a
# second consumer of this same token (or scoping a NEW non_identity policy)
# should treat that as expanding access to the whole domain, not to one app.
resource "cloudflare_zero_trust_access_service_token" "bitbucket_push" {
  account_id = var.cloudflare_account_id
  name       = var.bitbucket_push_service_token_name
  duration   = "8760h"
}

resource "aws_ssm_parameter" "bitbucket_push_service_token_client_id" {
  name        = var.bitbucket_push_service_token_client_id_ssm_parameter
  description = "Category: terraform-created. Created by GitOps — devtools-labs Terraform (terraform/modules/cloudflare). Do not edit manually; changes will be reverted on the next apply. Cloudflare Access service token client ID — bypasses Access's email-OTP wall for the WHOLE *.devopstashtiot.page wildcard domain (not just Bitbucket; Bitbucket push is only its current consumer). See main.tf's header comment above cloudflare_zero_trust_access_service_token.bitbucket_push for the verified live scope. Nothing to retrieve manually — created automatically by `terragrunt apply` in terraform/live/devtools/cloudflare."
  type        = "SecureString"
  value       = cloudflare_zero_trust_access_service_token.bitbucket_push.client_id

  tags = local.ssm_tags
}

resource "aws_ssm_parameter" "bitbucket_push_service_token_client_secret" {
  name        = var.bitbucket_push_service_token_client_secret_ssm_parameter
  description = "Category: terraform-created. Created by GitOps — devtools-labs Terraform (terraform/modules/cloudflare). Do not edit manually; changes will be reverted on the next apply. Cloudflare Access service token client secret — bypasses Access's email-OTP wall for the WHOLE *.devopstashtiot.page wildcard domain (not just Bitbucket; Bitbucket push is only its current consumer). See main.tf's header comment above cloudflare_zero_trust_access_service_token.bitbucket_push for the verified live scope. Nothing to retrieve manually — created automatically by `terragrunt apply` in terraform/live/devtools/cloudflare."
  type        = "SecureString"
  value       = cloudflare_zero_trust_access_service_token.bitbucket_push.client_secret

  tags = local.ssm_tags
}

# The account's only other available login method is Cloudflare's own
# built-in default IDP (type "cloudflare", restrict_to_account_members =
# true) — it was never explicitly configured by anyone, Cloudflare just
# falls back to it when no identity provider is set up, and it only lets in
# people who are invited Members of this Cloudflare *account* (dashboard
# access), not the external allowlisted emails below. This resource is what
# actually enables the "enter your email -> receive a one-time code ->
# enter it" flow documented in the parent CLAUDE.md, which was never true
# until now.
resource "cloudflare_zero_trust_access_identity_provider" "onetimepin" {
  account_id = var.cloudflare_account_id
  name       = "One-time PIN"
  type       = "onetimepin"
  config     = {}
}

resource "cloudflare_zero_trust_access_application" "this" {
  account_id = var.cloudflare_account_id
  name       = var.access_app_name
  domain     = var.access_app_domain
  type       = "self_hosted"

  # Restricts login to the email-OTP provider above — without this, Access
  # falls back to offering every enabled IDP on the account, including the
  # account-members-only default that blocks every allowlisted email that
  # isn't also a Cloudflare account Member.
  allowed_idps = [cloudflare_zero_trust_access_identity_provider.onetimepin.id]

  session_duration          = "24h"
  app_launcher_visible      = true
  auto_redirect_to_identity = false
  enable_binding_cookie     = false
  options_preflight_bypass  = false

  # Inline (non-reusable) policy, matching how this app's policy was
  # originally created via the dashboard/curl PUT — not a standalone
  # cloudflare_zero_trust_access_policy, which models Cloudflare's separate
  # *reusable* policy type instead. The provider's schema makes `id` and
  # `include` mutually exclusive (ExactlyOneOf): `id` alone is only for
  # referencing an existing *reusable* policy by UUID; an inline policy like
  # this one must omit `id` entirely — the API assigns and owns its UUID,
  # there's no way to pin it from config. A single-item list like this is
  # matched positionally, so this still updates the same policy in place on
  # every re-apply rather than drifting/recreating it.
  policies = [
    {
      name       = var.access_policy_name
      decision   = "allow"
      precedence = 1
      include = [
        for email in var.allowed_emails : { email = { email = email } }
      ]
    },
    # Second, independent policy — Access grants a request if ANY policy on
    # the app matches, so this doesn't weaken the email-OTP policy above; it
    # just adds a second, non-interactive way in for exactly this one
    # service token. decision = "non_identity" is the policy type meant for
    # service tokens specifically (no identity/email is ever established for
    # these requests, unlike the "allow" policy above).
    {
      name       = "Wildcard Access OTP Bypass"
      decision   = "non_identity"
      precedence = 2
      include = [
        { service_token = { token_id = cloudflare_zero_trust_access_service_token.bitbucket_push.id } }
      ]
    }
  ]
}

# Read-only lookup, not a resource — the classic tunnel_secret was generated
# client-side (by `cloudflared tunnel create`) and never round-trips through
# Cloudflare's API. A `resource` + `terraform import` would leave that
# Required, non-computed attribute unset in state, and the next apply would
# see it changing from null → whatever the config declares — almost
# certainly a destroy+recreate, which would break the live cloudflared
# Deployment (clusters-provision). A `data` source instead exposes
# identity/status for visibility with no lifecycle ownership — the actual
# credential stays exactly where it is today: SSM
# (/devtools/cloudflare/tunnel-credentials).
data "cloudflare_zero_trust_tunnel_cloudflared" "this" {
  count      = var.tunnel_id != "" ? 1 : 0
  account_id = var.cloudflare_account_id
  tunnel_id  = var.tunnel_id
}

# Origin CA certificate — fully Terraform-managed. Unlike the tunnel secret,
# nothing here needs to survive from the previous manually-created cert:
# Cloudflare's edge trusts *any* valid Origin CA cert whose hostnames match
# (it's not pinned to a specific cert instance), so generating a fresh
# key+CSR here and replacing the SSM values is a safe, non-disruptive
# rotation — ingress-nginx's ExternalSecret (clusters-provision/ingress-nginx)
# just picks up the new cert on its next refresh. The private key never
# leaves this state/SSM; only the CSR derived from it goes to Cloudflare.
resource "tls_private_key" "origin_cert" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "origin_cert" {
  private_key_pem = tls_private_key.origin_cert.private_key_pem

  subject {
    common_name = var.domain_name
  }

  dns_names = var.origin_cert_hostnames
}

# cloudflare_origin_ca_certificate's `hostnames` is ForceNew, and Cloudflare's
# API always echoes the hostnames back in plain lexicographic order
# regardless of the order submitted — so `hostnames` must be pre-sorted to
# match, or every `plan` after the first would see a spurious order-only
# diff and recreate the cert (and cascade into replacing
# tls_cert_request/tls_private_key too). A plain `sort()` is sufficient (not
# a wildcards-first-then-alphabetical split, which was tried first and still
# drifted): `*` (0x2A) sorts before every letter in ASCII, so a full
# lexicographic sort naturally puts every "*.foo" entry before any bare
# "foo" entry anyway — exactly matching what Cloudflare returns.
locals {
  origin_cert_hostnames_sorted = sort(var.origin_cert_hostnames)
}

resource "cloudflare_origin_ca_certificate" "this" {
  csr                = tls_cert_request.origin_cert.cert_request_pem
  hostnames          = local.origin_cert_hostnames_sorted
  request_type       = var.origin_cert_request_type
  requested_validity = var.origin_cert_validity_days
}

resource "aws_ssm_parameter" "origin_cert_crt" {
  name        = var.origin_cert_crt_ssm_parameter
  description = "Category: terraform-created. Created by GitOps — devtools-labs Terraform (terraform/modules/cloudflare). Do not edit manually; changes will be reverted on the next apply. Cloudflare Origin CA certificate (public cert), consumed by clusters-provision/clusters/ingress-nginx via ExternalSecret. Terraform-generated CSR submitted to Cloudflare's Origin CA API — nothing to retrieve manually, created automatically by `terragrunt apply` in terraform/live/devtools/cloudflare."
  type        = "SecureString"
  value       = cloudflare_origin_ca_certificate.this.certificate

  tags = local.ssm_tags
}

resource "aws_ssm_parameter" "origin_cert_key" {
  name        = var.origin_cert_key_ssm_parameter
  description = "Category: terraform-created. Created by GitOps — devtools-labs Terraform (terraform/modules/cloudflare). Do not edit manually; changes will be reverted on the next apply. Cloudflare Origin CA certificate private key, consumed by clusters-provision/clusters/ingress-nginx via ExternalSecret. Terraform-generated RSA key, never sent anywhere (only its CSR is) — nothing to retrieve manually, created automatically by `terragrunt apply` in terraform/live/devtools/cloudflare."
  type        = "SecureString"
  value       = tls_private_key.origin_cert.private_key_pem

  tags = local.ssm_tags
}
