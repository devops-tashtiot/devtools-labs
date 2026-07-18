# Trust policy shared by every Pod Identity role below — "pods.eks.amazonaws.com"
# is EKS Pod Identity's own trust principal, simpler than IRSA's OIDC-federated
# AssumeRoleWithWebIdentity condition (no OIDC provider registration needed).
data "aws_iam_policy_document" "pod_identity_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

# EBS CSI driver — lets the driver actually create/attach/detach the EBS
# volumes behind every gp3 PVC (Bitbucket/Confluence/Jira/Artifactory's
# local-home/shared-home, etc.). AWS-managed policy, standard for this addon.
resource "aws_iam_role" "ebs_csi" {
  name               = "${var.cluster_name}-ebs-csi-pod-identity"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_pod_identity_association" "ebs_csi" {
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "ebs-csi-controller-sa"
  role_arn        = aws_iam_role.ebs_csi.arn
}

# External Secrets Operator — identical permission set to
# modules/minikube/iam.tf's aws_iam_role_policy.ssm_parameter_store_read
# (ssm:GetParameter* on /devtools/*), just re-attached to a Pod Identity role
# instead of the EC2 instance role IMDS previously relied on.
resource "aws_iam_role" "eso" {
  name               = "${var.cluster_name}-eso-pod-identity"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}

resource "aws_iam_role_policy" "eso_ssm_parameter_store_read" {
  name = "ssm-parameter-store-read"
  role = aws_iam_role.eso.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParameterHistory"]
      Resource = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/devtools/*"
    }]
  })
}

resource "aws_eks_pod_identity_association" "eso" {
  cluster_name    = module.eks.cluster_name
  namespace       = var.eso_namespace
  service_account = var.eso_service_account_name
  role_arn        = aws_iam_role.eso.arn
}

# Artifactory S3 access — today this rides implicitly on the minikube
# instance's node IMDS role (persistence.awsS3V3.useInstanceCredentials);
# this is the explicit, narrowly-scoped replacement, granting only what
# Artifactory's binarystore actually needs against its one bucket.
resource "aws_iam_role" "artifactory_s3" {
  name               = "${var.cluster_name}-artifactory-s3-pod-identity"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}

resource "aws_iam_role_policy" "artifactory_s3" {
  name = "artifactory-binarystore-s3"
  role = aws_iam_role.artifactory_s3.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = "arn:aws:s3:::${var.artifactory_s3_bucket_name}"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "arn:aws:s3:::${var.artifactory_s3_bucket_name}/*"
      }
    ]
  })
}

resource "aws_eks_pod_identity_association" "artifactory_s3" {
  cluster_name    = module.eks.cluster_name
  namespace       = var.artifactory_namespace
  service_account = var.artifactory_service_account_name
  role_arn        = aws_iam_role.artifactory_s3.arn
}
