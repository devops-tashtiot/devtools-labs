terraform {
  source = "../../../modules/eks"
}

include "root" {
  path = find_in_parent_folders("root.hcl")
}

inputs = {
  cluster_name    = "devtools-eks"
  cluster_version = "1.36"

  vpc_id            = "vpc-0c5eaad2eb2976b41"
  subnet_tag_filter = "spokeSubnet"

  # Small and cheap — see modules/eks/variables.tf for why this must stay
  # stable/untainted rather than Karpenter-managed.
  system_node_instance_type = "t3.medium"
  system_node_count         = 2

  # Deliberately NOT "main" — see modules/eks/variables.tf's gitops_ref
  # description. Flip to "main" only at real cutover, once the eks-migration
  # branch has been fast-forward-merged across all four GitOps repos.
  gitops_ref = "eks-migration"

  argocd_chart_version = "9.4.2"

  argocd_provision_repo  = "https://github.com/devops-tashtiot/devtools-provision"
  argocd_definition_repo = "https://github.com/devops-tashtiot/devtools-definition"

  clusters_provision_repo  = "https://github.com/devops-tashtiot/clusters-provision"
  clusters_definition_repo = "https://github.com/devops-tashtiot/clusters-definition"
}
