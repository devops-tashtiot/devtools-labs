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
├── root.hcl                    # Shared: AWS provider, S3 remote state config
├── live/devtools/
│   ├── eks/                    # terragrunt.hcl — cluster inputs
│   ├── argocd/                 # terragrunt.hcl — depends on eks
│   └── argocd-ingress/         # terragrunt.hcl — depends on eks + argocd
└── modules/
    ├── eks/                    # VPC lookup + EKS managed node group
    ├── argocd/                 # Helm: argo-cd chart + ApplicationSet
    └── argocd-ingress/         # Helm: nginx-ingress; K8s: cloudflared + ArgoCD Ingress
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
1. Uses existing spoke VPC (`vpc-0c5eaad2eb2976b41`) — private subnets only (`map_public_ip_on_launch = false`), no NAT Gateway
2. All outbound traffic routes through a Gateway Load Balancer endpoint (`vpce-063335608106cb20a`) to a centralized hub firewall/inspection layer
3. EKS cluster — v1.31, public endpoint, single `t3.medium` managed node group

**argocd module:**
3. ArgoCD — installed via Helm (chart v9.4.2), `ClusterIP` only (no load balancer)
4. ApplicationSet — wires the two GitOps repos for auto-discovery of tools

**argocd-ingress module:**
5. `nginx-ingress` controller — `ClusterIP`, routes by `Host` header
6. `cloudflared` Deployment — dials out to Cloudflare edge, forwards traffic to nginx-ingress
7. `Ingress` resource — routes `argocd.devopstashtiot.page` → `argocd-server`

## Prerequisites

1. **Cloudflare tunnel credentials in S3** — upload once before first apply:
   ```bash
   aws s3 cp ~/.cloudflared/<tunnel-id>.json \
     s3://terraform-state-342831714456/cloudflare/devtools-labs-tunnel.json \
     --profile 342831714456_Workload-Admin-PS
   ```
2. **Cloudflare DNS CNAME** — each subdomain must point to `7de872ce-2826-42fb-9aea-325e10e3e5fc.cfargotunnel.com` (see parent `CLAUDE.md` for the API call).

## Apply Workflow

Dependency chain is `eks → argocd → argocd-ingress`. Run all at once:

```bash
cd terraform/live/devtools
terragrunt run-all apply
```

Or step by step:
```bash
cd terraform/live/devtools/eks           && terragrunt apply  # ~15-20 min
cd terraform/live/devtools/argocd        && terragrunt apply  # ~5-10 min
cd terraform/live/devtools/argocd-ingress && terragrunt apply # ~3-5 min
```

**ArgoCD:** `https://argocd.devopstashtiot.page` — user `admin`, password `123456`.

## Adding a New Service

1. Add a Cloudflare DNS CNAME for `mytool.devopstashtiot.page` (parent `CLAUDE.md`).
2. Deploy the service to the cluster.
3. Apply a Kubernetes `Ingress`:
   ```yaml
   metadata:
     annotations:
       nginx.ingress.kubernetes.io/ssl-redirect: "false"
   spec:
     ingressClassName: nginx
     rules:
       - host: mytool.devopstashtiot.page
         http:
           paths:
             - path: /
               pathType: Prefix
               backend:
                 service: { name: mytool-svc, port: { number: 80 } }
   ```

## Useful Commands

```bash
# Configure kubectl
cd terraform/live/devtools/eks && terragrunt output -raw kubeconfig_command | bash

# Check pods
kubectl get pods -n argocd
kubectl get pods -n kube-system | grep -E "nginx|cloudflared"
```

## AWS Account & Region

| Setting | Value |
|---|---|
| Account | `342831714456` |
| Region | `il-central-1` |
| AWS profile | `342831714456_Workload-Admin-PS` |
| Terraform state bucket | `terraform-state-342831714456` |

## Key Design Decisions

- **Private subnets, no NAT Gateway** — nodes run in private subnets (`map_public_ip_on_launch = false`); all egress goes through a Gateway Load Balancer endpoint to a hub VPC firewall. Worker nodes must reach AWS APIs (EKS, ECR, STS, S3) either via the hub or via VPC endpoints — if the hub blocks this, nodes will fail to bootstrap
- **No AWS load balancer** — `cloudflared` dials out to Cloudflare; `nginx-ingress` is ClusterIP. Zero LB cost.
- **ArgoCD runs insecure** (`--insecure` flag) — TLS is terminated at Cloudflare; acceptable for a dev platform
- **Two-source ApplicationSet** — the provision repo owns chart structure; the definition repo owns env-specific values, keeping configuration separate from packaging
- **Split Terragrunt units** — `eks` and `argocd` are separate units; the `argocd` unit's `dependency` block reads cluster outputs at plan time, so providers are always configured from real values with no `-target` workaround needed
