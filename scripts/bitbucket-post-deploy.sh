#!/usr/bin/env bash
set -euo pipefail

# Post-deployment setup for Bitbucket — guided walkthrough + automation.
# Full narrative: devtools-labs/docs/post-devtools-implementation/bitbucket/README.md
#
# Bitbucket Data Center has no REST API for the AD/LDAP directory screen,
# the SSO (OIDC) screen, OR the "Allow basic authentication on API calls"
# toggle under Authentication methods (confirmed against Atlassian's own
# configuration-properties docs — no bitbucket.properties key exists for
# it either) — all three are UI-only, same as Jira/Confluence's directory
# and SSO screens. So this script does two things:
#   1. Fetches every value those screens need from SSM and walks you
#      through exactly what to type/click where and why, field by field,
#      so you're never guessing or hunting for a parameter name mid-wizard
#      — including a live PROBE, in Step 2, that tells you right away
#      whether Basic Authentication still needs enabling, before you're
#      deep into Steps 4-5 which actually depend on it.
#   2. Fully automates steps 4 and 5 via Bitbucket's REST API, which *is*
#      scriptable for both: creates/rotates a Personal Access Token for
#      devops-api and publishes it to SSM (step 4), and grants the
#      Terraform-created AD group global ADMIN on Bitbucket (step 5).
#      Steps 1/2/3 only print instructions, since there's no API for this
#      script to drive instead.
#
# Walks through steps ONE AT A TIME: each step's instructions print, then
# the script pauses and waits for you to confirm you're done before the
# next step's instructions print — so you're never scrolling back through
# a wall of output trying to figure out which step you're on.
#
# Idempotent throughout:
#   - Step 4 rotates the token in place (Bitbucket's access-tokens API
#     treats the token "name" as the identity — PUTting the same name
#     again replaces the previous token rather than creating a duplicate),
#     and re-publishing to SSM with --overwrite is safe to repeat.
#   - Step 5's PUT on /rest/api/1.0/admin/permissions/groups sets the
#     group's permission to exactly ADMIN regardless of its prior value —
#     safe to re-run.

AWS_PROFILE="${AWS_PROFILE:-342831714456_Workload-Admin-PS}"
AWS_REGION="${AWS_REGION:-il-central-1}"
export AWS_PROFILE AWS_REGION

BITBUCKET_URL="${BITBUCKET_URL:-https://bitbucket.devopstashtiot.page}"
BITBUCKET_ADMIN_USER="${BITBUCKET_ADMIN_USER:-admin}"
TOKEN_NAME="${TOKEN_NAME:-devops-api}"
TOKEN_PERMISSIONS="${TOKEN_PERMISSIONS:-REPO_WRITE}"
TOKEN_SSM_PARAM="/devops/postdeploy/bitbucket/api-token"

ssm_get() {
  aws ssm get-parameter --name "$1" --with-decryption \
    --query 'Parameter.Value' --output text
}

confirm_step() {
  echo
  read -r -p "Press Enter once you've completed Step $1 above (or Ctrl+C to stop here and resume later)... "
}

