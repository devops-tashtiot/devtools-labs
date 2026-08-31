# Bootstrap from Scratch

End-to-end sequence for standing up this platform in a brand-new (or fully
destroyed) AWS account: bootstrap remote state, apply all six Terragrunt
units, then finish the manual per-devtool configuration that isn't
GitOps-managed.

!!! important "devtools-labs creates the whole cluster + devtools stack automatically"
    Terraform in this repo only ever touches six things: `eks`, `rds`,
    `domain-controller`, `cloudflare`, `devtools-secrets`, `backup`. It never
    runs Helm or `kubectl apply` against an individual cluster-infra tool or
    devtool. Instead, the `eks` unit's apply creates the cluster, installs
    ArgoCD, and registers two `ApplicationSet`s — `clusters-applicationset`
    and `devtools-applicationset` — that **auto-discover every chart** in the
    `clusters-provision`/`devtools-provision` repos and **auto-sync** them
    against the matching overrides in `clusters-definition`/
    `devtools-definition`. From the moment that apply finishes, every cluster
    infra tool (ingress, secrets sync, tunnel) and every devtool (Jira,
    Bitbucket, Confluence, Artifactory, ArgoCD) is created, updated, and kept
    in sync continuously — with no further Terraform, Helm, or `kubectl`
    command from you.

## 1. Bootstrap: `aws-terraform-bootstrap`

Before any Terragrunt unit in this repo can run, the S3 bucket its
`remote_state` block points at — `terraform-state-342831714456` (see
`terraform/root.hcl`) — has to already exist. That bucket is created by a
separate, one-time repo:
[`devops-tashtiot/aws-terraform-bootstrap`](https://github.com/devops-tashtiot/aws-terraform-bootstrap).

It's plain Terraform (no Terragrunt, no remote state of its own — its own
state is local) that creates exactly one thing:

- S3 bucket `terraform-state-<account_id>`, versioned, AES256-encrypted,
  all public access blocked

This bucket is shared across **every** project repo in the account, not just
`devtools-labs` — each project keys its state under its own prefix inside it
(`devtools-labs/...` here).

```bash
git clone https://github.com/devops-tashtiot/aws-terraform-bootstrap
cd aws-terraform-bootstrap
terraform init
terraform apply
```

Run this **once per AWS account**, using the `342831714456_Workload-Admin-PS`
profile. Skip it entirely if the bucket already exists (e.g. any subsequent
`devtools-labs` rebuild in the same account).

## 2. Prerequisite: SSM parameters you set by hand

Before any of the SSM values below can be set, **a real domain has to exist and be active on
Cloudflare** — the `/devops/prerequisite/cloudflare/tunnel-credentials` row needs a domain to
create a tunnel against in the first place, and the `cloudflare` Terraform unit needs an active
zone to look up. This isn't optional or something Terraform can create for you (see
[SCP Limitations](https://devops-tashtiot.github.io/docs/aws/scp-limitations/) — Route53 is
blocked wholesale in this AWS account regardless, so DNS was never going to come from AWS side
either way).

