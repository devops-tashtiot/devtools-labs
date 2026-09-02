# Post-Deployment Setup — ArgoCD

After `devtools-provision`/`devtools-definition` deploy ArgoCD's Helm
release, **no manual step is required** — unlike Jira/Confluence/Bitbucket/
Woodpecker, ArgoCD's login, authorization, and its one service-to-service
integration (`devops-api`) are all fully automated.

## Why nothing manual is needed here

**Human login (RHBK/OIDC):** ArgoCD authenticates via RHBK/OIDC only — no
AD/LDAP directory to configure the way Jira/Confluence/Bitbucket need (see
`../jira/README.md`'s directory section for contrast). The `argocd` OIDC
client's secret is wired automatically through ArgoCD's own
`oidcClientSecretSsmParameter`, unlike those three Atlassian tools which
need their SSO client secret pasted into the product's UI by hand.

**Authorization is automatic too, unlike the Atlassian tools:** `argocdClient`
is one of the few RHBK clients with the `"groups"` `optionalClientScope`
attached (see `clusters-definition/clusters/rhbk/values.yaml` — Jira/
Confluence/Bitbucket's clients deliberately don't have this), so a login's
OIDC token actually carries real AD group membership as a claim. ArgoCD's
own RBAC (`devtools-definition/devtools/argocd/values.yaml`'s `policy.csv`)
already binds that group to admin:

```
g, devops-tashtiot, role:admin
```

committed in git, applied on every Helm sync — so there's no Bitbucket/
Confluence/Jira-style "grant the Terraform-created AD group admin" manual
step to do here at all; anyone in `devops-tashtiot` is already an ArgoCD
admin the moment they log in.

**`devops-api`'s integration is a fully automated service account, not a
manually-generated API token:** an earlier version of this doc described
generating an ArgoCD API token by hand via the `argocd` CLI and publishing
it to `/devops/postdeploy/argocd/api-token`. That's now stale — checked
directly against `devtools-definition/devtools/devops-api/values.yaml` and
`clusters-provision/clusters/rhbk`: `/devops/postdeploy/argocd/api-token`
isn't referenced anywhere in either repo any more. `devops-api` instead
authenticates to ArgoCD's API via a dedicated OIDC `client_credentials`
service account (`argocdServiceClient` in
`clusters-provision/clusters/rhbk/templates/realm-import.yaml`), whose
secret is the same shared value every RHBK client uses
(`/devops/terraform-created/rhbk/oidc-client-secret`, sourced as
`ARGOCD_SSO_CLIENT_SECRET`) — no distinct credential to create or rotate.
Since a service account has no real AD group membership, the client
carries a synthetic `"groups"` claim via a dedicated
`devops-api-argocd-audience` protocol mapper, bound in the same
`policy.csv` above to a deliberately narrow role (`devops-api-argocd-svc`
— `applications: get/create/update/delete/sync` on the `default` project
only, not `role:admin`):

```
p, role:devops-api-argocd-svc, applications, get, default/*, allow
p, role:devops-api-argocd-svc, applications, create, default/*, allow
p, role:devops-api-argocd-svc, applications, update, default/*, allow
p, role:devops-api-argocd-svc, applications, delete, default/*, allow
p, role:devops-api-argocd-svc, applications, sync, default/*, allow
g, devops-api-argocd-svc, role:devops-api-argocd-svc
```

All of this ships in git and applies automatically — there is currently
nothing for `scripts/` to automate or a human to do post-deploy.
