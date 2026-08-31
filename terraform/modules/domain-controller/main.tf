# -----------------------------------------------------------------------------
# Windows Server 2022 EC2 Instance — Active Directory domain controller for
# Bitbucket LDAP integration testing (bootstraps a forest, an OU, a bind
# account, a sample user, and a group; see templates/ad-bootstrap.ps1.tftpl).
# Horizon LZ restrictions applied:
#   - All EBS volumes encrypted (SCP denies creation without encryption)
#   - IMDSv2 enforced (http_tokens = required)
#   - SSM Session Manager is the primary access method (no open admin ports)
#   - No key pair required (optional, only for initial password decryption)
# -----------------------------------------------------------------------------

# Sources the DSRM/local-Administrator and LDAP-bind passwords from the same
# shared prerequisite secret rds/devtools-secrets already use, instead of
# separate interactive TF_VAR_* prompts — a deliberate reversal of this
# module's earlier "keep these separate" stance (that stance was about not
# letting a future rotation of a SHARED secret silently touch the DSRM/local
# Administrator credential mid-AD-forest-lifecycle; reading the same value at
# apply time doesn't carry that risk the way consolidating the SSM path
# itself would have).
data "aws_ssm_parameter" "generic_password" {
  name            = var.generic_password_ssm_parameter
  with_decryption = true
}

locals {
  base_dn = join(",", [for label in split(".", var.domain_name) : "DC=${label}"])

  ssm_tags = {
    Repo      = "devtools-labs"
    Module    = "terraform/modules/domain-controller"
    ManagedBy = "GitOps"
  }

  ad_bootstrap_user_data = var.promote_domain_controller ? local.ad_bootstrap_script : ""

  ad_bootstrap_script = templatefile("${path.module}/templates/ad-bootstrap.ps1.tftpl", {
    base_dn                          = local.base_dn
    domain_name                      = var.domain_name
    domain_netbios_name              = var.domain_netbios_name
    admin_username_ssm_parameter     = var.admin_username_ssm_parameter
    admin_password_ssm_parameter     = var.admin_password_ssm_parameter
    ou_name                          = var.ou_name
    ldap_bind_username_ssm_parameter = var.ldap_bind_username_ssm_parameter
    sample_user_username             = var.sample_user_username
    sample_user_password             = var.sample_user_password
    ad_group_name                    = var.ad_group_name
    ad_group_member_username         = var.ad_group_member_username
  })
}

resource "aws_instance" "windows" {
  count = var.instance_enabled ? 1 : 0

  ami                    = data.aws_ami.windows_2022.id
  instance_type          = var.instance_type
  subnet_id              = data.aws_subnet.windows.id
  vpc_security_group_ids = [aws_security_group.windows.id]
  iam_instance_profile   = aws_iam_instance_profile.windows.name

  user_data                   = local.ad_bootstrap_user_data != "" ? base64encode(local.ad_bootstrap_user_data) : null
  user_data_replace_on_change = false

  associate_public_ip_address = false
  key_name                    = var.key_pair_name != "" ? var.key_pair_name : null

  # Root volume — MUST be encrypted or Horizon SCP will deny creation
  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size
    delete_on_termination = true
    encrypted             = true

    # BackupManaged=true is the tag terraform/modules/backup's
    # aws_backup_selection already matches on (same tag the EFS
    # shared-home filesystem uses) — this AD forest is the source of
    # truth for every SSO user/group (see docs/overview.md), so its root
    # volume gets the same daily-backup + cross-region-copy coverage as
    # RDS and EFS if the instance is ever destroyed.
    tags = { Name = "${var.hostname}-root", BackupManaged = "true" }
  }

  # IMDSv2 — enforced by Horizon SCP
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  tags = {
    Name = var.hostname
    Role = "domain-controller"
  }

  lifecycle {
    ignore_changes = [ami]
  }
}

# -----------------------------------------------------------------------------
# LDAP connection URL, published to SSM instead of a private Route53 zone —
# Horizon LZ's org-wide SCP has an explicit deny on route53:CreateHostedZone,
# so a private hosted zone isn't an option in this account. Terraform rewrites
# this parameter with the instance's current private_ip on every apply, so
# consumers (clusters-provision/clusters/rhbk's ExternalSecret, see
# clusters-definition/clusters/rhbk/values.yaml's ldap.connectionUrlSsmParameter)
# read the current value from SSM instead of a value baked into git.
# -----------------------------------------------------------------------------

