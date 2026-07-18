variable "cloudflare_account_id" {
  description = "Cloudflare account ID that owns the zone"
  type        = string
}

variable "domain_name" {
  description = "Domain name to manage as a Cloudflare zone"
  type        = string
}

variable "dns_records" {
  description = "DNS records to create in the zone, keyed by a unique name"
  type = map(object({
    name    = string
    type    = string
    content = string
    proxied = optional(bool, true)
    ttl     = optional(number, 1)
  }))
  default = {}
}

variable "access_app_domain" {
  description = "Domain (wildcard or exact) the Cloudflare Access application protects"
  type        = string
  default     = ""
}

variable "access_app_name" {
  description = "Display name for the Cloudflare Access application"
  type        = string
  default     = ""
}

variable "access_policy_name" {
  description = "Display name for the Access application's allow policy"
  type        = string
  default     = "Allowed Emails"
}

variable "allowed_emails" {
  description = "Emails allowed to authenticate via Cloudflare Access one-time PIN. Replaces the full list on every apply — Cloudflare's API has no append-only mode, so omitting an existing email here removes its access."
  type        = list(string)
  default     = []
}

variable "tunnel_id" {
  description = "UUID of the existing Cloudflare Tunnel to look up (read-only visibility only — see main.tf for why this module doesn't manage the tunnel or its credentials as a resource). Leave empty to skip the lookup."
  type        = string
  default     = ""
}

variable "origin_cert_hostnames" {
  description = "Hostnames/wildcards covered by the Terraform-managed Origin CA certificate (e.g. [\"example.com\", \"*.example.com\"]). A fresh certificate + private key are generated on first apply — Cloudflare never returns an existing cert's private key, so this can't just import the certificate that was previously created via the dashboard."
  type        = list(string)
  default     = []
}

variable "origin_cert_request_type" {
  description = "Signature type for the Origin CA certificate"
  type        = string
  default     = "origin-rsa"
}

variable "origin_cert_validity_days" {
  description = "Validity period (days) for the Origin CA certificate. Must be one of 7, 30, 90, 365, 730, 1095, 5475."
  type        = number
  default     = 5475
}

variable "origin_cert_crt_ssm_parameter" {
  description = "SSM Parameter Store path (SecureString) to publish the issued certificate to"
  type        = string
  default     = ""
}

variable "origin_cert_key_ssm_parameter" {
  description = "SSM Parameter Store path (SecureString) to publish the certificate's private key to"
  type        = string
  default     = ""
}

variable "aws_region" {
  type    = string
  default = ""
}

variable "aws_profile" {
  type    = string
  default = ""
}

variable "project_name" {
  type    = string
  default = ""
}
