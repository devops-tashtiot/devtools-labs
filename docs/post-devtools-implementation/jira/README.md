# Post-Deployment Setup — Jira

After `devtools-provision`/`devtools-definition` deploy Jira's Helm release,
these manual steps remain before it's fully usable:

1. **Finish the setup wizard** — first-run browser wizard
2. **User Directory (LDAP/AD)** — one-time admin UI configuration
3. **SSO (RHBK/OIDC)** — optional, on top of the directory above
4. **Admin group grant** — grants the Terraform-created AD group global admin on Jira (fully manual — no REST API for this, see below)

`scripts/jira-post-deploy.sh` walks through all four in this order, one
step at a time, pausing after each to confirm before printing the next.

> **You can just run the script instead of following this document by hand.**
> Unlike Bitbucket's, none of Jira's four steps can be automated via API —
> the setup wizard and the LDAP/SSO admin screens are UI-only, and Jira's
> own OpenAPI spec confirms it has **no** global-permissions endpoint at all
> (not even read-only) for Step 4. So the script's job is purely to:
> - **Fetch every value live from SSM** at run time (admin password, Jira
>   license, LDAP bind password, base DN, OIDC client secret, AD admin group
>   name) and print it inline with the same explanation as this doc — so
>   you're never copy-pasting a stale value out of a markdown file or
>   hunting for a parameter name mid-wizard.
> - **Print each step's field-by-field instructions one at a time**, pausing
>   after each so you can go complete it in the browser before the next step
>   prints — you're never scrolling back through a wall of output trying to
>   figure out which step you're on.
>
> There's nothing this doc has you do that the script doesn't also walk you
> through with live values — running it is strictly less typing/searching
> than following the sections below by hand:
> ```bash
> ./scripts/jira-post-deploy.sh
> ```

---

## 1. Finish the Setup Wizard

Jira's Helm chart has no mechanism to auto-complete this — see
`devtools-provision/devtools/jira/values.yaml`'s header comment. Complete
Jira's first-run setup wizard once in the browser after initial deploy, using
the shared admin password (`/devops/terraform-created/admin/password`) when creating the
first sysadmin account, same as every other devtool on this platform.

> **License must be pasted in by hand.** Unlike Bitbucket/Confluence, Jira's
> chart has no auto-apply mechanism for its license (no
> `licenseSsmParameter`-style `ExternalSecret` wiring exists for Jira — see
> `devtools-provision/devtools/jira/values.yaml`). Fetch the value and paste
> it into the wizard's license step yourself:
> ```bash
> aws ssm get-parameter --name /devops/prerequisite/jira/license --with-decryption --profile 342831714456_Workload-Admin-PS --region il-central-1 --query Parameter.Value --output text
> ```

---

## 2. User Directory (LDAP/AD)

Jira authenticates against the platform's AD domain controller
(`devtools-labs/terraform/modules/domain-controller`) instead of maintaining
its own local user base. There's no Helm value or automated setup for this —
it's a one-time manual configuration in Jira's admin UI after initial deploy.