echo "############################################################################"
echo "# Bitbucket post-deployment setup"
echo "#"
echo "# Five things need to happen before Bitbucket is fully usable:"
echo "#   1. Connect it to the platform's AD directory (manual, in the browser)"
echo "#   2. Enable Basic Authentication (checked live — script can't flip it)"
echo "#   3. Turn on SSO via RHBK (manual, in the browser)"
echo "#   4. Issue an API token for devops-api's Git integration (this script does it)"
echo "#   5. Grant the Terraform-created AD group admin on Bitbucket (this script does it)"
echo "#"
echo "# This script fetches every value you need for 1-3 from SSM and prints"
echo "# it below with an explanation of what it is and where it goes, one step"
echo "# at a time — it pauses after each one for you to confirm before moving"
echo "# on. It then offers to actually run steps 4 and 5."
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
# the LDAP bind account as its one Terraform-managed member. Anyone else
# added to this AD group becomes a Bitbucket admin the next time the LDAP
# directory syncs, via the global permission this script grants in step 5.
# Read from SSM (terraform/modules/domain-controller's aws_ssm_parameter.
# ad_group_name) instead of a hardcoded literal, so this script always
# matches whatever ad_group_name is currently set to in
# terraform/live/devtools/domain-controller/terragrunt.hcl.
AD_ADMIN_GROUP=$(ssm_get /devops/terraform-created/domain-controller/ad-group-name)
# Getting this value into the k8s Secret is automated (ExternalSecret into
# bitbucket.license.secretName/secretKey, devtools-provision/devtools/
# bitbucket/values.yaml), but actually applying it in Bitbucket's UI
# (Administration -> Licenses) is a manual step done alongside Step 1 —
# there's no setup-wizard screen for it the way Jira has, so it's printed
# here rather than getting its own step.
BITBUCKET_LICENSE=$(ssm_get /devops/prerequisite/bitbucket/license)

LDAP_HOST="${LDAP_URL#ldap://}"
LDAP_HOST="${LDAP_HOST%%:*}"
LDAP_BIND_UPN="${LDAP_BIND_USER}@devtools.local"

# Fetched here (not just before Step 4 as before) so Step 2's live probe
# below can use them too — bitbucket.devopstashtiot.page sits behind
# Cloudflare Access like every other *.devopstashtiot.page hostname, so any
# curl from outside the cluster (this script, running on a laptop/CI) needs
# these service-token headers alongside Bitbucket's own auth or it just
# gets 302'd to the Access email-OTP login page before reaching Bitbucket.
CF_ACCESS_CLIENT_ID=$(ssm_get /devops/terraform-created/cloudflare/wildcard-access-otp-bypass-client-id)
CF_ACCESS_CLIENT_SECRET=$(ssm_get /devops/terraform-created/cloudflare/wildcard-access-otp-bypass-client-secret)

echo "Done. All values below are fetched live — always current, never stale."

# ----------------------------------------------------------------------------
echo
echo "############################################################################"
echo "# STEP 1 of 5 — Connect Bitbucket to the AD Directory"
echo "############################################################################"
cat <<EOF

License — paste this in yourself at Administration -> Licenses:
    ${BITBUCKET_LICENSE}

    -> Sourced from /devops/prerequisite/bitbucket/license. Same as every
       other license on this platform: getting it into the k8s Secret is
       automated (ExternalSecret into bitbucket.license.secretName/secretKey,
       devtools-provision/devtools/bitbucket/values.yaml), but actually
       applying it in Bitbucket's UI is a manual step you do here.

Log in to Bitbucket as '${BITBUCKET_ADMIN_USER}' at:
    ${BITBUCKET_URL}/admin

Then navigate to:
    Administration (top nav)  ->  Security  ->  Directories  ->  Add Directory

On the "Add Directory" screen, pick directory type:
    Microsoft Active Directory

