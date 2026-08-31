# Cloudflare Limitations & Gotchas

This platform's Cloudflare setup (Tunnel + Access, see
[architecture.md](architecture.md) for how routing actually works) runs on the
**Free plan**, and a few of its behaviors have caused real, verified
incidents while operating this platform. This page is the limitations
reference — what's actually constrained, not how the happy path works.

## Free plan constraints

- No managed WAF rulesets, no advanced bot management, no Advanced
  Certificate Manager (multiple custom hostnames / more cert flexibility
  costs extra on paid plans).
- Cloudflare only charges if the zone is manually upgraded or a paid add-on
  is enabled — the plan itself has no usage-based billing surprise. Four
  budget alerts are configured at $1/$2/$5/$10 thresholds to
  `netanelzucaim100@gmail.com` regardless. To be fully charge-proof, remove
  the saved payment method under **Billing → Payment Methods**.

## Access session/identity gotchas

- **Access sessions last 24 hours per browser.** After the one-time email
  code login, a browser stays authenticated to `*.devopstashtiot.page` for
  24 hours, then has to re-authenticate. There's no "remember me" beyond
  that window on the Free plan's default session duration.
- **`allowed_idps` must be set explicitly on the Access Application, or
  Access silently falls back to its default IDP** (account-members-only)
  — which blocks every allowlisted email except the account owner, with
  **no trace in Access logs**, since the block happens before the email
  policy is ever evaluated. If someone reports "sign-in is restricted to
  account members," this is almost always the cause — check
  `allowed_idps` on the Access Application first.
- The email allowlist is a full-replace list, not additive: a `PUT` to the
  Access policy (or a Terraform apply of the `allowed_emails` variable)
  replaces the entire `include` list — omitting an existing email revokes
  their access rather than leaving it untouched.

## Service tokens have domain-wide blast radius, not per-subdomain scope

A Cloudflare Access **service token** (e.g. the one used for pushing to
Bitbucket from outside the cluster) bypasses the email-OTP wall for
**every hostname the Access Application's policy covers** — which for the
wildcard policy on `*.devopstashtiot.page` means every subdomain, not just
the one it was created for. A token minted "for Bitbucket push access" can
authenticate to any devtool behind the same wildcard Access app. Treat
service token creation as domain-wide credential issuance, not a
narrowly-scoped grant — name and document tokens accordingly (see the
`wildcard-access-otp-bypass` naming in `devtools-labs`' Cloudflare module
for why a token originally named for one purpose was renamed to reflect
its true scope).

## Origin CA trust is private, not a public CA

The Cloudflare Origin CA certificate presented by `ingress-nginx` to
`cloudflared` (see [architecture.md](architecture.md)) is **not** a
publicly-trusted certificate — it's only meant to be trusted between
Cloudflare's edge and an origin server. Every devtool's own outbound HTTP
clients (JVMs especially — Bitbucket, Jira, Confluence, Artifactory, RHBK)
need this specific root explicitly added to their truststore to make
in-cluster calls to `*.devopstashtiot.page` (routed via the CoreDNS
rewrite straight to `ingress-nginx-controller`, which presents this same
cert). Skipping this produces `PKIX path building failed: unable to find
valid certification path` — a TLS trust error, not a routing or DNS
problem, even though the symptom (a failed HTTPS call to a
`.devopstashtiot.page` hostname) looks identical to one.

## A single, static `cloudflared` ingress rule

Today there is exactly one catch-all ingress rule in `cloudflared`'s
config — every hostname routes to `ingress-nginx-controller`'s ClusterIP
over HTTPS with `originServerName: devopstashtiot.page` overriding SNI
validation (see [architecture.md](architecture.md) for why that override
exists). There's no per-hostname routing logic in `cloudflared` itself —
all host-based routing happens one layer down, inside ingress-nginx. A new
subdomain needs a DNS record and an `Ingress` resource, not a `cloudflared`
config change.

## Confluence's setup-wizard bug was NOT a Cloudflare issue — ruled out, not assumed

Worth recording since it was the leading hypothesis for a while: a real
Confluence Data Center setup-wizard bug (a broken Velocity template on its
"existing data found, confirm overwrite" page) was initially suspected to
be caused by Cloudflare's **Rocket Loader** or **Auto Minify (JavaScript)**
features mangling the wizard's inline JS. Both were checked directly via
the Cloudflare API and confirmed **already off** — this zone doesn't
enable either. The actual root cause was unrelated to Cloudflare entirely
(a stale `confluence.cfg.xml` setup-step marker out of sync with the
actual database schema state). Recorded here so this hypothesis isn't
re-investigated from scratch if a similar symptom reappears — check the
app-level cause first, Cloudflare content-modification features are
already confirmed off for this zone.

## Related

- [How Cloudflare routes traffic into the cluster](architecture.md) — the
  request-flow architecture this page's limitations apply to.
