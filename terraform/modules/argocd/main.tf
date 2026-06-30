resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_chart_version
  namespace        = "argocd"
  create_namespace = true
  wait             = true
  timeout          = 600

  values = [
    yamlencode({
      configs = {
        params = {
          "server.insecure" = true
        }
        cm = {
          "accounts.admin" = "apiKey, login"
        }
        secret = {
          argocdServerAdminPassword      = "$2a$10$OlAKK08KRfEsdW5lAbvBIuehF6oXILP1C0YKYup7OoXCOwj0/Wi5C"
          argocdServerAdminPasswordMtime = "2024-01-01T00:00:00Z"
        }
        repositories = {
          devtools-provisions = {
            url  = var.argocd_provisions_repo
            type = "git"
            name = "devtools-provisions"
          }
          devtools-definition = {
            url  = var.argocd_definition_repo
            type = "git"
            name = "devtools-definition"
          }
        }
      }
      server = {
        service = {
          type = "ClusterIP"
        }
        extraArgs = ["--insecure"]
        resources = {
          requests = { cpu = "50m", memory = "128Mi" }
          limits   = { cpu = "200m", memory = "256Mi" }
        }
      }
      controller = {
        replicas  = 1
        resources = {
          requests = { cpu = "100m", memory = "256Mi" }
          limits   = { cpu = "300m", memory = "512Mi" }
        }
      }
      repoServer = {
        replicas  = 1
        resources = {
          requests = { cpu = "50m", memory = "128Mi" }
          limits   = { cpu = "200m", memory = "256Mi" }
        }
      }
      applicationSet = {
        resources = {
          requests = { cpu = "25m", memory = "64Mi" }
          limits   = { cpu = "100m", memory = "128Mi" }
        }
      }
      redis = {
        enabled   = true
        resources = {
          requests = { cpu = "10m", memory = "64Mi" }
          limits   = { cpu = "100m", memory = "128Mi" }
        }
      }
      "redis-ha"    = { enabled = false }
      dex           = { enabled = false }
      notifications = { enabled = false }
    })
  ]
}


resource "kubectl_manifest" "devtools_app" {
  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "devtools-applicationset"
      namespace = "argocd"
    }
    spec = {
      project = "default"
      source = {
        repoURL        = var.argocd_definition_repo
        targetRevision = "main"
        path           = "."
        directory = {
          include = "applicationset.yaml"
        }
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "argocd"
      }
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
      }
    }
  })

  depends_on = [helm_release.argocd]
}
