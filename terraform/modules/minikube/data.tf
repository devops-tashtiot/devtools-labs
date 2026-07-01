# Built by packer/minikube-ami/ — Docker, kubectl, Helm and the minikube binary are
# already installed, so user_data only has to start minikube and bootstrap ArgoCD.
data "aws_ami" "minikube_base" {
  most_recent = true
  owners      = ["self"]

  filter {
    name   = "name"
    values = [var.ami_name_filter]
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

# Looked up independently (rather than via aws_instance.minikube.availability_zone)
# so the persistent data volume doesn't create a dependency cycle with the
# instance, whose user_data needs the volume's ID to mount it.
data "aws_subnet" "selected" {
  id = tolist(data.aws_subnets.target.ids)[0]
}
