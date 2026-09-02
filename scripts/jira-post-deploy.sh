#!/usr/bin/env bash
set -euo pipefail

# Post-deployment setup for Jira — guided walkthrough.
# Full narrative: devtools-labs/docs/post-devtools-implementation/jira/README.md
#
# Unlike Bitbucket, Jira has no post-deploy step this script can actually
# automate via API — both the setup wizard and the LDAP/SSO admin screens
# are UI-only, and (confirmed against Jira's own OpenAPI spec,
# jira_software_dc_11000_swagger.v3.json) it has NO global-permissions REST
# endpoint at all — not even read-only. Its /api/2/group/user endpoint only
# adds individual USERS to a group, never a group to a group, and there is
# no "globalpermission" path anywhere in the spec. This script's job is
# purely to fetch every value the UI screens need from SSM and walk you
# through exactly what to type where and why, so you're never guessing or
# hunting for a parameter name mid-wizard.
#
# Jira is the one Atlassian product on this platform with NO license
# auto-apply mechanism (confirmed against the upstream chart + Atlassian
# docs — no equivalent of Bitbucket/Confluence's licenseSsmParameter wiring
# exists for Jira) — the license has to be pasted into the wizard by hand,
# which is why this script fetches and prints it, unlike the other two.
#
# Walks through steps ONE AT A TIME: each step's instructions print, then
# the script pauses and waits for you to confirm you're done before the
# next step's instructions print — so you're never scrolling back through
# a wall of output trying to figure out which step you're on.

AWS_PROFILE="${AWS_PROFILE:-342831714456_Workload-Admin-PS}"
AWS_REGION="${AWS_REGION:-il-central-1}"
export AWS_PROFILE AWS_REGION

JIRA_URL="${JIRA_URL:-https://jira.devopstashtiot.page}"

ssm_get() {
  aws ssm get-parameter --name "$1" --with-decryption \
    --query 'Parameter.Value' --output text
}

confirm_step() {
  echo
  read -r -p "Press Enter once you've completed Step $1 above (or Ctrl+C to stop here and resume later)... "
}

echo "############################################################################"
echo "# Jira post-deployment setup"
echo "#"
echo "# Four things need to happen before Jira is fully usable, all in the"
echo "# browser — this script has nothing it can automate via API here, only"
echo "# values to hand you so you're not hunting for them mid-wizard:"
echo "#   1. Finish the first-run setup wizard (license included — Jira has"
echo "#      no auto-apply mechanism, unlike Bitbucket/Confluence)"
echo "#   2. Connect it to the platform's AD directory"
echo "#   3. Turn on SSO via RHBK"
echo "#   4. Grant the Terraform-created AD group admin on Jira"
echo "#      (manual — Jira's REST API has no global-permissions endpoint"
echo "#      at all, not even read-only)"
echo "#"
echo "# Steps print one at a time — the script pauses after each for you to"
echo "# confirm before moving on."
echo "############################################################################"
echo
echo "== Fetching values from SSM =="
LDAP_URL=$(ssm_get /devops/terraform-created/domain-controller/ldap-connection-url)
LDAP_BIND_USER=$(ssm_get /devops/terraform-created/domain-controller/ldap-bind-username)
# No separate ldap-bind-password parameter exists — it was consolidated away
# (see terraform/modules/domain-controller/main.tf): the bind account's
# password is the same as the domain controller's admin-password, both
# sourced from the shared generic_password prerequisite secret.
LDAP_BIND_PASS=$(ssm_get /devops/terraform-created/domain-controller/admin-password)
ADMIN_PASS=$(ssm_get /devops/terraform-created/admin/password)
OIDC_SECRET=$(ssm_get /devops/terraform-created/rhbk/oidc-client-secret)
JIRA_LICENSE=$(ssm_get /devops/prerequisite/jira/license)
# Domain root (no OU component) — see terraform/modules/domain-controller's
# aws_ssm_parameter.base_dn for why this is deliberately not the narrower
# OU-scoped DN.
BASE_DN=$(ssm_get /devops/terraform-created/domain-controller/base-dn)
# The AD security group ad-bootstrap.ps1.tftpl creates under the OU, with
# the LDAP bind account as its one Terraform-managed member. Read from SSM
# (terraform/modules/domain-controller's aws_ssm_parameter.ad_group_name)
# instead of a hardcoded literal, matching bitbucket-post-deploy.sh.
AD_ADMIN_GROUP=$(ssm_get /devops/terraform-created/domain-controller/ad-group-name)

LDAP_HOST="${LDAP_URL#ldap://}"
LDAP_HOST="${LDAP_HOST%%:*}"
LDAP_BIND_UPN="${LDAP_BIND_USER}@devtools.local"

echo "Done. All values below are fetched live — always current, never stale."

# ----------------------------------------------------------------------------
echo
echo "############################################################################"
echo "# STEP 1 of 3 — Finish the Setup Wizard"
echo "############################################################################"
cat <<EOF

