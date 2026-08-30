terraform {
  source = "../../../modules/eks"
}

include "root" {
  path = find_in_parent_folders("root.hcl")
}

inputs = {
  cluster_name       = "devtools-eks"
  kubernetes_version = "1.36"
  upgrade_policy     = "STANDARD"

  # Same spokeSubnet1/spokeSubnet2 pair minikube/rds already use — no new
  # NAT/VPC resource; their existing 0.0.0.0/0 route through a pre-existing
  # shared VPC endpoint is reused as-is.
  vpc_id            = ""
  subnet_tag_filter = "spokeSubnet"

  # Several smaller Spot instance types (not one large node) spread across
  # both AZs — see terraform/modules/eks/variables.tf's own comment and the
  # migration plan for the full reasoning.
  node_instance_types = ["m6i.xlarge", "m6i.2xlarge", "m6i.4xlarge"]
  node_min_size       = 2
  node_max_size       = 4
  # Reduced from 3 to 2: one node's worth of capacity moved to the separate
  # devtools-large group below (1x m6i.2xlarge) after this group's smallest
  # allowed type (m6i.xlarge, 3920m allocatable) turned out unable to ever
  # fit confluence's 4-core request. Net node count unchanged (2 + 1 = 3).
  #
  # Raised from 2 to 4 (the configured max): with desired=2, the ASG only
  # ever placed one node per AZ, and jira's local-home EBS PV is node-affinity
  # -pinned to whichever AZ (il-central-1a) it first provisioned in. That
  # single AZ-1a node ended up hosting nearly every AZ-1a-pinned workload
  # (artifactory, harbor, argocd, cloudflared, rhbk, woodpecker, xray, minio,
  # devops-api) and had no CPU headroom left for jira, which sat Pending
  # indefinitely (no cluster-autoscaler runs in this cluster to react to
  # that on its own). Scaling to 4 lets the ASG's AZ-balancing add a second
  # node in il-central-1a.
  node_desired_size = 4

  # See terraform/modules/eks/variables.tf's node_large_instance_types
  # comment for why this second group exists. Left at the module's own
  # defaults (m6i.2xlarge, min/max/desired = 1) — no override needed here.

  argocd_chart_version = "9.4.2"

  argocd_provision_repo  = "https://github.com/devops-tashtiot/devtools-provision"
  argocd_definition_repo = "https://github.com/devops-tashtiot/devtools-definition"

  clusters_provision_repo  = "https://github.com/devops-tashtiot/clusters-provision"
  clusters_definition_repo = "https://github.com/devops-tashtiot/clusters-definition"
}