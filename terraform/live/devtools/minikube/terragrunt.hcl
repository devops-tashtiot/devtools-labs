terraform {
  source = "../../../modules/minikube"
}

include "root" {
  path = find_in_parent_folders("root.hcl")
}

inputs = {
  instance_name  = "minikube-devtools"
  instance_type  = "t3.2xlarge" # 8 vCPU / 32 GB — t3.xlarge (4/16) was out of CPU for jira alongside bitbucket/confluence/argocd
  root_volume_size = 50
  data_volume_size = 60

  # Must track instance_type — minikube's docker driver doesn't auto-scale to
  # the host, it's hard-capped at whatever these say. Leaves 1 vCPU / ~4 GB
  # headroom on the host for docker/kubelet/SSM overhead.
  minikube_cpus      = 7
  minikube_memory_mb = 28672

  vpc_id            = "vpc-0c5eaad2eb2976b41"
  subnet_tag_filter = "spokeSubnet"

  key_pair_name = "devtools-eks-nodes"

  argocd_chart_version = "9.4.2"

  argocd_provisions_repo = "https://github.com/devops-tashtiot/devtools-provisions"
  argocd_definition_repo = "https://github.com/devops-tashtiot/devtools-definition"
}
