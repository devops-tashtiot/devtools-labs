terraform {
  source = "../../../modules/devtools-secrets"
}

include "root" {
  path = find_in_parent_folders("root.hcl")
}

# admin_password is deliberately left unset here — it's sensitive with no
# default, so `terragrunt apply` prompts for it interactively every time
# it's run (same behavior as rds's db_password). To avoid re-typing it on
# every apply, export TF_VAR_admin_password in your shell for the session
# instead — never commit a real value here.
#
# rhbk_oidc_client_secret has no variable at all — it's a random_password
# Terraform generates itself (see main.tf); there's nothing for a human to
# supply, unlike admin_password which is a real login credential.
inputs = {}
