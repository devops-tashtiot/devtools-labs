#!/usr/bin/env bash
set -euo pipefail

# Post-deployment setup for Bitbucket — guided walkthrough + automation.
# Full narrative: devtools-labs/docs/post-devtools-implementation/bitbucket/README.md
#
# Bitbucket Data Center has no REST API for either the AD/LDAP directory or
# the SSO (OIDC) admin screens — both are UI-only, same as Jira/Confluence.
# So this script does two things:
#   1. Fetches every value those two screens need from SSM and walks you
#      through exactly what to type where and why, field by field, so
#      you're never guessing or hunting for a parameter name mid-wizard.
#   2. Fully automates step 3 (API Token for devops-api) via Bitbucket's
#      access-tokens REST API, which *is* scriptable — creates/rotates a
#      Personal Access Token for the admin account and publishes it to SSM.
#      This part actually runs; steps 1/2 only print instructions, since
#      there's no API for this script to drive instead.
#
# Idempotent: re-running step 3 rotates the token in place (Bitbucket's
# access-tokens API treats the token "name" as the identity — PUTting the
# same name again replaces the previous token of that name rather than
# creating a duplicate), and re-publishing to SSM with --overwrite is safe
# to repeat.

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

echo "############################################################################"
echo "# Bitbucket post-deployment setup"
echo "#"
echo "# Three things need to happen before Bitbucket is fully usable:"
echo "#   1. Connect it to the platform's AD directory (manual, in the browser)"
echo "#   2. Turn on SSO via RHBK (manual, in the browser)"
echo "#   3. Issue an API token for devops-api's Git integration (this script does it)"
echo "#"
echo "# This script fetches every value you need for 1 & 2 from SSM and prints"
echo "# it below with an explanation of what it is and where it goes. It then"
echo "# offers to actually create the token for step 3."
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

LDAP_HOST="${LDAP_URL#ldap://}"
LDAP_HOST="${LDAP_HOST%%:*}"
LDAP_BIND_UPN="${LDAP_BIND_USER}@devtools.local"

echo "Done. All values below are fetched live — always current, never stale."

# ----------------------------------------------------------------------------
echo
echo "############################################################################"
echo "# STEP 1 of 3 — Connect Bitbucket to the AD Directory"
echo "############################################################################"
cat <<EOF

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

  Base DN    :  OU=devops-tashtiot,DC=devtools,DC=local
               -> The single organizational unit every platform user and
                  group lives under. There's nothing outside this OU to
                  search, so this is the narrowest correct value.

Click "Test Connection" here before moving on — if it fails, it's almost
always the Hostname/Port/Username/Password above, not anything further
down this form.

--------------------------------------------------------------------------
ADVANCED SETTINGS -> SCHEMA MAPPING -> USER SCHEMA
--------------------------------------------------------------------------
  User Object Class           :  user
  User Object Filter          :  (&(objectCategory=Person)(sAMAccountName=*))
  User Name Attribute         :  sAMAccountName
  User Name RDN Attribute     :  cn
  User First Name Attribute   :  givenName
  User Last Name Attribute    :  sn
  User Display Name Attribute :  displayName
  User Email Attribute        :  mail
  User Unique ID Attribute    :  objectGUID

These are standard AD attribute names, not anything custom to this
platform — you'd type the same values connecting any Atlassian DC product
to any AD domain.

--------------------------------------------------------------------------
ADVANCED SETTINGS -> SCHEMA MAPPING -> GROUP SCHEMA
--------------------------------------------------------------------------
  Group Object Class          :  group
  Group Object Filter         :  (objectCategory=Group)
  Group Name Attribute        :  cn
  Group Description Attribute :  description

--------------------------------------------------------------------------
ADVANCED SETTINGS -> SCHEMA MAPPING -> MEMBERSHIP SCHEMA
--------------------------------------------------------------------------
  Group Members Attribute             :  member
  Use the User Membership Attribute   :  "When finding the members of a group"
               -> This is a deliberate, non-default choice. AD's group
                  object already lists every member's DN in its own
                  "member" attribute, which is more reliable to resolve
                  from in a flat (non-nested) group structure than
                  walking each user's own back-link attribute. RHBK's own
                  LDAP federation for this same AD resolves group
                  membership the same way, so this keeps every
                  integration on the platform consistent with each other.

--------------------------------------------------------------------------
ADVANCED SETTINGS -> "FOLLOW REFERRALS" — UNCHECK THIS, READ WHY
--------------------------------------------------------------------------
  Follow Referrals   :  UNCHECKED (off)

  This is the one setting most likely to trip you up, because every field
  above can be entered correctly and the directory will still fail — on
  the "Test retrieve user" button specifically, not on "Test Connection".

  WHAT YOU'LL SEE IF YOU LEAVE IT CHECKED (the symptom):
      org.springframework.ldap.PartialResultException: nested exception is
      javax.naming.PartialResultException [Root exception is
      javax.naming.CommunicationException: devtools.local:389 [Root
      exception is java.net.UnknownHostException: devtools.local]]

  WHY THIS HAPPENS:
      Active Directory frequently answers an LDAP search with a
      "referral" — a response that essentially says "the rest of this
      search is at ldap://devtools.local/..." — even when you're already
      querying the right domain controller directly by its IP. This is
      completely normal AD behavior around naming-context boundaries and
      paged searches; it does not mean anything is misconfigured on the
      connection itself.

      If "Follow Referrals" is ON, Bitbucket's LDAP client (Spring
      LDAP/JNDI under the hood) dutifully tries to open a brand-new
      connection to that referral target. The referral target is AD's
      own DNS name ("devtools.local"), not the IP address you configured
      above — and since nothing in this platform resolves that DNS name
      (same reason the Hostname field above uses an IP), the connection
      attempt just fails outright with UnknownHostException.

  THE FIX:
      Uncheck "Follow Referrals" in this directory's Advanced Settings.
      There's no downside to turning it off here — this platform's AD
      structure is flat (one OU, no nested domains or partitions), so
      there is nothing a referral would ever legitimately need to point
      the client at anyway.

