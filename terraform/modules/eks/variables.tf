variable "aws_region" {
  type = string
}

variable "aws_profile" {
  type = string
}

variable "project_name" {
  type = string
}

variable "cluster_name" {
  description = "EKS cluster name."
  type        = string
  default     = "devtools-eks"
}

variable "cluster_version" {
  description = "Kubernetes version for the EKS control plane. Keep this inside AWS's Standard (not Extended) support window — Extended Support carries a per-cluster-hour surcharge on top of the base $0.10/hr control-plane cost."
  type        = string
  default     = "1.36"
}

variable "vpc_id" {
  description = "Explicit VPC ID. Leave empty to auto-discover the first VPC in the account — same convention as modules/minikube."
  type        = string
  default     = ""
}

variable "subnet_tag_filter" {
  description = "Tag Name wildcard filter for the target subnets. Matches both spokeSubnet1 (il-central-1a) and spokeSubnet2 (il-central-1b) — same convention as modules/minikube/modules/rds."
  type        = string
  default     = "spokeSubnet"
}

variable "system_node_instance_type" {
  description = "Instance type for the small, stable Managed Node Group that hosts cluster-critical add-ons (CoreDNS, Karpenter's own controller, the EBS CSI controller, metrics-server) — these must never be churned by Karpenter's own consolidation, so they run on a fixed node group instead of Karpenter-provisioned capacity. Deliberately small/cheap: these controllers are lightweight."
  type        = string
  default     = "t3.medium"
}

variable "system_node_count" {
  description = "Fixed node count for the system Managed Node Group — one per AZ (spokeSubnet1/spokeSubnet2) for basic resilience of cluster-critical add-ons."
  type        = number
  default     = 2
}

variable "gitops_ref" {
  description = "Git branch/ref this cluster's ArgoCD bootstrap tracks across all four GitOps repos (clusters-provision/clusters-definition/devtools-provision/devtools-definition). Deliberately NOT 'main' by default — the EKS-only changes (ESO Pod Identity auth, storageClassName renames, the new ebs-storageclass chart, Jira's RWX fix, Artifactory's Pod Identity S3 access) live on a temporary branch until real cutover, so minikube's still-live ArgoCD (which tracks 'main') is never affected. Flip to 'main' only at the literal cutover step, once eks-migration has been fast-forward-merged into main."
  type        = string
  default     = "eks-migration"
}

variable "argocd_chart_version" {
  description = "ArgoCD Helm chart version — kept identical to modules/minikube's value so both clusters run the same ArgoCD version during the parallel-validation window."
  type        = string
  default     = "9.4.2"
}

variable "argocd_admin_bcrypt_hash" {
  description = "Bcrypt hash of the ArgoCD admin password — same value as modules/minikube's hardcoded hash, so both clusters' ArgoCD accept the same admin login during validation."
  type        = string
  default     = "$2a$10$OlAKK08KRfEsdW5lAbvBIuehF6oXILP1C0YKYup7OoXCOwj0/Wi5C"
  sensitive   = true
}

variable "argocd_provision_repo" {
  description = "GitOps repo holding Helm chart sources (devtools-provision)."
  type        = string
  default     = "https://github.com/devops-tashtiot/devtools-provision"
}

variable "argocd_definition_repo" {
  description = "GitOps repo holding env-specific values overrides (devtools-definition)."
  type        = string
  default     = "https://github.com/devops-tashtiot/devtools-definition"
}

variable "clusters_provision_repo" {
  description = "GitOps repo holding Helm chart sources for shared cluster infrastructure."
  type        = string
  default     = "https://github.com/devops-tashtiot/clusters-provision"
}

variable "clusters_definition_repo" {
  description = "GitOps repo holding env-specific values overrides for clusters-provision."
  type        = string
  default     = "https://github.com/devops-tashtiot/clusters-definition"
}

variable "eso_namespace" {
  description = "Namespace external-secrets-operator deploys into — matches the ApplicationSet's destination.namespace: '{{path.basename}}' convention, i.e. the clusters-provision directory name."
  type        = string
  default     = "external-secrets-operator"
}

variable "eso_service_account_name" {
  description = "Pinned ServiceAccount name for external-secrets-operator's pods, so the Pod Identity association below doesn't have to guess a Helm-templated fullname. Set via clusters-definition/clusters/external-secrets-operator/values.yaml's external-secrets.serviceAccount.name override on the eks-migration branch."
  type        = string
  default     = "external-secrets"
}

variable "artifactory_namespace" {
  description = "Namespace Artifactory deploys into — matches the devtools ApplicationSet's destination.namespace convention."
  type        = string
  default     = "artifactory"
}

variable "artifactory_service_account_name" {
  description = "ServiceAccount name for Artifactory's pods. Set via devtools-provision/devtools/artifactory/values.yaml's (top-level, not artifactory.artifactory-nested) serviceAccount.name on the eks-migration branch."
  type        = string
  default     = "artifactory"
}

variable "artifactory_s3_bucket_name" {
  description = "S3 bucket Artifactory's binarystore uses — same bucket the minikube instance's node role currently reaches implicitly via IMDS (persistence.awsS3V3.useInstanceCredentials). On EKS this becomes an explicit, narrowly-scoped Pod Identity role instead."
  type        = string
  default     = "devtools-artifactory-binaries-342831714456"
}
