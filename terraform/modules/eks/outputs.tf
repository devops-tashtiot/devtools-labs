output "cluster_name" {
  value       = module.eks.cluster_name
  description = "EKS cluster name — use with: aws eks update-kubeconfig --name <this>"
}

output "cluster_endpoint" {
  value       = module.eks.cluster_endpoint
  description = "EKS API server endpoint."
}

output "vpc_id" {
  value       = data.aws_vpc.horizon.id
  description = "VPC the cluster runs in — same VPC as modules/minikube/modules/rds."
}

output "subnet_ids" {
  value       = data.aws_subnets.target.ids
  description = "Subnets matched by subnet_tag_filter (both spoke subnets, both AZs)."
}

output "karpenter_node_iam_role_name" {
  value       = module.karpenter.node_iam_role_name
  description = "Set as the `role:` field on the EC2NodeClass manifest once it lands in clusters-provision/clusters/karpenter (GitOps, not Terraform)."
}

output "karpenter_interruption_queue_name" {
  value       = module.karpenter.queue_name
  description = "SQS queue for Spot interruption/rebalance notices (enable_spot_termination defaults to true in module.karpenter) — set as settings.interruptionQueue in clusters-definition/clusters/karpenter/values.yaml so Karpenter drains nodes gracefully ahead of an actual Spot reclaim, instead of an abrupt kill."
}

output "karpenter_pod_identity_association_arn" {
  value       = module.karpenter.iam_role_arn
  description = "Karpenter controller's own IAM role — for reference; the Pod Identity association itself (namespace=kube-system, service_account=karpenter) is already wired by module.karpenter, nothing to copy into GitOps for this one."
}

output "eso_pod_identity_role_arn" {
  value       = aws_iam_role.eso.arn
  description = "No IAM role-arn annotation needed anywhere with Pod Identity (unlike IRSA) — the aws_eks_pod_identity_association resource, matched on namespace+ServiceAccount name alone, is the entire wiring. The ServiceAccount NAME itself still has to be pinned to eso_service_account_name via clusters-definition's values.yaml (a plain rename, not an IAM annotation) so that name-match is exact. Output kept for visibility/auditing only."
}

output "artifactory_s3_pod_identity_role_arn" {
  value       = aws_iam_role.artifactory_s3.arn
  description = "Same as eso_pod_identity_role_arn — no IAM annotation needed, just the ServiceAccount name pinned to artifactory_service_account_name via devtools-provision's values.yaml. Output kept for visibility/auditing only."
}
