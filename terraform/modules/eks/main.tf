# EKS cluster — real multi-node/multi-AZ replacement for the single Minikube
# EC2 instance. Node group spans both existing spoke subnets (no new NAT/VPC
# resource — their 0.0.0.0/0 route already goes through a pre-existing shared
# VPC endpoint, confirmed live against this account before this module was
# written). Spot Managed Node Group, not Karpenter: this workload is a fixed,
# always-on roster of replicaCount:1 devtools with no autoscaling anywhere —
# a static allocation problem, not the dynamic/varying-shape problem Karpenter
# is built to optimize. Several smaller instance types (not one large node) so
# a single Spot interruption can't take the whole platform down at once, and
# so the node group actually spans both AZs.
locals {
  # Grants every node in every managed node group (current nodes via an
  # in-place role update, and any future node the ASG launches on
  # replacement/scale-out) SSM Session Manager + Run Command access — the
  # EKS-optimized AL2023 AMI already ships the SSM agent, it just has no IAM
  # permission to register without this. Lets an operator reach a node
  # directly (e.g. to run psql/kubectl from inside the VPC) the same way
  # devtools-labs/CLAUDE.md already documents for the domain-controller
  # instance, without hand-installing anything or baking a custom AMI. This
  # v21 module has no eks_managed_node_group_defaults input (removed from
  # earlier majors), so this is set per node group instead of once.
  ssm_node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version

  vpc_id     = data.aws_vpc.selected.id
  subnet_ids = data.aws_subnets.target.ids

  endpoint_public_access = var.endpoint_public_access
  enable_irsa            = true

  # terraform-aws-modules/eks/aws's default node security group only opens
  # node-to-node traffic on ephemeral ports (1025-65535), DNS (53), and a
  # handful of control-plane webhook ports — NOT arbitrary ports below 1025.
  # Never mattered on the single-instance Minikube EC2 this cluster replaced
  # (one node means every pod-to-pod call is local, never crosses a security
  # group boundary), but on this real multi-node cluster it silently breaks
  # any cross-node call to a Service listening below 1025 — concretely,
  # ingress-nginx-controller's 80/443. Since every clusters-definition/
  # clusters/rhbk/values.yaml-driven *.devopstashtiot.page hostname resolves
  # in-cluster straight to that Service via the CoreDNS rewrite (coredns.tf),
  # any backend-to-backend call to one of those hostnames (e.g. Confluence's
  # own OIDC-discovery fetch against RHBK during SSO setup) times out unless
  # the calling pod happens to land on the same node as the single
  # ingress-nginx-controller replica. Confirmed live: a debug pod on a
  # different node timed out connecting to the ingress-nginx-controller
  # ClusterIP on both 80 and 443, while the SG's own rule set showed no
  # matching ingress rule for either port. Self-referencing all-ports/all-
  # protocols is the module's own documented fix for this exact gap, and
  # matches this platform's actual trust model — no NetworkPolicies exist
  # anywhere in the cluster, so there's already no intra-cluster traffic
  # restriction to preserve by scoping this any narrower.
  node_security_group_additional_rules = {
    ingress_self_all = {
      description = "Node to node all ports/protocols (required for cross-node ClusterIP traffic on ports below 1025, e.g. ingress-nginx 80/443 - see comment above)"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
  }

  upgrade_policy = {
    support_type = var.upgrade_policy
  }

  # v21 defaults this to false (a deliberate move away from an implicit
  # grant) — without it, the IAM principal that actually runs Terraform has
  # no Kubernetes RBAC access at all, which is exactly what broke the first
  # real apply: node group + addons (AWS-API-managed) succeeded fine, but
  # every kubernetes/kubectl-provider resource (StorageClasses, the
  # coredns-custom ConfigMap) failed with a plain "Unauthorized".
  enable_cluster_creator_admin_permissions = true

  addons = {
    vpc-cni = {
      before_compute = true
    }
    kube-proxy = {}
    # configuration_values.corefile — the addon's own supported override
    # point (verified live: `aws eks describe-addon-configuration` for this
    # exact addon version lists "corefile" in its schema), not a direct
    # ConfigMap patch. resolve_conflicts_on_update defaults to OVERWRITE, so
    # this wins on every addon reconcile/upgrade — a raw kubernetes_config_map
    # patch (this module's first approach) has no such guarantee: the addon
    # controller can revert it on its own reconciliation pass, since the
    # ConfigMap is addon-managed state, not something Terraform/the addon
    # resource itself tracks as source of truth.
    coredns = {
      configuration_values = jsonencode({
        corefile = local.coredns_corefile
      })
    }
    aws-ebs-csi-driver = {
      service_account_role_arn = aws_iam_role.ebs_csi.arn
    }
    aws-efs-csi-driver = {
      service_account_role_arn = aws_iam_role.efs_csi.arn
    }
  }

  # ssm_node_iam_role_additional_policies (below) is applied to both groups —
  # this v21 module version has no eks_managed_node_group_defaults input
  # (removed from earlier majors), so each node group entry sets it directly.
  eks_managed_node_groups = {
    devtools = {
      instance_types     = var.node_instance_types
      capacity_type      = var.node_capacity_type
      kubernetes_version = coalesce(var.node_group_kubernetes_version, var.kubernetes_version)

      min_size     = var.node_min_size
      max_size     = var.node_max_size
      desired_size = var.node_desired_size

      iam_role_additional_policies = local.ssm_node_iam_role_additional_policies
    }
    # Second, small group carved out for devtools that can never fit the
    # primary group's smallest allowed type (see variables.tf's
    # node_large_instance_types comment — confluence's 4-core request always
    # exceeds m6i.xlarge's 3920m allocatable, regardless of how empty the
    # node is).
    devtools-large = {
      instance_types     = var.node_large_instance_types
      capacity_type      = var.node_capacity_type
      kubernetes_version = coalesce(var.node_group_kubernetes_version, var.kubernetes_version)

      min_size     = var.node_large_min_size
      max_size     = var.node_large_max_size
      desired_size = var.node_large_desired_size

      iam_role_additional_policies = local.ssm_node_iam_role_additional_policies
    }
  }

  tags = {
    Role = "devtools-eks"
  }
}

# ── EBS: gp3 StorageClass, WaitForFirstConsumer (required once nodes span
# multiple AZs — otherwise a PVC could bind before the scheduler knows which
# AZ the pod will land in, since EBS volumes are AZ-locked). ReclaimPolicy
# Delete: this is the AZ-locked, node-local-cache tier (each devtool's
# localHome, plus harbor/minio/woodpecker/xray/sonarqube/prometheus data) —
# reprovisionable state, not the thing worth protecting. Real shared devtool
# data lives on the efs-sc StorageClass below instead, which stays Retain.
# (This StorageClass's own reclaim_policy only governs newly-provisioned PVs
# going forward — a PV already bound before this change keeps whatever
# policy it had at creation time unless patched individually.)
resource "kubernetes_storage_class" "gp3" {
  metadata {
    name = "gp3"
    # Default StorageClass: several devtools (harbor, minio, woodpecker, xray,
    # sonarqube) never set an explicit storageClassName in devtools-provision,
    # relying on whatever the cluster marks default — EKS ships no default of
    # its own (only a plain, non-default `gp2` using the deprecated in-tree
    # provisioner), so without this their PVCs stay Pending forever.
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = {
    type = "gp3"
  }

  # No depends_on here — the kubernetes provider (providers.tf) already reads
  # module.eks.cluster_endpoint/cluster_certificate_authority_data directly,
  # which gives Terraform a fine-grained dependency on just those two output
  # attributes. A blanket `depends_on = [module.eks]` used to sit here
  # instead; its real cost showed up once, not before: `-target` can't
  # partially scope across a whole-module dependency, so targeting this
  # resource pulled in every other pending diff inside module.eks (node
  # group AMI/addon version bumps included) and triggered an unwanted
  # rolling node replacement. Removing it restores safe, narrow targeting.
}

# ── EFS: shared, multi-AZ storage for Bitbucket/Jira/Confluence's sharedHome
# PVCs (all three moved to ReadWriteMany here — not just Jira's, which is the
# only one strictly forced to by its hardcoded chart template — matching
# Atlassian's own documented Data Center "SHARED_STORAGE" pattern and
# removing the storage blocker for future multi-replica clustering).
resource "aws_security_group" "efs" {
  name_prefix = "${var.cluster_name}-efs-"
  description = "Allow NFS (2049) from EKS nodes only"
  vpc_id      = data.aws_vpc.selected.id

  ingress {
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.cluster_name}-efs-sg"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_efs_file_system" "shared_home" {
  encrypted = true

  # BackupManaged=true is the tag terraform/modules/backup's aws_backup_selection
  # matches on — this filesystem holds bitbucket/jira/confluence's sharedHome,
  # not just node-local cache data, so it's covered by the same daily
  # backup+cross-region-copy plan as the RDS instance.
  tags = {
    Name          = "${var.cluster_name}-shared-home"
    BackupManaged = "true"
  }
}

resource "aws_efs_mount_target" "shared_home" {
  for_each = toset(data.aws_subnets.target.ids)

  file_system_id  = aws_efs_file_system.shared_home.id
  subnet_id       = each.value
  security_groups = [aws_security_group.efs.id]
}

resource "kubernetes_storage_class" "efs" {
  metadata {
    name = "efs-sc"
  }

  storage_provisioner = "efs.csi.aws.com"
  reclaim_policy      = "Retain"

  parameters = {
    provisioningMode = "efs-ap"
    fileSystemId     = aws_efs_file_system.shared_home.id
    directoryPerms   = "700"
  }

  # depends_on scoped to just the mount targets (needed for real volume
  # provisioning to succeed later, not for this object's own creation) — no
  # module.eks reference here. See kubernetes_storage_class.gp3's comment
  # above for why a whole-module depends_on is dangerous with -target.
  depends_on = [aws_efs_mount_target.shared_home]
}

# Per-devtool EFS StorageClasses, each with a FIXED uid/gid matching that
# devtool's actual process user (bitbucket=2003, confluence=2002, jira=2001
# — confirmed live via `getent passwd` in each pod). efs-sc above leaves
# uid/gid unset, so the EFS CSI driver falls back to its own gidRangeStart
# default (50000) and hands out 50000, 50001, 50002... sequentially to
# whichever PVC asks first — nothing to do with any devtool's real identity.
# Access Point identity enforcement is *always* applied for dynamic
# provisioning (confirmed against the driver's own docs) regardless of what
# uid/gid is configured — even root inside the pod can't chown around a
# mismatched one, confirmed live 2026-09-01 ("Operation not permitted" on a
# plain `chown -R` against an efs-sc-provisioned volume). Baking in the
# correct identity here instead of trying to fix it after provisioning means
# a fresh PVC is correctly owned from the moment it's created — no
# chown/safe.directory workaround ever needed, and this self-heals
# correctly on a genuinely fresh volume (e.g. disaster recovery) the way a
# manually-created PV never would.
resource "kubernetes_storage_class" "efs_bitbucket" {
  metadata {
    name = "efs-sc-bitbucket"
  }

  storage_provisioner = "efs.csi.aws.com"
  reclaim_policy      = "Retain"

  parameters = {
    provisioningMode = "efs-ap"
    fileSystemId     = aws_efs_file_system.shared_home.id
    directoryPerms   = "700"
    uid              = "2003"
    gid              = "2003"
  }

  depends_on = [aws_efs_mount_target.shared_home]
}

resource "kubernetes_storage_class" "efs_confluence" {
  metadata {
    name = "efs-sc-confluence"
  }

  storage_provisioner = "efs.csi.aws.com"
  reclaim_policy      = "Retain"

  parameters = {
    provisioningMode = "efs-ap"
    fileSystemId     = aws_efs_file_system.shared_home.id
    directoryPerms   = "700"
    uid              = "2002"
    gid              = "2002"
  }

  depends_on = [aws_efs_mount_target.shared_home]
}

resource "kubernetes_storage_class" "efs_jira" {
  metadata {
    name = "efs-sc-jira"
  }

  storage_provisioner = "efs.csi.aws.com"
  reclaim_policy      = "Retain"

  parameters = {
    provisioningMode = "efs-ap"
    fileSystemId     = aws_efs_file_system.shared_home.id
    directoryPerms   = "700"
    uid              = "2001"
    gid              = "2001"
  }

  depends_on = [aws_efs_mount_target.shared_home]
}

# ── Base-path-scoped dynamic EFS provisioning, as an alternative to the
# efs-sc-* dynamic StorageClasses above. Still fully dynamic — a PVC against
# one of these StorageClasses gets a freshly created Access Point AND PV
# automatically, exactly like efs-sc-bitbucket does today — but `basePath`
# roots every Access Point this class provisions under a fixed, named
# directory (e.g. /bitbucket/pvc-<uuid>) instead of the filesystem root
# (/pvc-<uuid>). No access point or PV needs to be pre-created: EFS's own
# CreateAccessPoint API creates any missing parent directories in the path
# (here, /bitbucket itself) the first time it's asked to, using the same
# uid/gid/permissions enforcement as the existing efs-sc-* classes.
#
# Each app's PVC lands under a FRESH base path (/bitbucket, /confluence,
# /jira) — not the existing pvc-<uuid> directories the efs-sc-* classes
# already provisioned, which still hold live data (retained, just no longer
# mounted once each app's PVC is repointed here).
resource "kubernetes_storage_class" "efs_static_bitbucket" {
  metadata {
    name = "efs-static-bitbucket"
  }

  storage_provisioner = "efs.csi.aws.com"
  reclaim_policy      = "Retain"

  parameters = {
    provisioningMode = "efs-ap"
    fileSystemId     = aws_efs_file_system.shared_home.id
    directoryPerms   = "700"
    basePath         = "/bitbucket"
    uid              = "2003"
    gid              = "2003"
  }

  depends_on = [aws_efs_mount_target.shared_home]
}

resource "kubernetes_storage_class" "efs_static_confluence" {
  metadata {
    name = "efs-static-confluence"
  }

  storage_provisioner = "efs.csi.aws.com"
  reclaim_policy      = "Retain"

  parameters = {
    provisioningMode = "efs-ap"
    fileSystemId     = aws_efs_file_system.shared_home.id
    directoryPerms   = "700"
    basePath         = "/confluence"
    uid              = "2002"
    gid              = "2002"
  }

  depends_on = [aws_efs_mount_target.shared_home]
}

resource "kubernetes_storage_class" "efs_static_jira" {
  metadata {
    name = "efs-static-jira"
  }

  storage_provisioner = "efs.csi.aws.com"
  reclaim_policy      = "Retain"

  parameters = {
    provisioningMode = "efs-ap"
    fileSystemId     = aws_efs_file_system.shared_home.id
    directoryPerms   = "700"
    basePath         = "/jira"
    uid              = "2001"
    gid              = "2001"
  }

  depends_on = [aws_efs_mount_target.shared_home]
}

# ── CoreDNS: the rewrite rules are injected via the coredns EKS addon's own
# `configuration_values.corefile` (see the addons map above), not a direct
# ConfigMap patch. Two earlier approaches were tried and rejected in this
# exact module: (1) a "coredns-custom" ConfigMap + an
# `import /etc/coredns/custom/*.override` extension point — doesn't exist on
# this EKS addon version, confirmed live (default Corefile has no such
# import, and the coredns Deployment mounts only the main ConfigMap's own
# Corefile key); (2) a direct `kubernetes_config_map_v1_data` patch of the
# addon-owned "coredns" ConfigMap (force = true) — works, but the addon
# controller can revert it on its own reconciliation/upgrade pass, since
# that ConfigMap is addon-managed state, not something the addon resource
# itself treats as source of truth. `configuration_values` is the addon's
# actual supported override point (verified live via
# `aws eks describe-addon-configuration`) — it survives addon
# upgrades/reconciliation the other two don't, and needs no separate restart
# step: applying a new addon configuration triggers a supported rollout
# through the AWS-managed addon lifecycle already.
#
# Without these rewrites actually taking effect, in-cluster callers (e.g.
# argocd-server's own OIDC discovery call to rhbk.devopstashtiot.page)
# resolve via public DNS straight to Cloudflare's edge instead of
# ingress-nginx's ClusterIP — and since that OIDC client's TLS trust is
# scoped only to the internal Origin CA (not whatever public CA actually
# signed Cloudflare's edge cert), every such call fails with "certificate
# signed by unknown authority" even though the TLS handshake itself is
# otherwise fine. host.minikube.internal is dropped (Docker-driver-only,
# dead weight on EKS). The per-consumer ArgoCD wildcard is a deliberate
# exception, same as minikube's version: no Ingress rule exists for
# arbitrary *.argocd subdomains, so it routes straight to the one real
# argocd-server.
locals {
  coredns_rewrites = join("\n    ", concat(
    [
      "rewrite name exact argocd.devopstashtiot.page ingress-nginx-controller.ingress-nginx.svc.cluster.local answer auto",
      "rewrite name regex (.*)\\.argocd\\.devopstashtiot\\.page argocd-server.argocd.svc.cluster.local answer auto",
    ],
    [for h in var.coredns_rewrite_hosts : "rewrite name exact ${h} ingress-nginx-controller.ingress-nginx.svc.cluster.local answer auto"]
  ))

  coredns_corefile = <<-EOT
    .:53 {
        errors
        health {
            lameduck 5s
          }
        ready
        ${local.coredns_rewrites}
        kubernetes cluster.local in-addr.arpa ip6.arpa {
          pods insecure
          fallthrough in-addr.arpa ip6.arpa
        }
        prometheus :9153
        forward . /etc/resolv.conf
        cache 30
        loop
        reload
        loadbalance
    }
  EOT
}


