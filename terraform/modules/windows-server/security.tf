# -----------------------------------------------------------------------------
# Security Group for the Windows Server
# Admin access is via SSM Session Manager — no inbound ports needed for that.
# RDP and WinRM are open only within the VPC CIDR (for internal management).
# Horizon SCP blocks 0.0.0.0/0 inbound on management ports.
# -----------------------------------------------------------------------------

resource "aws_security_group" "windows" {
  name_prefix = "win-srv-"
  description = "Windows Server - VPC-internal management ports, SSM for admin"
  vpc_id      = data.aws_vpc.horizon.id

  tags = { Name = "win-srv-sg" }

  lifecycle {
    create_before_destroy = true
  }
}

locals {
  vpc_cidr = data.aws_vpc.horizon.cidr_block
}

resource "aws_vpc_security_group_ingress_rule" "rdp" {
  security_group_id = aws_security_group.windows.id
  description       = "RDP from VPC only"
  from_port         = 3389
  to_port           = 3389
  ip_protocol       = "tcp"
  cidr_ipv4         = local.vpc_cidr
}


resource "aws_vpc_security_group_ingress_rule" "winrm_http" {
  security_group_id = aws_security_group.windows.id
  description       = "WinRM HTTP from VPC"
  from_port         = 5985
  to_port           = 5985
  ip_protocol       = "tcp"
  cidr_ipv4         = local.vpc_cidr
}

resource "aws_vpc_security_group_ingress_rule" "winrm_https" {
  security_group_id = aws_security_group.windows.id
  description       = "WinRM HTTPS from VPC"
  from_port         = 5986
  to_port           = 5986
  ip_protocol       = "tcp"
  cidr_ipv4         = local.vpc_cidr
}

resource "aws_vpc_security_group_egress_rule" "all_out" {
  security_group_id = aws_security_group.windows.id
  description       = "Allow all outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}
