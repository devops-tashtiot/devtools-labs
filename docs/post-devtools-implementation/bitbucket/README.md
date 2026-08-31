# Post-Deployment Setup — Bitbucket

After `devtools-provision`/`devtools-definition` deploy Bitbucket's Helm
release, these manual steps remain before it's fully usable:

1. **User Directory (LDAP/AD)** — one-time admin UI configuration
2. **SSO (RHBK/OIDC)** — optional, on top of the directory above
3. **API Token for devops-api** — required for `devops-api`'s Git integration

No setup-wizard step is listed here because, unlike Jira/Confluence,
Bitbucket's license and first admin account are both fully automated: the
license comes from `/devops/prerequisite/bitbucket/license` (set this before
first deploy; see `devtools-labs/docs/bootstrap.md`) via an `ExternalSecret`
into `bitbucket.license.secretName`/`secretKey`
(`devtools-provision/devtools/bitbucket/values.yaml`), and the admin account
is created with the shared admin password
(`/devops/terraform-created/admin/password`) — nothing to do in a browser
wizard for either.

---

## 1. User Directory (LDAP/AD)

Bitbucket authenticates against the platform's AD domain controller
(`devtools-labs/terraform/modules/domain-controller`) instead of maintaining
its own local user base. There's no Helm value or automated setup for this —
it's a one-time manual configuration in Bitbucket's admin UI after initial
deploy.