--------------------------------------------------------------------------
CONNECTION SETTINGS
--------------------------------------------------------------------------
  Hostname   :  ${LDAP_HOST}
               -> This is the domain controller's private IP, NOT a DNS
                  name. There is no DNS zone for "devtools.local" anywhere
                  on this platform (no CoreDNS stub, no Route53 private
                  zone), so a hostname here would just fail to resolve.
                  Always use this IP even if it looks wrong to type an IP
                  into a "Hostname" field.

  Port       :  389
               -> Plain LDAP. The domain controller is not configured for
                  LDAPS on this port, so this MUST stay 389, not 636.

  Use SSL    :  No
               -> Matches the plain ldap:// scheme above. Leave unchecked.

  Username   :  ${LDAP_BIND_UPN}
               -> The dedicated bind service account, in UPN form
                  (user@domain), not the bare sAMAccountName. This is the
                  SAME account RHBK/Keycloak's own LDAP federation binds
                  as — nothing Bitbucket-specific about it.

  Password   :  ${LDAP_BIND_PASS}
               -> Do not save this anywhere outside this one form. It is
                  also the domain controller's local Administrator/DSRM
                  password (they were consolidated onto one shared value)
                  — treat it accordingly.

  Base DN    :  ${BASE_DN}
               -> The domain root, not an OU-scoped DN. Deliberate: every
                  object the domain controller creates today lives inside
                  one specific OU, but nothing stops a real AD user being
                  created elsewhere in the domain later — an OU-scoped
                  Base DN would make that user permanently invisible to
                  Bitbucket (LDAP subtree search only reaches down from
                  the Base DN, never sideways). The domain root has no
                  such blind spot. Accepted tradeoff: AD's own built-in
                  accounts (Administrator, Guest, krbtgt) are now also in
                  scope and will show up as syncable users — the User
                  Object Filter below is intentionally left broad rather
                  than excluding them.

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
already correct at Bitbucket's own defaults for a Microsoft Active
Directory directory type — nothing else needs changing.

Click "Test retrieve user", then save the directory and run a directory
sync so users/groups actually populate.
EOF
confirm_step 1

# ----------------------------------------------------------------------------
echo
echo "############################################################################"
echo "# STEP 2 of 5 — Enable Basic Authentication (checked live, below)"
echo "############################################################################"
cat <<EOF

There is no REST API or bitbucket.properties setting for this — it is a
pure UI-only checkbox (same category of platform limitation as the
LDAP/SSO screens), so this script cannot flip it for you. What it CAN do
is check right now whether you still need to.
EOF

PROBE_RESPONSE=$(curl -sk -u "${BITBUCKET_ADMIN_USER}:${ADMIN_PASS}" \
  -H "CF-Access-Client-Id: ${CF_ACCESS_CLIENT_ID}" \
  -H "CF-Access-Client-Secret: ${CF_ACCESS_CLIENT_SECRET}" \
  "${BITBUCKET_URL}/rest/access-tokens/1.0/users/${BITBUCKET_ADMIN_USER}" 2>/dev/null || true)

