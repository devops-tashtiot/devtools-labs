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

# Allows user_data to fetch the Cloudflare tunnel credentials from S3 at boot
resource "aws_iam_role_policy" "s3_tunnel_creds" {
  name = "minikube-s3-tunnel-creds"
  role = aws_iam_role.minikube.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject"]
      Resource = "arn:aws:s3:::${var.tunnel_credentials_s3_bucket}/${var.tunnel_credentials_s3_key}"
    }]
  })
}

resource "aws_iam_instance_profile" "minikube" {
  name_prefix = "minikube-"
  role        = aws_iam_role.minikube.name
}
