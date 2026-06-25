output "cluster_name" {
  value = module.eks.cluster_name
}

output "kubeconfig_command" {
  description = "Configure kubectl to talk to your cluster"
  value       = "aws eks update-kubeconfig --name ${var.cluster_name} --region ${var.aws_region} --profile ${var.aws_profile}"
}

output "argocd_url" {
  description = "Open this in your browser — no load balancer, no domain needed"
  value       = "http://${data.aws_instances.eks_nodes.public_ips[0]}:30080"
}

output "argocd_initial_password_command" {
  description = "Run this to get your ArgoCD admin password"
  value       = "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d && echo"
}
