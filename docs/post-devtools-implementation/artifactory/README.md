# Post-Deployment Setup — Artifactory

After `devtools-provision`/`devtools-definition` deploy Artifactory's Helm
release, these manual steps remain before it's fully usable:

1. **License (Artifactory + Xray)** — required for Xray federation and any
   Pro+ feature
2. **Admin Identity Token for devops-api** — required for `devops-api`'s
   Artifactory integration (Access API calls)

---

## 1. License (Artifactory + Xray)

Artifactory is deployed intentionally **unlicensed** at first boot — see the
header comment in `devtools-definition/devtools/artifactory/values.yaml`.
There is no Helm value or ExternalSecret wiring for this by default; add a
real license through the running app's own Admin UI after first boot
(Administration → Licenses).

Two distinct licenses may be needed, applied in two different places:

- **Artifactory license** — Administration → Licenses. A Trial (or higher)
  license here is what makes Xray's Access Federation with this instance
  (`masterKey`/`joinKey` in `devtools-definition/devtools/artifactory/values.yaml`
  and `devtools-definition/devtools/xray/values.yaml`) establish at all.
- **Xray Trial License** — a *separate* license, applied under
  Administration → Licenses → **Xray Trial Licenses** tab (not the main
  Artifactory license tab above). Even with a valid Artifactory Trial
  license installed, Xray itself reports `"To enable JFrog Xray, you need to
  install an Artifactory Pro X license or above"` until this second license
  is installed — confirmed live 2026-07-14. There is no documented REST API
  for installing this one; it's a UI-only step.

Once a license is active, `wrapper.artifactorySecrets.licenseSsmParameter`
in `devtools-definition/devtools/artifactory/values.yaml` can optionally be
set to `/devtools/artifactory/license` (populate that SSM `SecureString`
first) to make future redeploys pick the license up automatically instead
of repeating this manual step — not done yet as of this writing.

---

## 2. Admin Identity Token for devops-api

`devops-api`'s `app/v1/artifactory` module (see
`devops-api/app/v1/artifactory/CLAUDE.md`) calls Artifactory's **Access
API** (`/access/api/v1/*` — projects, permissions, roles). Since Artifactory
7.12, every endpoint under `/access/api/*` rejects Basic authentication
outright, **including the token-creation endpoint itself** — confirmed live
2026-07-14 both through the public hostname and directly against
`artifactory-0`'s `localhost:8082`, with correct admin credentials, on both
a `GET` and the `POST /access/api/v1/tokens` bootstrap call. Basic auth
still works fine on the classic `/artifactory/api/*` REST API — this is
specific to the Access API only.

This means a Bearer token cannot be bootstrapped via the API at all; it
requires an interactive UI login:

1. Log into Artifactory's Admin UI as `admin` (password: shared platform
   admin password, `/devtools/admin/password` in SSM).
2. User Profile (top right) → **Generate Identity Token**.
3. Publish it to SSM:
   ```bash
   aws ssm put-parameter --name /devtools/artifactory/api-token --type SecureString --value "<token>" --overwrite --profile 342831714456_Workload-Admin-PS --region il-central-1
   ```

Not GitOps-managed — rotate it the same way (manual `put-parameter`), same
as Bitbucket's `/devtools/bitbucket/api-token` and ArgoCD's
`/devtools/argocd/api-token`.

> **Wiring status as of 2026-07-14:** this parameter exists and is
> populated, and has been verified live (`Bearer <token>` against
> `/access/api/v1/projects` on `artifactory-0` → `200`). `devops-api`'s
> `app/v1/artifactory` module itself still authenticates with Basic auth
> (`ARTIFACTORY_USERNAME`/`ARTIFACTORY_PASSWORD`, which also default to
> placeholder dev values never overridden in
> `devtools-definition/devtools/devops-api/values.yaml` — a second,
> compounding bug) — the module's client construction needs reworking to
> send `Authorization: Bearer` using this token instead before its routes
> will actually work. See `devops-api/app/v1/artifactory/CLAUDE.md`'s
> "Live-check findings" section for the full writeup.
