output "vault_name" {
  value = aws_backup_vault.this.name
}

output "vault_arn" {
  value = aws_backup_vault.this.arn
}

output "backup_plan_id" {
  value = aws_backup_plan.this.id
}
