# CLAUDE.md — devtools-labs

This repo provisions the EKS cluster and bootstraps ArgoCD for the devtools platform. It uses Terragrunt to drive Terraform modules.

## Cost Warning

**EKS is not free-tier eligible.** The control plane costs ~$0.10/hr and the `t3.medium` nodes are not free-tier. Destroy the cluster when not in use:

```bash
cd terraform/live/devtools/eks
terragrunt destroy
```

## Repository Structure

```
terraform/
├── root.hcl                         # Shared: AWS provider, S3 remote state config
├── live/
│   └── devtools/
│       ├── eks/
│       │   └── terragrunt.hcl       # Cluster inputs (name, version, node type)
│       └── argocd/
│           └── terragrunt.hcl       # ArgoCD inputs; dependency on eks unit
└── modules/
    ├── eks/                         # VPC + EKS cluster only
    │   ├── main.tf                  # VPC + EKS managed node group
    │   ├── providers.tf             # AWS provider
    │   ├── variables.tf             # Cluster variables
    │   ├── outputs.tf               # cluster_name, cluster_endpoint, cluster_certificate_authority, kubeconfig_command
    │   └── versions.tf              # AWS provider constraint
    └── argocd/                      # ArgoCD Helm install + ApplicationSet
        ├── main.tf                  # helm_release argocd + kubernetes_manifest ApplicationSet
        ├── providers.tf             # Helm/Kubernetes providers (configured from input variables)
        ├── variables.tf             # cluster_endpoint, cluster_certificate_authority, repo URLs
        ├── outputs.tf               # argocd_url, argocd_initial_password_command
        └── versions.tf              # Helm + Kubernetes provider constraints
```

## Three-Repo GitOps Architecture

This repo is one of three that form the platform:

| Repo | Role |
|---|---|
| **devtools-labs** (this repo) | Infrastructure: EKS cluster + ArgoCD bootstrap |
| **devtools-provision** | What to deploy: Helm charts for each tool under `devtools/` |
| **devtools-definition** | How to configure: env-specific `values.yaml` overrides per tool |

ArgoCD's ApplicationSet (defined in `argocd.tf`) auto-discovers every directory under `devtools/*` in the provision repo and creates one Application per tool. Each application uses **two sources**: the chart from `devtools-provision` and values overrides from `devtools-definition`.

## What the Modules Provision

**eks module:**
1. VPC — public subnets only; NAT Gateway disabled (not free-tier)
2. EKS cluster — v1.31, public endpoint, single `t3.medium` managed node group

**argocd module:**
3. ArgoCD — installed via Helm (chart v9.4.2), exposed as an internet-facing NLB
4. ApplicationSet — wires the two GitOps repos for auto-discovery of tools

## Apply Workflow

The two units are independent Terragrunt configs. Terragrunt's `dependency` block in the `argocd` unit reads the cluster endpoint/cert from the `eks` unit's outputs, so there is no `-target` hack needed.

```bash
# Step 1 — provision the EKS cluster
cd terraform/live/devtools/eks
terragrunt apply

# Step 2 — install ArgoCD (reads cluster outputs via dependency block)
cd terraform/live/devtools/argocd
terragrunt apply
```

Or run both at once from the parent directory:
```bash
cd terraform/live/devtools
terragrunt run-all apply
```

## Useful Outputs

```bash
# Configure kubectl (from eks unit)
cd terraform/live/devtools/eks
terragrunt output -raw kubeconfig_command | bash

# Get ArgoCD URL (from argocd unit)
cd terraform/live/devtools/argocd
terragrunt output argocd_url

# Get ArgoCD admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d && echo
```

## AWS Account & Region

| Setting | Value |
|---|---|
| Account | `342831714456` |
| Region | `il-central-1` |
| AWS profile | `342831714456_Workload-Admin-PS` |
| Terraform state bucket | `terraform-state-342831714456` |

## Key Design Decisions

- **No NAT Gateway** — nodes run in public subnets with `map_public_ip_on_launch = true` to avoid NAT Gateway costs
- **ArgoCD runs insecure** (`--insecure` flag) — TLS is terminated at the NLB; acceptable for a dev platform
- **Two-source ApplicationSet** — the provision repo owns chart structure; the definition repo owns env-specific values, keeping configuration separate from packaging
- **Split Terragrunt units** — `eks` and `argocd` are separate units; the `argocd` unit's `dependency` block reads cluster outputs at plan time, so providers are always configured from real values with no `-target` workaround needed
