output "arn" {
  description = "RDS instance ARN — consumed by the backup module's aws_backup_selection to target this instance directly."
  value       = aws_db_instance.this.arn
}

output "endpoint" {
  description = "RDS instance endpoint (host:port)"
  value       = aws_db_instance.this.endpoint
}

output "address" {
  description = "RDS hostname"
  value       = aws_db_instance.this.address
}

output "port" {
  description = "RDS port"
  value       = aws_db_instance.this.port
}

output "db_name" {
  description = "Initial database name"
  value       = aws_db_instance.this.db_name
}

output "db_username" {
  description = "Master DB username"
  value       = aws_db_instance.this.username
}

output "admin_password" {
  description = "Master DB password — sourced from the shared prerequisite secret (generic_password_ssm_parameter) and mirrored into SSM Parameter Store (admin_password_ssm_parameter) so devtool init containers can provision their own per-tool databases/roles"
  value       = data.aws_ssm_parameter.generic_password.value
  sensitive   = true
}
