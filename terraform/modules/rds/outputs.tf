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
  description = "Master DB password — mirrored into SSM Parameter Store (/devtools/rds/admin-password) so devtool init containers can provision their own per-tool databases/roles"
  value       = var.db_password
  sensitive   = true
}
