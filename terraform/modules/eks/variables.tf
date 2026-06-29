variable "aws_region" {
  type = string
}

variable "aws_profile" {
  type = string
}

variable "project_name" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "cluster_version" {
  type    = string
  default = "1.31"
}

variable "node_instance_type" {
  type    = string
  default = "t3.medium"
}

variable "node_desired_size" {
  type    = number
  default = 1
}

variable "node_min_size" {
  type    = number
  default = 1
}

variable "node_max_size" {
  type    = number
  default = 2
}

variable "node_key_pair_name" {
  description = "Existing EC2 key pair name to enable SSH access to EKS nodes. Leave empty to disable SSH."
  type        = string
  default     = ""
}

variable "vpc_id" {
  description = "Explicit VPC ID to deploy into. Leave empty to auto-discover the first VPC in the account."
  type        = string
  default     = ""
}

variable "subnet_tag_filter" {
  description = "Tag Name filter to find the target subnets (matched via wildcard). EKS uses all matching subnets."
  type        = string
  default     = "spokeSubnet"
}



