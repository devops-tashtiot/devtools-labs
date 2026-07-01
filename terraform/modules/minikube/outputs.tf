output "instance_id" {
  value       = aws_instance.minikube.id
  description = "EC2 instance ID — use with SSM: aws ssm start-session --target <id>"
}

output "private_ip" {
  value       = aws_instance.minikube.private_ip
  description = "Private IP of the Minikube EC2 instance."
}

output "vpc_id" {
  value       = data.aws_vpc.horizon.id
  description = "VPC the Minikube instance runs in."
}

output "subnet_ids" {
  value       = tolist(data.aws_subnets.target.ids)
  description = "Subnets matched by subnet_tag_filter, for reuse by other modules (e.g. RDS)."
}

output "security_group_id" {
  value       = aws_security_group.minikube.id
  description = "Minikube instance security group, for allow-listing (e.g. RDS ingress)."
}

output "iam_instance_profile_name" {
  value       = aws_iam_instance_profile.minikube.name
  description = "Instance profile name — reused by packer/minikube-ami/ so the AMI build instance can reach SSM without provisioning its own IAM resources."
}
