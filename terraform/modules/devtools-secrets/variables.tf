variable "admin_password" {
  description = "Shared initial admin password for every devtool on the platform (see devtools-provision/README.md). No default — Terraform prompts for it interactively on apply if not supplied via TF_VAR_admin_password or a tfvars file."
  type        = string
  sensitive   = true
}

variable "admin_password_ssm_parameter" {
  description = "SSM Parameter Store path (SecureString) to publish admin_password to"
  type        = string
  default     = "/devtools/admin/password"
}

variable "rhbk_oidc_client_secret_ssm_parameter" {
  description = "SSM Parameter Store path (SecureString) to publish rhbk_oidc_client_secret to"
  type        = string
  default     = "/devtools/rhbk/oidc-client-secret"
}

variable "cloudflare_origin_ca_root_cert_ssm_parameter" {
  description = "SSM Parameter Store path (SecureString) to publish cloudflare_origin_ca_root_cert to"
  type        = string
  default     = "/devtools/cloudflare/origin-ca-root-cert"
}

variable "cloudflare_origin_ca_root_cert" {
  description = "Cloudflare's public Origin CA root certificate (PEM). Static and publicly-published by Cloudflare — the same value for every Cloudflare customer, not generated per-account (contrast with the cloudflare module's origin_cert_crt/key, which ARE this zone's own Terraform-generated leaf cert). Leave unset (default) to use the copy committed in files/ — see local.cloudflare_origin_ca_root_cert in main.tf (variable defaults can't call file())."
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
