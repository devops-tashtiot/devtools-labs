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
  default     = "minikube-devtools"
}

variable "instance_type" {
  description = "EC2 instance type. t3.xlarge (4 vCPU / 16 GB) is the minimum for running Bitbucket, Confluence, Jira and ArgoCD together."
  type        = string
  default     = "t3.xlarge"
}

variable "root_volume_size" {
  description = "Root EBS volume size in GB. Docker images and Minikube state consume significant space."
  type        = number
  default     = 50
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

variable "ami_name_filter" {
  description = "Name filter for the custom AMI built by packer/minikube-ami/ (Docker/kubectl/Helm/minikube pre-installed)."
  type        = string
  default     = "minikube-devtools-base-*"
}

variable "argocd_chart_version" {
  description = "ArgoCD Helm chart version to install inside Minikube."
  type        = string
  default     = "9.4.2"
}

variable "argocd_provisions_repo" {
  description = "GitOps repo holding Helm chart sources (devtools-provisions)."
  type        = string
  default     = "https://github.com/devops-tashtiot/devtools-provisions"
}

variable "argocd_definition_repo" {
  description = "GitOps repo holding env-specific values overrides (devtools-definition)."
  type        = string
  default     = "https://github.com/devops-tashtiot/devtools-definition"
}
