output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_certificate_authority" {
  value = module.eks.cluster_certificate_authority_data
}

output "kubeconfig_command" {
  description = "Configure kubectl to talk to your cluster"
  value       = "aws eks update-kubeconfig --name ${var.cluster_name} --region ${var.aws_region} --profile ${var.aws_profile}"
}

output "vpc_id" {
  description = "VPC the cluster was deployed into"
  value       = data.aws_vpc.horizon.id
}

output "subnet_ids" {
  description = "All subnet IDs used by the cluster"
  value       = data.aws_subnets.target.ids
}

output "subnet_id" {
  description = "First subnet ID (use for single-subnet deployments)"
  value       = data.aws_subnet.eks.id
}

output "get_node_instance_ids" {
  description = "Command to list node instance IDs (needed for SSM/SSH targets)"
  value       = "kubectl get nodes -o json | jq -r '.items[].spec.providerID' | cut -d/ -f5"
}

output "ssm_node_command" {
  description = "Open an interactive SSM session on a node (no key pair needed)"
  value       = "aws ssm start-session --target <NODE_INSTANCE_ID> --region ${var.aws_region} --profile ${var.aws_profile}"
}

output "ssh_over_ssm_command" {
  description = "SSH into a node via SSM tunnel — port 22 never opens to the internet"
  value       = var.node_key_pair_name != "" ? "ssh -i ~/.ssh/${var.node_key_pair_name}.pem -o ProxyCommand='aws ssm start-session --target %h --document-name AWS-StartSSHSession --parameters portNumber=22 --region ${var.aws_region} --profile ${var.aws_profile}' ec2-user@<NODE_INSTANCE_ID>" : "Set node_key_pair_name to enable SSH-over-SSM."
}
