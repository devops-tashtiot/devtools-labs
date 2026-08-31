variable "aws_region" {
  type = string
}

variable "aws_profile" {
  type = string
}

variable "project_name" {
  type = string
}

variable "vault_name" {
  description = "AWS Backup vault name. All recovery points (RDS + EBS) land here."
  type        = string
  default     = "devtools-backup-vault"
}

variable "dr_region" {
  description = "Destination region for cross-region backup copies (RDS snapshots and EFS backups are regional resources — a single-region incident, or account-level action against the primary region, can't touch a copy that already landed here). us-east-1 chosen for confirmed AWS Backup + RDS resource-type support; eu-central-1/eu-west-1 were the closer EU-based alternatives considered."
  type        = string
  default     = "us-east-1"
}

variable "dr_vault_name" {
  description = "AWS Backup vault name in dr_region that copies land in."
  type        = string
  default     = "devtools-backup-vault-dr"
}

variable "dr_retention_days" {
  description = "Days the cross-region copy in dr_region is retained before deletion — independent of (and shorter than) retention_days, since the DR copy only needs to survive long enough to matter for a regional-incident scenario, not serve as the primary retention window."
  type        = number
  default     = 1
}

variable "rds_instance_arn" {
  description = "ARN of the RDS instance to back up via AWS Backup's native RDS support (produces a consistent DB snapshot through the Backup service, tracked in this vault instead of RDS's own disconnected snapshot list)."
  type        = string
}

variable "backup_target_tag_key" {
  description = "Tag key AWS Backup's resource selection matches on, for any additional resource (e.g. the minikube EBS data volume) opted in by tag rather than by explicit ARN. Matches the key the resource itself must carry with backup_target_tag_value."
  type        = string
  default     = "BackupManaged"
}

variable "backup_target_tag_value" {
  type    = string
  default = "true"
}

variable "schedule_cron" {
  description = "AWS Backup plan schedule (cron, UTC)."
  type        = string
  default     = "cron(0 3 * * ? *)"
}

variable "retention_days" {
  description = "Days AWS Backup retains each recovery point before deleting it. This is a plain, unlocked retention window — see the module README/comments for how to add Vault Lock (compliance or governance mode) on top of this vault later."
  type        = number
  default     = 3
}
