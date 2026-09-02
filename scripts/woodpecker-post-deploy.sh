#!/usr/bin/env bash
set -euo pipefail

# Post-deployment setup for Woodpecker CI — guided walkthrough + automation.
# Full narrative: devtools-provision/devtools/woodpecker/values.yaml's
# wrapper.bitbucketDcSecrets comment (the manual-step source of truth).
#
# Woodpecker is architecturally different from Jira/Confluence/Bitbucket on
# this platform: it authenticates directly against Bitbucket as an OAuth
# "forge" (WOODPECKER_BITBUCKET_DC), not via the platform's AD directory or
# RHBK/Keycloak SSO. Admin bootstrap and open registration are already fully
# automated via Helm values (WOODPECKER_ADMIN=svc-devops-tashtiot,
# WOODPECKER_OPEN=true — see devtools-provision/devtools/woodpecker/
# values.yaml) — nothing to configure for either, unlike every Atlassian
# devtool on this platform.
#
# That leaves exactly ONE manual step: registering Woodpecker as a Bitbucket
# "Application Link" (OAuth consumer). Bitbucket has no REST API for this —
# same category of platform limitation already documented for its LDAP/SSO/
# Basic-Auth-toggle screens in devtools-labs/docs/post-devtools-implementation/
# bitbucket/README.md — so it's a one-time manual browser action. This script
# walks you through it, then takes the resulting OAuth client ID/secret and
# publishes them to SSM for you (the part that *is* automatable).
#
# Idempotent: re-running just overwrites both SSM parameters with whatever
# you paste in — safe to use for rotation too, not just first-time setup.

AWS_PROFILE="${AWS_PROFILE:-342831714456_Workload-Admin-PS}"
AWS_REGION="${AWS_REGION:-il-central-1}"
export AWS_PROFILE AWS_REGION

WOODPECKER_URL="${WOODPECKER_URL:-https://woodpecker.devopstashtiot.page}"
BITBUCKET_URL="${BITBUCKET_URL:-https://bitbucket.devopstashtiot.page}"
CLIENT_ID_SSM_PARAM="/devops/postdeploy/woodpecker/bitbucket-client-id"
CLIENT_SECRET_SSM_PARAM="/devops/postdeploy/woodpecker/bitbucket-client-secret"

echo "############################################################################"
echo "# Woodpecker CI post-deployment setup"
echo "#"
echo "# One thing needs to happen before Woodpecker is fully usable:"
echo "#   1. Register Woodpecker as a Bitbucket Application Link (manual, in the"
echo "#      browser — Bitbucket has no REST API for this), then publish the"
echo "#      resulting OAuth client ID/secret to SSM (this script does that part)"
echo "#"
echo "# Nothing else is needed: admin bootstrap (WOODPECKER_ADMIN=svc-devops-tashtiot)"
echo "# and open registration (WOODPECKER_OPEN=true) are already fully automated"
echo "# via Helm values — unlike Jira/Confluence/Bitbucket, there's no LDAP"
echo "# directory, no RHBK/SSO screen, and no license to configure here."
echo "############################################################################"

# ----------------------------------------------------------------------------
echo
echo "############################################################################"
echo "# STEP 1 of 1 — Register the Bitbucket Application Link"
echo "############################################################################"
cat <<EOF

Log in to Bitbucket as an admin at:
    ${BITBUCKET_URL}/admin

Then navigate to:
    Administration  ->  Applications  ->  Application links  ->  Create link

On this version of Bitbucket, pick the type/direction FIRST, before any
URL field appears:
    Link type  :  External application
    Direction  :  Incoming

--------------------------------------------------------------------------
"Add the details of your external application"
--------------------------------------------------------------------------
  Name           :  Woodpecker CI
               -> Just a label, shown in Bitbucket's own Application
                  Links list — not read by Woodpecker at all.

  Redirect URL   :  ${WOODPECKER_URL}/authorize
               -> Must be this EXACT path, not just the bare host — this
                  is hardcoded in Woodpecker's own Bitbucket DC forge code
                  (RedirectURL: "<OAuthHost>/authorize"). If you paste
                  just the host or the URL gets truncated in the field,
                  the OAuth callback will 404 or mismatch and login will
                  fail with a redirect_uri error.

--------------------------------------------------------------------------
Application permissions -- check EXACTLY these three, nothing else
--------------------------------------------------------------------------
  [x] Repositories : Read
  [x] Repositories : Write
  [x] Repositories : Admin
  [ ] Account, Projects, System Administration -- leave ALL unchecked

  -> Not a guess: this is the exact scope list Woodpecker's own Bitbucket
     DC forge code requests (PermissionRepoRead, PermissionRepoWrite,
     PermissionRepoAdmin in server/forge/bitbucketdatacenter/
     bitbucketdatacenter.go). Repositories:Admin is required specifically
     for webhook management (create/list/delete on repos) -- Read/Write
     alone isn't enough for that. There's a fourth optional scope
     (Projects:Admin) gated behind a Woodpecker feature flag this
     platform doesn't set, so it's never requested and checking it here
     would just be an unused, unnecessary grant.

