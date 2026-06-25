output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "kubeconfig_command" {
  description = "Run this to configure kubectl for the cluster"
  value       = "aws eks update-kubeconfig --name ${var.cluster_name} --region ${var.aws_region} --profile ${var.aws_profile}"
}

output "argocd_portforward_command" {
  description = "Access ArgoCD UI at http://localhost:8080 (free, no LB needed)"
  value       = "kubectl port-forward svc/argocd-server -n argocd 8080:80"
}

output "argocd_initial_password_command" {
  description = "Get the initial ArgoCD admin password"
  value       = "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d && echo"
}
