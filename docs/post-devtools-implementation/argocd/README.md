# Post-Deployment Setup — ArgoCD

After `devtools-provision`/`devtools-definition` deploy ArgoCD's Helm
release, this manual step remains:

1. **API Token for devops-api** — required for `devops-api`'s ArgoCD
   integration (cluster-secret management)

Unlike Jira/Confluence/Bitbucket, ArgoCD doesn't need its own AD/LDAP
directory configured — it authenticates via RHBK/OIDC only (the `argocd`
OIDC client in `clusters-definition/clusters/rhbk/values.yaml`, wired
automatically through ArgoCD's own `oidcClientSecretSsmParameter`, unlike
the three Atlassian tools which need their SSO client secret pasted in
manually — see `../jira/README.md`'s SSO section for why that's manual for
those three but not for ArgoCD).

---

## 1. API Token for devops-api

`devops-api` needs an ArgoCD API token to call ArgoCD's own API — see
`ARGOCD_CLUSTER_SECRET_REPO_URL`/`ARGOCD_ALLOWED_ENVS` in
`devtools-definition/devtools/devops-api/values.yaml`, the cluster-secret
management feature this token supports. This isn't created automatically.

Generate one (via the `argocd` CLI, authenticated as an admin or a
service account with appropriate RBAC):
```bash
argocd login argocd.devopstashtiot.page --sso   # or --username admin
argocd account generate-token --account <account-name>
```
Publish it to SSM:
```bash
aws ssm put-parameter --name /devtools/argocd/api-token --type SecureString --value "<token>" --overwrite --profile 342831714456_Workload-Admin-PS --region il-central-1
```
Not GitOps-managed — rotate it the same way (manual `put-parameter`), same
as Bitbucket's `/devtools/bitbucket/api-token`.

> **Wiring status as of 2026-07-14:** this parameter exists and is
> populated, but `devtools-definition/devtools/devops-api/values.yaml`'s
> `vault.secrets` list only sources `GIT_TOKEN` from Bitbucket's token today
> — there's no `ARGOCD_TOKEN`-style entry yet. Wire one in alongside
> `GIT_TOKEN` once `devops-api`'s cluster-secret feature is ready to consume
> it from an env var; until then this token exists for direct/manual API use
> only.
