# Bootstrap from Scratch

End-to-end sequence for standing up this platform in a brand-new (or fully
destroyed) AWS account: bootstrap remote state, apply all five Terragrunt
units, then finish the manual per-devtool configuration that isn't
GitOps-managed.

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

## 2. Apply all five units in `devtools-labs`

Once the state bucket exists, `terraform/live/devtools` has five independent
Terragrunt units — `minikube`, `rds`, `domain-controller`, `cloudflare`,
`devtools-secrets` — with no dependency graph between them (see
`devtools-labs/CLAUDE.md` → "Five independent units"). `terragrunt run-all
apply` from that directory runs all five in parallel:

```bash
cd terraform/live/devtools
terragrunt run-all plan     # dry run
terragrunt run-all apply
```

### Prerequisite: the Minikube base AMI

The `minikube` module looks up the latest AMI matching
`minikube-devtools-base-*`. On a fresh account none exists yet — build it
first via the separate
[`devops-tashtiot/minikube-ami`](https://github.com/devops-tashtiot/minikube-ami)
Packer template. `devtools-labs/CLAUDE.md` → "Building the Minikube base AMI"
has the exact one-time bootstrap + `packer build` commands (it needs a
security group / IAM instance profile from the `minikube` unit to exist
first, via a `-target`ed partial apply).

`run-all apply` will prompt interactively for every sensitive variable with
no default, across whichever units happen to run first: `rds`'s
`db_password`, `domain-controller`'s `admin_password`/`ldap_bind_password`,
`devtools-secrets`' `admin_password`. Export the matching `TF_VAR_*` env vars
beforehand to avoid juggling simultaneous prompts.

### What this apply actually does

- **`rds`** — a Postgres RDS instance (`db.t3.micro`/20GB, free-tier) devtools
  like Bitbucket use as an external database; publishes admin creds to SSM.
- **`domain-controller`** — a Windows Server 2022 EC2 instance (`t3.small`,
  ~$15/mo, **not** free-tier), optionally promoted to an AD forest for
  testing LDAP integration; publishes admin/LDAP-bind creds to SSM.
- **`cloudflare`** — the Cloudflare zone, DNS CNAME records per subdomain,
  and the Access policy; read-only lookups of the tunnel and Origin CA cert.
- **`devtools-secrets`** — the shared `/devtools/admin/password` every devtool
  uses as its initial admin password, plus the shared RHBK OIDC client
  secret.
- **`minikube`** — the real bootstrap, and the slow one (~15-20 min):
    1. Boots an EC2 instance from the custom AMI, mounts the data volume,
       installs a `minikube.service` systemd unit so the cluster survives the
       nightly auto-stop.
    2. Installs ArgoCD via Helm inside Minikube (`ClusterIP`, `--insecure` —
       TLS terminates at Cloudflare).
    3. Registers the `clusters-applicationset` app-of-apps and blocks until
       `ingress-nginx`, `cloudflared`, and `external-secrets-operator` all
       report Synced+Healthy.
    4. Registers the `devtools-applicationset` app-of-apps last. **From this
       point on, ArgoCD deploys and manages everything else itself** — Jira,
       Bitbucket, Confluence, Artifactory, ArgoCD's own `Ingress`, etc. —
       Terraform never touches individual devtools again.

Once `minikube`'s apply finishes, ArgoCD is reachable at
`https://argocd.devopstashtiot.page` (`admin` / `123456`), and every devtool
Application should show up Syncing/Healthy over the following few minutes as
ArgoCD works through `devtools-applicationset`.

## 3. Post-installation configuration for the devtools

ArgoCD deploying a devtool's Helm release only gets it running — a few
things per tool aren't GitOps-managed and need a manual, one-time pass once
the pod is up. These live in [`post-devtools-implementation/`](post-devtools-implementation/jira/README.md):

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