Bitbucket will then generate an OAuth Consumer Key (Client ID) and a
Consumer Secret (Client Secret) — have both ready to paste below.
EOF
echo
read -r -p "Ready to publish the Client ID/Secret to SSM now? [y/N] " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
  cat <<EOF
Skipped. Re-run this script when ready, or publish manually:
  aws ssm put-parameter --name ${CLIENT_ID_SSM_PARAM} --type SecureString --value "<client-id>" --overwrite --profile ${AWS_PROFILE} --region ${AWS_REGION}
  aws ssm put-parameter --name ${CLIENT_SECRET_SSM_PARAM} --type SecureString --value "<client-secret>" --overwrite --profile ${AWS_PROFILE} --region ${AWS_REGION}
EOF
  exit 0
fi

read -r -p "Paste the Bitbucket OAuth Client ID: " CLIENT_ID
read -r -s -p "Paste the Bitbucket OAuth Client Secret (input hidden): " CLIENT_SECRET
echo

if [ -z "$CLIENT_ID" ] || [ -z "$CLIENT_SECRET" ]; then
  echo
  echo "FAILED: both values are required. Nothing was published. Re-run when ready."
  exit 1
fi

aws ssm put-parameter --name "$CLIENT_ID_SSM_PARAM" --type SecureString \
  --value "$CLIENT_ID" --overwrite \
  --description "Category: postdeploy. Not managed by GitOps/Terraform — created and rotated manually (see scripts/woodpecker-post-deploy.sh). Bitbucket Application Link OAuth client ID for Woodpecker's forge integration."

aws ssm put-parameter --name "$CLIENT_SECRET_SSM_PARAM" --type SecureString \
  --value "$CLIENT_SECRET" --overwrite \
  --description "Category: postdeploy. Not managed by GitOps/Terraform — created and rotated manually (see scripts/woodpecker-post-deploy.sh). Bitbucket Application Link OAuth client secret for Woodpecker's forge integration."

echo
echo "  [x] Published to SSM:"
echo "      ${CLIENT_ID_SSM_PARAM}"
echo "      ${CLIENT_SECRET_SSM_PARAM}"
cat <<EOF
  [ ] The woodpecker-bitbucket-dc-credentials ExternalSecret fetches THREE
      values in one object (client id, client secret, and the git
      machine-account password from /devops/terraform-created/admin/password) —
      External Secrets Operator applies it all-or-nothing, so until this
      publish, the sync was failing entirely and even the already-correct
      git password was never reaching the pod either. It refreshes every 1m
      (devtools-provision/devtools/woodpecker/templates/secrets.yaml —
      shortened from the platform's usual 1h specifically for this
      ExternalSecret, since these values rotate manually/unpredictably).

      That only fixes how fast the SSM value reaches the Kubernetes Secret
      object, though — it does NOT make the running pod pick it up.
      woodpecker-server consumes this Secret via envFrom (whole-secret-as-
      env-vars), and env vars are read once at container start and frozen
      for the container's life; nothing re-injects them into an already-
      running process. So a pod restart is REQUIRED after every rotation,
      not just a "skip if you don't want to wait" — even instant ESO sync
      wouldn't remove this step. Confirmed live 2026-09-01: this exact gap
      produced a stale-credential "Unable to find client with that Id"
      error that looked like a Bitbucket-side registration problem but was
      actually just the pod running on a days-old client id.
EOF
echo
read -r -p "Restart woodpecker-server-0 now to pick up the new credentials? [y/N] " RESTART_CONFIRM
if [[ "$RESTART_CONFIRM" == "y" || "$RESTART_CONFIRM" == "Y" ]]; then
  kubectl delete pod woodpecker-server-0 -n woodpecker
  echo "Waiting for the pod to come back up..."
  kubectl wait --for=condition=Ready pod/woodpecker-server-0 -n woodpecker --timeout=90s
  echo "  [x] woodpecker-server-0 restarted and Ready."
else
  echo "Skipped. Restart manually when ready:"
  echo "    kubectl delete pod woodpecker-server-0 -n woodpecker"
fi

echo
echo "############################################################################"
echo "# Done"
echo "############################################################################"
cat <<EOF

Verify at ${WOODPECKER_URL}: log in as any Bitbucket user (not just
svc-devops-tashtiot — WOODPECKER_OPEN=true means open registration for
everyone) and confirm your Bitbucket repos list under "Add repository".
Only svc-devops-tashtiot gets Woodpecker admin rights (WOODPECKER_ADMIN) —
everyone else gets normal user access, by design.
EOF
