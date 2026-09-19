terraform {
  source = "../../../modules/rds"
}

include "root" {
  path = find_in_parent_folders("root.hcl")
}

inputs = {
  identifier     = "devtools-rds"
  instance_class = "db.t3.small"

  # No dependency on eks: auto-discovers the account's only VPC and
  # filters subnets by the same "spokeSubnet" tag eks/domain-controller
  # use, so this unit can apply in parallel with them instead of waiting.
  vpc_id            = ""
  subnet_tag_filter = "spokeSubnet"

  # CIDR-based ingress instead of referencing eks's security group —
  # same reachability (eks/domain-controller both live in these spoke
  # subnets), but doesn't require eks's SG ID at plan time.
  allowed_cidr_blocks = ["10.3.65.0/24", "10.3.66.0/24"]

  db_name     = "bitbucket"
  db_username = "devtools"
  # db_password intentionally omitted — it's sensitive with no default, so
  # `terragrunt apply` prompts for it interactively instead of a real
  # password living in git. Export TF_VAR_db_password in your shell for the
  # session to avoid retyping it on every apply.
  postgres_version = "17"
}
