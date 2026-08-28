locals {
  oidc_issuer_host = trimprefix(module.eks.cluster_oidc_issuer_url, "https://")
}

# Shared trust-policy shape for every IRSA role below — a role assumable only
# by the specific Kubernetes ServiceAccount named in `sub`, via this cluster's
# own OIDC provider. Hand-rolled (not the terraform-aws-modules/iam
# iam-role-for-service-accounts-eks submodule) so external-secrets' role can
# carry the exact SSM-Parameter-Store policy this platform actually uses,
# rather than that submodule's Secrets-Manager-oriented built-ins.
data "aws_iam_policy_document" "irsa_assume_role" {
  for_each = {
    ebs_csi = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
    efs_csi = "system:serviceaccount:kube-system:efs-csi-controller-sa"
    # Actual namespace/ServiceAccount name deployed by clusters-provision's
    # external-secrets Helm chart (verified live against the real cluster,
    # not assumed) — both happen to be "external-secrets-operator", not the
    # upstream chart's own default "external-secrets"/"external-secrets".
    external_secrets = "system:serviceaccount:external-secrets-operator:external-secrets-operator"
  }

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_host}:sub"
      values   = [each.value]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name_prefix        = "${var.cluster_name}-ebs-csi-"
  assume_role_policy = data.aws_iam_policy_document.irsa_assume_role["ebs_csi"].json
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_iam_role" "efs_csi" {
  name_prefix        = "${var.cluster_name}-efs-csi-"
  assume_role_policy = data.aws_iam_policy_document.irsa_assume_role["efs_csi"].json
}

resource "aws_iam_role_policy_attachment" "efs_csi" {
  role       = aws_iam_role.efs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy"
}

# Replaces the node-wide IMDS role pattern minikube used (every pod on the
# node could read /devtools/* via the instance profile) with a role scoped to
# exactly the external-secrets ServiceAccount — the EKS least-privilege best
# practice. Same SSM policy shape as
# devtools-labs/terraform/modules/minikube/iam.tf's ssm_parameter_store_read.
resource "aws_iam_role" "external_secrets" {
  name_prefix        = "${var.cluster_name}-external-secrets-"
  assume_role_policy = data.aws_iam_policy_document.irsa_assume_role["external_secrets"].json
}

resource "aws_iam_role_policy" "external_secrets_ssm_read" {
  name = "${var.cluster_name}-external-secrets-ssm-read"
  role = aws_iam_role.external_secrets.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParameterHistory"]
      Resource = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/devops/*"
    }]
  })
}
