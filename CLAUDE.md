# CLAUDE.md — devtools-labs

This repo provisions the infra behind the devtools platform: a multi-node **EKS** cluster (with ArgoCD bootstrapped inside it), an RDS Postgres instance, a standalone Windows AD domain controller, Cloudflare zone/DNS/Access, and AWS Backup coverage. It uses Terragrunt to drive Terraform modules.

Full architecture/bootstrap detail also lives in [`docs/`](docs/), published at https://devops-tashtiot.github.io/devtools-labs/, and is summarized in the repo [`README.md`](README.md).

## Repository Structure

```
terraform/
├── root.hcl                    # Shared: AWS provider, S3 remote state config
├── live/devtools/
│   ├── eks/                     # terragrunt.hcl — EKS cluster + ArgoCD bootstrap
│   ├── rds/                     # terragrunt.hcl — standalone RDS instance
│   ├── domain-controller/       # terragrunt.hcl — standalone Windows AD EC2 instance
│   ├── cloudflare/              # terragrunt.hcl — Cloudflare zone + DNS records + Access
│   ├── devtools-secrets/        # terragrunt.hcl — platform-wide SSM secrets not tied to any other unit
│   └── backup/                  # terragrunt.hcl — AWS Backup vault + cross-region DR copy
└── modules/
    ├── eks/                      # EKS cluster, node groups, storage classes, IRSA, ArgoCD + both ApplicationSets
    ├── rds/                      # Postgres RDS instance + security group; publishes admin creds to SSM
    ├── domain-controller/        # Windows Server 2022 EC2 + AD forest bootstrap; publishes admin/LDAP-bind creds to SSM
    ├── cloudflare/                # cloudflare_zone + cloudflare_dns_record + Access app; read-only tunnel lookup; Origin CA cert managed + published to SSM
    ├── devtools-secrets/          # aws_ssm_parameter for the shared admin password, RHBK OIDC client secret, and Cloudflare Origin CA root cert
    └── backup/                    # aws_backup_vault (primary + DR) covering RDS and BackupManaged=true-tagged resources
```

**eks module scope:** creates the cluster, node groups, storage, IRSA roles, installs ArgoCD via Helm, and registers exactly two app-of-apps `Applications` (`clusters-applicationset` then `devtools-applicationset`, see "What the Modules Provision" below) — nothing else. `nginx-ingress`, `cloudflared`, `external-secrets-operator`, and `rhbk` are GitOps-managed via `clusters-provision`/`clusters-definition`, not Terraform, same as before.

## Six independent units — not a dependency chain

`eks`, `rds`, `domain-controller`, `cloudflare`, `devtools-secrets`, and `backup` are six separate Terragrunt units under `terraform/live/devtools`, and **none has a `dependency` block on any other**:

- Any one can be applied, destroyed, or rebuilt without touching the others.
- `terragrunt run-all apply`/`destroy` from `terraform/live/devtools` runs all six **in parallel** — no ordering to wait on.
- `eks`, `rds`, and `domain-controller` reuse the account's existing spoke subnets (`subnet_tag_filter = "spokeSubnet"`) by convention, not by Terraform reference — no new VPC/NAT/EIP is created (this account's SCPs block that anyway). `cloudflare` doesn't touch AWS at all — different provider, different account. `devtools-secrets` is pure SSM. All independent by construction, not just convention.

## Five-Repo GitOps Architecture

This repo is one of five that form the platform:

| Repo | Role |
|---|---|
| **devtools-labs** (this repo) | Infrastructure: EKS cluster + ArgoCD bootstrap, RDS, domain controller, Cloudflare, backups |
| **devtools-provision** | What to deploy: Helm charts for each devtool (bitbucket, confluence, jira, argocd, woodpecker, artifactory, xray) under `devtools/` |
| **devtools-definition** | How to configure: env-specific `values.yaml` overrides per devtool |
| **clusters-provision** | What to deploy: Helm charts for shared cluster infra (ingress-nginx, cloudflared, external-secrets-operator, rhbk) under `clusters/` |
| **clusters-definition** | How to configure: env-specific `values.yaml` overrides per cluster-infra tool |

Each `-provision`/`-definition` pair has its own `ApplicationSet`, following the same pattern: the `ApplicationSet` auto-discovers every directory under the provision repo's top-level folder (`devtools/*` or `clusters/*`) and creates one Application per tool, using **two sources** — the chart from the `-provision` repo and values overrides from the `-definition` repo.

