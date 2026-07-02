# CLAUDE.md — devtools-labs

This repo provisions the infra behind the devtools platform: a Minikube cluster (with ArgoCD bootstrapped inside it), an RDS Postgres instance, and a standalone Windows AD domain controller. It uses Terragrunt to drive Terraform modules.

## Repository Structure

```
terraform/
├── root.hcl                    # Shared: AWS provider, S3 remote state config
├── live/devtools/
│   ├── minikube/                # terragrunt.hcl — standalone EC2 instance
│   ├── rds/                     # terragrunt.hcl — standalone RDS instance
│   └── domain-controller/       # terragrunt.hcl — standalone Windows AD EC2 instance
└── modules/
    ├── minikube/                # EC2 user_data: start minikube + ArgoCD + app-of-apps only
    ├── rds/                     # Postgres RDS instance + security group
    └── domain-controller/       # Windows Server 2022 EC2 + AD forest bootstrap
```

The Packer template for the minikube module's golden AMI (Docker/kubectl/Helm/minikube
pre-installed) lives in its own repo:
[`devops-tashtiot/minikube-ami`](https://github.com/devops-tashtiot/minikube-ami).

**minikube module scope is intentionally minimal** — it bootstraps ArgoCD plus two app-of-apps Applications, `clusters-applicationset` then `devtools-applicationset` in that order (see "What the Modules Provision" below), and nothing else. `nginx-ingress`, `cloudflared`, `external-secrets-operator`, and the ArgoCD `Ingress` are **not** provisioned by Terraform; they're GitOps-managed via `clusters-provision`/`clusters-definition` (plus an `ingress` block in the `argocd` devtool) that ArgoCD deploys itself once it's up.

## Three independent units — not a dependency chain

`minikube`, `rds`, and `domain-controller` are three separate Terragrunt units under `terraform/live/devtools`, and **none of them has a `dependency` block on either of the others**. Each resolves its own VPC/subnets independently (by data lookup or hardcoded tag filter, not by reading another unit's outputs), so:

- Any one of them can be applied, destroyed, or torn down and rebuilt without touching the other two.
- `terragrunt run-all apply`/`destroy` from `terraform/live/devtools` runs all three **in parallel** — there's no ordering to wait on.
- They happen to share the same VPC (`vpc-0c5eaad2eb2976b41`) and similar spoke-subnet tag filters by convention, not by Terraform reference.

## Five-Repo GitOps Architecture

This repo is one of five that form the platform:

| Repo | Role |
|---|---|
| **devtools-labs** (this repo) | Infrastructure: Minikube cluster + ArgoCD bootstrap, RDS, domain controller |
| **devtools-provision** | What to deploy: Helm charts for each devtool (bitbucket, confluence, jira, argocd, woodpecker) under `devtools/` |
| **devtools-definition** | How to configure: env-specific `values.yaml` overrides per devtool |
| **clusters-provision** | What to deploy: Helm charts for shared cluster infra (ingress-nginx, cloudflared, external-secrets-operator) under `clusters/` |
| **clusters-definition** | How to configure: env-specific `values.yaml` overrides per cluster-infra tool |

Each `-provision`/`-definition` pair has its own ApplicationSet, following the same pattern: the ApplicationSet auto-discovers every directory under the provision repo's top-level folder (`devtools/*` or `clusters/*`) and creates one Application per tool, using **two sources** — the chart from the `-provision` repo and values overrides from the `-definition` repo.

**Why split cluster infra from devtools:** devtools can depend on cluster-level infra being ready first — e.g. bitbucket's `ExternalSecret` needs `external-secrets-operator` running before it can sync. Two separate ApplicationSets let the minikube module's bootstrap enforce that ordering explicitly by waiting on `clusters-applicationset`'s apps before registering `devtools-applicationset`; a single shared ApplicationSet couldn't express that dependency.

## What the Modules Provision

**minikube module:**
1. A single EC2 instance running Minikube (docker driver), built from a custom AMI (see below) with Docker/kubectl/Helm/minikube already installed — `user_data` only starts minikube and bootstraps ArgoCD
2. `user_data` also installs and enables a `minikube.service` systemd unit (`ExecStart=minikube start --driver=docker --force --cpus=<minikube_cpus> --memory=<minikube_memory_mb> --wait=all`, `After=docker.service`, `WantedBy=multi-user.target`) — this is what makes the cluster survive the nightly auto-stop (see "Cost note" below): without it, a plain one-shot `minikube start` in `user_data` only ever runs on the instance's very first boot, so every later boot after a stop would leave the EC2 instance up but the cluster itself down until someone manually SSMed in and ran `minikube start` by hand. The unit is only written/enabled *after* the data-volume mount + `/var/lib/docker` bind-mount dance (step 1) completes, specifically to avoid racing `minikube start` against the not-yet-remounted docker storage on a truly fresh instance launch.
3. ArgoCD — installed via Helm inside Minikube, `ClusterIP` only
4. The `clusters-applicationset` Application (app-of-apps) is registered first; `user_data` then blocks until `ingress-nginx`, `cloudflared`, and `external-secrets-operator` all report Synced+Healthy
5. The `devtools-applicationset` Application (app-of-apps) is registered last — from here on, ArgoCD itself deploys everything else, including the ArgoCD `Ingress`, as regular devtools

**rds module:**
1. A Postgres RDS instance (`db.t3.micro`/20GB by default, free-tier) in a DB subnet group built from the account's spoke subnets
2. A security group allowing Postgres (5432) from CIDR blocks matching the minikube/domain-controller spoke subnets — CIDR-based, not a reference to either unit's security group, so `rds` never has to wait on them
3. Used by devtools (e.g. Bitbucket) that need an external database instead of an in-cluster one

**domain-controller module:**
1. A Windows Server 2022 EC2 instance (`instance_enabled` toggles whether it's created at all)
2. Optionally promotes itself to an Active Directory forest (`promote_domain_controller = true`) — bootstraps a domain, an OU, an LDAP bind account, a sample user, and a group, for testing Bitbucket's LDAP integration
3. Access is via SSM Session Manager / Fleet Manager (browser RDP) — no open admin ports, no NAT/public IP needed
4. Publishes `ldap://<current-private_ip>:389` to the `/devtools/domain-controller/ldap-connection-url` SSM parameter on every apply (`aws_ssm_parameter.ldap_connection_url`) — the stable address consumers (RHBK) read instead of a literal IP that would go stale if the instance is ever replaced. A private Route53 hosted zone was tried first for this but **this account's Horizon LZ org-wide SCP has an explicit deny on `route53:CreateHostedZone`** — don't re-attempt a Route53-based approach here without first confirming that policy has changed

## Prerequisites

**Cloudflare tunnel credentials in SSM Parameter Store** — a `SecureString` at `/devtools/cloudflare/tunnel-credentials` (already populated). The `external-secrets-operator` devtool must be deployed first for the `cloudflared` devtool's ExternalSecret to sync — it is, automatically, via the `clusters-applicationset`. To rotate the tunnel credentials later:
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

**Cloudflare DNS CNAME** — each subdomain must point to `7de872ce-2826-42fb-9aea-325e10e3e5fc.cfargotunnel.com` (see parent `CLAUDE.md` for the API call).

**The minikube base AMI must exist** — the `minikube` module looks up the most recent AMI matching `minikube-devtools-base-*` (owned by this account) via `data.aws_ami.minikube_base`. If none exists yet (fresh account), build one first — see below.

**domain-controller's admin/LDAP-bind credentials in SSM Parameter Store** — four `SecureString`s the `ad-bootstrap.ps1.tftpl` user-data script fetches at boot instead of baking into user-data or Terraform state: `/devtools/domain-controller/admin-username`, `/devtools/domain-controller/admin-password` (DSRM/local Administrator), and `/devtools/domain-controller/ldap-bind-username`, `/devtools/domain-controller/ldap-bind-password` (the `svc-devops-tashtiot` service account Bitbucket/RHBK bind to LDAP with — `clusters-definition/clusters/rhbk/values.yaml` points at these same two paths, so RHBK and the domain controller never share a literal credential value in git). Populate all four before applying, e.g.:
```bash
aws ssm put-parameter --name /devtools/domain-controller/admin-username --type SecureString --value "Administrator" --profile 342831714456_Workload-Admin-PS --region il-central-1
aws ssm put-parameter --name /devtools/domain-controller/admin-password --type SecureString --value "<password>" --profile 342831714456_Workload-Admin-PS --region il-central-1
aws ssm put-parameter --name /devtools/domain-controller/ldap-bind-username --type SecureString --value "svc-devops-tashtiot" --profile 342831714456_Workload-Admin-PS --region il-central-1
aws ssm put-parameter --name /devtools/domain-controller/ldap-bind-password --type SecureString --value "<password>" --profile 342831714456_Workload-Admin-PS --region il-central-1
```
Until these exist, `terragrunt apply` still succeeds (the instance boots) but `ad-bootstrap.ps1.tftpl` fails to fetch them and forest promotion/LDAP object creation never completes. Note `/devtools/domain-controller/ldap-connection-url` is *not* a prerequisite — the module writes that one itself on every apply (see "domain-controller module" above).

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

```bash
cd terraform/live/devtools/minikube
terragrunt apply   # ~15-20 min; installs Minikube + ArgoCD, then ArgoCD deploys cluster infra, waits for it to be healthy, then deploys devtools
```

**ArgoCD:** `https://argocd.devopstashtiot.page` — user `admin`, password `123456`.

**Restarting after the nightly auto-stop (or any EC2 stop/start):** nothing manual is needed — `minikube.service` (installed by `user_data`, see "What the Modules Provision" → minikube module) auto-starts the cluster on every boot. Just start the EC2 instance (console/CLI/SSM: `aws ec2 start-instances --instance-ids <id>`) and wait a few minutes; no need to SSM in and run `minikube start` by hand. This only applies to an existing instance being stopped/started — a full `terragrunt apply` that replaces the instance (e.g. after a `user_data` change, since `user_data` isn't in `lifecycle.ignore_changes`) still goes through the full ~15-20 min first-boot flow above.

### Applying all three units together

`terraform/live/devtools` has only these three units, so a plain `terragrunt run-all` from that directory applies/destroys all of them — no scoping needed. Since none of the three depends on another, they run in parallel.

```bash
cd terraform/live/devtools
terragrunt run-all plan       # dry run
terragrunt run-all apply      # apply (interactive approval)
terragrunt run-all destroy
```

**Cost note:** `rds` defaults to `db.t3.micro`/20GB (free-tier). `domain-controller` defaults to `t3.small` (~$15/mo, **not** free-tier) and `instance_enabled = true` in its `terragrunt.hcl` — running `run-all apply` creates it. Set `instance_enabled = false` there first if you only want the RDS piece.

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

- **No AWS load balancer** — `cloudflared` dials out to Cloudflare; `nginx-ingress` is ClusterIP. Zero LB cost.
- **ArgoCD runs insecure** (`--insecure` flag) — TLS is terminated at Cloudflare; acceptable for a dev platform
- **Two-source ApplicationSet** — the provision repo owns chart structure; the definition repo owns env-specific values, keeping configuration separate from packaging
- **Three independent Terragrunt units, no dependency graph** — `minikube`, `rds`, and `domain-controller` each resolve their own VPC/subnets rather than reading another unit's outputs, so any one can be applied/destroyed independently of the others (see "Three independent units" above)
- **minikube instance boots from a custom AMI, not stock Amazon Linux** — the instance is torn down and recreated often; baking Docker/kubectl/Helm/minikube into a golden AMI (built via Packer, see "Building the Minikube base AMI") removes several flaky external downloads from the boot-time critical path, leaving `user_data` with only the fast, instance-specific steps
- **Route53 is unusable in this account** — the Horizon LZ org-wide SCP has an explicit deny on `route53:CreateHostedZone` (hit while building domain-controller's LDAP DNS name, see "domain-controller module" above). Anything needing stable internal service discovery in this account has to use an SSM-parameter-published value (or similar) instead of a private hosted zone
