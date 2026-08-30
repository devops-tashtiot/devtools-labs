# AWS Backup — a second, independent layer on top of RDS's own automated
# backups and the minikube module's DLM policy. Both of those live inside
# the same account under the same broad admin role that deleted everything
# in the first place (an accidental or deliberate rds:DeleteDBSnapshot /
# ec2:DeleteSnapshot from that role can still remove them). AWS Backup gives
# one place to later apply Vault Lock (compliance or governance mode, see
# below) — a protection that holds even against the account's own admins,
# which nothing else in this repo provides.
#
# NOT locked yet, by deliberate choice — this vault is unlocked so its
# behavior can be observed for a while first. To lock it later:
#
#   resource "aws_backup_vault_lock_configuration" "this" {
#     backup_vault_name = aws_backup_vault.this.name
#     changeable_for_days = 3     # governance mode: still overridable within this window
#     max_retention_days  = 90
#     min_retention_days  = var.retention_days
#   }
#
# Omitting changeable_for_days makes the lock COMPLIANCE mode instead —
# irreversible for min_retention_days, not even by the root user or AWS
# support. Confirm that tradeoff explicitly before adding it; it is a
# one-way door once applied.

resource "aws_backup_vault" "this" {
  name = var.vault_name
}

data "aws_iam_policy_document" "backup_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["backup.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "backup" {
  name               = "${var.project_name}-aws-backup-role"
  assume_role_policy = data.aws_iam_policy_document.backup_assume_role.json
}

resource "aws_iam_role_policy_attachment" "backup" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

resource "aws_iam_role_policy_attachment" "restores" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores"
}

resource "aws_backup_plan" "this" {
  name = "${var.project_name}-daily-backup-plan"

  rule {
    rule_name         = "daily"
    target_vault_name = aws_backup_vault.this.name
    schedule          = var.schedule_cron

    lifecycle {
      delete_after = var.retention_days
    }
  }
}

# Two selection mechanisms on purpose: the RDS instance is targeted directly
# by ARN (there's exactly one, no ambiguity), while anything else opted in
# (the minikube EBS data volume) is targeted by tag — matches the same
# tag-based pattern the minikube module's own DLM policy already uses for
# target_tags, so a future additional volume/resource just needs the tag,
# not a Terraform change here.
resource "aws_backup_selection" "this" {
  name         = "${var.project_name}-backup-selection"
  plan_id      = aws_backup_plan.this.id
  iam_role_arn = aws_iam_role.backup.arn

  resources = [
    var.rds_instance_arn,
  ]

  selection_tag {
    type  = "STRINGEQUALS"
    key   = var.backup_target_tag_key
    value = var.backup_target_tag_value
  }
}
