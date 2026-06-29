variable "aws_region" {
  type = string
}

variable "aws_profile" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "cluster_endpoint" {
  type = string
}

variable "cluster_certificate_authority" {
  type = string
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
