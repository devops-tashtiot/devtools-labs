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

variable "argocd_hostname" {
  description = "Public hostname for ArgoCD (e.g. argocd.devopstashtiot.page)"
  type        = string
  default     = "argocd.devopstashtiot.page"
}

variable "tunnel_credentials_s3_bucket" {
  description = "S3 bucket where the Cloudflare tunnel credentials JSON is stored"
  type        = string
  default     = "terraform-state-342831714456"
}

variable "tunnel_credentials_s3_key" {
  description = "S3 key for the Cloudflare tunnel credentials JSON"
  type        = string
  default     = "cloudflare/devtools-labs-tunnel.json"
}

variable "nginx_ingress_chart_version" {
  type    = string
  default = "4.11.3"
}
