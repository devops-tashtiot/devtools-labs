terraform {
  source = "../../../modules/backup"
}

include "root" {
  path = find_in_parent_folders("root.hcl")
}

locals {
  # Plain string, not a `dependency` block on the rds unit — matches this
  # repo's existing pattern of independent, parallel-applicable units (see
  # rds/terragrunt.hcl's own comment on why it avoids depending on minikube).
  # RDS instance ARNs are deterministic from account/region/identifier, so no
  # actual cross-unit read is needed.
  rds_identifier = "devtools-rds"
}

inputs = {
  vault_name = "devtools-backup-vault"

  rds_instance_arn = "arn:aws:rds:il-central-1:342831714456:db:${local.rds_identifier}"

  retention_days = 3
}