Once Follow Referrals is off, click "Test retrieve user" again — it
should now succeed. Save the directory, then run a directory sync so
users/groups actually populate.
EOF

# ----------------------------------------------------------------------------
echo
echo "############################################################################"
echo "# STEP 2 of 3 — Turn on SSO via RHBK"
echo "############################################################################"
cat <<EOF

Navigate to:
    Administration  ->  Security  ->  Single sign-on

This is Bitbucket's own built-in Data Center SSO screen (not an
Atlassian Marketplace app) — it should already show an RHBK/OIDC client
pre-configured with the correct Redirect URI. You only need to fill in
the secret and the mapping field:

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
EOF

# ----------------------------------------------------------------------------
echo
echo "############################################################################"
echo "# STEP 3 of 3 — API Token for devops-api (this script does this part)"
echo "############################################################################"
cat <<EOF

devops-api needs a Bitbucket Personal Access Token to call Bitbucket's
REST API on the platform's behalf (this is separate from the
BITBUCKET_USERNAME/BITBUCKET_PASSWORD fields devops-api also uses, which
are the AD/LDAP bind credentials — this token is a distinct credential).

If Basic Authentication is enabled on this instance, saying yes below
will fully automate this: call Bitbucket's own access-tokens REST API
as user '${BITBUCKET_ADMIN_USER}' to create (or, if one already exists
with this exact name, silently rotate/replace) a token named
"${TOKEN_NAME}" scoped to: ${TOKEN_PERMISSIONS} — then publish it straight
to SSM at ${TOKEN_SSM_PARAM}.

KNOWN GOTCHA ON THIS PLATFORM: this Bitbucket instance has Basic
Authentication disabled instance-wide (Administration > Security) —
confirmed by direct probe, not assumed. That setting blocks BOTH the
REST API call above AND plain "https://user:pass@host" git pushes
(this repo's own CLAUDE.md documents that git-push pattern, which is
currently broken by the same setting — worth fixing separately).
Bearer/PAT auth is a genuinely different, still-open path (confirmed:
an invalid Bearer token gets a normal 401, not the Basic-Auth-blocked
403) — but creating the very first token needs SOME existing
credential, and with Basic Auth off and no token created yet, there is
no way to bootstrap the first one via API. If this script's automated
attempt below fails with "Basic Authentication has been disabled", it
will fall back to walking you through creating that one token by hand.
EOF
echo
read -r -p "Attempt to create/rotate the '${TOKEN_NAME}' access token now? [y/N] " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
  echo "Skipped. Re-run this script when ready, or do it manually per the README."
  exit 0
fi

# bitbucket.devopstashtiot.page sits behind Cloudflare Access, same as every
# other *.devopstashtiot.page hostname — a plain curl with only Bitbucket's
# own Basic Auth gets intercepted at Cloudflare's edge and 302'd to the
# email-OTP login page before it ever reaches Bitbucket. Calling in from
# outside the cluster (this script, running on a laptop/CI, not from an
# in-cluster caller that bypasses Access via the CoreDNS rewrites) needs the
# CF-Access-Client-Id/CF-Access-Client-Secret service-token headers too,
# alongside Bitbucket's own auth — same pattern the parent CLAUDE.md
# documents for `git push` from outside the cluster.
CF_ACCESS_CLIENT_ID=$(ssm_get /devops/terraform-created/cloudflare/wildcard-access-otp-bypass-client-id)
CF_ACCESS_CLIENT_SECRET=$(ssm_get /devops/terraform-created/cloudflare/wildcard-access-otp-bypass-client-secret)

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

Confirmed: Basic Authentication is disabled on this instance, so this
step can't be automated end-to-end. There's no way around this from
outside — the first token has to be created in the browser, once:

    1. Log in at ${BITBUCKET_URL} as '${BITBUCKET_ADMIN_USER}'
       (password: the shared admin password, /devops/terraform-created/admin/password)
    2. Go to: Administration -> Personal access tokens -> Create token
    3. Name it "${TOKEN_NAME}", grant: ${TOKEN_PERMISSIONS} (repository read/write)
    4. Copy the token value — Bitbucket only shows it once
EOF
    echo
    read -r -s -p "Paste that token value here (input hidden), then Enter: " TOKEN
    echo
    if [ -z "$TOKEN" ]; then
      echo "No token entered — nothing published. Re-run this script when you have it."
      exit 1
    fi
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
echo "############################################################################"
echo "# Done"
echo "############################################################################"
cat <<EOF

  [x] Token "${TOKEN_NAME}" created in Bitbucket for user '${BITBUCKET_ADMIN_USER}'
  [x] Published to SSM at ${TOKEN_SSM_PARAM}
  [ ] devops-api will pick it up on its ExternalSecret's next refresh —
      nothing further to do; check its pod logs if it doesn't seem to be
      authenticating within a few minutes of this run.

Steps 1 and 2 above still need you in the browser — everything you need
for both is printed above this. Once the directory sync (Step 1) and SSO
(Step 2) are done, you can verify:
  - Directory: log out, log back in with an AD username/password
  - SSO: the login page should now also show a "Log in with RHBK" option
EOF