Go to ${JIRA_URL} and complete the first-run wizard once. Create the first
sysadmin account with the shared admin password:

  Admin password :  ${ADMIN_PASS}

Unlike Bitbucket/Confluence, Jira's chart has NO mechanism to auto-apply
the license — you have to paste it into the wizard's license step by
hand:

  License key :  ${JIRA_LICENSE}
EOF
confirm_step 1

# ----------------------------------------------------------------------------
echo
echo "############################################################################"
echo "# STEP 2 of 3 — Connect Jira to the AD Directory"
echo "############################################################################"
cat <<EOF

Navigate to:
    Administration (gear icon)  ->  User management  ->  Configure a
    directory connector

--------------------------------------------------------------------------
CONNECTION SETTINGS
--------------------------------------------------------------------------
  Hostname   :  ${LDAP_HOST}
               -> This is the domain controller's private IP, NOT a DNS
                  name. There is no DNS zone for "devtools.local" anywhere
                  on this platform (no CoreDNS stub, no Route53 private
                  zone), so a hostname here would just fail to resolve.

  Port       :  389
               -> Plain LDAP. The domain controller is not configured for
                  LDAPS on this port, so this MUST stay 389, not 636.

  Use SSL    :  No
               -> Matches the plain ldap:// scheme above. Leave unchecked.

  Username   :  ${LDAP_BIND_UPN}
               -> The dedicated bind service account, in UPN form
                  (user@domain), not the bare sAMAccountName. Same account
                  RHBK/Keycloak's own LDAP federation binds as.

  Password   :  ${LDAP_BIND_PASS}
               -> Do not save this anywhere outside this one form. It is
                  also the domain controller's local Administrator/DSRM
                  password (consolidated onto one shared value) — treat
                  it accordingly.

  Base DN    :  ${BASE_DN}
               -> The domain root, not an OU-scoped DN. Deliberate: every
                  object the domain controller creates today lives inside
                  one specific OU, but nothing stops a real AD user being
                  created elsewhere in the domain later — an OU-scoped
                  Base DN would make that user permanently invisible to
                  Jira (LDAP subtree search only reaches down from the
                  Base DN, never sideways). Accepted tradeoff: AD's own
                  built-in accounts (Administrator, Guest, krbtgt) also
                  come into scope, left unfiltered — the default User
                  Object Filter is broad enough to include them.

Click "Test Connection" here before moving on — if it fails, it's almost
always the Hostname/Port/Username/Password above, not anything further
down this form.

--------------------------------------------------------------------------
ADVANCED SETTINGS -> ENABLE NESTED GROUPS
--------------------------------------------------------------------------
  Enable Nested Groups   :  CHECKED (on)

--------------------------------------------------------------------------
ADVANCED SETTINGS -> LDAP CONNECTION POOLING
--------------------------------------------------------------------------
  LDAP Connection Pool   :  JNDI (not Dynamic pool)
               -> JNDI is Atlassian's legacy pooling type, configured
                  globally (JVM system properties in setenv.sh, not
                  per-directory). Dynamic pool is the newer alternative
                  with more per-directory tuning knobs. This platform
                  uses JNDI on every directory, not Dynamic pool.

Everything else on this form (schema mapping, Follow Referrals, etc.) is
already correct at Jira's own defaults for a Microsoft Active Directory
directory type (same finding confirmed live against Bitbucket's identical
Embedded Crowd directory screen; not independently re-verified against
Jira specifically).

FALLBACK if "Test retrieve user" fails with something like
UnknownHostException: devtools.local: uncheck "Follow Referrals" in this
directory's Advanced Settings. AD sometimes answers with a referral to its
own DNS name instead of the IP you configured, which nothing on this
platform resolves. Safe to turn off — this platform's AD structure is
flat (one OU, no nested domains/partitions), so there's nothing a
referral would ever legitimately need to point at anyway.

Click "Test retrieve user", then save the directory and run a directory
sync so users/groups actually populate.
EOF
confirm_step 2

# ----------------------------------------------------------------------------
echo
echo "############################################################################"
echo "# STEP 3 of 4 — Turn on SSO via RHBK"
echo "############################################################################"
cat <<EOF

Navigate to:
    Administration (gear icon)  ->  Single sign-on

