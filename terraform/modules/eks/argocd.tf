# ArgoCD bootstrap — reproduces devtools-labs/terraform/modules/minikube/main.tf's
# steps [4/6]-[6/6] via this module's own helm/kubectl/http providers instead of
# a bash user_data script, since Terraform here runs from outside the VPC (this
# session's own shell), not from a process running on the cluster's own node.

resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_chart_version

  values = [yamlencode({
    configs = {
      params = {
        "server.insecure" = "true"
      }
      cm = {
        "accounts.admin" = "apiKey, login"
      }
      secret = {
        argocdServerAdminPassword      = "$2a$10$OlAKK08KRfEsdW5lAbvBIuehF6oXILP1C0YKYup7OoXCOwj0/Wi5C"
        argocdServerAdminPasswordMtime = "2024-01-01T00:00:00Z"
      }
      repositories = {
        devtools-provision = {
          url  = var.argocd_provision_repo
          type = "git"
          name = "devtools-provision"
        }
        devtools-definition = {
          url  = var.argocd_definition_repo
          type = "git"
          name = "devtools-definition"
        }
        clusters-provision = {
          url  = var.clusters_provision_repo
          type = "git"
          name = "clusters-provision"
        }
        clusters-definition = {
          url  = var.clusters_definition_repo
          type = "git"
          name = "clusters-definition"
        }
      }
    }
    server = {
      extraArgs = ["--insecure"]
      service   = { type = "ClusterIP" }
      resources = {
        requests = { cpu = "50m", memory = "128Mi" }
        limits   = { cpu = "200m", memory = "256Mi" }
      }
    }
    # Sized for managing ~19 real Applications (4 cluster-infra + 15 devtools),
    # not minikube's minimal bootstrap-only initial state this whole values
    # block was originally copied from — the controller OOMKilled repeatedly
    # (exit 137) at the original 512Mi limit the moment the devtools
    # ApplicationSet registered and it had a real resource tree to manage.
    controller = {
      replicas  = 1
      resources = {
        requests = { cpu = "250m", memory = "512Mi" }
        limits   = { cpu = "1000m", memory = "1536Mi" }
      }
    }
    repoServer = {
      replicas  = 1
      resources = {
        requests = { cpu = "100m", memory = "256Mi" }
        limits   = { cpu = "500m", memory = "512Mi" }
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
    "redis-ha"     = { enabled = false }
    dex            = { enabled = false }
    notifications  = { enabled = false }
  })]

  depends_on = [module.eks]
}

data "http" "clusters_application_yaml" {
  url = "${replace(var.clusters_definition_repo, "https://github.com", "https://raw.githubusercontent.com")}/main/application.yaml"
}

data "http" "devtools_application_yaml" {
  url = "${replace(var.argocd_definition_repo, "https://github.com", "https://raw.githubusercontent.com")}/main/application.yaml"
}

# [5/6] Register the clusters ApplicationSet (app-of-apps) first — devtools
# depend on cluster-level infra (e.g. bitbucket's ExternalSecret needs
# external-secrets-operator running), same ordering minikube's user_data uses.
resource "kubectl_manifest" "clusters_applicationset" {
  yaml_body = data.http.clusters_application_yaml.response_body

  depends_on = [helm_release.argocd]
}

# Block here until every cluster-infra Application this ApplicationSet
# generates is Healthy, before registering devtools — its ArgoCD OIDC values
# depend on rhbk's client already existing.
#
# Health only, not Sync+Health (minikube's user_data originally required
# both): a controller/operator that writes back to one of its own
# git-declared resources after creation causes a real, permanent OutOfSync
# that never resolves even though the app is fully functional — observed
# live on two separate apps during this cluster's own first bootstrap:
# ingress-nginx's Helm-hook admission Job, and rhbk's Keycloak-operator-owned
# admin Secret. Health reflects actual functional readiness; Sync reflects
# git-state matching, which isn't what this gate actually needs.
resource "null_resource" "wait_for_cluster_apps" {
  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.aws_region} --profile ${var.aws_profile}
      for app in ingress-nginx cloudflared external-secrets-operator rhbk; do
        echo "--- Waiting for cluster app '$app' to be Healthy ---"
        health=""
        for i in $(seq 1 120); do
          health=$(kubectl get application.argoproj.io "$app" -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || true)
          sync=$(kubectl get application.argoproj.io "$app" -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || true)
          echo "    sync=$sync health=$health"
          [ "$health" = "Healthy" ] && break
          sleep 5
        done
        [ "$health" = "Healthy" ] || { echo "$app never became Healthy (last sync=$sync health=$health)" >&2; exit 1; }
      done
    EOT
  }

  depends_on = [kubectl_manifest.clusters_applicationset]
}

# [6/6] Register the devtools ApplicationSet (app-of-apps).
resource "kubectl_manifest" "devtools_applicationset" {
  yaml_body = data.http.devtools_application_yaml.response_body

  depends_on = [null_resource.wait_for_cluster_apps]
}
