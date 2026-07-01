# -----------------------------------------------------------------------------
# IAM Role for the Bitbucket AD domain controller instance
# - SSM Session Manager (remote access without public ports or RDP exposure)
# - SSM Parameter Store read (fetches its own admin username/password at boot,
#   instead of baking them into user-data — see templates/ad-bootstrap.ps1.tftpl)
# -----------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

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

resource "aws_iam_role_policy" "ssm_parameter_store_read" {
  name = "domain-controller-ssm-parameter-store-read"
  role = aws_iam_role.windows.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParameterHistory"]
      Resource = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/devtools/domain-controller/*"
    }]
  })
}

resource "aws_iam_instance_profile" "windows" {
  name_prefix = "win-srv-"
  role        = aws_iam_role.windows.name
}
