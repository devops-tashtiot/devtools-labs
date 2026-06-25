data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.cluster_name}-vpc"
  cidr = "10.0.0.0/16"

  azs            = local.azs
  public_subnets = [for k, _ in local.azs : cidrsubnet("10.0.0.0/16", 8, k)]

  # No NAT Gateway — nodes live in public subnets with direct internet access.
  # NAT Gateway is not free-tier eligible.
  enable_nat_gateway      = false
  map_public_ip_on_launch = true
  enable_dns_hostnames    = true

  public_subnet_tags = {
    "kubernetes.io/role/elb"                    = 1
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  }

  tags = {
    Project = var.project_name
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  cluster_endpoint_public_access = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.public_subnets

  eks_managed_node_groups = {
    default = {
      instance_types = [var.node_instance_type]
      min_size       = var.node_min_size
      max_size       = var.node_max_size
      desired_size   = var.node_desired_size
    }
  }

  enable_cluster_creator_admin_permissions = true

  tags = {
    Project = var.project_name
  }
}

# Data sources consumed by helm/kubernetes providers and argocd.tf.
# Requires EKS to exist — use -target on first apply (see outputs.tf).
data "aws_eks_cluster" "this" {
  name       = module.eks.cluster_name
  depends_on = [module.eks]
}

# Open port 30080 on the worker node so your laptop can reach ArgoCD directly.
# The node is in a public subnet and already has a public IP — no load balancer needed.
resource "aws_security_group_rule" "argocd_nodeport" {
  type              = "ingress"
  from_port         = 30080
  to_port           = 30080
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = module.eks.node_security_group_id
  description       = "ArgoCD UI via NodePort"
}

# Look up the running worker nodes to get their public IPs.
data "aws_instances" "eks_nodes" {
  filter {
    name   = "tag:eks:cluster-name"
    values = [var.cluster_name]
  }
  filter {
    name   = "instance-state-name"
    values = ["running"]
  }
  depends_on = [module.eks]
}
