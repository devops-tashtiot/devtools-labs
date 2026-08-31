# How Cloudflare Routes Traffic Into the Cluster

`*.devopstashtiot.page` has no inbound-facing LoadBalancer, public IP, or
open firewall port anywhere in this platform. A browser reaching a devtool
and an in-cluster caller reaching the exact same hostname take genuinely
different paths, converging only at `ingress-nginx-controller`.

## A browser hitting `https://bitbucket.devopstashtiot.page`

```
Browser
  │  DNS lookup (public) — CNAME to <tunnel-id>.cfargotunnel.com, proxied (orange-cloud)
  ▼
Cloudflare anycast edge
  │  Cloudflare Access: valid session cookie present?
  │    no  → redirect to email one-time-code login, then back here
  │    yes → continue
  ▼
Cloudflare Tunnel (the pre-established OUTBOUND connection from cloudflared)
  │  request travels down the tunnel cloudflared already opened
  ▼
cloudflared pod (inside the cluster)
  │  matches the request against its ingress rules (a single catch-all today):
  │    service: https://ingress-nginx-controller.ingress-nginx.svc.cluster.local:443
  │    originServerName: devopstashtiot.page   (TLS SNI override — see note below)
  ▼
ingress-nginx-controller Service (ClusterIP, in-cluster)
  │  routes by Host header, same as any Kubernetes Ingress controller
  ▼
bitbucket Service → bitbucket-0 pod
```

**Why `originServerName` is set explicitly**: `cloudflared` connects to
ingress-nginx over *real* HTTPS (ingress-nginx presents a Cloudflare Origin
Certificate on :443), not plain HTTP — plain HTTP was tried first and was
the root cause of every devtool computing the wrong
`X-Forwarded-Port`/`X-Forwarded-Proto` (nginx's `$scheme`/`$server_port`
reflect the actual connection, which was always `http`/`80` regardless of
what scheme the browser used at the edge; RHBK/Keycloak and Bitbucket both
built `:80` redirect URLs because of this). But `cloudflared` connects to
the Service by its cluster-DNS name
(`ingress-nginx-controller.ingress-nginx.svc.cluster.local`), which the
Origin Certificate's SAN doesn't cover — the cert only covers
`*.devopstashtiot.page`/`devopstashtiot.page`. `originServerName` overrides
only what's used for TLS validation (the SNI/hostname the cert is checked
against), not where the connection actually goes — so the connection still
opens to the cluster-DNS name, but Cloudflare validates the certificate as
if it had connected to `devopstashtiot.page`.

## An in-cluster caller hitting the same hostname

Example: `argocd-server`'s own OIDC discovery call to
`rhbk.devopstashtiot.page` during login.

```
argocd-server pod
  │  DNS lookup for rhbk.devopstashtiot.page
  ▼
CoreDNS (in-cluster resolver)
  │  rewrite name exact rhbk.devopstashtiot.page
  │    ingress-nginx-controller.ingress-nginx.svc.cluster.local answer auto
  ▼
ingress-nginx-controller Service (ClusterIP) — SAME final step as the browser path
  │  routes by Host header
  ▼
rhbk Service → rhbk-0 pod
```

No Cloudflare edge, no tunnel, no Access check — the DNS answer is
substituted before the request ever leaves the cluster's own network. Both
paths converge on the same `ingress-nginx-controller` Service; only how a
caller *reaches* that Service differs.

**Why this rewrite has to exist.** Without it, an in-cluster caller's DNS
lookup for `rhbk.devopstashtiot.page` would resolve the normal, public
way — straight to Cloudflare's edge, exactly like a browser's would. The
request would still technically succeed in reaching RHBK (Cloudflare would
forward it right back into the cluster via the tunnel), but the *TLS
certificate chain* would be wrong for that caller: RHBK's own OIDC client
is configured to trust only the internal Origin CA (a private CA used for
east-west/in-cluster TLS), not whatever public CA actually terminates
Cloudflare's edge-facing certificate. The handshake itself works fine; the
caller just doesn't trust the chain, and the call fails with a
certificate-verification error. Routing in-cluster callers directly to the
ClusterIP sidesteps the problem entirely — no public cert, no trust
mismatch.

The rewrite list currently covers: `bitbucket`, `confluence`, `jira`,
`sonarqube`, `artifactory`, `harbor`, `rhbk`, and `woodpecker`
(`*.devopstashtiot.page`), plus a dedicated pair of rules for
`argocd.devopstashtiot.page` and any `*.argocd.devopstashtiot.page`
subdomain (routed to `argocd-server` directly rather than through
ingress-nginx, since no Ingress rule exists for arbitrary ArgoCD
subdomains).

**How the rewrite is actually applied** — worth calling out since two
other approaches were tried first and didn't hold up: injected via the
`coredns` EKS addon's own `configuration_values.corefile` field, not a
direct ConfigMap edit. A `coredns-custom` ConfigMap + `import` extension
point was tried first — it doesn't exist on this EKS addon version
(confirmed live: the default Corefile has no such import, and the CoreDNS
Deployment only mounts the main ConfigMap's own key). A direct patch of the
addon-owned ConfigMap was tried next — it works, but the addon controller
can revert it on its own reconciliation/upgrade pass, since Terraform
doesn't own that ConfigMap as a resource. Setting it via the addon's own
supported configuration input survives addon upgrades and needs no
separate restart step.

## Cloudflare Access

Every hostname under `*.devopstashtiot.page` sits behind Cloudflare Access
with a single policy: only a fixed allowlist of email addresses can
authenticate, via a one-time code sent by email (no separate credential to
manage). This is enforced entirely at Cloudflare's edge, before a request
ever reaches the tunnel — the cluster itself has no idea Access exists.

## What's not covered here

This page is scoped to the network path — Cloudflare Access, the
tunnel, and the DNS-rewrite split. It does not cover: how the Tunnel
credential itself gets provisioned (a one-time `cloudflared tunnel create`,
stored in SSM at `/devops/prerequisite/cloudflare/tunnel-credentials` and
pulled in via an `ExternalSecret`), Cloudflare Access service tokens used
for non-interactive access (e.g. pushing to Bitbucket from outside the
cluster), or the Origin CA certificate's own issuance/rotation. See the
parent `CLAUDE.md`'s Cloudflare section for those.
