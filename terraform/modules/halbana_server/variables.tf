variable "aws_region" {
  type = string
}

variable "aws_profile" {
  type = string
}

variable "project_name" {
  type = string
}

variable "instance_name" {
  description = "Name tag for the EC2 instance."
  type        = string
  default     = "halbana-server"
}

variable "instance_type" {
  description = "EC2 instance type. Must be a 'd'-suffixed family (c5d/m5d/m6id/...) to get a built-in NVMe instance store — that's the whole point of this box. c5d.large (2 vCPU/4GB RAM/50GB NVMe) is the validated default; bump to m5d.large or larger if a staging run needs more RAM (Docker + a containerized browser together were tight at 4GB)."
  type        = string
  default     = "c5d.large"
}

variable "root_volume_size" {
  description = "Root EBS volume size in GB. Keep this comfortably above what the OS + whatever tooling you install on it (browser packages, 7zip, awscli, ...) needs — the default Ubuntu AMI's 8GB root disk filled to 87% just from package installs during validation."
  type        = number
  default     = 20
}

variable "swap_size_gb" {
  description = "Size of the swapfile created on the NVMe instance store at boot, as a safety net against OOM kills on smaller instance types."
  type        = number
  default     = 4
}

variable "vpc_id" {
  description = "Explicit VPC ID. Leave empty to auto-discover the first VPC in the account."
  type        = string
  default     = ""
}

variable "subnet_tag_filter" {
  description = "Tag Name wildcard filter for the target subnet."
  type        = string
  default     = "spokeSubnet"
}

variable "key_pair_name" {
  description = "Existing EC2 key pair name (optional — SSM is the primary access method)."
  type        = string
  default     = ""
}

variable "enable_spot" {
  description = "Request the instance as a persistent Spot Instance instead of On-Demand. IMPORTANT: unlike minikube (whose persistent data lives on a separate EBS volume), this box's entire point is its NVMe *instance store* — and instance store is wiped on every stop, including a Spot interruption's 'stop' action. A Spot interruption here means losing everything staged (pulled images, exports) and having to redo that work, not just a brief pause. Validated in practice: this happened twice in one afternoon on il-central-1. Default is true to match this repo's cost-conscious convention, but flip to false for the duration of an active staging run if you'd rather pay ~2-5x more per hour than risk redoing 20-30 minutes of work."
  type        = bool
  default     = true
}
