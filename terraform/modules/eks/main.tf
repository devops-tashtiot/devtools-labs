locals {
  # Mirrors modules/minikube's exact same locals — except the git ref is
  # var.gitops_ref (default "eks-migration"), not a hardcoded "main", so this
  # cluster's bootstrap can track a temporary branch until real cutover
  # without touching minikube's still-live ArgoCD (which fetches from "main").
  devtools_application_yaml_raw_url = "${replace(var.argocd_definition_repo, "https://github.com", "https://raw.githubusercontent.com")}/${var.gitops_ref}/application.yaml"
  clusters_application_yaml_raw_url = "${replace(var.clusters_definition_repo, "https://github.com", "https://raw.githubusercontent.com")}/${var.gitops_ref}/application.yaml"
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = var.cluster_name
  kubernetes_version = var.cluster_version

  vpc_id     = data.aws_vpc.horizon.id
  subnet_ids = data.aws_subnets.target.ids

  # No bastion/VPN into this VPC anywhere in this platform (SSM is the access
  # pattern for the minikube/domain-controller EC2 instances too) — the
  # operator's workstation reaches the API server over the public endpoint,
  # same as it reaches AWS's own APIs. Still IAM-authenticated, not open.
  endpoint_public_access  = true
  endpoint_private_access = true

  # v21's Access Entries API — the identity running `terragrunt apply`
  # (aws_profile) gets cluster-admin automatically, no aws-auth ConfigMap
  # hand-editing needed.
  enable_cluster_creator_admin_permissions = true

  # Pod Identity (not IRSA/OIDC) is this platform's chosen mechanism for
  # giving pods scoped AWS permissions — see iam.tf. eks-pod-identity-agent is
  # what actually serves those credentials to pods at runtime.
  addons = {
    coredns = {
      # The *.devopstashtiot.page in-cluster rewrite (same need as
      # modules/minikube/main.tf step 3) is layered on top of this managed
      # addon via a new clusters-provision "coredns-custom" chart, not
      # Terraform — a managed addon's own ConfigMap gets reconciled/reverted
      # on every addon version bump, so it can't be edited directly here.
    }
    vpc-cni                = {}
    kube-proxy             = {}
    eks-pod-identity-agent = {}
    aws-ebs-csi-driver = {
      pod_identity_association = [{
        role_arn        = aws_iam_role.ebs_csi.arn
        service_account = "ebs-csi-controller-sa"
      }]
    }
  }

  # Small, stable, On-Demand — hosts CoreDNS, Karpenter's own controller, the
  # EBS CSI controller, metrics-server: components that must not be churned
  # by Karpenter's own consolidation, and that Karpenter itself needs a node
  # to run *on* before it can provision anything else. Deliberately
  # untainted, so cluster-infra pods (ingress-nginx, cloudflared, ESO, RHBK,
  # ArgoCD's own components) can also land here while Karpenter capacity is
  # still coming up, avoiding a bootstrap deadlock.
  eks_managed_node_groups = {
    system = {
      instance_types = [var.system_node_instance_type]
      ami_type       = "AL2023_x86_64_STANDARD"

      min_size     = var.system_node_count
      max_size     = var.system_node_count
      desired_size = var.system_node_count

      subnet_ids = data.aws_subnets.target.ids

      labels = {
        "devtools/role" = "system-critical"
      }
    }
  }

  tags = {
    Project = "devops-tashtiot"
    Repo    = var.project_name
  }
}

# AWS-side plumbing only (controller IAM role, node IAM role/instance
# profile, the Spot-interruption SQS queue + EventBridge rules) — Karpenter's
# actual Helm install and its EC2NodeClass/NodePool config are a new
# clusters-provision chart (GitOps), not Terraform. Pod Identity, same as the
# rest of this module, via create_pod_identity_association — no OIDC/IRSA
# wiring needed.
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 21.0"

  cluster_name = module.eks.cluster_name

  create_pod_identity_association = true
  namespace                       = "kube-system"
  service_account                 = "karpenter"

  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  tags = {
    Project = "devops-tashtiot"
    Repo    = var.project_name
  }
}

# Tags Karpenter's EC2NodeClass (a clusters-provision chart, once it lands)
# discovers Karpenter-launched nodes' subnets and security group by
# (karpenter.sh/discovery selector terms). These are the same pre-existing
# LZA spoke subnets modules/minikube/modules/rds already use, so aws_ec2_tag
# — not owning the subnet resource outright — avoids clobbering their
# existing Name/other tags.
resource "aws_ec2_tag" "karpenter_subnet_discovery" {
  for_each    = toset(data.aws_subnets.target.ids)
  resource_id = each.value
  key         = "karpenter.sh/discovery"
  value       = module.eks.cluster_name
}

resource "aws_ec2_tag" "karpenter_sg_discovery" {
  resource_id = module.eks.node_security_group_id
  key         = "karpenter.sh/discovery"
  value       = module.eks.cluster_name
}

