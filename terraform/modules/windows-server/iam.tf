# -----------------------------------------------------------------------------
# IAM Role for the Windows Server instance
# - SSM Session Manager (remote access without public ports or RDP exposure)
# - SSM Parameter Store (read /windows-server/* parameters)
# -----------------------------------------------------------------------------

resource "aws_iam_role" "windows" {
  name_prefix = "win-srv-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.windows.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "windows" {
  name_prefix = "win-srv-"
  role        = aws_iam_role.windows.name
}
