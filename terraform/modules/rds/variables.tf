variable "identifier" {
  description = "RDS instance identifier"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "subnet_ids" {
  description = "Private subnet IDs for the DB subnet group"
  type        = list(string)
}

variable "allowed_security_group_ids" {
  description = "Security group IDs allowed to reach port 5432"
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
  description = "Master DB password"
  type        = string
  sensitive   = true
}

variable "postgres_version" {
  description = "PostgreSQL engine version"
  type        = string
  default     = "15"
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
