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
  description = "Master DB password — consumed by the rds-databases module to provision per-tool databases"
  value       = var.db_password
  sensitive   = true
}
