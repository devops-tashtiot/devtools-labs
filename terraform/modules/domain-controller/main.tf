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

locals {
  base_dn = join(",", [for label in split(".", var.domain_name) : "DC=${label}"])

  ad_bootstrap_user_data = var.promote_domain_controller ? local.ad_bootstrap_script : ""

  ad_bootstrap_script = templatefile("${path.module}/templates/ad-bootstrap.ps1.tftpl", {
    base_dn                      = local.base_dn
    domain_name                  = var.domain_name
    domain_netbios_name          = var.domain_netbios_name
    admin_username_ssm_parameter = var.admin_username_ssm_parameter
    admin_password_ssm_parameter = var.admin_password_ssm_parameter
    ou_name                      = var.ou_name
    ldap_bind_username           = var.ldap_bind_username
    ldap_bind_password           = var.ldap_bind_password
    sample_user_username         = var.sample_user_username
    sample_user_password         = var.sample_user_password
    ad_group_name                = var.ad_group_name
    ad_group_member_username     = var.ad_group_member_username
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

    tags = { Name = "${var.hostname}-root" }
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
