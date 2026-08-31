# SSM Parameter Reference

Every SSM Parameter Store value this platform reads or writes, in one place, grouped by who
creates it and when. All paths live under `/devops/<category>/...`, where the category tells you
what to expect:

- **`prerequisite`** — a human sets this once, by hand, **before** the first `terragrunt apply`.
  Terraform only ever reads these (`data "aws_ssm_parameter"` lookups) — it never owns their
  lifecycle or generates a value for them.
- **`terraform-created`** — Terraform creates and manages the value automatically. Don't edit
  these manually; changes get reverted on the next apply.
- **`postdeploy`** — a human creates this **after** the cluster is up, as a one-time manual step
  per devtool (an API token, an OAuth client secret from a UI you have to click through). See each
  tool's own page under `post-devtools-implementation/` (linked in the table below) for the full
  walkthrough.

---

## Prerequisite (set by hand before first apply)

| Parameter | Used by |
|---|---|
| `/devops/prerequisite/generic-password` | `rds` (master DB password), `devtools-secrets` (shared devtools admin password), `domain-controller` (Administrator/DSRM + LDAP-bind account passwords) — one shared value across all of them |
| `/devops/prerequisite/bitbucket/license` | Bitbucket's Helm release, auto-applied via ExternalSecret |
| `/devops/prerequisite/confluence/license` | Confluence's Helm release, auto-applied via ExternalSecret |
| `/devops/prerequisite/jira/license` | Read manually during Jira's first-run setup wizard — no auto-apply mechanism exists for Jira |
| `/devops/prerequisite/cloudflare/tunnel-credentials` | `cloudflared`'s ExternalSecret — the one-time output of `cloudflared tunnel create` |

Full detail on each, including exactly how to obtain the value: see
[Bootstrap from scratch → Prerequisite](bootstrap.md#2-prerequisite-ssm-parameters-you-set-by-hand).

## Terraform-created (automatic, do not edit)

| Parameter | Created by | Consumed by |
|---|---|---|
| `/devops/terraform-created/rds/admin-username` | `rds` | Devtool init containers provisioning their own databases |
| `/devops/terraform-created/rds/admin-password` | `rds` (value sourced from `generic-password`) | Same |
| `/devops/terraform-created/admin/password` | `devtools-secrets` (value sourced from `generic-password`) | Every devtool's initial admin login |
| `/devops/terraform-created/rhbk/oidc-client-secret` | `devtools-secrets` (`random_password`, fully generated) | Every devtool's OIDC client federating SSO through RHBK |
| `/devops/terraform-created/cloudflare/origin-ca-root-cert` | `devtools-secrets` (static, publicly-published by Cloudflare) | Every devtool's JVM truststore, for outbound in-cluster TLS to `*.devopstashtiot.page` |
| `/devops/terraform-created/domain-controller/admin-username` | `domain-controller` | The instance's own boot script |
| `/devops/terraform-created/domain-controller/admin-password` | `domain-controller` (value sourced from `generic-password`) | The instance's own boot script |
| `/devops/terraform-created/domain-controller/ldap-bind-username` | `domain-controller` | RHBK's LDAP bind username |
| `/devops/terraform-created/domain-controller/ldap-connection-url` | `domain-controller` (refreshed on every apply) | RHBK's LDAP connection URL — a stable path since the instance's IP could change on replacement |
| `/devops/terraform-created/cloudflare/origin-cert-crt` / `-key` | `cloudflare` | `ingress-nginx`'s TLS secret, so `cloudflared` can connect over real HTTPS |
| `/devops/terraform-created/cloudflare/wildcard-access-otp-bypass-client-id` / `-client-secret` | `cloudflare` (`cloudflare_zero_trust_access_service_token`, fully generated) | Non-interactive Cloudflare Access authentication (e.g. pushing to Bitbucket from outside the cluster) — see [Cloudflare limitations & gotchas](cloudflare-limitations.md) for this token's actual (domain-wide) blast radius |

!!! note "RHBK's LDAP bind password isn't a separate parameter"
    There's no dedicated `ldap-bind-password` path — it would just duplicate
    `admin-password`'s value, since both source from the same `generic-password` secret. RHBK's
    `ldapBind.passwordSsmParameter` (`clusters-definition/clusters/rhbk/values.yaml`) points
    straight at `/devops/prerequisite/generic-password` instead of a redundant republished copy.

## Postdeploy (created by hand, after the cluster is up)

| Parameter | For | Set during |
|---|---|---|
| `/devops/postdeploy/bitbucket/api-token` | `devops-api`'s Bitbucket integration, Artifactory's Bitbucket Application Link | [Post-deployment: Bitbucket](post-devtools-implementation/bitbucket/README.md) |
| `/devops/postdeploy/bitbucket/git-ssh-private-key` | `devops-api`'s git operations against Bitbucket | [Post-deployment: Bitbucket](post-devtools-implementation/bitbucket/README.md) |
| `/devops/postdeploy/artifactory/api-token` | `devops-api`'s Artifactory integration | [Post-deployment: Artifactory](post-devtools-implementation/artifactory/README.md) |
| `/devops/postdeploy/argocd/api-token` | `devops-api`'s ArgoCD integration | [Post-deployment: ArgoCD](post-devtools-implementation/argocd/README.md) |
| `/devops/postdeploy/woodpecker/bitbucket-client-id` / `-client-secret` | Woodpecker's Bitbucket OAuth Application Link (required for login) | [Post-deployment: Woodpecker](post-devtools-implementation/woodpecker/README.md) |

---

## Related Topics

- [Bootstrap from scratch](bootstrap.md) — the full apply sequence these parameters gate
- [Architecture overview](overview.md) — what each Terraform unit actually creates
