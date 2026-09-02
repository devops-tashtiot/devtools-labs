# Post-Deployment Setup — Woodpecker CI

After `devtools-provision`/`devtools-definition` deploy Woodpecker's Helm
release, one manual step remains before it's usable at all — not just
before it's fully featured, but before **login itself works**.

> **You can just run the script instead of following this document by hand.**
> `scripts/woodpecker-post-deploy.sh` walks through the one manual step below
> and automates everything after it:
> - **Prints the Application Link registration instructions** (link
>   type/direction, redirect URL, exact permission scopes) inline — Bitbucket
>   has no REST API to create this, so you still do this one part in the
>   browser either way.
> - **Publishes the resulting OAuth client ID/secret to SSM for you** once
>   you paste them in, instead of you constructing the two `aws ssm
>   put-parameter` calls below by hand.
> - **Prompts to restart `woodpecker-server-0` automatically** right after
>   publishing — the step most likely to be forgotten (see "A pod restart is
>   always required" below), since the new credentials won't take effect on
>   the running pod otherwise.
> - Idempotent — safe to re-run any time you need to rotate the Application
>   Link's credentials, not just on first setup.
>
> Run it with:
> ```bash
> ./scripts/woodpecker-post-deploy.sh
> ```

## Bitbucket Application Link (required for login to work)

Woodpecker authenticates users by delegating to its configured forge —
Bitbucket Data Center on this platform (`WOODPECKER_BITBUCKET_DC=true`,
see `devtools-provision/devtools/woodpecker/templates/secrets.yaml`). There
is no local username/password login. That forge integration needs an
OAuth client id/secret, and Bitbucket has **no REST API** to register one —
it's a one-time manual step in Bitbucket's admin UI.

**Where:** Bitbucket → Administration → **Applications** → **Application
links** → **Create link**.

On this version of Bitbucket, the type/direction picker comes **before**
any URL field:

1. Link type: **External application**. Direction: **Incoming**.
2. On the "Add the details of your external application" screen:
   - **Name**: anything (e.g. `Woodpecker CI`) — just a label in
     Bitbucket's own list, not read by Woodpecker.
   - **Redirect URL**: `https://woodpecker.devopstashtiot.page/authorize`
     — must be this exact path, not just the bare host. It's hardcoded in
     Woodpecker's own Bitbucket DC forge code
     (`RedirectURL: "<OAuthHost>/authorize"` in
     `server/forge/bitbucketdatacenter/bitbucketdatacenter.go`). A
     truncated or host-only value here means the OAuth callback 404s or
     mismatches and login fails with a `redirect_uri` error.
3. **Application permissions** — check exactly these three:
   - **Repositories: Read**
   - **Repositories: Write**
   - **Repositories: Admin**

   Leave **Account**, **Projects**, and **System Administration**
   unchecked. This isn't a guess — it's the exact scope list Woodpecker's
   own Bitbucket DC forge code requests (`PermissionRepoRead`,
   `PermissionRepoWrite`, `PermissionRepoAdmin`, verified directly against
   `newOAuth2Config()` in the source above). `Repositories: Admin` is
   specifically required for webhook management (create/list/delete on
   repos) — `Read`/`Write` alone isn't enough for that. A fourth scope
   (`Projects: Admin`) exists but is gated behind a Woodpecker feature
   flag (`oauthEnableProjectAdminScope`) this platform doesn't set, so
   it's never requested and checking it would just be an unused grant.
4. Bitbucket generates an OAuth client id and client secret — copy both.

Publish them to SSM (`SecureString`, matching every other devtool's
convention of never committing real credentials to git):

```bash
aws ssm put-parameter --name /devops/postdeploy/woodpecker/bitbucket-client-id \
  --type SecureString --value "<client-id>" --overwrite \
  --profile 342831714456_Workload-Admin-PS --region il-central-1

aws ssm put-parameter --name /devops/postdeploy/woodpecker/bitbucket-client-secret \
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
machine-account password (`/devops/terraform-created/admin/password` — the platform's
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

### A pod restart is always required after rotating these values

This `ExternalSecret` refreshes every **1m**
(`devtools-provision/devtools/woodpecker/templates/secrets.yaml` —
shortened from the platform's usual 1h specifically here, since these
values rotate manually/unpredictably rather than being Terraform-managed).
That only controls how fast a new SSM value reaches the **Kubernetes
Secret object**, though — it does **not** make the already-running pod
pick it up.

`woodpecker-server` consumes this Secret via `envFrom` (the whole Secret
injected as env vars), and env vars are read once at container start and
frozen for the container's life — nothing re-injects them into an
already-running process. So restarting the pod after every rotation is a
hard requirement, not an optimization to skip a refresh wait:

```bash
kubectl delete pod woodpecker-server-0 -n woodpecker
```

Confirmed live 2026-09-01: this exact gap produced a stale-credential
`"Unable to find client with that Id"` error on the Bitbucket OAuth screen
that looked like a problem with the Application Link registration itself,
but was actually just the pod still running on a days-old client id from
before the ExternalSecret had ever successfully synced past its very first
value. `scripts/woodpecker-post-deploy.sh` now prompts to restart the pod
automatically right after publishing new credentials, so this doesn't need
to be remembered by hand.