**Where:** Administration (gear icon) → **User management** → **Configure a
directory connector** (embedded-crowd's LDAP directory screen).

### Connection Settings

| Field | Value | Why |
|---|---|---|
| Directory Type | Microsoft Active Directory | |
| Hostname | the domain controller's current private IP (`aws ec2 describe-instances` on the `WIN-SRV-01` instance, or the `/devops/terraform-created/domain-controller/ldap-connection-url` SSM parameter) | see callout below — do **not** use the domain DNS name here |
| Port | `389` | Plain LDAP, not LDAPS — the domain controller isn't configured for TLS on the LDAP port |
| Use SSL | **No** | matches the plain `ldap://` scheme above |
| Username | the bind account's UPN, `<bind-username>@devtools.local` (username from `/devops/terraform-created/domain-controller/ldap-bind-username`) | same bind account RHBK's `set-ldap-credentials-job.yaml` uses |
| Password | fetch with `aws ssm get-parameter --name /devops/terraform-created/domain-controller/admin-password --with-decryption` | no separate `ldap-bind-password` parameter exists — it was consolidated away (`terraform/modules/domain-controller/main.tf`): the bind account's password is the same as the domain controller's admin/DSRM password, both sourced from the shared `generic_password` prerequisite secret. Never commit this value anywhere. |
| Base DN | `DC=devtools,DC=local` (domain root — published to SSM at `/devops/terraform-created/domain-controller/base-dn`) | **Deliberately not** the OU-scoped `OU=devops-tashtiot,DC=devtools,DC=local` — everything the domain controller creates today lives inside that one OU, but a real AD user created elsewhere in the domain later would be permanently invisible to Jira if the Base DN stayed OU-scoped (subtree search only reaches down from the Base DN, never sideways). Accepted tradeoff: AD's own built-in accounts (`Administrator`, `Guest`, `krbtgt`) also come into scope, left unfiltered — the default User Object Filter is broad enough to include them. |

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
is already correct at Jira's own defaults for a Microsoft Active Directory
directory type (same finding confirmed live against Bitbucket's identical
Embedded Crowd directory screen — see `../bitbucket/README.md`; not
independently re-verified against Jira specifically).

**Fallback** if "Test retrieve user" fails with something like
`UnknownHostException: devtools.local`: uncheck **"Follow Referrals"** in
Advanced Settings. AD sometimes answers a search with a referral to its own
DNS name instead of the IP configured above, which nothing on this platform
resolves. Safe to turn off — this platform's AD structure is flat (one OU,
no nested domains/partitions), so there's nothing a referral would ever
legitimately need to point the client at anyway.

Click "Test retrieve user", then save the directory and run a directory sync
so users/groups actually populate.

---

## 3. SSO (RHBK/OIDC)

The LDAP directory above enables one login path; RHBK/Keycloak SSO is a
second, independent one. Both can be active at once, and both ultimately
check the same AD credentials — they differ in *how* the user gets
authenticated, not *against what*.

**1. LDAP-backed username/password (Directory login)**

This is what configuring the directory above enables by default — no extra
setup. A user types their AD `sAMAccountName` and password into Jira's normal
login form; Jira binds to the directory as that user to verify the password.
Project/group permissions are also driven by this directory's group sync
(the Membership schema configured above), independent of any SSO login.

**2. SSO via RHBK (OIDC)**

A "Log in with RHBK" button, provided by the **SSO for Atlassian Data
Center** plugin (already installed on this instance — confirmed present
under Administration → System info → Plugins), configured against the
`jira` OIDC client in `clusters-definition/clusters/rhbk/values.yaml`. This
redirects to RHBK/Keycloak's `devtools` realm, which itself authenticates
against the *same* AD (via its own LDAP federation, `clusters-provision/
clusters/rhbk/templates/realm-import.yaml`) — so SSO doesn't introduce a
separate identity, just a Keycloak-brokered login flow in front of it.

> **Important distinction:** SSO here only proves *identity* (who the user
> is). It does **not** carry authorization — `jiraClient` deliberately has no
> `groups` optionalClientScope (unlike `argocdClient`/`sonarqubeClient`), so
> Jira's project permissions and roles still come entirely from this LDAP
> directory's own group sync, not from anything in the OIDC token.

