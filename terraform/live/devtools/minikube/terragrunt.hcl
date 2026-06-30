terraform {
  source = "../../../modules/minikube"
}

include "root" {
  path = find_in_parent_folders("root.hcl")
}

inputs = {
  instance_name  = "minikube-devtools"
  instance_type  = "t3.xlarge"
  root_volume_size = 50

  vpc_id            = "vpc-0c5eaad2eb2976b41"
  subnet_tag_filter = "spokeSubnet"

  key_pair_name = "devtools-eks-nodes"

  argocd_chart_version        = "9.4.2"
  nginx_ingress_chart_version = "4.11.3"
  argocd_hostname             = "argocd.devopstashtiot.page"

  tunnel_credentials_s3_bucket = "terraform-state-342831714456"
  tunnel_credentials_s3_key    = "cloudflare/devtools-labs-tunnel.json"
}
