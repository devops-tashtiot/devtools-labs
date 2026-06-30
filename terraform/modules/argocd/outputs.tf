output "argocd_url" {
  description = "ArgoCD will be accessible at this URL once argocd-ingress is applied"
  value       = "https://argocd.devopstashtiot.page"
}

output "argocd_initial_password_command" {
  description = "Run this to get your ArgoCD admin password"
  value       = "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d && echo"
}
