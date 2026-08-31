# Architecture Overview

What actually exists in AWS to bring the devtools platform up, and how the
pieces fit together. This is the resource map — for the Cloudflare-specific
request path, see [Cloudflare/CoreDNS routing](architecture.md); for the
apply sequence and prerequisites, see
[Bootstrap from scratch](bootstrap.md).

## The six things Terraform creates

Each is an independent `terragrunt` unit under `terraform/live/devtools` —
no dependency graph between them (see `devtools-labs/CLAUDE.md` → "Six
independent units").

```
                      ┌─────────────────────────────────────────┐
                      │              devtools-labs               │
                      │         (Terraform / Terragrunt)          │
                      └─────────────────────────────────────────┘
                                        │
        ┌──────────────┬───────────────┼───────────────┬──────────────┬──────────────┐
        ▼              ▼               ▼               ▼              ▼              ▼
   ┌────────┐    ┌──────────┐   ┌─────────────┐  ┌───────────┐  ┌──────────┐   ┌──────────┐
   │  eks   │    │   rds    │   │   domain-   │  │ cloudflare│  │ devtools-│   │  backup  │
   │        │    │          │   │  controller │  │           │  │ secrets  │   │          │
   └────────┘    └──────────┘   └─────────────┘  └───────────┘  └──────────┘   └──────────┘
```

### `eks` — the cluster itself (the slow one, does the real bootstrap)

- A multi-node, multi-AZ **EKS cluster** (`terraform-aws-modules/eks/aws`),
  in the existing `spokeSubnet1`/`spokeSubnet2` pair — no new VPC, subnet,
  NAT Gateway, or Elastic IP (creating any of those is hard-denied by this
  account's SCPs, not just a cost choice — see
  [SCP Limitations](https://devops-tashtiot.github.io/docs/aws/scp-limitations/)).
  Egress reuses a pre-existing shared VPC endpoint.
- Two **Managed Node Groups**: `devtools` (general-purpose, spans both
  AZs, `m6i.xlarge`/`2xlarge`/`4xlarge`) and `devtools-large` (a dedicated
  lane sized for Confluence's 4-core CPU request, which the primary
  group's smallest instance type can never satisfy). Both IAM roles carry
  `AmazonSSMManagedInstanceCore` — any node is reachable via SSM Session
  Manager, no SSH/bastion/key pair.
- **Storage**: `gp3` (EBS CSI, `reclaimPolicy: Delete`, node-local volumes
  — each devtool's `localHome`) and `efs-sc` (EFS CSI,
  `reclaimPolicy: Retain`, `ReadWriteMany` — Bitbucket/Jira/Confluence's
  `sharedHome`, matching Atlassian's own Data Center `SHARED_STORAGE`
  pattern). This module also provisions the EFS filesystem itself.
- **IRSA** (not node-wide IMDS credentials) for `external-secrets`,
  `aws-ebs-csi-driver`, `aws-efs-csi-driver`.
- Installs **ArgoCD** via Helm and registers two `ApplicationSet`
  app-of-apps — `clusters-applicationset` (cluster-infra: ingress-nginx,
  cloudflared, external-secrets-operator, rhbk) first, blocking until
  Synced+Healthy, then `devtools-applicationset` (Jira, Bitbucket,
  Confluence, Artifactory, ArgoCD, Xray, Woodpecker, Harbor, ...). From
  that point on, **ArgoCD owns everything in the cluster** — this
  Terraform module never touches an individual devtool or cluster-infra
  tool again.

### `rds` — the shared database

One PostgreSQL instance (`db.t3.small`, autoscaling storage) that most
devtools connect to as external storage, each provisioning its own
database/role via an init container. Master credentials are published to
SSM for those init containers to read.

### `domain-controller` — LDAP for SSO/directory testing

A Windows Server 2022 EC2 instance (not free-tier, ~$15/mo), optionally
promoted to an Active Directory forest, for testing LDAP directory
integration against Jira/Bitbucket/Confluence. Publishes admin/LDAP-bind
credentials to SSM.

### `cloudflare` — DNS, tunnel routing, Access, and the Origin CA

The Cloudflare zone, per-subdomain DNS records, and the Access policy
protecting `*.devopstashtiot.page`. Also manages the Origin CA
certificate every devtool trusts for in-cluster TLS. See
[Cloudflare/CoreDNS routing](architecture.md) for how a request actually
flows through this, and
[Cloudflare limitations & gotchas](cloudflare-limitations.md) for what's
constrained.

### `devtools-secrets` — platform-wide values not tied to one resource

The shared initial admin password every devtool uses, and the shared RHBK
OIDC client secret every devtool federates SSO through.

### `backup` — the actual disaster-recovery layer

An AWS Backup vault + daily plan covering the RDS instance (by ARN) and
anything tagged `BackupManaged=true` (the EFS shared-home filesystem
today), with a cross-region copy action landing a second copy in
`us-east-1` — independent of whatever caused an incident in the primary
region.

## What a human sets before any of this can run

A handful of SSM Parameter Store values are prerequisites, not generated —
see [Bootstrap from scratch → Prerequisite](bootstrap.md#2-prerequisite-ssm-parameters-you-set-by-hand)
for the exact list and how to set each one.

## What's NOT Terraform's job

Every cluster-infra tool and every devtool — their Helm charts, their
per-environment config, their versions — lives in four sibling repos
(`clusters-provision`/`clusters-definition`,
`devtools-provision`/`devtools-definition`) and is deployed and kept in
sync continuously by ArgoCD, not by anything in this repo. `devtools-labs`
creates the cluster and the handful of AWS-level resources above; it never
runs Helm or `kubectl apply` against an individual tool.
