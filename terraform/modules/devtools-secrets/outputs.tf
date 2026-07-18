output "admin_password_ssm_parameter" {
  description = "SSM Parameter Store path holding the shared admin password"
  value       = aws_ssm_parameter.admin_password.name
}

output "rhbk_oidc_client_secret_ssm_parameter" {
  description = "SSM Parameter Store path holding the shared RHBK OIDC client secret"
  value       = aws_ssm_parameter.rhbk_oidc_client_secret.name
}
