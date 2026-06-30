terraform {
  source = "../../../modules/rds"
}

include "root" {
  path = find_in_parent_folders("root.hcl")
}

dependency "eks" {
  config_path = "../eks"

  mock_outputs_allowed_terraform_commands = ["destroy"]
  mock_outputs = {
    vpc_id     = "vpc-mock"
    subnet_ids = ["subnet-mock-1", "subnet-mock-2"]
  }
}

inputs = {
  identifier  = "devtools-rds"
  vpc_id      = dependency.eks.outputs.vpc_id
  subnet_ids  = dependency.eks.outputs.subnet_ids

  allowed_security_group_ids = [
    "sg-0d03a5f939b24b0a5",  # EKS node SG
    "sg-0deaa66f71ef928be",  # EKS cluster SG
  ]

  db_name         = "bitbucket"
  db_username     = "devtools"
  db_password     = "bitbucket-db-2024"
  postgres_version = "15"
}
