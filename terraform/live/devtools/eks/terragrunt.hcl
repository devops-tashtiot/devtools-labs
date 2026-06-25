terraform {
  source = "../../../modules/eks"
}

include "root" {
  path = find_in_parent_folders("root.hcl")
}

inputs = {
  cluster_name    = "devtools-labs"
  cluster_version = "1.31"

  # NOTE: t3.medium is NOT free-tier. EKS control plane costs ~$0.10/hr.
  # Destroy the cluster when not in use to avoid charges.
  node_instance_type = "t3.medium"
  node_desired_size  = 1
  node_min_size      = 1
  node_max_size      = 2

  argocd_provisions_repo = "https://github.com/devops-tashtiot/devtools-provisions"
  argocd_definition_repo = "https://github.com/devops-tashtiot/devtools-definition"
  argocd_chart_version   = "9.4.2"

  argocd_domain    = "argocd.devtools-labs.example.com"
  hosted_zone_name = "example.com"
}
