output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "kubeconfig_command" {
  description = "Configure kubectl for the cluster"
  value       = "aws eks update-kubeconfig --name ${var.cluster_name} --region ${var.aws_region} --profile ${var.aws_profile}"
}

output "argocd_url" {
  description = "ArgoCD UI — accessible from your laptop"
  value       = "http://${var.argocd_domain}"
}

output "argocd_nlb_hostname" {
  description = "Raw NLB hostname (the CNAME target)"
  value       = data.kubernetes_service.argocd_server.status[0].load_balancer[0].ingress[0].hostname
}

output "argocd_initial_password_command" {
  description = "Get the initial ArgoCD admin password"
  value       = "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d && echo"
}
