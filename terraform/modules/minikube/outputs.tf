output "instance_id" {
  value       = aws_instance.minikube.id
  description = "EC2 instance ID — use with SSM: aws ssm start-session --target <id>"
}

output "private_ip" {
  value       = aws_instance.minikube.private_ip
  description = "Private IP of the Minikube EC2 instance."
}