!!! tip "You don't need to buy a domain to follow this guide"
    The [GitHub Student Developer Pack](https://education.github.com/pack) includes a free
    domain (via Namecheap, typically a `.me` for one year, renewable while you're a student) with
    free DNS management included. Point that domain's nameservers at Cloudflare (a free-plan
    zone, same as this platform's own `devopstashtiot.page` setup) and everything in this guide
    works with zero cost for the domain itself — only the AWS resources underneath cost anything.

A handful of values have to exist in SSM Parameter Store **before** the
first `terragrunt apply` — Terraform reads them as data sources rather than
prompting for them or generating them itself. Set each with
`aws ssm put-parameter --type SecureString --overwrite`:

| Parameter | Used by | Notes |
|---|---|---|
| `/devops/prerequisite/generic-password` | `rds` (master DB password) and `devtools-secrets` (shared devtools admin password) | One value, deliberately shared — this platform doesn't need separate credentials per resource. Both modules read the same parameter via a `data "aws_ssm_parameter"` lookup; neither owns its lifecycle. |
| `/devops/prerequisite/bitbucket/license` | Bitbucket's Helm release (`licenseSsmParameter`) | Get this from your Atlassian license/trial account. Auto-applied via an ExternalSecret — the chart supports this natively. |
| `/devops/prerequisite/confluence/license` | Confluence's Helm release (`licenseSsmParameter`) | Same as above — auto-applied. |
| `/devops/prerequisite/jira/license` | Read manually during Jira's first-run setup wizard | Jira's chart has **no** auto-apply mechanism for a license or sysadmin account (confirmed against the upstream chart + Atlassian docs — no equivalent of Bitbucket's `licenseSsmParameter` wiring exists for Jira), so this value is never read by Terraform, Helm, or an ExternalSecret — only by a human, via `aws ssm get-parameter --name /devops/prerequisite/jira/license --with-decryption`, pasted into the browser wizard. See [`post-devtools-implementation/jira`](post-devtools-implementation/jira/README.md). |
| `/devops/prerequisite/cloudflare/tunnel-credentials` | `cloudflared`'s ExternalSecret (`tunnelCredentialsSsmParameter` in `clusters-definition/clusters/cloudflared/values.yaml`) | The one-time output of `cloudflared tunnel create <name>` (a JSON file at `~/.cloudflared/<tunnel-id>.json`) — `aws ssm put-parameter --name /devops/prerequisite/cloudflare/tunnel-credentials --type SecureString --value "$(cat ~/.cloudflared/<tunnel-id>.json)"`. This one matters for `terragrunt apply` to actually finish, not just for a devtool to work afterward: the `eks` unit's apply blocks on `clusters-applicationset` reaching Healthy, and `cloudflared` (part of that first wave) can never start without it — set this **before** running `terragrunt apply`, not after. |

`domain-controller`'s `admin_password`/`ldap_bind_password` are **not** part
of this prerequisite-SSM pattern — they stay as interactive `TF_VAR_*`
prompts (see the next section). That's a deliberate exception: consolidating
them onto the shared generic password would mean a future password rotation
also rotates the domain controller's DSRM/local Administrator credential,
which risks an unrecoverable AD forest if it goes wrong mid-promotion.

## 3. Apply all six units in `devtools-labs`

Once the state bucket and prerequisite SSM parameters above exist,
`terraform/live/devtools` has six independent Terragrunt units — `eks`,
`rds`, `domain-controller`, `cloudflare`, `devtools-secrets`, `backup` — with
no dependency graph between them (see `devtools-labs/CLAUDE.md` → "Six
independent units"). `terragrunt run-all apply` from that directory runs all
of them in parallel:

```bash
cd terraform/live/devtools
terragrunt run-all plan     # dry run
terragrunt run-all apply
```

`run-all apply` will still prompt interactively for `domain-controller`'s
`admin_password`/`ldap_bind_password` (no default, not sourced from the
prerequisite SSM pattern — see above). Export the matching `TF_VAR_*` env
vars beforehand to avoid an interactive prompt mid-`run-all`.

### What this apply actually does

- **`rds`** — a Postgres RDS instance (`db.t3.small`, autoscaling storage)
  devtools like Bitbucket use as an external database; its master password
  comes from `/devops/prerequisite/generic-password`, republished to
  `/devops/terraform-created/rds/admin-password` for devtool init containers
  to read.
- **`domain-controller`** — a Windows Server 2022 EC2 instance (`t3.small`,
  ~$15/mo, **not** free-tier), optionally promoted to an AD forest for
  testing LDAP integration; publishes admin/LDAP-bind creds to
  `/devops/terraform-created/domain-controller/...`.
- **`cloudflare`** — the Cloudflare zone, DNS CNAME records per subdomain,
  and the Access policy; read-only lookups of the tunnel and Origin CA cert.
- **`devtools-secrets`** — the shared `/devops/terraform-created/admin/password`
  every devtool uses as its initial admin password (sourced from the same
  prerequisite generic password as `rds`), plus the shared RHBK OIDC client
  secret.
- **`backup`** — an AWS Backup vault + daily plan covering the RDS instance
  and any resource tagged `BackupManaged=true` (currently the EFS
  shared-home filesystem), with a cross-region copy action to a second vault
  in `us-east-1` — a regional incident, or anything with the same broad
  reach as whatever caused an incident in the primary region, can't touch a
  copy that already landed in a second region.
- **`eks`** — the real bootstrap, and the slow one:
    1. Creates a multi-node, multi-AZ EKS cluster
       (`terraform-aws-modules/eks/aws`) in the existing `spokeSubnet1`/
       `spokeSubnet2` pair — no new NAT/VPC resource, their existing
       `0.0.0.0/0` route already goes through a pre-existing shared VPC
       endpoint. No custom AMI to build or look up — EKS resolves the
       standard EKS-optimized AL2023 AMI itself for both Managed Node Groups
       (`devtools`: general-purpose, spans both AZs; `devtools-large`: a
       dedicated lane sized for Confluence's 4-core CPU request, which the
       primary group's smallest instance type can never satisfy). Both node
       groups' IAM roles carry `AmazonSSMManagedInstanceCore`, so any node
       is reachable via AWS Systems Manager Session Manager — no SSH, no
       bastion, no key pair to manage.
    2. Installs the `gp3` (EBS, `reclaimPolicy: Delete`, node-local volumes)
       and `efs-sc` (EFS, `reclaimPolicy: Retain`, `ReadWriteMany`) storage
       classes, and provisions the EFS filesystem `efs-sc` points at —
       shared-home storage for Bitbucket/Jira/Confluence, matching
       Atlassian's own Data Center `SHARED_STORAGE` pattern.
    3. Installs ArgoCD via Helm (`ClusterIP`, `--insecure` — TLS terminates
       at Cloudflare) using this module's own `helm`/`kubectl` Terraform
       providers — no bash `user_data` script.
    4. Registers the `clusters-applicationset` app-of-apps, which
       **auto-discovers every chart under `clusters-provision/clusters/*`**
       and auto-syncs it with the matching overrides from
       `clusters-definition` — `ingress-nginx`, `cloudflared`,
       `external-secrets-operator` all get created this way, with no manual
       `helm install`/`kubectl apply`. The unit blocks here until all three
       report Synced+Healthy.
    5. Registers the `devtools-applicationset` app-of-apps last, which the
       same way **auto-discovers every chart under
       `devtools-provision/devtools/*`** and auto-syncs it against
       `devtools-definition` — Jira, Bitbucket, Confluence, Artifactory,
       ArgoCD's own `Ingress`, etc. **From this point on, ArgoCD creates and
       continuously reconciles everything else itself** — Terraform never
       touches an individual cluster-infra tool or devtool, not even once.

Once `eks`'s apply finishes, ArgoCD is reachable at
`https://argocd.devopstashtiot.page` — user `admin`, password is the shared
value at `/devops/terraform-created/admin/password` in SSM Parameter Store — and every
devtool Application should show up Syncing/Healthy over the following few
minutes as ArgoCD works through `devtools-applicationset`.

## 4. How Cloudflare routes traffic into the cluster

See [Cloudflare/CoreDNS request-flow architecture](architecture.md) for the
full walkthrough — a browser's path through Cloudflare Access/Tunnel vs. an
in-cluster caller's path via the CoreDNS rewrite, and why both matter.

## 5. Post-installation configuration for the devtools

ArgoCD deploying a devtool's Helm release only gets it running — a few
things per tool aren't GitOps-managed and need a manual, one-time pass once
the pod is up. These live in [`post-devtools-implementation/`](post-devtools-implementation/jira/README.md).

!!! note "Admin passwords, licenses, and LDAP connection details all come from SSM"
    None of these are typed into a wizard from memory or invented on the
    spot — every one of them lives in SSM Parameter Store, sourced either
    from the prerequisite parameters in section 2 above or from a
    `/devops/terraform-created/...` path Terraform publishes automatically.
    Each tool's page below gives the exact parameter name.

| Tool | Covers |
|---|---|
| [`jira`](post-devtools-implementation/jira/README.md) | Setup wizard, LDAP/AD user directory + schema mapping, SSO (RHBK/OIDC) |
| [`confluence`](post-devtools-implementation/confluence/README.md) | Setup wizard, LDAP/AD user directory + schema mapping, SSO (RHBK/OIDC) |
| [`bitbucket`](post-devtools-implementation/bitbucket/README.md) | LDAP/AD user directory + schema mapping, SSO (RHBK/OIDC), API token for `devops-api` |
| [`argocd`](post-devtools-implementation/argocd/README.md) | API token for `devops-api` (ArgoCD needs no manual LDAP/SSO setup — it federates through RHBK/OIDC automatically) |

Common thread across Jira/Confluence/Bitbucket: the LDAP/AD directory
against `domain-controller` and the SSO client secret both have to be pasted
in through each tool's admin UI by hand — unlike ArgoCD, which wires its
OIDC client secret automatically via `oidcClientSecretSsmParameter`. See
each tool's page for exact connection settings, schema mapping, and the
"follow referrals must be disabled" gotcha they all share.
