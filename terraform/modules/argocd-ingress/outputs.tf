output "argocd_url" {
  description = "Public URL for ArgoCD"
  value       = "https://${var.argocd_hostname}"
}

output "add_new_service" {
  description = "To expose a new tool: add a Kubernetes Ingress with ingressClassName=nginx and run: cloudflared tunnel route dns devtools-labs <hostname>"
  value       = "kubectl apply -f <ingress.yaml>  &&  cloudflared tunnel route dns devtools-labs <hostname.devopstashtiot.page>"
}
