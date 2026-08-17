# Official Canonical Ubuntu 24.04 amd64 AMI. amd64 (not arm64) is deliberate —
# unlike minikube's Graviton-friendly instance types, this box exists specifically
# to stage container images for devtools whose upstream registries only publish
# amd64/x86_64 builds (verified the hard way: an arm64 scratch box silently pulls
# the wrong architecture from a multi-arch manifest, producing images that can't
# run on the platform's x86_64 minikube instance).
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

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

data "aws_caller_identity" "current" {}
