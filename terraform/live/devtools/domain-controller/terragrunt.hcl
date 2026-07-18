terraform {
  source = "../../../modules/domain-controller"
}

include "root" {
  path = find_in_parent_folders("root.hcl")
}

inputs = {
  hostname         = "WIN-SRV-01"
  instance_type    = "t3.small" # 2GB RAM — minimum for AD DS; not free-tier (~$15/mo), see devtools-labs/CLAUDE.md
  root_volume_size = 30
  instance_enabled = true

  vpc_id                    = "vpc-0c5eaad2eb2976b41"
  private_subnet_tag_filter = "spokeSubnet1"

  key_pair_name = ""

  promote_domain_controller = true
  domain_name               = "devtools.local"
  domain_netbios_name       = "DEVTOOLS"

  # Not a secret — the literal value lives here rather than as a module
  # default. admin_password and ldap_bind_password are deliberately omitted:
  # both are sensitive with no default, so `terragrunt apply` prompts for
  # them interactively every run (export TF_VAR_admin_password /
  # TF_VAR_ldap_bind_password in your shell to avoid retyping them).
  admin_username = "Administrator"
}
