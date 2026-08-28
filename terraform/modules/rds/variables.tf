variable "identifier" {
  description = "RDS instance identifier"
  type        = string
}

variable "vpc_id" {
  description = "Explicit VPC ID. Leave empty to auto-discover the first VPC in the account."
  type        = string
  default     = ""
}

variable "subnet_tag_filter" {
  description = "Tag Name wildcard filter for the DB subnet group's subnets."
  type        = string
  default     = "spokeSubnet"
}

variable "allowed_cidr_blocks" {
  description = "CIDR blocks allowed to reach port 5432."
  type        = list(string)
}

variable "db_name" {
  description = "Initial database name"
  type        = string
  default     = "bitbucket"
}

variable "db_username" {
  description = "Master DB username"
  type        = string
  default     = "devtools"
}

variable "db_password" {
  description = "Master DB password. No default — Terraform prompts for it interactively on apply if not supplied via TF_VAR_db_password or a tfvars file."
  type        = string
  sensitive   = true
}

variable "admin_username_ssm_parameter" {
  description = "SSM Parameter Store path (SecureString) to publish db_username to. Category: terraform-created — plain value set directly in terraform/live/devtools/rds/terragrunt.hcl, applied automatically."
  type        = string
  default     = "/devops/terraform-created/rds/admin-username"
}

variable "admin_password_ssm_parameter" {
  description = "SSM Parameter Store path (SecureString) to publish db_password to. Category: terraform-created — the SSM object is Terraform-managed, but the value is human-chosen: exported as TF_VAR_db_password before `terragrunt apply` (Terraform prompts interactively if not set)."
  type        = string
  default     = "/devops/terraform-created/rds/admin-password"
}

variable "postgres_version" {
  description = "PostgreSQL engine version"
  type        = string
  default     = "15"
}

variable "instance_class" {
  description = "RDS instance class. Bump this (via terragrunt inputs) if the shared instance gets too small for the growing number of devtool databases."
  type        = string
  default     = "db.t3.micro"
}

variable "allocated_storage" {
  description = "Initial/minimum storage in GB. Bump this (via terragrunt inputs) if the shared instance runs low on space."
  type        = number
  default     = 20
}

variable "max_allocated_storage" {
  description = "Ceiling for RDS storage autoscaling in GB."
  type        = number
  default     = 20
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

variable "enable_nightly_stop" {
  description = "Create an EventBridge Scheduler rule that stops the DB instance daily at stop_schedule_cron. Restarting is manual (console, CLI, or SSM) — there is no matching auto-start schedule."
  type        = bool
  default     = true
}

variable "stop_schedule_cron" {
  description = "EventBridge Scheduler cron expression (in schedule_timezone) for the daily stop."
  type        = string
  default     = "cron(0 21 * * ? *)"
}

variable "schedule_timezone" {
  description = "IANA timezone stop_schedule_cron is evaluated in."
  type        = string
  default     = "Asia/Jerusalem"
}

variable "deletion_protection" {
  description = "AWS enforces this at the API level — DeleteDBInstance is rejected outright, regardless of skipFinalSnapshot/deleteAutomatedBackups on the request and regardless of the caller's IAM permissions, unless deletion protection is explicitly disabled first (ModifyDBInstance, a separate auditable step). This is the real guardrail against an accidental or malicious DeleteDBInstance call."
  type        = bool
  default     = true
}

variable "backup_retention_period" {
  description = "Days of automated backups AWS retains (point-in-time recovery). 0 disables automated backups entirely — that was this instance's prior setting, and combined with skipFinalSnapshot=true on the delete call that destroyed it, left nothing to restore from."
  type        = number
  default     = 7
}
