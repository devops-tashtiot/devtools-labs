terraform {
  source = "../../../modules/minikube"
}

include "root" {
  path = find_in_parent_folders("root.hcl")
}

inputs = {
  instance_name  = "minikube-devtools"
  # EMERGENCY ROLLBACK: attempted m5.4xlarge for more headroom, but
  # RunInstances failed with InsufficientInstanceCapacity in il-central-1a
  # (the only AZ available to us — the data EBS volume is AZ-locked there).
  # The prior t3.2xlarge instance was already destroyed by the replace
  # before the new one failed to launch, so the cluster was down. Reverting
  # to the known-good t3.2xlarge to restore service; revisit sizing
  # separately with a different family/generation that has confirmed
  # capacity in il-central-1a.
  instance_type  = "t3.2xlarge"
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

  argocd_provision_repo  = "https://github.com/devops-tashtiot/devtools-provision"
  argocd_definition_repo = "https://github.com/devops-tashtiot/devtools-definition"

  clusters_provision_repo  = "https://github.com/devops-tashtiot/clusters-provision"
  clusters_definition_repo = "https://github.com/devops-tashtiot/clusters-definition"

  # Cost controls: Spot instead of On-Demand (~60-70% cheaper; "stop" on
  # interruption keeps it safe since Bitbucket/Confluence/Jira data already
  # lives on the separate persistent data volume, not the root volume), plus
  # a nightly auto-stop at 21:00 Asia/Jerusalem. No auto-start — start it
  # manually (console/CLI/SSM) when you need it.
  enable_spot         = true
  enable_nightly_stop = true
  stop_schedule_cron  = "cron(0 21 * * ? *)"
  schedule_timezone   = "Asia/Jerusalem"
}