**Where:** Administration → **Security** → **Directories** → **Add
Directory** → Microsoft Active Directory (Bitbucket Data Center uses the same
Atlassian Embedded Crowd component as Jira/Confluence, so the screen and
field names below match Jira's directory config almost exactly).

### Connection Settings

| Field | Value | Why |
|---|---|---|
| Directory Type | Microsoft Active Directory | |
| Hostname | the domain controller's current private IP (`aws ec2 describe-instances` on the `WIN-SRV-01` instance, or the `/devops/terraform-created/domain-controller/ldap-connection-url` SSM parameter) | see callout below — do **not** use the domain DNS name here |
| Port | `389` | Plain LDAP, not LDAPS — the domain controller isn't configured for TLS on the LDAP port |
| Use SSL | **No** | matches the plain `ldap://` scheme above |
| Username | the bind account's UPN, `<bind-username>@devtools.local` (username from `/devops/terraform-created/domain-controller/ldap-bind-username`) | same bind account RHBK's `set-ldap-credentials-job.yaml` uses |
| Password | fetch with `aws ssm get-parameter --name /devops/terraform-created/domain-controller/ldap-bind-password --with-decryption` | never commit this value anywhere |
| Base DN | `DC=devtools,DC=local` (domain root — published to SSM at `/devops/terraform-created/domain-controller/base-dn`) | **Deliberately not** the OU-scoped `OU=devops-tashtiot,DC=devtools,DC=local` — everything the domain controller creates today lives inside that one OU, but a real AD user created elsewhere in the domain later would be permanently invisible to Bitbucket if the Base DN stayed OU-scoped (subtree search only reaches down from the Base DN, never sideways). Accepted tradeoff: AD's own built-in accounts (`Administrator`, `Guest`, `krbtgt`) also come into scope and are not filtered out below — see the User Object Filter row. |

> **Hostname must be an IP, not `devtools.local`:** there is no DNS zone for
> the AD domain configured anywhere in this platform (no CoreDNS stub domain,
> no `hostAliases`, no Route53 private hosted zone).

### Advanced Settings — Enable Nested Groups

Check **"Enable Nested Groups"**. Everything else on this form — schema
mapping, Follow Referrals, and so on — is already correct at Bitbucket's own
defaults for a Microsoft Active Directory directory type; confirmed against
the live instance, nothing else needs changing.

Click "Test retrieve user", then save the directory and run a directory sync
so users/groups actually populate.

---

## 2. SSO (RHBK/OIDC)

The LDAP directory above enables one login path; RHBK/Keycloak SSO is a
second, independent one. Both can be active at once, and both ultimately
check the same AD credentials — they differ in *how* the user gets
authenticated, not *against what*.

**1. LDAP-backed username/password (Directory login)**

This is what configuring the directory above enables by default — no extra
setup. A user types their AD `sAMAccountName` and password into Bitbucket's
normal login form; Bitbucket binds to the directory as that user to verify
the password. Project/repo permissions are also driven by this directory's
group sync (the Membership schema configured above), independent of any SSO
login.

**2. SSO via RHBK (OIDC)**

A "Log in with RHBK" option, provided by Bitbucket 10.2.2's **built-in
Single sign-on** admin screen (Administration → Security → Single sign-on —
not the older Atlassian Marketplace SSO app), configured against the
`bitbucket` OIDC client in `clusters-definition/clusters/rhbk/values.yaml`.
This redirects to RHBK/Keycloak's `devtools` realm, which itself
authenticates against the *same* AD (via its own LDAP federation,
`clusters-provision/clusters/rhbk/templates/realm-import.yaml`) — so SSO
doesn't introduce a separate identity, just a Keycloak-brokered login flow
in front of it.

> **Important distinction:** SSO here only proves *identity* (who the user
> is). It does **not** carry authorization — `bitbucketClient` deliberately
> has no `groups` optionalClientScope (unlike `argocdClient`/
> `sonarqubeClient`), so Bitbucket's project/repo permissions still come
> entirely from this LDAP directory's own group sync, not from anything in
> the OIDC token.

**Already fixed, note for context:** Bitbucket's `redirectUri` is set to
`/plugins/servlet/oidc/callback` — Bitbucket's built-in SSO screen uses the
same first-party callback path as Jira/Confluence's built-in DC SSO feature
(not the older Atlassian Marketplace SSO app's `/plugins/servlet/
oauth/callback` path, originally assumed for all three — see
`../jira/README.md`). No action needed here unless this client
config regresses.

**User mapping must use `${preferred_username}`, not `${sub}` or
`${sAMAccountName}`:** same issue as documented in `../jira/README.md`'s SSO
section — Bitbucket's SSO admin screen also has a "user mapping" field, and
`${sub}` (Keycloak's own internal ID for federated users, not actually
derived from AD's `objectGUID` despite the LDAP federation provider's
`uuidLDAPAttribute` setting) never resolves to a real local user. Use
`${preferred_username}` instead.

**Client Secret:** shared across all six RHBK OIDC clients
(`/devops/terraform-created/rhbk/oidc-client-secret`, Terraform-generated —
`devtools-labs/terraform/modules/devtools-secrets`), but Bitbucket isn't
wired to SSM/ExternalSecret like ArgoCD/SonarQube/Grafana are — this value
must be pasted into Bitbucket's SSO client secret field manually, and
**manually updated again any time the secret rotates** (it won't
auto-propagate). Fetch the current value with:
```bash
aws ssm get-parameter --name /devops/terraform-created/rhbk/oidc-client-secret --with-decryption --profile 342831714456_Workload-Admin-PS --region il-central-1 --query "Parameter.Value" --output text
```

---

## 3. API Token for devops-api

`devops-api` authenticates to Bitbucket's REST API with a bearer token
(`GIT_TOKEN`), sourced from `/devops/postdeploy/bitbucket/api-token` via
ExternalSecret (see `devtools-definition/devtools/devops-api/values.yaml`'s
`vault.secrets`) — distinct from the AD/LDAP bind credentials used for the
`BITBUCKET_USERNAME`/`BITBUCKET_PASSWORD` fields elsewhere in that same file.

This token isn't created automatically. `scripts/bitbucket-post-deploy.sh` in
this repo automates both the token creation and the SSM publish below via
Bitbucket's access-tokens REST API — but that call needs Basic Authentication
enabled on this instance first, which is **off by default** on a fresh
Bitbucket DC install (confirmed by direct probe: it returns `403
"Basic Authentication has been disabled on this instance."` until enabled).
One-time fix, in the browser:
```
Administration → Accounts → Authentication methods
  → next to the default method: Actions → Edit
  → check "Allow basic authentication on API calls"
  → Save configuration
```
This same setting also gates the laptop `git push` pattern documented in the
parent `CLAUDE.md`'s Cloudflare section (Gotcha 3).

To do it by hand instead, generate a Bitbucket Personal Access
Token (Administration → Personal access tokens — either your own or a
dedicated service account's, scoped with repo read/write access), then
publish it:
```bash
aws ssm put-parameter --name /devops/postdeploy/bitbucket/api-token --type SecureString --value "<token>" --overwrite --profile 342831714456_Workload-Admin-PS --region il-central-1
```
Not GitOps-managed — rotate it the same way (manual `put-parameter`). The
parameter's own description already reflects this: "Not managed by
GitOps/Terraform — created and rotated manually."
