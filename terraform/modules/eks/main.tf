module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  cluster_endpoint_public_access  = true
  bootstrap_self_managed_addons   = false

  vpc_id     = data.aws_vpc.horizon.id
  subnet_ids = data.aws_subnets.target.ids

  eks_managed_node_groups = {
    default = {
      instance_types         = [var.node_instance_type]
      min_size               = var.node_min_size
      max_size               = var.node_max_size
      desired_size           = var.node_desired_size
    }
  }

  enable_cluster_creator_admin_permissions = true

  tags = {
    Project = var.project_name
  }
}
