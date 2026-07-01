resource "aws_iam_role" "minikube" {
  name_prefix = "minikube-"

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
  role       = aws_iam_role.minikube.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_caller_identity" "current" {}

# Lets External Secrets Operator (running in-cluster on this instance) read
# devtool secrets from SSM Parameter Store via the instance's IAM role over
# IMDS — no static AWS credentials in the cluster.
resource "aws_iam_role_policy" "ssm_parameter_store_read" {
  name = "minikube-ssm-parameter-store-read"
  role = aws_iam_role.minikube.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParameterHistory"]
      Resource = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/devtools/*"
    }]
  })
}

resource "aws_iam_instance_profile" "minikube" {
  name_prefix = "minikube-"
  role        = aws_iam_role.minikube.name
}
