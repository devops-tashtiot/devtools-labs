# Post-Deployment Setup — Bitbucket

After `devtools-provision`/`devtools-definition` deploy Bitbucket's Helm
release, these manual steps remain before it's fully usable:

1. **User Directory (LDAP/AD)** — one-time admin UI configuration
2. **Enable Basic Authentication** — one-time admin UI toggle, prerequisite for steps 4-5
3. **SSO (RHBK/OIDC)** — optional, on top of the directory above
4. **API Token for devops-api** — required for `devops-api`'s Git integration
5. **Admin group grant** — grants the Terraform-created AD group global admin on Bitbucket

`scripts/bitbucket-post-deploy.sh` walks through all five in this order, one
step at a time, pausing after each to confirm before printing the next.

> **You can just run the script instead of following this document by hand.**
> Everything below is the full written reference (and the fallback for doing
> any single step manually) — `scripts/bitbucket-post-deploy.sh` does the
> same walkthrough interactively, plus more:
> - **Fetches every value live from SSM** at run time (LDAP bind password,
>   base DN, OIDC client secret, license, AD admin group name, ...) and
>   prints it inline with the same explanation as this doc — so you're never
>   copy-pasting a stale value out of a markdown file or hunting for a
>   parameter name mid-wizard.
> - **Prints Steps 1-3's field-by-field instructions one at a time**,
>   pausing after each so you can go complete it in the browser before the
>   next step prints — you're never scrolling back through a wall of output
>   trying to figure out which step you're on.
> - **Live-checks Basic Authentication (Step 2)** against the running
>   instance instead of just telling you to check it yourself, so you know
>   immediately whether Steps 4-5 will work before you get there.
> - **Actually performs Steps 4 and 5 for you** via Bitbucket's REST API —
>   creates/rotates the `devops-api` access token and publishes it to SSM
>   (Step 4), and grants the Terraform-created AD group global `ADMIN` (Step
>   5) — both of which this doc otherwise has you do by hand with `curl`.
> - Idempotent throughout — safe to re-run any time (e.g. after a secret
>   rotation) instead of hunting for which step still needs redoing.
>
> Run it with:
> ```bash
> ./scripts/bitbucket-post-deploy.sh
> ```

No separate setup-wizard step is listed here because, unlike Jira/Confluence,
Bitbucket's first admin account is fully automated — created with the shared
admin password (`/devops/terraform-created/admin/password`), nothing to do
in a browser for that. The license is a different story: getting the value
into the cluster is automated (`/devops/prerequisite/bitbucket/license`, set
this before first deploy — see `devtools-labs/docs/bootstrap.md` — via an
`ExternalSecret` into `bitbucket.license.secretName`/`secretKey`,
`devtools-provision/devtools/bitbucket/values.yaml`), but you still apply it
yourself at Administration → Licenses — folded into Step 1 below rather than
its own step, since there's no dedicated setup wizard screen for it.

---

## 1. User Directory (LDAP/AD)

> **License:** getting the value into the cluster is automated —
> `/devops/prerequisite/bitbucket/license` via an `ExternalSecret` into
> `bitbucket.license.secretName`/`secretKey`
> (`devtools-provision/devtools/bitbucket/values.yaml`) — but applying it in
> Bitbucket's UI is a manual step you do yourself, at Administration →
> Licenses. Fetch the value:
> ```bash
> aws ssm get-parameter --name /devops/prerequisite/bitbucket/license --with-decryption --profile 342831714456_Workload-Admin-PS --region il-central-1 --query Parameter.Value --output text
> ```

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
| Password | fetch with `aws ssm get-parameter --name /devops/terraform-created/domain-controller/admin-password --with-decryption` | no separate `ldap-bind-password` parameter exists — it was consolidated away (`terraform/modules/domain-controller/main.tf`): the bind account's password is the same as the domain controller's admin/DSRM password, both sourced from the shared `generic_password` prerequisite secret. Never commit this value anywhere. |
| Base DN | `DC=devtools,DC=local` (domain root — published to SSM at `/devops/terraform-created/domain-controller/base-dn`) | **Deliberately not** the OU-scoped `OU=devops-tashtiot,DC=devtools,DC=local` — everything the domain controller creates today lives inside that one OU, but a real AD user created elsewhere in the domain later would be permanently invisible to Bitbucket if the Base DN stayed OU-scoped (subtree search only reaches down from the Base DN, never sideways). Accepted tradeoff: AD's own built-in accounts (`Administrator`, `Guest`, `krbtgt`) also come into scope, left unfiltered — the default User Object Filter is broad enough to include them. |

> **Hostname must be an IP, not `devtools.local`:** there is no DNS zone for
> the AD domain configured anywhere in this platform (no CoreDNS stub domain,
> no `hostAliases`, no Route53 private hosted zone).

### Advanced Settings — Enable Nested Groups & LDAP Connection Pooling

Check **"Enable Nested Groups"**.

Under **LDAP Connection Pooling**, select **JNDI**, not **Dynamic pool**.
JNDI is Atlassian's legacy pooling type, configured globally via JVM system
properties (`setenv.sh`/`setenv.bat`), not per-directory. Dynamic pool is the
newer alternative with more per-directory tuning knobs. This platform uses
JNDI on every directory.