This screen is provided by the "SSO for Atlassian Data Center" plugin
(already installed on this instance — confirmed present under
Administration -> System info -> Plugins), not something you need to
install yourself. Fill in:

  Client ID     :  jira
               -> Static, not a secret — matches jiraClient.clientId in
                  clusters-definition/clusters/rhbk/values.yaml.

  Issuer URL    :  https://rhbk.devopstashtiot.page/realms/devtools
               -> Standard Keycloak issuer format: <RHBK base URL>/realms/<realm>.
                  Realm name is "devtools" — every devtool on this
                  platform federates through this same realm.

  Login text    :  Log in with RHBK
               -> The button text shown on Jira's login page. Matches
                  the same wording already used for Confluence/Bitbucket's
                  SSO buttons — keep it consistent rather than inventing
                  new copy per devtool.

  Client Secret :  ${OIDC_SECRET}
               -> Shared by all six RHBK OIDC clients on this platform.
                  Jira doesn't read this from SSM automatically like
                  ArgoCD/SonarQube/Grafana do, so it's pasted in by hand
                  here — and must be pasted in again by hand any time the
                  secret rotates, since nothing will do that for you.

  User mapping  :  \${preferred_username}
               -> NOT \${sub} — Keycloak's \${sub} claim is its own
                  internally generated ID for the federated user, and
                  despite the LDAP federation provider being configured
                  with uuidLDAPAttribute=objectGUID, \${sub} is NOT
                  actually derived from AD's objectGUID (confirmed by
                  direct byte-for-byte comparison against a real user's
                  objectGUID — neither byte order matched). Matching on
                  \${sub} can therefore never resolve to a real local Jira
                  user, no matter how many times you sync. The failure
                  mode is AuthenticationFailedException: "Received SSO
                  request for user <uuid>, but the user does not exist"
                  in atlassian-jira.log.
               -> Also NOT \${sAMAccountName} — that's an LDAP *attribute*
                  name, not an OIDC *claim* name; it isn't present on the
                  token at all.
               -> \${preferred_username} is the standard OIDC claim
                  carrying the AD username, populated by Keycloak's
                  default "profile" client scope, which is already
                  attached to this client.

  Redirect URI  :  already correct — /plugins/servlet/oidc/callback
               -> No action needed unless this field is ever blank or
                  shows /plugins/servlet/oauth/callback instead (that's
                  the older Marketplace SSO app's path, not this one).

Note this only proves WHO logged in — it does not carry project
permissions/roles. Those still come entirely from the LDAP directory's
group sync in Step 2, independent of SSO.

IF YOU SEE "We couldn't fetch the data from your identity provider. Fill
these fields manually.": this is a real, confirmed platform gap, not
something wrong with your setup — ingress-nginx presents a Cloudflare
Origin CA certificate (only meant to be trusted by Cloudflare's edge, not
generic clients), so Jira's own backend HTTPS call to fetch RHBK's OIDC
discovery document fails certificate validation, even though RHBK itself
is fully reachable and healthy. Fill the fields in yourself:

  Issuer                        :  https://rhbk.devopstashtiot.page/realms/devtools
  Authorization endpoint        :  https://rhbk.devopstashtiot.page/realms/devtools/protocol/openid-connect/auth
  Token endpoint                :  https://rhbk.devopstashtiot.page/realms/devtools/protocol/openid-connect/token
  User info endpoint            :  https://rhbk.devopstashtiot.page/realms/devtools/protocol/openid-connect/userinfo
  JWK Set URL                   :  https://rhbk.devopstashtiot.page/realms/devtools/protocol/openid-connect/certs
  Logout/end-session endpoint   :  https://rhbk.devopstashtiot.page/realms/devtools/protocol/openid-connect/logout
EOF
confirm_step 3

# ----------------------------------------------------------------------------
echo
echo "############################################################################"
echo "# STEP 4 of 4 — Grant the Terraform-created AD group admin on Jira"
echo "############################################################################"
cat <<EOF

Fully manual, no automation possible: confirmed directly against Jira's
own OpenAPI spec that it has NO global-permissions REST endpoint at all —
not even read-only (Bitbucket has a full grant/revoke API for this;
Confluence at least has a read-only one; Jira has neither). Its
/api/2/group/user endpoint only adds individual users to a group, never a
group to a group.

devtools-labs' domain-controller module creates an AD security group
("${AD_ADMIN_GROUP}") under the OU, with the LDAP bind
account as its one Terraform-managed member — anyone else added to that
AD group by hand becomes a Jira admin, once both of these are true:
  1. Jira's LDAP directory (Step 2) has synced at least once, so the
     group actually exists in Jira.
  2. That group has been granted Jira's "Jira Administrators" global
     permission (below).

Navigate to:
    Administration (gear icon)  ->  System  ->  Security  ->
    Global permissions

Find the "${AD_ADMIN_GROUP}" group and grant it:
    Jira Administrators

(Not "Jira System Administrators" — that's a broader, more sensitive
permission that also covers managing other admins; "Jira Administrators"
is the standard admin-level grant, matching what Bitbucket's ADMIN and
Confluence's "Confluence Administrator" already give this group there.)

Order matters: if the LDAP directory sync in Step 2 hasn't run yet, the
group won't be there to grant a permission to at all — go finish that
first.
EOF

echo
echo "############################################################################"
echo "# Done printing values. Everything above needs you in the browser at"
echo "# ${JIRA_URL}"
echo "############################################################################"