**Already fixed, note for context:** Jira's `redirectUri` in
`clusters-definition/clusters/rhbk/values.yaml`'s `jiraClient` used to assume
the `/plugins/servlet/oauth/callback` path (the Atlassian Marketplace SSO
app's fixed path). Jira's actual "Single sign-on" admin screen is the
built-in DC feature, not the marketplace app, and uses
`/plugins/servlet/oidc/callback` instead — same path as Bitbucket (see
`../bitbucket/README.md`). Corrected in both `clusters-provision`
and `clusters-definition`'s `rhbk` values and live in Keycloak. No action
needed here unless this client config regresses (symptom if it does:
`Invalid parameter: redirect_uri` from Keycloak).

**User mapping must use `${preferred_username}`, not `${sub}` or
`${sAMAccountName}`:** Jira's SSO admin screen has a "user mapping" field —
an expression like `${sub}` or `${preferred_username}` — that determines
which OIDC token claim Jira uses to look up the matching local (LDAP-synced)
user. The default/intuitive choice, `${sub}`, is Keycloak's own internally
generated ID for federated users; despite the LDAP federation provider being
configured with `uuidLDAPAttribute: objectGUID`, `sub` is **not** actually
derived from AD's `objectGUID` (confirmed by direct comparison — neither
byte-order rendering of a real user's `objectGUID` matched the `sub`
Keycloak issued for that same user). Matching on `sub` therefore can never
resolve to a real Jira user, no matter how many times the directory is
synced (full or incremental) or how correct the AD data is. The failure
mode is `AuthenticationFailedException: Received SSO request for user
<uuid>, but the user does not exist` in `atlassian-jira.log`, or a generic
"We can't log you in right now" page whose correlation ID traces back to the
same exception. `${sAMAccountName}` doesn't work either — that's the LDAP
*attribute* name, not the OIDC *claim* name. The correct mapping is
`${preferred_username}`, the standard OIDC claim carrying the AD username,
populated by Keycloak's default `profile` client scope (confirmed present on
`jira`/`confluence`/`bitbucket`'s client config via its built-in `username`
protocol mapper).

**Client Secret:** shared across all six RHBK OIDC clients
(`/devops/terraform-created/rhbk/oidc-client-secret`, Terraform-generated —
`devtools-labs/terraform/modules/devtools-secrets`), but Jira isn't wired to
SSM/ExternalSecret like ArgoCD/SonarQube/Grafana are — this value must be
pasted into Jira's SSO client secret field manually, and **manually updated
again any time the secret rotates** (it won't auto-propagate). Fetch the
current value with:
```bash
aws ssm get-parameter --name /devops/terraform-created/rhbk/oidc-client-secret --with-decryption --profile 342831714456_Workload-Admin-PS --region il-central-1 --query "Parameter.Value" --output text
```

> **"We couldn't fetch the data from your identity provider. Fill these
> fields manually."** — a real, confirmed platform gap, not a symptom of
> misconfiguration. `ingress-nginx` presents a Cloudflare Origin CA
> certificate (only meant to be trusted by Cloudflare's edge, not generic
> clients), so Jira's own backend HTTPS call to fetch RHBK's OIDC discovery
> document fails certificate validation — even though RHBK itself is fully
> reachable and healthy (confirmed live: fetching the discovery document
> with certificate verification skipped, from a pod in-cluster, returns a
> complete, correct document). Fill the fields in yourself:
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
> practical path until that's done. Same root cause affects Confluence and
> Bitbucket's SSO setup identically (same RHBK, same ingress-nginx, same
> Origin CA cert) — see their own READMEs for the same table.

---

## 4. Admin Group Grant

Fully manual — unlike Bitbucket, there is no way to automate this step.
Confirmed directly against Jira's own OpenAPI spec
(`jira_software_dc_11000_swagger.v3.json`): it has **no global-permissions
REST endpoint at all**, not even read-only (Bitbucket has a full
grant/revoke API for this; Confluence at least has a read-only one; Jira
has neither). Its `/rest/api/2/group/user` endpoint only adds individual
users to a group, never a group to a group.

`devtools-labs/terraform/modules/domain-controller` creates an AD security
group (`devops-tashtiot`, its `ad_group_name` variable's default) under the
OU, with the LDAP bind account as its one Terraform-managed member. Anyone
else added to that AD group by hand becomes a Jira admin — but only once
**both** of these are true:

1. Jira's LDAP directory (Step 2) has synced at least once, so the group
   actually exists in Jira.
2. That group has been granted Jira's **Jira Administrators** global
   permission (manually, below).

**Where:** Administration (gear icon) → **System** → **Security** →
**Global permissions**. Find the `devops-tashtiot` group and grant it
**Jira Administrators**.

> Not **Jira System Administrators** — that's a broader, more sensitive
> permission that also covers managing other admins. **Jira
> Administrators** is the standard admin-level grant, matching what
> Bitbucket's `ADMIN` and Confluence's **Confluence Administrator** already
> give this group there.

Order matters: run this only after the directory sync in Step 2 has
actually run — the group won't be there to grant a permission to at all
otherwise.
