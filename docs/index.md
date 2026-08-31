# devtools-labs

Terraform + Terragrunt infra for the self-hosted devtools platform: a real
multi-node/multi-AZ EKS cluster with ArgoCD bootstrapped inside it, an RDS
Postgres instance, EFS shared storage, a standalone Windows AD domain
controller, and cross-region AWS Backup. This is the only one of the
platform's five repos that runs real infrastructure code — from the moment
ArgoCD comes up, everything else (Jira, Bitbucket, Confluence, cluster-wide
infra) is deployed and managed by ArgoCD itself, via the sibling
`*-provision`/`*-definition` repos.

<div class="grid cards" markdown>

- :material-rocket-launch: **[Bootstrap from scratch](bootstrap.md)**

    Standing up the platform in a brand-new AWS account: the one-time state
    bucket, `terragrunt run-all apply`, and what each unit provisions.

- :material-wrench: **[Post-deployment setup](post-devtools-implementation/jira/README.md)**

    The manual, one-time steps per devtool that aren't GitOps-managed — LDAP
    directory config, SSO client secrets, API tokens.

- :material-sitemap: **[Architecture overview](overview.md)**

    What actually exists in AWS to bring the devtools platform up — the six
    Terraform units, and what each one owns.

</div>

## At a glance

| You want to… | Go to |
|---|---|
| Stand up the whole platform on a fresh account | [Bootstrap from scratch](bootstrap.md) |
| Set the prerequisite SSM parameters before first apply | [Bootstrap from scratch → Prerequisite](bootstrap.md#2-prerequisite-ssm-parameters-you-set-by-hand) |
| See the full resource map (EKS, RDS, EFS, backup, ...) | [Architecture overview](overview.md) |
| Understand how Cloudflare/CoreDNS route traffic into the cluster | [Cloudflare/CoreDNS routing](architecture.md) |
| Check Cloudflare's known limitations/gotchas before debugging | [Cloudflare limitations & gotchas](cloudflare-limitations.md) |
| Look up any SSM parameter — who creates it, who reads it | [SSM Parameter Reference](ssm-parameters.md) |
| Configure Jira's LDAP directory + SSO | [Post-deployment: Jira](post-devtools-implementation/jira/README.md) |
| Configure Confluence's LDAP directory + SSO | [Post-deployment: Confluence](post-devtools-implementation/confluence/README.md) |
| Configure Bitbucket's LDAP directory + SSO + API token | [Post-deployment: Bitbucket](post-devtools-implementation/bitbucket/README.md) |
| Generate ArgoCD's API token for `devops-api` | [Post-deployment: ArgoCD](post-devtools-implementation/argocd/README.md) |
| Register Woodpecker's Bitbucket Application Link (required for login) | [Post-deployment: Woodpecker](post-devtools-implementation/woodpecker/README.md) |

For the full repo/module architecture, prerequisites, and design decisions,
see `CLAUDE.md` at the repo root — these docs cover the *procedures*; that
file covers the *why*.

!!! note "Reading these docs"
    ```bash
    pip install mkdocs-material
    mkdocs serve   # from the repo root — http://127.0.0.1:8000
    ```
