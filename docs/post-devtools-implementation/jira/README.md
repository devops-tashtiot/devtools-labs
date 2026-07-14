# Post-Deployment Setup — Jira

After `devtools-provision`/`devtools-definition` deploy Jira's Helm release,
these manual steps remain before it's fully usable:

1. **Finish the setup wizard** — first-run browser wizard
2. **User Directory (LDAP/AD)** — one-time admin UI configuration
3. **SSO (RHBK/OIDC)** — optional, on top of the directory above

---

## 1. Finish the Setup Wizard

Jira's Helm chart has no mechanism to auto-complete this — see
`devtools-provision/devtools/jira/values.yaml`'s header comment. Complete
Jira's first-run setup wizard once in the browser after initial deploy, using
the shared admin password (`/devtools/admin/password`) when creating the
first sysadmin account, same as every other devtool on this platform.

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

These map Active Directory's actual attribute names onto Jira's generic
directory-schema fields. They're standard AD attributes, not specific to this
environment, but worth having in one place since the field names in Jira's UI
don't always make the AD equivalent obvious.

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

The last one is a deliberate choice, not Jira's default: AD's group object
carries a `member` attribute listing every member's DN directly, which is the
more reliable direction to resolve membership from in a flat (non-nested)
group structure. `clusters-provision/clusters/rhbk`'s Keycloak LDAP
federation resolves AD group membership the same way (via the group's
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

If "Follow Referrals" is enabled, Jira's underlying LDAP client (Spring LDAP /
JNDI) dutifully tries to open a *new* connection to that referral target —
which is the AD domain's DNS name (`devtools.local`), not the IP address
configured above. Since nothing in this platform resolves that domain name
(see the callout above), the hostname lookup fails outright.

**Fix:** uncheck **"Follow Referrals"** in the directory's Advanced Settings.
There is no other side effect to turning it off here — the platform's AD
structure is flat (one OU, no nested domains/partitions), so there's nothing
a referral would ever need to point the client at anyway.

> **Why RHBK/Keycloak's LDAP federation never hit this:** Keycloak's LDAP
> provider defaults to *ignoring* referrals rather than following them, so it
> never attempts the DNS lookup that trips up Jira's Spring-LDAP-based
> client. If a future integration exposes a referral setting, ignoring/
> not-following is the option to match this platform's setup.

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
(`/devtools/rhbk/oidc-client-secret`, Terraform-generated —
`devtools-labs/terraform/modules/devtools-secrets`), but Jira isn't wired to
SSM/ExternalSecret like ArgoCD/SonarQube/Grafana are — this value must be
pasted into Jira's SSO client secret field manually, and **manually updated
again any time the secret rotates** (it won't auto-propagate). Fetch the
current value with:
```bash
aws ssm get-parameter --name /devtools/rhbk/oidc-client-secret --with-decryption --profile 342831714456_Workload-Admin-PS --region il-central-1 --query "Parameter.Value" --output text
```
