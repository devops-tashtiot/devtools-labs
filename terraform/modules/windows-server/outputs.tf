output "instance_id" {
  description = "EC2 instance ID (use this with SSM)"
  value       = var.instance_enabled ? aws_instance.windows[0].id : null
}

output "private_ip" {
  description = "Private IP of the Windows server"
  value       = var.instance_enabled ? aws_instance.windows[0].private_ip : null
}

output "vpc_id" {
  description = "VPC ID the instance is deployed into"
  value       = data.aws_vpc.horizon.id
}

output "subnet_id" {
  description = "Subnet ID the instance is deployed into"
  value       = data.aws_subnet.windows.id
}

output "security_group_id" {
  description = "Security group ID attached to the instance"
  value       = aws_security_group.windows.id
}

output "ssm_session_command" {
  description = "Open an interactive SSM session on the Windows server"
  value       = var.instance_enabled ? "aws ssm start-session --target ${aws_instance.windows[0].id} --region ${var.aws_region} --profile ${var.aws_profile}" : "Instance not deployed (instance_enabled = false)"
}

output "ssm_rdp_command" {
  description = "Start SSM port-forwarding for RDP (then connect to localhost:13389)"
  value       = var.instance_enabled ? "aws ssm start-session --target ${aws_instance.windows[0].id} --document-name AWS-StartPortForwardingSession --parameters portNumber=3389,localPortNumber=13389 --region ${var.aws_region} --profile ${var.aws_profile}" : "Instance not deployed (instance_enabled = false)"
}

output "fleet_manager_url" {
  description = "AWS Fleet Manager browser-based RDP (Option 1 — no local client needed)"
  value       = var.instance_enabled ? "https://${var.aws_region}.console.aws.amazon.com/systems-manager/fleet-manager/managed-nodes/${aws_instance.windows[0].id}/remote-desktop" : "Instance not deployed (instance_enabled = false)"
}

output "admin_password_command" {
  description = "Decrypt the initial Administrator password (requires key pair)"
  value       = var.instance_enabled && var.key_pair_name != "" ? "aws ec2 get-password-data --instance-id ${aws_instance.windows[0].id} --priv-launch-key <path-to-${var.key_pair_name}.pem> --region ${var.aws_region} --profile ${var.aws_profile}" : "No key pair configured — use SSM Fleet Manager to set a password."
}
