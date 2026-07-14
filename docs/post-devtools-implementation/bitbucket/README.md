# Post-Deployment Setup — Bitbucket

After `devtools-provision`/`devtools-definition` deploy Bitbucket's Helm
release, these manual steps remain before it's fully usable:

1. **User Directory (LDAP/AD)** — one-time admin UI configuration
2. **SSO (RHBK/OIDC)** — optional, on top of the directory above
3. **API Token for devops-api** — required for `devops-api`'s Git integration

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
| Hostname | the domain controller's current private IP (`aws ec2 describe-instances` on the `WIN-SRV-01` instance, or the `/devtools/domain-controller/ldap-connection-url` SSM parameter) | see callout below — do **not** use the domain DNS name here |
| Port | `389` | Plain LDAP, not LDAPS — the domain controller isn't configured for TLS on the LDAP port |
| Use SSL | **No** | matches the plain `ldap://` scheme above |
| Username | the bind account's UPN, `<bind-username>@devtools.local` (username from `/devtools/domain-controller/ldap-bind-username`) | same bind account RHBK's `set-ldap-credentials-job.yaml` uses |
| Password | fetch with `aws ssm get-parameter --name /devtools/domain-controller/ldap-bind-password --with-decryption` | never commit this value anywhere |
| Base DN | `OU=devops-tashtiot,DC=devtools,DC=local` | from `domain-controller`'s `ou_name`/`domain_name` variables |

> **Hostname must be an IP, not `devtools.local`:** there is no DNS zone for
> the AD domain configured anywhere in this platform (no CoreDNS stub domain,
> no `hostAliases`, no Route53 private hosted zone). This matters more than it
> looks like it should — see the Follow Referrals section below.

### Advanced Settings — Schema Mapping

These map Active Directory's actual attribute names onto Bitbucket's generic
directory-schema fields. They're standard AD attributes, not specific to this
environment, but worth having in one place since the field names in
Bitbucket's UI don't always make the AD equivalent obvious.

**User schema:**

| Field | Value |
|---|---|
| User Object Class | `user` |
| User Object Filter | `(&(objectCategory=Person)(sAMAccountName=*))` |
| User Name Attribute | `sAMAccountName` |
| User Name RDN Attribute | `cn` |
| User First Name Attribute | `givenName` |
| User Last Name Attribute | `sn` |
| User Display Name Attribute | `displayName` |
| User Email Attribute | `mail` |
| User Unique ID Attribute | `objectGUID` |

**Group schema:**

| Field | Value |
|---|---|
| Group Object Class | `group` |
| Group Object Filter | `(objectCategory=Group)` |
| Group Name Attribute | `cn` |
| Group Description Attribute | `description` |

**Membership schema:**

| Field | Value |
|---|---|
| Group Members Attribute | `member` |
| Use the User Membership Attribute | **"When finding the members of a group"** |

The last one is a deliberate choice, not Bitbucket's default: AD's group
object carries a `member` attribute listing every member's DN directly,
which is the more reliable direction to resolve membership from in a flat
(non-nested) group structure. `clusters-provision/clusters/rhbk`'s Keycloak
LDAP federation resolves AD group membership the same way (via the group's
`member` attribute, `LOAD_GROUPS_BY_MEMBER_ATTRIBUTE`, not a per-user
back-link) — this keeps both integrations consistent with each other.

### Follow Referrals Must Be Disabled

This is the one setting most likely to trip you up, because everything else
can be configured correctly and the directory will still fail — specifically
on **"Test retrieve user."**

**Symptom:**

```
org.springframework.ldap.PartialResultException: nested exception is
javax.naming.PartialResultException [Root exception is
javax.naming.CommunicationException: devtools.local:389 [Root exception is
java.net.UnknownHostException: devtools.local]]
```

**Why it happens:** Active Directory frequently answers LDAP searches with a
*referral* — a response telling the client "continue this search at
`ldap://devtools.local/...`" — even when the client is already querying the
correct domain controller directly by IP. This is normal AD behavior around
naming-context boundaries and paged searches, not a sign anything is
misconfigured.

If "Follow Referrals" is enabled, Bitbucket's underlying LDAP client (Spring
LDAP / JNDI) dutifully tries to open a *new* connection to that referral
target — which is the AD domain's DNS name (`devtools.local`), not the IP
address configured above. Since nothing in this platform resolves that domain
name (see the callout above), the hostname lookup fails outright.

**Fix:** uncheck **"Follow Referrals"** in the directory's Advanced Settings.
There is no other side effect to turning it off here — the platform's AD
structure is flat (one OU, no nested domains/partitions), so there's nothing
a referral would ever need to point the client at anyway.

> **Why RHBK/Keycloak's LDAP federation never hit this:** Keycloak's LDAP
> provider defaults to *ignoring* referrals rather than following them, so it
> never attempts the DNS lookup that trips up Bitbucket's Spring-LDAP-based
> client. If a future integration exposes a referral setting, ignoring/
> not-following is the option to match this platform's setup.

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
(`/devtools/rhbk/oidc-client-secret`, Terraform-generated —
`devtools-labs/terraform/modules/devtools-secrets`), but Bitbucket isn't
wired to SSM/ExternalSecret like ArgoCD/SonarQube/Grafana are — this value
must be pasted into Bitbucket's SSO client secret field manually, and
**manually updated again any time the secret rotates** (it won't
auto-propagate). Fetch the current value with:
```bash
aws ssm get-parameter --name /devtools/rhbk/oidc-client-secret --with-decryption --profile 342831714456_Workload-Admin-PS --region il-central-1 --query "Parameter.Value" --output text
```

---

## 3. API Token for devops-api

`devops-api` authenticates to Bitbucket's REST API with a bearer token
(`GIT_TOKEN`), sourced from `/devtools/bitbucket/api-token` via
ExternalSecret (see `devtools-definition/devtools/devops-api/values.yaml`'s
`vault.secrets`) — distinct from the AD/LDAP bind credentials used for the
`BITBUCKET_USERNAME`/`BITBUCKET_PASSWORD` fields elsewhere in that same file.

This token isn't created automatically. Generate a Bitbucket Personal Access
Token (Administration → Personal access tokens — either your own or a
dedicated service account's, scoped with repo read/write access), then
publish it:
```bash
aws ssm put-parameter --name /devtools/bitbucket/api-token --type SecureString --value "<token>" --overwrite --profile 342831714456_Workload-Admin-PS --region il-central-1
```
Not GitOps-managed — rotate it the same way (manual `put-parameter`). The
parameter's own description already reflects this: "Not managed by
GitOps/Terraform — created and rotated manually."
