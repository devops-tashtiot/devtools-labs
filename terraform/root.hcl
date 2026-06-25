locals {
  project_name = "devtools-labs"
  account_id   = "342831714456"
  aws_region   = "il-central-1"
  aws_profile  = "342831714456_Workload-Admin-PS"
  state_bucket = "terraform-state-${local.account_id}"
}

remote_state {
  backend = "s3"
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite"
  }
  config = {
    bucket       = local.state_bucket
    key          = "${local.project_name}/${path_relative_to_include()}/terraform.tfstate"
    region       = local.aws_region
    use_lockfile = true
    encrypt      = true
    profile      = local.aws_profile
  }
}

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite"
  contents  = <<-EOF
    provider "aws" {
      region  = "${local.aws_region}"
      profile = "${local.aws_profile}"
    }
  EOF
}

inputs = {
  aws_region   = local.aws_region
  aws_profile  = local.aws_profile
  project_name = local.project_name
}