Everything else on this form — schema mapping, Follow Referrals, and so on —
is already correct at Bitbucket's own defaults for a Microsoft Active
Directory directory type; confirmed against the live instance, nothing else
needs changing.

Click "Test retrieve user", then save the directory and run a directory sync
so users/groups actually populate.

---

## 2. Enable Basic Authentication

Confirmed by direct research (Atlassian's own configuration-properties docs,
plus a live probe against this instance): there is **no REST API and no
`bitbucket.properties` setting** for the "Allow basic authentication on API
calls" toggle — it exists only as a checkbox on the Authentication methods
screen, with no scriptable equivalent (same category of platform limitation
as the LDAP/SSO screens). `scripts/bitbucket-post-deploy.sh` can't flip it
for you, but it does check live, at this point in the walkthrough, so you
find out before moving on to SSO and the automated steps below.

Steps 4 and 5 below (the parts the script *does* automate) both need this
enabled first, or they fail with `403 "Basic Authentication has been
disabled on this instance."` One-time fix, in the browser:
```
Administration → Accounts → Authentication methods
  → next to the default method: Actions → Edit
  → check "Allow basic authentication on API calls"
  → Save configuration
```
This same setting also gates the laptop `git push` pattern documented in the
parent `CLAUDE.md`'s Cloudflare section (Gotcha 3).

---

## 3. SSO (RHBK/OIDC)

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

> **"We couldn't fetch the data from your identity provider. Fill these
> fields manually."** — a real, confirmed platform gap, not a symptom of
> misconfiguration. `ingress-nginx` presents a Cloudflare Origin CA
> certificate (only meant to be trusted by Cloudflare's edge, not generic
> clients), so Bitbucket's own backend HTTPS call to fetch RHBK's OIDC
> discovery document fails certificate validation — even though RHBK itself
> is fully reachable and healthy (confirmed live: fetching the discovery
> document with certificate verification skipped, from a pod in-cluster,
> returns a complete, correct document). Fill the fields in yourself:
>
> | Field | Value |
> |---|---|
> | Issuer | `https://rhbk.devopstashtiot.page/realms/devtools` |
> | Authorization endpoint | `https://rhbk.devopstashtiot.page/realms/devtools/protocol/openid-connect/auth` |
> | Token endpoint | `https://rhbk.devopstashtiot.page/realms/devtools/protocol/openid-connect/token` |
> | User info endpoint | `https://rhbk.devopstashtiot.page/realms/devtools/protocol/openid-connect/userinfo` |
> | JWK Set URL | `https://rhbk.devopstashtiot.page/realms/devtools/protocol/openid-connect/certs` |
> | Logout/end-session endpoint | `https://rhbk.devopstashtiot.page/realms/devtools/protocol/openid-connect/logout` |
>
> The real long-term fix — importing the Cloudflare Origin CA certificate
> (`/devops/terraform-created/cloudflare/origin-cert-crt`) into each
> Atlassian product's JVM truststore — is a `devtools-provision` Helm chart
> change, out of this repo's scope; this manual-entry workaround is the
> practical path until that's done. Same root cause affects Jira and
> Confluence's SSO setup identically (same RHBK, same ingress-nginx, same
> Origin CA cert) — see their own READMEs for the same table.

---

## 4. API Token for devops-api

`devops-api` authenticates to Bitbucket's REST API with a bearer token
(`GIT_TOKEN`), sourced from `/devops/postdeploy/bitbucket/api-token` via
ExternalSecret (see `devtools-definition/devtools/devops-api/values.yaml`'s
`vault.secrets`) — distinct from the AD/LDAP bind credentials used for the
`BITBUCKET_USERNAME`/`BITBUCKET_PASSWORD` fields elsewhere in that same file.

This token isn't created automatically. `scripts/bitbucket-post-deploy.sh` in
this repo automates both the token creation and the SSM publish below via
Bitbucket's access-tokens REST API — but that call needs Basic Authentication
enabled on this instance first (see Step 2 above).

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

---

## 5. Admin Group Grant

`devtools-labs/terraform/modules/domain-controller` creates an AD security
group (`devops-tashtiot`, its `ad_group_name` variable's default) under the
OU, with the LDAP bind account as its one Terraform-managed member. Anyone
else added to that AD group by hand becomes a Bitbucket admin — but only
once **both** of these are true:

1. Bitbucket's LDAP directory (Step 1) has synced at least once, so the
   group actually exists in Bitbucket.
2. That group has been granted Bitbucket's global `ADMIN` permission.

`scripts/bitbucket-post-deploy.sh` automates step 2 via Bitbucket's REST
API (same Basic-Auth prerequisite as the API token step above):
```bash
curl -u admin:<admin-password> \
  -H "CF-Access-Client-Id: <client-id>" -H "CF-Access-Client-Secret: <client-secret>" \
  -X PUT "https://bitbucket.devopstashtiot.page/rest/api/1.0/admin/permissions/groups?name=devops-tashtiot&permission=ADMIN"
```
Order matters: run this only after the directory sync in Step 1 has
actually run — Bitbucket has no group to grant a permission to otherwise,
and the call fails with a "does not exist" error.

To do it by hand instead: Administration → Security → Global permissions
→ search for the `devops-tashtiot` group → set its permission to
**Admin**.
