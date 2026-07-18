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
