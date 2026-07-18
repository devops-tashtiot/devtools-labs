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
  description = "SSM Parameter Store path (SecureString) to publish db_username to"
  type        = string
  default     = "/devtools/rds/admin-username"
}

variable "admin_password_ssm_parameter" {
  description = "SSM Parameter Store path (SecureString) to publish db_password to"
  type        = string
  default     = "/devtools/rds/admin-password"
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
