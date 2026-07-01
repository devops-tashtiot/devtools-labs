terraform {
  source = "../../../modules/rds"
}

include "root" {
  path = find_in_parent_folders("root.hcl")
}

dependency "minikube" {
  config_path = "../minikube"

  mock_outputs_allowed_terraform_commands = ["destroy"]
  mock_outputs = {
    vpc_id             = "vpc-mock"
    subnet_ids         = ["subnet-mock-1", "subnet-mock-2"]
    security_group_id  = "sg-mock"
  }
}

inputs = {
  identifier  = "devtools-rds"
  vpc_id      = dependency.minikube.outputs.vpc_id
  subnet_ids  = dependency.minikube.outputs.subnet_ids

  allowed_security_group_ids = [
    dependency.minikube.outputs.security_group_id,
  ]

  db_name         = "bitbucket"
  db_username     = "devtools"
  db_password     = "bitbucket-db-2024"
  postgres_version = "17"
}
