terraform {
  source = "../../../modules/argocd"
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

inputs = {
  cluster_name                  = dependency.eks.outputs.cluster_name
  cluster_endpoint              = dependency.eks.outputs.cluster_endpoint
  cluster_certificate_authority = dependency.eks.outputs.cluster_certificate_authority

  argocd_provision_repo  = "https://github.com/devops-tashtiot/devtools-provision"
  argocd_definition_repo = "https://github.com/devops-tashtiot/devtools-definition"
  argocd_chart_version   = "9.4.2"
}
