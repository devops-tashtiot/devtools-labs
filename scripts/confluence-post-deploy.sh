#!/usr/bin/env bash
set -euo pipefail

# Post-deployment setup for Confluence — guided walkthrough.
# Full narrative: devtools-labs/docs/post-devtools-implementation/confluence/README.md
#
# Unlike Bitbucket, Confluence has no post-deploy step this script can
# actually automate via API — both the setup wizard and the LDAP/SSO admin
# screens are UI-only, and (confirmed against Confluence's own OpenAPI spec,
# 9.2.6.swagger.v3.json) its Global Permissions REST endpoints
# (/rest/api/permissions/*) are GET-only — no PUT/POST/DELETE to grant a
# global permission to a group, unlike /rest/api/space/{spaceKey}/permissions
# which does have a .../group/{groupName}/grant endpoint (space-scoped only).
# This script's job is purely to fetch every value the UI screens need from
# SSM and walk you through exactly what to type where and why, so you're
# never guessing or hunting for a parameter name mid-wizard.
#
# Walks through steps ONE AT A TIME: each step's instructions print, then
# the script pauses and waits for you to confirm you're done before the
# next step's instructions print — so you're never scrolling back through
# a wall of output trying to figure out which step you're on.

AWS_PROFILE="${AWS_PROFILE:-342831714456_Workload-Admin-PS}"
AWS_REGION="${AWS_REGION:-il-central-1}"
export AWS_PROFILE AWS_REGION

CONFLUENCE_URL="${CONFLUENCE_URL:-https://confluence.devopstashtiot.page}"

ssm_get() {
  aws ssm get-parameter --name "$1" --with-decryption \
    --query 'Parameter.Value' --output text
}

confirm_step() {
  echo
  read -r -p "Press Enter once you've completed Step $1 above (or Ctrl+C to stop here and resume later)... "
}

echo "############################################################################"
echo "# Confluence post-deployment setup"
echo "#"
echo "# Four things need to happen before Confluence is fully usable, all in"
echo "# the browser — this script has nothing it can automate via API here,"
echo "# only values to hand you so you're not hunting for them mid-wizard:"
echo "#   1. Finish the first-run setup wizard"
echo "#   2. Connect it to the platform's AD directory"
echo "#   3. Turn on SSO via RHBK"
echo "#   4. Grant the Terraform-created AD group admin on Confluence"
echo "#      (manual — Confluence's REST API has no write endpoint for"
echo "#      global permissions, unlike Bitbucket)"
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

Go to ${CONFLUENCE_URL} and complete the first-run wizard once. Create the
first sysadmin account with the shared admin password:

  Admin password :  ${ADMIN_PASS}

The license itself is NOT something to type in from a physical key — it's
sourced from /devops/prerequisite/confluence/license via an ExternalSecret
and applied automatically, so the wizard's license step should already be
satisfied when you reach it.

ON THE CLUSTER-CONFIGURATION STEP: submit once and then wait — don't
retry, resubmit, or restart the pod. Submitting that page makes Confluence
tear down and rebuild its Spring/OSGi plugin context LIVE, in-process, to
apply the new cluster settings. Any request that lands during that
rebuild — including the browser's own page load right after the form
POST — hits "Error retrieving text key: login.button" /
"IllegalStateException: Spring Application context has not been set". It
looks like a fatal crash but isn't: it self-resolves in roughly 15-90
seconds with zero intervention. Reload the same page once after waiting;
do not resubmit the form or restart the pod — both just re-roll the same
race at a different point, and confirmed identical across Confluence
9.3.1, 9.3.2, 9.4.1, and 10.2.13 (not fixed by upgrading).

Separately, the DB-selection step will very likely say "Confluence tables
already exist in the selected database" even on a genuinely fresh
install — Confluence auto-creates its schema on first DB connection,
before setup ever reaches that page, so this message is expected and safe
to click through ("overwrite") whenever there's no real content yet.
EOF
confirm_step 1

# ----------------------------------------------------------------------------
echo
echo "############################################################################"
echo "# STEP 2 of 3 — Connect Confluence to the AD Directory"
echo "############################################################################"
cat <<EOF

