variable "aws_region" {
  type = string
}

variable "aws_profile" {
  type = string
}

variable "project_name" {
  type = string
}

variable "cluster_name" {
  description = "EKS cluster name."
  type        = string
  default     = "devtools-eks"
}

variable "kubernetes_version" {
  type    = string
  default = "1.36"
}

variable "upgrade_policy" {
  description = "Cluster upgrade policy support_type. STANDARD (default here): once this version reaches end of standard support, EKS auto-upgrades the cluster to the next version instead of silently moving it into paid Extended Support. EXTENDED costs extra per cluster-hour and is what this cluster drifted into by not setting this explicitly."
  type        = string
  default     = "STANDARD"
}

variable "node_group_kubernetes_version" {
  description = "Kubernetes version for the managed node group's AMI/kubelet. Defaults to var.kubernetes_version (control plane and nodes move together). Override with an older version during a staged control-plane-only upgrade — EKS's UpdateClusterVersion API only allows the control plane to move one minor version at a time, so bumping var.kubernetes_version through several intermediate versions requires pinning this to hold the node group (and its pod-disrupting rolling replacement) back until the control plane reaches its final target."
  type        = string
  default     = null
}

variable "vpc_id" {
  description = "Explicit VPC ID. Leave empty to auto-discover the first VPC in the account — matches minikube/rds's own convention."
  type        = string
  default     = ""
}

variable "subnet_tag_filter" {
  description = "Tag Name wildcard filter for the target subnets — same spokeSubnet1/spokeSubnet2 pair minikube/rds already use. No new NAT Gateway or VPC change: these subnets' existing 0.0.0.0/0 route (through a pre-existing shared VPC endpoint) is reused as-is."
  type        = string
  default     = "spokeSubnet"
}

variable "node_instance_types" {
  description = "Instance types for the managed node group. Several smaller types (not one large node) so a single interruption doesn't take the whole platform down at once, and so the node group actually spans both AZs."
  type        = list(string)
  default     = ["m6i.xlarge", "m6i.2xlarge", "m6i.4xlarge"]
}

variable "node_capacity_type" {
  description = "SPOT or ON_DEMAND. Defaults to ON_DEMAND: the first real apply of this module hit repeated 'UnfulfillableCapacity' Spot launch failures for all three node_instance_types across both AZs (confirmed via the ASG's own scaling-activity log, retrying every ~2 minutes with zero instances ever launched) — the same Spot depletion minikube's own terragrunt.hcl already documented and worked around by running On-Demand. capacity_type is ForceNew on aws_eks_node_group, so revisiting this later means a full node group replacement, same as this one was."
  type        = string
  default     = "ON_DEMAND"
}

variable "node_min_size" {
  type    = number
  default = 2
}

variable "node_max_size" {
  type    = number
  default = 4
}

variable "node_desired_size" {
  type    = number
  default = 3
}

variable "node_large_instance_types" {
  description = "Instance types for the second, small managed node group — carved out because some devtools (e.g. confluence, cpu request 4 full cores) can never fit on the primary group's smallest allowed type (m6i.xlarge's 3920m allocatable is always under a 4-core request, no matter how empty the node is). Kept as its own group rather than dropping m6i.xlarge from node_instance_types so the primary group's 3 nodes don't all have to move to a pricier type."
  type        = list(string)
  default     = ["m6i.2xlarge"]
}

variable "node_large_min_size" {
  type    = number
  default = 1
}

variable "node_large_max_size" {
  type    = number
  default = 1
}

variable "node_large_desired_size" {
  type    = number
  default = 1
}

variable "endpoint_public_access" {
  description = "Whether the EKS API server endpoint is reachable from outside the VPC. Needed here because this repo's Terraform (and this session's own kubectl access) runs from outside the VPC, unlike minikube's bootstrap, which ran user_data ON the instance itself. Still gated by IAM — a public endpoint doesn't grant access to anyone without a valid AWS credential AND an EKS access entry."
  type        = bool
  default     = true
}

variable "argocd_chart_version" {
  type    = string
  default = "9.4.2"
}

variable "argocd_provision_repo" {
  type    = string
  default = "https://github.com/devops-tashtiot/devtools-provision"
}

variable "argocd_definition_repo" {
  type    = string
  default = "https://github.com/devops-tashtiot/devtools-definition"
}

variable "clusters_provision_repo" {
  type    = string
  default = "https://github.com/devops-tashtiot/clusters-provision"
}

variable "clusters_definition_repo" {
  type    = string
  default = "https://github.com/devops-tashtiot/clusters-definition"
}

variable "coredns_rewrite_hosts" {
  description = "Hostnames rewritten straight to ingress-nginx-controller's ClusterIP for in-cluster callers, via the coredns-custom ConfigMap (EKS's supported CoreDNS extension point). Same list minikube's user_data currently hardcodes — kept as a variable here so it's a one-line change instead of an embedded script edit."
  type        = list(string)
  default = [
    "bitbucket.devopstashtiot.page",
    "confluence.devopstashtiot.page",
    "jira.devopstashtiot.page",
    "sonarqube.devopstashtiot.page",
    "artifactory.devopstashtiot.page",
    "harbor.devopstashtiot.page",
    "rhbk.devopstashtiot.page",
    "woodpecker.devopstashtiot.page",
  ]
}
