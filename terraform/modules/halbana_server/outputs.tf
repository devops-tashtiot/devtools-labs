output "instance_id" {
  value       = aws_instance.halbana_server.id
  description = "EC2 instance ID — connect with: aws ssm start-session --target <id>"
}

output "private_ip" {
  value       = aws_instance.halbana_server.private_ip
  description = "Private IP of the halbana-server instance."
}

output "security_group_id" {
  value       = aws_security_group.halbana_server.id
  description = "halbana-server instance security group."
}

output "iam_instance_profile_name" {
  value       = aws_iam_instance_profile.halbana_server.name
  description = "Instance profile name."
}