resource "aws_ssm_parameter" "ldap_connection_url" {
  count       = var.instance_enabled ? 1 : 0
  name        = "/devops/terraform-created/domain-controller/ldap-connection-url"
  description = "Category: terraform-created. Created by GitOps — devtools-labs Terraform (terraform/modules/domain-controller). Do not edit manually; changes will be reverted on the next apply. LDAP connection URL for the domain-controller EC2 instance, consumed by clusters-provision/clusters/rhbk via ExternalSecret (see clusters-definition/clusters/rhbk/values.yaml's ldap.connectionUrlSsmParameter). Computed automatically from the instance's current private IP on every apply — nothing to retrieve manually."
  type        = "SecureString"
  value       = "ldap://${aws_instance.windows[0].private_ip}:389"
  tags        = local.ssm_tags
}

# -----------------------------------------------------------------------------
# Admin/DSRM and LDAP-bind credentials, published to SSM instead of the
# manual `aws ssm put-parameter` prerequisite steps this module used to
# require before a fresh apply — ad-bootstrap.ps1.tftpl fetches these same
# paths at boot (see admin_username_ssm_parameter etc. above), so Terraform
# now owns both ends: it writes the values here, and the instance reads them
# back at first boot. ldap_bind_username intentionally reuses
# ad_group_member_username instead of a separate variable — ad-bootstrap
# creates the bind account using the SSM-sourced username but adds
# ad_group_member_username (a plain Terraform var, not SSM-sourced) to the
# AD group directly, so the two must always be the same literal value or the
# account actually created won't be the one added to the group.
# -----------------------------------------------------------------------------

resource "aws_ssm_parameter" "admin_username" {
  count       = var.instance_enabled ? 1 : 0
  name        = var.admin_username_ssm_parameter
  description = "Category: terraform-created. Created by GitOps — devtools-labs Terraform (terraform/modules/domain-controller). Do not edit manually; changes will be reverted on the next apply. Local Administrator/DSRM username, fetched at boot by ad-bootstrap.ps1.tftpl. To change: edit admin_username in terraform/live/devtools/domain-controller/terragrunt.hcl and re-apply."
  type        = "SecureString"
  value       = var.admin_username
  tags        = local.ssm_tags
}

resource "aws_ssm_parameter" "admin_password" {
  count       = var.instance_enabled ? 1 : 0
  name        = var.admin_password_ssm_parameter
  description = "Category: terraform-created. Created by GitOps — devtools-labs Terraform (terraform/modules/domain-controller). Do not edit manually; changes will be reverted on the next apply. Local Administrator/DSRM password, fetched at boot by ad-bootstrap.ps1.tftpl. Value comes from the shared prerequisite secret at var.generic_password_ssm_parameter (default /devops/prerequisite/generic-password) — set that once before the first apply; no TF_VAR needed."
  type        = "SecureString"
  value       = data.aws_ssm_parameter.generic_password.value
  tags        = local.ssm_tags
}

resource "aws_ssm_parameter" "ldap_bind_username" {
  count       = var.instance_enabled ? 1 : 0
  name        = var.ldap_bind_username_ssm_parameter
  description = "Category: terraform-created. Created by GitOps — devtools-labs Terraform (terraform/modules/domain-controller). Do not edit manually; changes will be reverted on the next apply. LDAP bind service account username, fetched at boot by ad-bootstrap.ps1.tftpl and consumed by clusters-definition/clusters/rhbk/values.yaml (ldap.usernameSsmParameter). Value comes from ad_group_member_username in terraform/live/devtools/domain-controller/terragrunt.hcl — no separate retrieval step."
  type        = "SecureString"
  value       = var.ad_group_member_username
  tags        = local.ssm_tags
}

# No separate ldap_bind_password SSM parameter — it would just hold the same
# value as admin_password (both source from generic_password now), so RHBK
# reads admin_password_ssm_parameter directly (see
# clusters-definition/clusters/rhbk/values.yaml's ldap.passwordSsmParameter)
# instead of a redundant second copy.