# The one thing that must bootstrap via Terraform — nothing else can install
# ArgoCD before ArgoCD exists. Terraform-native helm_release (tracked in
# state, diffable), not a shell-out — same chart/values as
# modules/minikube/main.tf's ArgoCD install, so both clusters run identically
# during the parallel-validation window.
resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_chart_version
  wait             = true
  timeout          = 300

  values = [yamlencode({
    configs = {
      params = { "server.insecure" = "true" }
      cm     = { "accounts.admin" = "apiKey, login" }
      secret = {
        argocdServerAdminPassword      = var.argocd_admin_bcrypt_hash
        argocdServerAdminPasswordMtime = "2024-01-01T00:00:00Z"
      }
      repositories = {
        devtools-provision  = { url = var.argocd_provision_repo, type = "git", name = "devtools-provision" }
        devtools-definition = { url = var.argocd_definition_repo, type = "git", name = "devtools-definition" }
        clusters-provision  = { url = var.clusters_provision_repo, type = "git", name = "clusters-provision" }
        clusters-definition = { url = var.clusters_definition_repo, type = "git", name = "clusters-definition" }
      }
    }
    server = {
      extraArgs = ["--insecure"]
      service   = { type = "ClusterIP" }
      resources = { requests = { cpu = "50m", memory = "128Mi" }, limits = { cpu = "200m", memory = "256Mi" } }
    }
    controller = {
      replicas  = 1
      resources = { requests = { cpu = "100m", memory = "256Mi" }, limits = { cpu = "300m", memory = "512Mi" } }
    }
    repoServer = {
      replicas  = 1
      resources = { requests = { cpu = "50m", memory = "128Mi" }, limits = { cpu = "200m", memory = "256Mi" } }
    }
    applicationSet = {
      resources = { requests = { cpu = "25m", memory = "64Mi" }, limits = { cpu = "100m", memory = "128Mi" } }
    }
    redis         = { enabled = true, resources = { requests = { cpu = "10m", memory = "64Mi" }, limits = { cpu = "100m", memory = "128Mi" } } }
    "redis-ha"    = { enabled = false }
    dex           = { enabled = false }
    notifications = { enabled = false }
  })]

  depends_on = [module.eks]
}

data "http" "clusters_application_yaml" {
  url = local.clusters_application_yaml_raw_url
}

data "http" "devtools_application_yaml" {
  url = local.devtools_application_yaml_raw_url
}

# clusters-definition/application.yaml and devtools-definition/application.yaml
# are the single sources of truth for these Application manifests — fetched
# and applied directly, same as modules/minikube/main.tf does, just via
# kubectl_manifest instead of a `curl | kubectl apply` shell line.
resource "kubectl_manifest" "clusters_applicationset" {
  yaml_body  = data.http.clusters_application_yaml.response_body
  depends_on = [helm_release.argocd]
}

# devtools' pods need cluster-infra dependencies ready first (ESO for
# ExternalSecrets, ingress-nginx/cloudflared for routing, rhbk for ArgoCD's
# own OIDC values) — same reasoning as modules/minikube/main.tf step 5 — plus
# karpenter, added here on top of the original four, since devtools' pods
# also need Karpenter-provisioned compute to actually schedule. Terraform has
# no native "poll an external condition" primitive, so this one narrow
# local-exec (not a stand-in for the whole bootstrap) reuses the exact same
# polling loop modules/minikube already runs.
resource "terraform_data" "wait_for_cluster_apps" {
  input = kubectl_manifest.clusters_applicationset.yaml_body_parsed

  provisioner "local-exec" {
    environment = {
      KUBECONFIG = "${path.module}/.kubeconfig-${var.cluster_name}"
    }
    command = <<-EOT
      set -euo pipefail
      aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.aws_region} --profile ${var.aws_profile} --kubeconfig "$KUBECONFIG" >/dev/null

      for app in ingress-nginx cloudflared external-secrets-operator rhbk karpenter; do
        echo "--- Waiting for cluster app '$app' to be Synced+Healthy ---"
        sync="" health=""
        for i in $(seq 1 120); do
          sync=$(kubectl get application.argoproj.io "$app" -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || true)
          health=$(kubectl get application.argoproj.io "$app" -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || true)
          [ "$sync" = "Synced" ] && [ "$health" = "Healthy" ] && break
          sleep 5
        done
        [ "$sync" = "Synced" ] && [ "$health" = "Healthy" ] || { echo "$app never became Synced+Healthy (sync=$sync health=$health)" >&2; exit 1; }
      done
    EOT
  }

  depends_on = [kubectl_manifest.clusters_applicationset]
}

resource "kubectl_manifest" "devtools_applicationset" {
  yaml_body  = data.http.devtools_application_yaml.response_body
  depends_on = [terraform_data.wait_for_cluster_apps]
}
