# -----------------------------------------------------------------------------
# Windows Server 2022 EC2 Instance
# Horizon LZ restrictions applied:
#   - All EBS volumes encrypted (SCP denies creation without encryption)
#   - IMDSv2 enforced (http_tokens = required)
#   - SSM Session Manager is the primary access method (no open admin ports)
#   - associate_public_ip_address = true so SSM agent can reach AWS endpoints
#   - No key pair required (optional, only for initial password decryption)
# -----------------------------------------------------------------------------

resource "aws_instance" "windows" {
  count = var.instance_enabled ? 1 : 0

  ami                    = data.aws_ami.windows_2022.id
  instance_type          = var.instance_type
  subnet_id              = data.aws_subnet.windows.id
  vpc_security_group_ids = [aws_security_group.windows.id]
  iam_instance_profile   = aws_iam_instance_profile.windows.name

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
    Role = "windows-server"
  }

  lifecycle {
    ignore_changes = [ami]
  }
}