**Why split cluster infra from devtools:** devtools can depend on cluster-level infra being ready first — e.g. bitbucket's `ExternalSecret` needs `external-secrets-operator` running before it can sync. Two separate `ApplicationSet`s let the `eks` module's own Terraform (see `argocd.tf`) enforce that ordering explicitly by blocking until `clusters-applicationset`'s apps are Healthy before registering `devtools-applicationset`; a single shared `ApplicationSet` couldn't express that dependency.

## What the Modules Provision

**eks module:**
1. A multi-node, multi-AZ **EKS cluster** (`terraform-aws-modules/eks/aws`, cluster name `devtools-eks`) in the account's existing spoke subnets. Two Managed Node Groups: `devtools` (general purpose — `node_instance_types` default `["m6i.xlarge", "m6i.2xlarge", "m6i.4xlarge"]`, min 2/max 4, spans both AZs) and `devtools-large` (carved out because Confluence's 4-core CPU request can never fit on `devtools`'s smallest allowed instance type — one dedicated `m6i.2xlarge`, min/max/desired 1).
2. **`node_capacity_type` defaults to `ON_DEMAND`, not Spot** — the first real apply hit repeated `UnfulfillableCapacity` errors trying Spot across all three instance types in both AZs (confirmed via the ASG's own scaling-activity log). `capacity_type` is `ForceNew` on `aws_eks_node_group`, so revisiting this later means a full node group replacement.
3. Storage: a `gp3` EBS storage class (per-node), an EFS filesystem + `efs-sc` `ReadWriteMany` storage class (Bitbucket/Jira/Confluence shared-home), plus static-provisioning EFS storage classes per tool (`efs_static_bitbucket`/`efs_static_confluence`/`efs_static_jira`).
4. IRSA (not node-wide IMDS creds) for `external-secrets`, the EBS CSI driver, and the EFS CSI driver — dedicated IAM roles in `iam.tf`, not shared with node instance roles.
5. Installs ArgoCD via Helm (`server.insecure = true`, `ClusterIP`, `dex`/`redis-ha`/`notifications` disabled) sized for managing ~19 real Applications (4 cluster-infra + ~15 devtools) — the controller initially OOMKilled (exit 137) the moment `devtools-applicationset` registered and gave it a real resource tree to manage; controller limits are now 1000m CPU / 1536Mi memory.
6. Registers `clusters-applicationset` (app-of-apps, fetched via `data.http` from the `clusters-definition` repo's `application.yaml`), then a `null_resource` with a `local-exec` provisioner runs `aws eks update-kubeconfig` and polls `kubectl get application.argoproj.io <app>` for `ingress-nginx`, `cloudflared`, `external-secrets-operator`, `rhbk` until each reports **Health = Healthy** (Sync status is deliberately not gated on — a controller that writes back to its own git-declared resources after creation can leave a permanent, harmless OutOfSync that would otherwise block forever; observed live on `ingress-nginx`'s Helm-hook admission Job and `rhbk`'s Keycloak-operator-owned admin Secret during this cluster's first bootstrap).
7. Registers `devtools-applicationset` last (same `data.http` + `kubectl_manifest` pattern, from `devtools-definition`'s `application.yaml`) — from here on, ArgoCD itself deploys everything else, including the ArgoCD `Ingress`, as regular devtools.

**rds module:**
1. A Postgres RDS instance (`db.t3.small`, autoscaling storage — not the smallest free-tier size) in a DB subnet group built from the account's spoke subnets.
2. A security group allowing Postgres (5432) from CIDR blocks matching the eks/domain-controller spoke subnets — CIDR-based, not a reference to either unit's security group, so `rds` never has to wait on them.
3. The master password is **not** an interactive prompt — `admin_password_ssm_parameter` (`/devops/terraform-created/rds/admin-password`) is populated automatically from the shared prerequisite value at `/devops/prerequisite/generic-password` (see Prerequisites below). `admin_username` stays a plain-text value set in `terraform/live/devtools/rds/terragrunt.hcl`.
4. Used by devtools (e.g. Bitbucket) that need an external database instead of an in-cluster one, each provisioning its own DB/role via an init container.

**domain-controller module:**
1. A Windows Server 2022 EC2 instance (`instance_enabled` toggles whether it's created at all).
2. Optionally promotes itself to an Active Directory forest (`promote_domain_controller = true`) — this forest is the **source of truth for every user/group in the platform's SSO** (not a test fixture, and not itself the identity provider — that's RHBK/Keycloak via OIDC, but every account RHBK federates actually comes from here). Bootstraps a domain, an OU, an LDAP bind account, a sample user (fixed default password baked into `variables.tf`, not a runtime secret), and a group.
3. Access is via SSM Session Manager / Fleet Manager (browser RDP) — no open admin ports, no NAT/public IP, no key pair needed.
4. Publishes `ldap://<current-private_ip>:389` to `/devops/terraform-created/domain-controller/ldap-connection-url` on every apply — the stable address consumers (RHBK) read instead of a literal IP that would go stale if the instance is ever replaced. A private Route53 hosted zone was tried first for this but **this account's Horizon LZ org-wide SCP has an explicit deny on `route53:CreateHostedZone`** — don't re-attempt a Route53-based approach here without first confirming that policy has changed.
5. `admin_password_ssm_parameter` (`/devops/terraform-created/domain-controller/admin-password`, the DSRM/local Administrator password) is also populated automatically from `/devops/prerequisite/generic-password` — **there is no separate LDAP-bind password**; RHBK and everything else reads `admin_password_ssm_parameter` directly. `ldap_bind_username` is published from `ad_group_member_username`, which must stay in sync with the account `ad-bootstrap.ps1.tftpl` creates.

**cloudflare module:**
1. The Cloudflare zone, per-subdomain DNS `CNAME` records (see the `dns_records` map in `terraform/live/devtools/cloudflare/terragrunt.hcl` — add new subdomains there), and the Access Application/policy protecting `*.devopstashtiot.page`.
2. Issues and manages the Origin CA certificate every devtool trusts for in-cluster TLS (CSR generated and submitted by Terraform; private key never leaves Terraform state/SSM).
3. Looks up the Tunnel and the Origin CA certificate ID **read-only** (`data` sources), not as managed resources — the classic tunnel secret is generated client-side and never round-trips through Cloudflare's API, so this unit can't own its lifecycle.
4. Uses its own generated Cloudflare provider (`generate "provider_cloudflare"`), separate from the `aws` provider every other unit under `terraform/live/devtools` gets from `root.hcl` — auth is `CLOUDFLARE_API_TOKEN` (scoped: Zone Read + DNS Write on `devopstashtiot.page`, plus account-level Access Apps/Policies Write), never written to a file.

**devtools-secrets module:**
1. Platform-wide SSM values not tied to any other unit's AWS resource:
   - `/devops/terraform-created/admin/password` — the shared initial admin password every devtool uses (see `devtools-provision/README.md`), read automatically from `/devops/prerequisite/generic-password`.
   - `/devops/terraform-created/rhbk/oidc-client-secret` — the shared OIDC client secret RHBK issues to every federating devtool. **Fully Terraform-generated** (`random_password`, 40 chars, `special = false`) — no human input, no SSM prerequisite to set.
   - `/devops/terraform-created/cloudflare/origin-ca-root-cert` — Cloudflare's public Origin CA root cert, statically committed under `files/` in this module (not sensitive — same value for every Cloudflare customer), so every devtool's `ExternalSecret` can reference one shared value instead of duplicating the PEM across `devtools-provision` charts.
2. Deliberate consolidation: `rds`'s DB password and `devtools-secrets`'s admin password both read the same `/devops/prerequisite/generic-password` value — one human-set secret instead of two separate `TF_VAR_*` prompts.

**backup module:**
1. An `aws_backup_vault` (primary region) plus a second `aws_backup_vault` in `us-east-1` (`provider = aws.dr`) as a cross-region DR copy target — a second, independent layer on top of RDS's own automated backups, specifically to survive an accidental or deliberate `rds:DeleteDBSnapshot`/`ec2:DeleteSnapshot` from the same broad admin role that could delete the primary-region originals.
2. Covers the RDS instance (by ARN) and anything tagged `BackupManaged=true` (currently the EFS shared-home filesystem from the `eks` module), on a daily plan with a cross-region copy action.
3. **Not Vault-Locked yet, by deliberate choice** — left unlocked so behavior can be observed first. Locking later (`aws_backup_vault_lock_configuration`) is a one-way door if COMPLIANCE mode is used (irreversible for `min_retention_days`, not even by root/AWS support) — confirm that tradeoff explicitly before adding it; GOVERNANCE mode (`changeable_for_days` set) stays overridable within that window.

## Prerequisites

**`/devops/prerequisite/generic-password` (SecureString)** — the one shared password a human sets by hand before the first apply of `rds`, `domain-controller`, or `devtools-secrets`. It is read via a `data "aws_ssm_parameter"` lookup and republished by each module to its own `terraform-created` path (RDS master password, domain-controller admin/DSRM password, the shared devtools admin password). **No `TF_VAR_*` export is needed anymore for any of these** — this replaced the old per-module interactive password prompts. The only `sensitive` Terraform variable left anywhere in this repo (`domain-controller`'s `sample_user_password`) has a hardcoded default, so it never prompts either.
```bash
aws ssm put-parameter \
  --name /devops/prerequisite/generic-password \
  --type SecureString \
  --value '<choose-a-password>' \
  --profile 342831714456_Workload-Admin-PS \
  --region il-central-1
```

**License SSM parameters** (`SecureString`, set by hand before the devtools Applications sync):
- `/devops/prerequisite/bitbucket/license` — auto-applied via the Bitbucket Helm chart's `ExternalSecret` support.
- `/devops/prerequisite/confluence/license` — same, auto-applied.
- `/devops/prerequisite/jira/license` — Jira's chart has **no** auto-apply mechanism; a human pastes this into the browser setup wizard during Jira's first run.

**Cloudflare tunnel credentials in SSM Parameter Store** — a `SecureString` at `/devops/prerequisite/cloudflare/tunnel-credentials` (already populated). Must be set **before** the first `eks` apply, not after — that apply's `null_resource.wait_for_cluster_apps` blocks on `cloudflared` reaching Healthy, and `cloudflared` can't start without this parameter (`external-secrets-operator` syncs it, handled automatically by the `clusters-applicationset` ordering). To rotate later:
```bash
aws ssm put-parameter \
  --name /devops/prerequisite/cloudflare/tunnel-credentials \
  --type SecureString \
  --value "$(cat ~/.cloudflared/<tunnel-id>.json)" \
  --overwrite \
  --profile 342831714456_Workload-Admin-PS \
  --region il-central-1
```
The path must match `tunnelCredentialsSsmParameter` in `devtools-definition/devtools/cloudflared/values.yaml`, and fall under the `arn:aws:ssm:*:*:parameter/devops/*` prefix the `external-secrets` IRSA role is allowed to read (see `terraform/modules/eks/iam.tf`'s `external_secrets_ssm_read` policy).

**Cloudflare Origin CA certificate in SSM Parameter Store** — two `SecureString`s, `/devops/terraform-created/cloudflare/origin-cert-crt` and `/devops/terraform-created/cloudflare/origin-cert-key` (already populated), consumed by `clusters-provision/clusters/ingress-nginx`'s `origin-cert-secret.yaml` so `cloudflared` can connect to nginx-ingress over real HTTPS instead of plain HTTP. The private key was generated locally (never sent to Cloudflare — only a CSR derived from it was), so there's no `put-parameter` rotation snippet here the way there is for tunnel credentials; regenerate both via a fresh CSR/cert if the key is ever compromised. Separately, the **root CA cert** (public, not sensitive) is republished by the `devtools-secrets` module at `/devops/terraform-created/cloudflare/origin-ca-root-cert` for devtool JVM truststores.

`terraform/live/devtools/cloudflare` looks up this cert (and the tunnel) read-only for visibility, via `origin_ca_certificate_id`/`tunnel_id` inputs — see that module's `main.tf` for why it's a `data` source lookup and not a managed `resource`. To find the cert ID for that input:
```bash
curl -s "https://api.cloudflare.com/client/v4/certificates?zone_id=148024e9103dc1676dc7bf81d9363603" \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" | jq '.result[] | {id, hostnames, expires_on}'
```
(Origin CA endpoints sometimes require the account's dedicated Origin CA Key — `X-Auth-User-Service-Key` header — instead of a scoped API token; if the above 403s, that's why.)

**Cloudflare DNS CNAME** — each subdomain must point to `7de872ce-2826-42fb-9aea-325e10e3e5fc.cfargotunnel.com`. Managed via Terraform now — see the `dns_records` map in `terraform/live/devtools/cloudflare/terragrunt.hcl` (the parent `CLAUDE.md`'s curl steps are the old manual fallback only).

**Bitbucket push access** — Bitbucket is the sole source of truth for `devops-tashtiot` app repos; developers push directly into it over HTTPS at the same `bitbucket.devopstashtiot.page` hostname the web UI uses (no dedicated hostname or `cloudflared` ingress rule needed — plain HTTPS through the existing catch-all rule). Since a `git push` can't go through Access's browser email-OTP flow, it authenticates with a service token (`cloudflare_zero_trust_access_service_token.bitbucket_push`, published to `/devops/terraform-created/cloudflare/wildcard-access-otp-bypass-client-id`/`-client-secret`) sent as `CF-Access-Client-Id`/`CF-Access-Client-Secret` headers, via a non-identity policy on the shared `*.devopstashtiot.page` wildcard Access application — both in `terraform/modules/cloudflare/main.tf`. Full client-side usage is in the top-level `devops/CLAUDE.md`'s "Bitbucket push access" section.

**The `eks` unit needs no pre-existing AMI** — it uses the standard EKS-optimized AL2023 AMI that EKS resolves itself for its managed node groups.

## Apply Workflow

```bash
cd terraform/live/devtools/eks
terragrunt apply   # slow — creates the cluster/node groups, installs ArgoCD, then blocks until clusters-applicationset's apps are Healthy before registering devtools-applicationset
```

**ArgoCD:** `https://argocd.devopstashtiot.page` — user `admin`, password is the shared value at `/devops/terraform-created/admin/password` in SSM Parameter Store.

### Applying all six units together

`terraform/live/devtools` has these six platform units, so a plain `terragrunt run-all` from that directory applies/destroys all of them — no scoping needed. Since none depends on another, they run in parallel. No unit prompts interactively anymore (see Prerequisites) as long as `/devops/prerequisite/generic-password` is already set in SSM.

```bash
cd terraform/live/devtools
terragrunt run-all plan       # dry run
terragrunt run-all apply      # apply (interactive approval)
terragrunt run-all destroy
```

**Cost note:** `rds` defaults to `db.t3.small` (autoscaling storage — not the smallest free-tier size). `domain-controller` defaults to `t3.small` (~$15/mo, **not** free-tier) and `instance_enabled = true` — running `run-all apply` creates it; set `instance_enabled = false` first if you only want other pieces. `eks`'s node groups run **On-Demand, not Spot** (see eks module notes above) — this is the most expensive unit in the repo. `backup` adds ongoing cross-region storage cost proportional to what's backed up.

## Adding a New Service

1. Add an entry to the `dns_records` map in `terraform/live/devtools/cloudflare/terragrunt.hcl` for `mytool.devopstashtiot.page` and `terragrunt apply` that unit.
2. Deploy the service to the cluster (normally via the sibling `-provision`/`-definition` repos, not directly).
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
aws eks update-kubeconfig --name devtools-eks --region il-central-1 --profile 342831714456_Workload-Admin-PS

# Check pods
kubectl get pods -n argocd
kubectl get pods -n kube-system | grep -E "nginx|cloudflared"

# Reach a node or the domain controller without SSH (no bastion, no key pair)
aws ssm start-session --target <instance-id>
```

## AWS Account & Region

| Setting | Value |
|---|---|
| Account | `342831714456` |
| Region | `il-central-1` |
| AWS profile | `342831714456_Workload-Admin-PS` |
| Terraform state bucket | `terraform-state-342831714456` |
| EKS cluster name | `devtools-eks` |

## Key Design Decisions

- **No AWS load balancer** — `cloudflared` dials out to Cloudflare; `nginx-ingress` is ClusterIP. Zero LB cost.
- **ArgoCD runs insecure** (`--insecure` flag) — TLS is terminated at Cloudflare; acceptable for a dev platform.
- **No new VPC/NAT/EIP** — `eks`, `rds`, and `domain-controller` all reuse the account's existing spoke subnets; this account's Horizon LZ SCPs block creating those resources outright regardless.
- **On-Demand over Spot for `eks` node groups** — hit a real Spot failure mode in practice (capacity exhaustion), not a default/oversight.
- **One shared prerequisite password (`generic-password`) instead of per-module secrets** — deliberate simplification; this platform doesn't need per-resource credentials, and it collapses what used to be three separate interactive `TF_VAR_*` prompts into one SSM parameter set once.
