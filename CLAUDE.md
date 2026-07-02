# CLAUDE.md — devtools-labs

This repo provisions the cluster and bootstraps ArgoCD for the devtools platform. It uses Terragrunt to drive Terraform modules. Two alternative environments are supported — **EKS** (heavier, always-on cost) and **minikube** (a single EC2 instance, cheaper) — only one should be active at a time (see "Key Design Decisions").

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
│   ├── argocd-ingress/         # terragrunt.hcl — depends on eks + argocd
│   └── minikube/               # terragrunt.hcl — standalone EC2 instance
└── modules/
    ├── eks/                    # VPC lookup + EKS managed node group
    ├── argocd/                 # Helm: argo-cd chart + ApplicationSet
    ├── argocd-ingress/         # Helm: nginx-ingress; K8s: cloudflared + ArgoCD Ingress
    └── minikube/               # EC2 user_data: start minikube + ArgoCD + app-of-apps only
```

The Packer template for the minikube module's golden AMI (Docker/kubectl/Helm/minikube
pre-installed) lives in its own repo:
[`devops-tashtiot/minikube-ami`](https://github.com/devops-tashtiot/minikube-ami).

**minikube module scope is intentionally minimal** — it bootstraps ArgoCD plus two app-of-apps Applications, `clusters-applicationset` then `devtools-applicationset` in that order (see "What the Modules Provision" below), and nothing else. `nginx-ingress`, `cloudflared`, `external-secrets-operator`, and the ArgoCD `Ingress` are **not** provisioned by Terraform for this environment; they're GitOps-managed via `clusters-provision`/`clusters-definition` (plus an `ingress` block in the `argocd` devtool) that ArgoCD deploys itself once it's up. This mirrors the EKS split (`eks` → `argocd` → `argocd-ingress`) except the ingress layer moved from Terraform into GitOps.

## Five-Repo GitOps Architecture

This repo is one of five that form the platform:

| Repo | Role |
|---|---|
| **devtools-labs** (this repo) | Infrastructure: EKS/minikube cluster + ArgoCD bootstrap |
| **devtools-provision** | What to deploy: Helm charts for each devtool (bitbucket, confluence, jira, argocd, woodpecker) under `devtools/` |
| **devtools-definition** | How to configure: env-specific `values.yaml` overrides per devtool |
| **clusters-provision** | What to deploy: Helm charts for shared cluster infra (ingress-nginx, cloudflared, external-secrets-operator) under `clusters/` |
| **clusters-definition** | How to configure: env-specific `values.yaml` overrides per cluster-infra tool |

Each `-provision`/`-definition` pair has its own ApplicationSet, following the same pattern: the ApplicationSet auto-discovers every directory under the provision repo's top-level folder (`devtools/*` or `clusters/*`) and creates one Application per tool, using **two sources** — the chart from the `-provision` repo and values overrides from the `-definition` repo.

**Why split cluster infra from devtools:** devtools can depend on cluster-level infra being ready first — e.g. bitbucket's `ExternalSecret` needs `external-secrets-operator` running before it can sync. Two separate ApplicationSets let the minikube module's bootstrap enforce that ordering explicitly by waiting on `clusters-applicationset`'s apps before registering `devtools-applicationset`; a single shared ApplicationSet couldn't express that dependency.

**EKS is not wired to `clusters-applicationset`** — `modules/argocd` (the EKS path) still only registers `devtools-applicationset`. If EKS is ever brought back up, cluster-level infra keeps coming from Terraform (`argocd-ingress` module) as before; only the `minikube` module's `user_data` sequences both ApplicationSets.

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

**minikube module:**
1. A single EC2 instance running Minikube (docker driver), built from a custom AMI (see below) with Docker/kubectl/Helm/minikube already installed — `user_data` only starts minikube and bootstraps ArgoCD
2. ArgoCD — installed via Helm inside Minikube, `ClusterIP` only
3. The `clusters-applicationset` Application (app-of-apps) is registered first; `user_data` then blocks until `ingress-nginx`, `cloudflared`, and `external-secrets-operator` all report Synced+Healthy
4. The `devtools-applicationset` Application (app-of-apps) is registered last — from here on, ArgoCD itself deploys everything else, including the ArgoCD `Ingress`, as regular devtools

## Prerequisites

**EKS (`argocd-ingress` module):**
1. **Cloudflare tunnel credentials in S3** — upload once before first apply:
   ```bash
   aws s3 cp ~/.cloudflared/<tunnel-id>.json \
     s3://terraform-state-342831714456/cloudflare/devtools-labs-tunnel.json \
     --profile 342831714456_Workload-Admin-PS
   ```
2. **Cloudflare DNS CNAME** — each subdomain must point to `7de872ce-2826-42fb-9aea-325e10e3e5fc.cfargotunnel.com` (see parent `CLAUDE.md` for the API call).

**minikube (`cloudflared` devtool):**
1. **Cloudflare tunnel credentials in SSM Parameter Store** — a `SecureString` at `/devtools/cloudflare/tunnel-credentials` (already populated, migrated from the S3 object above). The `external-secrets-operator` devtool must be deployed first for the `cloudflared` devtool's ExternalSecret to sync — it is, automatically, via the same ApplicationSet. To rotate the tunnel credentials later:
   ```bash
   aws ssm put-parameter \
     --name /devtools/cloudflare/tunnel-credentials \
     --type SecureString \
     --value "$(cat ~/.cloudflared/<tunnel-id>.json)" \
     --overwrite \
     --profile 342831714456_Workload-Admin-PS \
     --region il-central-1
   ```
   The path must match `tunnelCredentialsSsmParameter` in `devtools-definition/devtools/cloudflared/values.yaml`, and fall under the `arn:aws:ssm:*:*:parameter/devtools/*` prefix the minikube instance role is allowed to read.
2. **Cloudflare DNS CNAME** — same as EKS, above.
3. **The minikube base AMI must exist** — the `minikube` module looks up the most recent AMI matching `minikube-devtools-base-*` (owned by this account) via `data.aws_ami.minikube_base`. If none exists yet (fresh account), build one first — see below.

## Building the Minikube base AMI

[`devops-tashtiot/minikube-ami`](https://github.com/devops-tashtiot/minikube-ami) (separate repo) builds the AMI the `minikube` module boots from — Docker, kubectl, Helm and the minikube binary pre-installed, so tearing down and recreating the EC2 instance doesn't depend on `dnf`/GitHub/`dl.k8s.io`/GCS being reachable at boot time. Rebuild it only when one of those versions needs bumping (edit that repo's `scripts/install.sh`).

**Prerequisite:** the AWS `session-manager-plugin` installed locally — Packer reaches the private-subnet build instance by tunneling through SSM Session Manager (`ssh_interface = "session_manager"`), since there's no NAT/public IP path to it.

**One-time bootstrap** (only needed the very first time, on a fully-destroyed/fresh account — the security group and IAM instance profile the build reuses don't exist yet, and can't be created by a full `terragrunt apply` because that also tries to resolve `data.aws_ami.minikube_base`, which won't have a match yet):
```bash
cd terraform/live/devtools/minikube
terragrunt apply \
  -target=aws_security_group.minikube \
  -target=aws_iam_instance_profile.minikube \
  -target=aws_iam_role_policy_attachment.ssm_core
```

**Build:**
```bash
cd terraform/live/devtools/minikube
terragrunt output -json subnet_ids | jq -r '.[0]'   # subnet_ids is a list — take the first
terragrunt output -raw security_group_id
terragrunt output -raw iam_instance_profile_name

cd <path-to-your-clone-of>/minikube-ami   # https://github.com/devops-tashtiot/minikube-ami
packer init .
packer build \
  -var "aws_region=il-central-1" \
  -var "aws_profile=342831714456_Workload-Admin-PS" \
  -var "project_name=devtools-labs" \
  -var "subnet_id=<from above>" \
  -var "security_group_id=<from above>" \
  -var "iam_instance_profile=<from above>" \
  .
```
The next `terragrunt apply`/`plan` in `terraform/live/devtools/minikube` will pick up the new AMI automatically (`most_recent = true`). The instance has `lifecycle { ignore_changes = [ami] }`, so an already-running instance won't be replaced just because a newer AMI appears — only a fresh `apply` after destroying/replacing the instance picks it up.

## Apply Workflow

Dependency chain is `eks → argocd → argocd-ingress`. Run all at once:

```bash
cd terraform/live/devtools
terragrunt run-all apply
```

**Caution:** since `eks`, `argocd`, `argocd-ingress`, `minikube`, `rds`, and `domain-controller` are all sibling units under `terraform/live/devtools`, a plain `terragrunt run-all apply` from that directory targets **all six** — including both alternative environments (EKS and minikube) at once, which "Key Design Decisions" below explicitly warns against. Use the scoped wrapper (below) or step-by-step commands instead unless you actually want everything.

Or step by step:
```bash
cd terraform/live/devtools/eks           && terragrunt apply  # ~15-20 min
cd terraform/live/devtools/argocd        && terragrunt apply  # ~5-10 min
cd terraform/live/devtools/argocd-ingress && terragrunt apply # ~3-5 min
```

**ArgoCD:** `https://argocd.devopstashtiot.page` — user `admin`, password `123456`.

Or, for the minikube environment:
```bash
cd terraform/live/devtools/minikube
terragrunt apply   # ~15-20 min; installs Minikube + ArgoCD, then ArgoCD deploys cluster infra, waits for it to be healthy, then deploys devtools
```

### Minikube stack wrapper (minikube + rds + domain-controller)

`terraform/live/devtools/apply-minikube-stack.sh` runs `terragrunt run-all` scoped to just `minikube`, `rds`, and `domain-controller` (via `--queue-strict-include`), so it never touches `eks`/`argocd`/`argocd-ingress`. Terragrunt's own dependency graph handles ordering: `rds` and `domain-controller` both read `minikube`'s outputs (vpc/subnets/security group), so they wait for minikube, but run in parallel with each other since neither depends on the other.

```bash
cd terraform/live/devtools
./apply-minikube-stack.sh plan       # dry run
./apply-minikube-stack.sh            # apply (interactive approval)
./apply-minikube-stack.sh destroy
```

**Cost note:** `rds` defaults to `db.t3.micro`/20GB (free-tier). `domain-controller` defaults to `t3.small` (~$15/mo, **not** free-tier) and `instance_enabled = true` in its `terragrunt.hcl` — running this wrapper creates it. Set `instance_enabled = false` there first if you only want the RDS piece.

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
- **EKS and minikube are alternatives, not simultaneous** — both bootstrap ArgoCD via Helm and a `devtools-applicationset` Application against the same `devtools-provision`/`devtools-definition` repos (minikube additionally bootstraps `clusters-applicationset` against `clusters-provision`/`clusters-definition` first — EKS does not). They also share one Cloudflare tunnel, so running both clusters at once would race two `cloudflared` Deployments and (if `devtools-definition/devtools/argocd/values.yaml`'s `ingress.enabled` is `true`) two controllers fighting over the same `argocd` Ingress object. Destroy one before standing up the other
- **minikube instance boots from a custom AMI, not stock Amazon Linux** — the instance is torn down and recreated often; baking Docker/kubectl/Helm/minikube into a golden AMI (built via Packer, see "Building the Minikube base AMI") removes several flaky external downloads from the boot-time critical path, leaving `user_data` with only the fast, instance-specific steps
