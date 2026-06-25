# Bootstrap ArgoCD using the official Helm chart.
# ArgoCD then self-manages via the ApplicationSet below,
# pulling its own umbrella chart from devtools-provisions and values from devtools-definition.
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
      global = {
        domain = "localhost"
      }
      configs = {
        params = {
          "server.insecure" = true
        }
        cm = {
          "accounts.admin" = "apiKey, login"
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
        service    = { type = "ClusterIP" }
        extraArgs  = ["--insecure"]
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

  depends_on = [data.aws_eks_cluster.this]
}

# ApplicationSet: ArgoCD scans charts/* in devtools-provisions and deploys each tool.
# For each chart, values are merged from devtools-provisions (base) + devtools-definition (env overrides).
resource "kubernetes_manifest" "devtools_appset" {
  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "ApplicationSet"
    metadata = {
      name      = "devtools"
      namespace = "argocd"
    }
    spec = {
      generators = [
        {
          git = {
            repoURL  = var.argocd_provisions_repo
            revision = "main"
            directories = [
              { path = "charts/*" }
            ]
          }
        }
      ]
      template = {
        metadata = {
          name      = "{{path.basename}}"
          namespace = "argocd"
        }
        spec = {
          project = "default"
          sources = [
            {
              repoURL        = var.argocd_provisions_repo
              targetRevision = "main"
              path           = "{{path}}"
              helm = {
                valueFiles = [
                  "values.yaml",
                  "$definition/devtools/{{path.basename}}/values.yaml",
                ]
              }
            },
            {
              repoURL        = var.argocd_definition_repo
              targetRevision = "main"
              ref            = "definition"
            },
          ]
          destination = {
            server    = "https://kubernetes.default.svc"
            namespace = "{{path.basename}}"
          }
          syncPolicy = {
            automated = {
              prune    = true
              selfHeal = true
            }
            syncOptions = ["CreateNamespace=true"]
          }
        }
      }
    }
  }

  depends_on = [helm_release.argocd]
}
