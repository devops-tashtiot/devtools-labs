# Post-Deployment Setup — Woodpecker CI

After `devtools-provision`/`devtools-definition` deploy Woodpecker's Helm
release, one manual step remains before it's usable at all — not just
before it's fully featured, but before **login itself works**.

## Bitbucket Application Link (required for login to work)

Woodpecker authenticates users by delegating to its configured forge —
Bitbucket Data Center on this platform (`WOODPECKER_BITBUCKET_DC=true`,
see `devtools-provision/devtools/woodpecker/templates/secrets.yaml`). There
is no local username/password login. That forge integration needs an
OAuth client id/secret, and Bitbucket has **no REST API** to register one —
it's a one-time manual step in Bitbucket's admin UI.

**Where:** Bitbucket → Administration → **Application Links** → **Create
link**.

1. Enter `https://woodpecker.devopstashtiot.page` as the application URL.
   Bitbucket won't be able to auto-detect it (no reciprocal link on
   Woodpecker's side) — when prompted, choose **"I don't want to
   reciprocate"**.
2. Application type: **External Application**.
3. Direction: **Incoming**.
4. Bitbucket generates an OAuth client id and client secret — copy both.

Publish them to SSM (`SecureString`, matching every other devtool's
convention of never committing real credentials to git):

```bash
aws ssm put-parameter --name /devtools/woodpecker/bitbucket-client-id \
  --type SecureString --value "<client-id>" --overwrite \
  --profile 342831714456_Workload-Admin-PS --region il-central-1

aws ssm put-parameter --name /devtools/woodpecker/bitbucket-client-secret \
  --type SecureString --value "<client-secret>" --overwrite \
  --profile 342831714456_Workload-Admin-PS --region il-central-1
```

These paths are already wired in
`devtools-definition/devtools/woodpecker/values.yaml`
(`wrapper.bitbucketDcSecrets.clientIdSsmParameter`/
`clientSecretSsmParameter`) — no chart or values change needed once the
parameters exist.

### Why this blocks login entirely, not just repo listing

The `woodpecker-bitbucket-dc-credentials` `ExternalSecret` fetches **three**
values from SSM in one object: the client id, the client secret, and a git
machine-account password (`/devtools/admin/password` — the platform's
shared admin password, already populated and otherwise fine on its own).

External Secrets Operator does not partially apply an `ExternalSecret` — if
any one of its `data[].remoteRef.key` entries fails to resolve, the *entire*
sync fails, and none of the three keys land in the target Secret. So until
both Bitbucket OAuth parameters above exist, the git-password key never
reaches the pod either, even though that SSM parameter itself is already
correct. The server logs show this as:

```
{"level":"error","error":"must have a git machine account password","message":"cannot get forge by id 1"}
```

and the browser sees it as a generic `https://woodpecker.devopstashtiot.page/login?error=internal_error`.

**After creating both SSM parameters**, restart the server pod so it picks
up the newly-synced secret (it doesn't watch for changes to env vars sourced
from a Secret at runtime):

```bash
kubectl delete pod woodpecker-server-0 -n woodpecker
```
