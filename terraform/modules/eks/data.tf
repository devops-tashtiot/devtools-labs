data "aws_caller_identity" "current" {}

data "aws_vpcs" "all" {
  dynamic "filter" {
    for_each = var.vpc_id != "" ? [var.vpc_id] : []
    content {
      name   = "vpc-id"
      values = [filter.value]
    }
  }
}

data "aws_vpc" "horizon" {
  id = tolist(data.aws_vpcs.all.ids)[0]
}

# Both spoke subnets (spokeSubnet1/il-central-1a, spokeSubnet2/il-central-1b) —
# unlike modules/minikube (which only ever needs one, since it's a single
# instance), EKS's control plane and managed node group both span every
# subnet returned here.
data "aws_subnets" "target" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.horizon.id]
  }

  filter {
    name   = "tag:Name"
    values = ["*${var.subnet_tag_filter}*"]
  }
}