if echo "$PROBE_RESPONSE" | grep -q "Basic Authentication has been disabled"; then
  cat <<EOF

  [ ] Basic Authentication is currently DISABLED on this instance.
      Steps 4 and 5 (the parts this script automates) will fail until
      you enable it, one time, in the browser:

          Administration -> Accounts -> Authentication methods
            -> next to the default method: Actions -> Edit
            -> check "Allow basic authentication on API calls"
            -> Save configuration

      Same setting the parent CLAUDE.md's Gotcha 3 documents — also
      required for the laptop \`git push\` pattern documented there. Do
      this now, then confirm below once it's done.
EOF
else
  echo
  echo "  [x] Basic Authentication is already enabled — Steps 4-5 below will work as-is."
fi
confirm_step 2

# ----------------------------------------------------------------------------
echo
echo "############################################################################"
echo "# STEP 3 of 5 — Turn on SSO via RHBK"
echo "############################################################################"
cat <<EOF

Navigate to:
    Administration  ->  Security  ->  Single sign-on

This is Bitbucket's own built-in Data Center SSO screen (not an
Atlassian Marketplace app). Fill in:

  Client ID     :  bitbucket
               -> Static, not a secret — matches bitbucketClient.clientId
                  in clusters-definition/clusters/rhbk/values.yaml.

  Issuer URL    :  https://rhbk.devopstashtiot.page/realms/devtools
               -> Standard Keycloak issuer format: <RHBK base URL>/realms/<realm>.
                  Realm name is "devtools" (clusters-provision/clusters/rhbk/
                  values.yaml's realm.name) — every devtool on this platform
                  federates through this same realm.

  Login text    :  Log in with RHBK
               -> The button text shown on Bitbucket's login page. Matches
                  the same wording already used for Jira/Confluence's SSO
                  buttons — keep it consistent rather than inventing new
                  copy per devtool.

  Client Secret :  ${OIDC_SECRET}
               -> Shared by all six RHBK OIDC clients on this platform.
                  Bitbucket doesn't read this from SSM automatically like
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
                  \${sub} can therefore never resolve to a real local
                  Bitbucket user, no matter how many times you sync.
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

Note this only proves WHO logged in — it does not carry project/repo
permissions. Those still come entirely from the LDAP directory's group
sync in Step 1, independent of SSO.

IF YOU SEE "We couldn't fetch the data from your identity provider. Fill
these fields manually.": this is a real, confirmed platform gap, not
something wrong with your setup — ingress-nginx presents a Cloudflare
Origin CA certificate (only meant to be trusted by Cloudflare's edge, not
generic clients), so Bitbucket's own backend HTTPS call to fetch RHBK's
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
echo "# STEP 4 of 5 — API Token for devops-api (this script does this part)"
echo "############################################################################"
cat <<EOF

devops-api needs a Bitbucket Personal Access Token to call Bitbucket's
REST API on the platform's behalf (this is separate from the
BITBUCKET_USERNAME/BITBUCKET_PASSWORD fields devops-api also uses, which
are the AD/LDAP bind credentials — this token is a distinct credential).

Saying yes below calls Bitbucket's own access-tokens REST API as user
'${BITBUCKET_ADMIN_USER}' to create (or, if one already exists with this
exact name, silently rotate/replace) a token named "${TOKEN_NAME}" scoped
to: ${TOKEN_PERMISSIONS} — then publishes it straight to SSM at
${TOKEN_SSM_PARAM}.

PREREQUISITE — Basic Authentication must be enabled on this instance
first (see Step 2's live check above), or this call fails with 403
"Basic Authentication has been disabled on this instance."
EOF
echo
read -r -p "Attempt to create/rotate the '${TOKEN_NAME}' access token now? [y/N] " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
  echo "Skipped. Re-run this script when ready, or do it manually per the README."
  exit 0
fi

RESPONSE=$(curl -sk -u "${BITBUCKET_ADMIN_USER}:${ADMIN_PASS}" \
  -H "CF-Access-Client-Id: ${CF_ACCESS_CLIENT_ID}" \
  -H "CF-Access-Client-Secret: ${CF_ACCESS_CLIENT_SECRET}" \
  -X PUT \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json' \
  -d "{\"name\": \"${TOKEN_NAME}\", \"permissions\": [\"${TOKEN_PERMISSIONS}\"]}" \
  "${BITBUCKET_URL}/rest/access-tokens/1.0/users/${BITBUCKET_ADMIN_USER}")

TOKEN=$(echo "$RESPONSE" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('token',''))" 2>/dev/null || true)

if [ -z "$TOKEN" ]; then
  if echo "$RESPONSE" | grep -q "Basic Authentication has been disabled"; then
    cat <<EOF

FAILED: Basic Authentication is disabled on this instance. Enable it
first, then re-run this script:

    1. Log in at ${BITBUCKET_URL} as '${BITBUCKET_ADMIN_USER}'
       (password: the shared admin password, /devops/terraform-created/admin/password)
    2. Administration -> Accounts -> Authentication methods
    3. Next to the default method: Actions -> Edit
    4. Check "Allow basic authentication on API calls"
    5. Save configuration
EOF
    exit 1
  else
    echo
    echo "FAILED to create the token. Bitbucket's raw response was:"
    echo "$RESPONSE"
    echo
    echo "Common causes: wrong admin password (check /devops/terraform-created/admin/password"
    echo "is still current), or Bitbucket isn't reachable yet at ${BITBUCKET_URL}."
    exit 1
  fi
fi

aws ssm put-parameter --name "$TOKEN_SSM_PARAM" --type SecureString \
  --value "$TOKEN" --overwrite \
  --description "Category: postdeploy. Not managed by GitOps/Terraform — created and rotated manually (see scripts/bitbucket-post-deploy.sh)."

echo
echo "  [x] Token \"${TOKEN_NAME}\" created in Bitbucket for user '${BITBUCKET_ADMIN_USER}'"
echo "  [x] Published to SSM at ${TOKEN_SSM_PARAM}"
echo "  [ ] devops-api will pick it up on its ExternalSecret's next refresh —"
echo "      nothing further to do; check its pod logs if it doesn't seem to be"
echo "      authenticating within a few minutes of this run."
confirm_step 4

# ----------------------------------------------------------------------------
echo
echo "############################################################################"
echo "# STEP 5 of 5 — Grant the Terraform-created AD group admin on Bitbucket"
echo "############################################################################"
cat <<EOF

devtools-labs' domain-controller module creates an AD security group
("${AD_ADMIN_GROUP}") under the OU, with the LDAP bind
account as its one Terraform-managed member — anyone else added to that
AD group by hand becomes a Bitbucket admin, once both this step's global
permission grant is in place AND the LDAP directory (Step 1) has synced
that group into Bitbucket at least once. Order matters: if this step runs
before the group has ever synced, Bitbucket has no such group to grant a
permission to yet, and the call below fails.
EOF
echo
read -r -p "Grant AD group '${AD_ADMIN_GROUP}' global ADMIN on Bitbucket now? [y/N] " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
  echo "Skipped. Re-run this script when ready, once Step 1's directory sync has run at least once."
  exit 0
fi

GROUP_RESPONSE=$(curl -sk -u "${BITBUCKET_ADMIN_USER}:${ADMIN_PASS}" \
  -H "CF-Access-Client-Id: ${CF_ACCESS_CLIENT_ID}" \
  -H "CF-Access-Client-Secret: ${CF_ACCESS_CLIENT_SECRET}" \
  -w '\nHTTP_STATUS:%{http_code}' \
  -X PUT \
  "${BITBUCKET_URL}/rest/api/1.0/admin/permissions/groups?name=${AD_ADMIN_GROUP}&permission=ADMIN")

GROUP_HTTP_STATUS=$(echo "$GROUP_RESPONSE" | grep -o 'HTTP_STATUS:[0-9]*' | cut -d: -f2)
GROUP_BODY=$(echo "$GROUP_RESPONSE" | sed 's/HTTP_STATUS:[0-9]*$//')

if [ "$GROUP_HTTP_STATUS" = "204" ] || [ "$GROUP_HTTP_STATUS" = "200" ]; then
  echo
  echo "  [x] AD group '${AD_ADMIN_GROUP}' granted global ADMIN on Bitbucket"
elif echo "$GROUP_BODY" | grep -q "Basic Authentication has been disabled"; then
  cat <<EOF

FAILED: Basic Authentication is disabled on this instance. Enable it
first (see Step 2's failure message above for the exact steps), then
re-run this script.
EOF
  exit 1
elif echo "$GROUP_BODY" | grep -qi "does not exist\|not found"; then
  cat <<EOF

FAILED: Bitbucket doesn't know about the group "${AD_ADMIN_GROUP}" yet.
This means Step 1's LDAP directory sync hasn't run (or hasn't completed)
— go finish the directory setup and run a sync first, then re-run this
script.
EOF
  exit 1
else
  echo
  echo "FAILED (HTTP $GROUP_HTTP_STATUS). Bitbucket's raw response was:"
  echo "$GROUP_BODY"
  exit 1
fi

echo
echo "############################################################################"
echo "# Done"
echo "############################################################################"
cat <<EOF

Steps 1 and 3 above still needed you in the browser — everything you
needed for both was printed above. Once the directory sync (Step 1) and
SSO (Step 3) are done, you can verify:
  - Directory: log out, log back in with an AD username/password
  - SSO: the login page should now also show a "Log in with RHBK" option
  - Admin group: an AD user who is a member of "${AD_ADMIN_GROUP}" should
    see Bitbucket's Administration menu after their next login
EOF
