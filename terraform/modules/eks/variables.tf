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

variable "argocd_provisions_repo" {
  type = string
}

variable "argocd_definition_repo" {
  type = string
}

variable "argocd_chart_version" {
  type    = string
  default = "9.4.2"
}

variable "argocd_domain" {
  type        = string
  description = "Full hostname for ArgoCD, e.g. argocd.devtools-labs.example.com"
}

variable "hosted_zone_name" {
  type        = string
  description = "Route53 hosted zone that owns the argocd_domain, e.g. example.com"
}
