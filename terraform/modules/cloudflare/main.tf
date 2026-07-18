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

resource "cloudflare_zero_trust_access_application" "this" {
  account_id = var.cloudflare_account_id
  name       = var.access_app_name
  domain     = var.access_app_domain
  type       = "self_hosted"

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
# API always echoes wildcard entries before non-wildcard ones regardless of
# the order submitted — so `hostnames` must be pre-sorted to match, or every
# `plan` after the first would see a spurious order-only diff and recreate
# the cert (and cascade into replacing tls_cert_request/tls_private_key too).
locals {
  origin_cert_hostnames_sorted = concat(
    [for h in var.origin_cert_hostnames : h if startswith(h, "*.")],
    [for h in var.origin_cert_hostnames : h if !startswith(h, "*.")],
  )
}

resource "cloudflare_origin_ca_certificate" "this" {
  csr                = tls_cert_request.origin_cert.cert_request_pem
  hostnames          = local.origin_cert_hostnames_sorted
  request_type       = var.origin_cert_request_type
  requested_validity = var.origin_cert_validity_days
}

resource "aws_ssm_parameter" "origin_cert_crt" {
  name        = var.origin_cert_crt_ssm_parameter
  description = "Created by GitOps — devtools-labs Terraform (terraform/modules/cloudflare). Do not edit manually; changes will be reverted on the next apply. Cloudflare Origin CA certificate (public cert), consumed by clusters-provision/clusters/ingress-nginx via ExternalSecret."
  type        = "SecureString"
  value       = cloudflare_origin_ca_certificate.this.certificate

  tags = local.ssm_tags
}

resource "aws_ssm_parameter" "origin_cert_key" {
  name        = var.origin_cert_key_ssm_parameter
  description = "Created by GitOps — devtools-labs Terraform (terraform/modules/cloudflare). Do not edit manually; changes will be reverted on the next apply. Cloudflare Origin CA certificate private key, consumed by clusters-provision/clusters/ingress-nginx via ExternalSecret."
  type        = "SecureString"
  value       = tls_private_key.origin_cert.private_key_pem

  tags = local.ssm_tags
}
