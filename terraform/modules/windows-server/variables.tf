variable "aws_region" {
  type = string
}

variable "aws_profile" {
  type = string
}

variable "project_name" {
  type = string
}

variable "hostname" {
  description = "Windows hostname (max 15 chars)"
  type        = string
  default     = "WIN-SRV-01"
}

variable "instance_type" {
  description = "EC2 instance type — t3.micro is free-tier eligible for Windows (750 hrs/month); t2.micro is not available in il-central-1"
  type        = string
  default     = "t3.micro"
}

variable "root_volume_size" {
  description = "Root EBS volume size in GB"
  type        = number
  default     = 30
}

variable "instance_enabled" {
  description = "Set to true to deploy the EC2 instance. false = no billable compute resources."
  type        = bool
  default     = false
}

variable "vpc_id" {
  description = "Explicit VPC ID to deploy into. Leave empty to auto-discover the first VPC in the account."
  type        = string
  default     = ""
}

variable "private_subnet_tag_filter" {
  description = "Tag Name filter to find the target subnet (matched via wildcard). Check your VPC console for subnet Name tags."
  type        = string
  default     = "spokeSubnet1"
}

variable "key_pair_name" {
  description = "Existing EC2 key pair name (optional — only needed to decrypt the initial Administrator password from the EC2 console)."
  type        = string
  default     = ""
}
