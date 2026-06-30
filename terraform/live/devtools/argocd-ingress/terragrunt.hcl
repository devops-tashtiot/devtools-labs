terraform {
  source = "../../../modules/argocd-ingress"
}

include "root" {
  path = find_in_parent_folders("root.hcl")
}

dependency "eks" {
  config_path = "../eks"

  mock_outputs_allowed_terraform_commands = ["destroy"]
  mock_outputs = {
    cluster_name                  = "mock"
    cluster_endpoint              = "https://mock.eks.amazonaws.com"
    cluster_certificate_authority = "bW9jaw=="
  }
}

dependency "argocd" {
  config_path = "../argocd"

  mock_outputs_allowed_terraform_commands = ["destroy"]
  mock_outputs = {
    argocd_url = "https://argocd.devopstashtiot.page"
  }
}

inputs = {
  cluster_name                  = dependency.eks.outputs.cluster_name
  cluster_endpoint              = dependency.eks.outputs.cluster_endpoint
  cluster_certificate_authority = dependency.eks.outputs.cluster_certificate_authority

  argocd_hostname = "argocd.devopstashtiot.page"

  # Cloudflare tunnel credentials are read automatically from S3.
  # To rotate: upload a new credentials file to the S3 path and re-apply.
  tunnel_credentials_s3_bucket = "terraform-state-342831714456"
  tunnel_credentials_s3_key    = "cloudflare/devtools-labs-tunnel.json"
}
