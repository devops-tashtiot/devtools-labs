# Bootstrap ArgoCD using the official Helm chart with a LoadBalancer service so Terraform
# can read the NLB hostname and create the Route53 CNAME in the same apply.
# ArgoCD then self-manages via the ApplicationSet below, keeping its config in sync with
# devtools-provisions (chart) + devtools-definition (env values).
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
        domain = var.argocd_domain
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
        service = {
          type = "LoadBalancer"
          annotations = {
            "service.beta.kubernetes.io/aws-load-balancer-type"   = "nlb"
            "service.beta.kubernetes.io/aws-load-balancer-scheme" = "internet-facing"
          }
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

  depends_on = [data.aws_eks_cluster.this]
}

# Read the NLB hostname that the AWS cloud-controller assigns to the argocd-server Service.
# If this data source fails because AWS hasn't finished provisioning the NLB yet,
# re-run: terragrunt apply
data "kubernetes_service" "argocd_server" {
  metadata {
    name      = "argocd-server"
    namespace = "argocd"
  }
  depends_on = [helm_release.argocd]
}

# Route53 CNAME: argocd_domain → NLB hostname
data "aws_route53_zone" "this" {
  name         = var.hosted_zone_name
  private_zone = false
}

resource "aws_route53_record" "argocd" {
  zone_id = data.aws_route53_zone.this.zone_id
  name    = var.argocd_domain
  type    = "CNAME"
  ttl     = 300
  records = [data.kubernetes_service.argocd_server.status[0].load_balancer[0].ingress[0].hostname]
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
