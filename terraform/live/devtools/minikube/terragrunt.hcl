terraform {
  source = "../../../modules/minikube"
}

include "root" {
  path = find_in_parent_folders("root.hcl")
}

inputs = {
  instance_name = "minikube-devtools"
  # Verified via live RunInstances tests (both Spot and On-Demand) before
  # changing this: Spot capacity for anything above t3/t3a is currently
  # depleted in both il-central-1a and il-central-1b (the only two AZs this
  # VPC has subnets in) at the 2xlarge tier and up — that's what caused the
  # prior m5.4xlarge emergency rollback. On-Demand capacity for m6i.4xlarge
  # in il-central-1a (the only AZ available to us — the data EBS volume is
  # AZ-locked there) tested successfully, so this instance is On-Demand
  # (see enable_spot below) until Spot capacity frees up at this size.
  instance_type    = "m6i.4xlarge"
  root_volume_size = 50
  data_volume_size = 60

  # Must track instance_type — minikube's docker driver doesn't auto-scale to
  # the host, it's hard-capped at whatever these say. Leaves 1 vCPU / ~4 GB
  # headroom on the host for docker/kubelet/SSM overhead.
  minikube_cpus      = 15
  minikube_memory_mb = 61440

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
  # enable_spot is false here specifically: Spot capacity for m6i.4xlarge is
  # currently depleted in both available AZs (verified above), so this
  # instance runs On-Demand instead until that changes.
  enable_spot         = false
  enable_nightly_stop = true
  stop_schedule_cron  = "cron(0 21 * * ? *)"
  schedule_timezone   = "Asia/Jerusalem"
}
