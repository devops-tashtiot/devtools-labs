# Named providers.tf, not provider.tf — root.hcl's generate block writes the
# aws provider to "provider.tf" with if_exists = "overwrite" on every
# terragrunt run; a different filename means that generation never clobbers
# these. Only two providers, deliberately: helm (installs ArgoCD — the one
# thing that must bootstrap via Terraform) and kubectl (applies exactly the
# two app-of-apps Application objects). Everything else this cluster runs is
# deployed by ArgoCD itself via GitOps, not by a Terraform provider.
#
# Both authenticate via the applying identity's own AWS credentials, the same
# "aws eks get-token" mechanism the kubectl CLI itself uses — no separate
# kubeconfig/credential to manage. Works because
# enable_cluster_creator_admin_permissions = true (main.tf) grants that
# identity cluster-admin via an EKS Access Entry automatically.

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region, "--profile", var.aws_profile]
    }
  }
}

# gavinbunney/kubectl — needed for the two Application objects specifically
# because the ArgoCD Application CRD is installed by the same helm_release in
# the same apply; the core kubernetes_manifest resource needs the CRD schema
# known at plan time, which doesn't hold on a first-ever apply. kubectl_manifest
# applies raw YAML without that constraint.
provider "kubectl" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  load_config_file       = false

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region, "--profile", var.aws_profile]
  }
}
