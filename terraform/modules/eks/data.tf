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

data "aws_vpc" "selected" {
  id = tolist(data.aws_vpcs.all.ids)[0]
}

data "aws_subnets" "target" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.selected.id]
  }

  filter {
    name   = "tag:Name"
    values = ["*${var.subnet_tag_filter}*"]
  }
}

# The Workload-Admin-PS SSO role that gets cluster admin (main.tf's
# access_entries). Matched by name prefix, not a hardcoded ARN: IAM Identity
# Center appends a random suffix that changes whenever the permission set is
# re-provisioned. one() fails the plan loudly if the match is ever ambiguous
# or missing, instead of silently granting admin to the wrong role.
data "aws_iam_roles" "workload_admin" {
  name_regex  = "^AWSReservedSSO_Workload-Admin-PS_[0-9a-f]+$"
  path_prefix = "/aws-reserved/sso.amazonaws.com/"
}
