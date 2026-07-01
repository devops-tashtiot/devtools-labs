# -----------------------------------------------------------------------------
# Windows Server 2022 AMI
# il-central-1 has Windows Server AMIs available from Amazon.
# -----------------------------------------------------------------------------

data "aws_ami" "windows_2022" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["Windows_Server-2022-English-Full-Base-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# -----------------------------------------------------------------------------
# Horizon LZ VPC discovery
# If vpc_id is set, filter to that VPC. Otherwise pick the first VPC found.
# -----------------------------------------------------------------------------

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
    values = ["*${var.private_subnet_tag_filter}*"]
  }
}

data "aws_subnet" "windows" {
  id = tolist(data.aws_subnets.target.ids)[0]
}

