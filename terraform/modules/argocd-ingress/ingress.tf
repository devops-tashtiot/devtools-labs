# Read tunnel credentials from S3 — uploaded once, reused on every apply
data "aws_s3_object" "tunnel_creds" {
  bucket = var.tunnel_credentials_s3_bucket
  key    = var.tunnel_credentials_s3_key
}

locals {
  tunnel_creds = jsondecode(data.aws_s3_object.tunnel_creds.body)
  tunnel_id    = local.tunnel_creds["TunnelID"]
}

# nginx-ingress — ClusterIP only, no AWS load balancer needed.
# cloudflared handles inbound traffic and routes to this service.
resource "helm_release" "nginx_ingress" {
  name             = "nginx-ingress"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  version          = var.nginx_ingress_chart_version
  namespace        = "kube-system"
  create_namespace = false
  wait             = true
  timeout          = 300

  values = [
    yamlencode({
      controller = {
        service = {
          type = "ClusterIP"
        }
        resources = {
          requests = { cpu = "50m", memory = "128Mi" }
          limits   = { cpu = "200m", memory = "256Mi" }
        }
      }
    })
  ]
}

# Cloudflare Tunnel credentials — the JSON file from cloudflared tunnel create
resource "kubernetes_secret" "cloudflared_credentials" {
  metadata {
    name      = "cloudflared-credentials"
    namespace = "kube-system"
  }
  data = {
    "credentials.json" = data.aws_s3_object.tunnel_creds.body
  }
}

# Cloudflare Tunnel config — routes all inbound traffic to nginx-ingress.
# nginx-ingress uses the Host header to route each hostname to the right service.
# To add a new tool: add a Kubernetes Ingress with ingressClassName: nginx.
resource "kubernetes_config_map" "cloudflared_config" {
  metadata {
    name      = "cloudflared-config"
    namespace = "kube-system"
  }
  data = {
    "config.yaml" = yamlencode({
      tunnel             = local.tunnel_id
      "credentials-file" = "/etc/cloudflared/creds/credentials.json"
      ingress = [
        {
          service = "http://nginx-ingress-ingress-nginx-controller.kube-system.svc.cluster.local:80"
        }
      ]
    })
  }
}

# cloudflared — 2 replicas for resilience, connects to Cloudflare edge via outbound HTTPS
resource "kubernetes_deployment" "cloudflared" {
  metadata {
    name      = "cloudflared"
    namespace = "kube-system"
    labels    = { app = "cloudflared" }
  }

  spec {
    replicas = 2

    selector {
      match_labels = { app = "cloudflared" }
    }

    template {
      metadata {
        labels = { app = "cloudflared" }
      }

      spec {
        container {
          name  = "cloudflared"
          image = "cloudflare/cloudflared:2024.12.0"
          args  = ["tunnel", "--no-autoupdate", "--config", "/etc/cloudflared/config/config.yaml", "run"]

          resources {
            requests = {
              cpu    = "10m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "100m"
              memory = "128Mi"
            }
          }

          volume_mount {
            name       = "credentials"
            mount_path = "/etc/cloudflared/creds"
            read_only  = true
          }

          volume_mount {
            name       = "config"
            mount_path = "/etc/cloudflared/config"
            read_only  = true
          }
        }

        volume {
          name = "credentials"
          secret {
            secret_name = kubernetes_secret.cloudflared_credentials.metadata[0].name
          }
        }

        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map.cloudflared_config.metadata[0].name
          }
        }
      }
    }
  }

  depends_on = [helm_release.nginx_ingress]
}

# ArgoCD Ingress — nginx routes argocd.devopstashtiot.page → argocd-server
resource "kubernetes_ingress_v1" "argocd" {
  metadata {
    name      = "argocd"
    namespace = "argocd"
    annotations = {
      # Cloudflare terminates TLS; inside the cluster we use plain HTTP
      "nginx.ingress.kubernetes.io/ssl-redirect" = "false"
    }
  }

  spec {
    ingress_class_name = "nginx"
    rule {
      host = var.argocd_hostname
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = "argocd-server"
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }

  depends_on = [helm_release.nginx_ingress]
}
