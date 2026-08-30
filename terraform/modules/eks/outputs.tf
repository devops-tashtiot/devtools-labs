output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  value     = module.eks.cluster_certificate_authority_data
  sensitive = true
}

output "oidc_provider_arn" {
  value = module.eks.oidc_provider_arn
}

output "node_security_group_id" {
  value = module.eks.node_security_group_id
}

output "efs_file_system_id" {
  value = aws_efs_file_system.shared_home.id
}

output "vpc_id" {
  value = data.aws_vpc.selected.id
}

output "subnet_ids" {
  value = data.aws_subnets.target.ids
}