Navigate to:
    Administration (gear icon)  ->  User management  ->  Add Directory
    ->  Microsoft Active Directory

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
                  Confluence (LDAP subtree search only reaches down from
                  the Base DN, never sideways). Accepted tradeoff: AD's
                  own built-in accounts (Administrator, Guest, krbtgt)
                  also come into scope, left unfiltered — the default
                  User Object Filter is broad enough to include them.

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
already correct at Confluence's own defaults for a Microsoft Active
Directory directory type — nothing else needs changing (same finding
confirmed live against Bitbucket's identical Embedded Crowd directory
screen; not independently re-verified against Confluence specifically).

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

This is Confluence's own built-in Data Center SSO screen (not an
Atlassian Marketplace app). Fill in:

  Client ID     :  confluence
               -> Static, not a secret — matches confluenceClient.clientId
                  in clusters-definition/clusters/rhbk/values.yaml.

  Issuer URL    :  https://rhbk.devopstashtiot.page/realms/devtools
               -> Standard Keycloak issuer format: <RHBK base URL>/realms/<realm>.
                  Realm name is "devtools" — every devtool on this
                  platform federates through this same realm.

  Login text    :  Log in with RHBK
               -> The button text shown on Confluence's login page.
                  Matches the same wording already used for
                  Jira/Bitbucket's SSO buttons — keep it consistent
                  rather than inventing new copy per devtool.

  Client Secret :  ${OIDC_SECRET}
               -> Shared by all six RHBK OIDC clients on this platform.
                  Confluence doesn't read this from SSM automatically
                  like ArgoCD/SonarQube/Grafana do, so it's pasted in by
                  hand here — and must be pasted in again by hand any
                  time the secret rotates, since nothing will do that
                  for you.

  User mapping  :  \${preferred_username}
               -> NOT \${sub} — Keycloak's \${sub} claim is its own
                  internally generated ID for the federated user, and
                  despite the LDAP federation provider being configured
                  with uuidLDAPAttribute=objectGUID, \${sub} is NOT
                  actually derived from AD's objectGUID (confirmed by
                  direct byte-for-byte comparison against a real user's
                  objectGUID — neither byte order matched). Matching on
                  \${sub} can therefore never resolve to a real local
                  Confluence user, no matter how many times you sync.
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

Note this only proves WHO logged in — it does not carry space
permissions. Those still come entirely from the LDAP directory's group
sync in Step 2, independent of SSO.

IF YOU SEE "We couldn't fetch the data from your identity provider. Fill
these fields manually.": this is a real, confirmed platform gap, not
something wrong with your setup — ingress-nginx presents a Cloudflare
Origin CA certificate (only meant to be trusted by Cloudflare's edge, not
generic clients), so Confluence's own backend HTTPS call to fetch RHBK's
OIDC discovery document fails certificate validation, even though RHBK
itself is fully reachable and healthy. Fill the fields in yourself:

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
echo "# STEP 4 of 4 — Grant the Terraform-created AD group admin on Confluence"
echo "############################################################################"
cat <<EOF

Fully manual, no automation possible: confirmed directly against
Confluence's own OpenAPI spec that its Global Permissions REST endpoints
(/rest/api/permissions/*) are GET-only — there is no PUT/POST/DELETE to
grant a global permission to a group. (Space-level permissions do have a
grant/revoke REST API — /rest/api/space/{spaceKey}/permissions/group/
{groupName}/grant — but that only covers one space at a time, not
product-wide admin access, so it's not a substitute here.)

devtools-labs' domain-controller module creates an AD security group
("${AD_ADMIN_GROUP}") under the OU, with the LDAP bind
account as its one Terraform-managed member — anyone else added to that
AD group by hand becomes a Confluence admin, once both of these are true:
  1. Confluence's LDAP directory (Step 2) has synced at least once, so
     the group actually exists in Confluence.
  2. That group has been granted Confluence's global "Confluence
     Administrator" permission (below).

Navigate to:
    Administration (gear icon)  ->  General Configuration  ->
    Global permissions

Find the "${AD_ADMIN_GROUP}" group in the group list (add it to the
permissions table first via "Edit Permissions" if it isn't listed yet),
then check:
    Confluence Administrator

Save. Order matters: if the LDAP directory sync in Step 2 hasn't run yet,
the group won't be in the list to check at all — go finish that first.
EOF

echo
echo "############################################################################"
echo "# Done printing values. Everything above needs you in the browser at"
echo "# ${CONFLUENCE_URL}"
echo "############################################################################"
