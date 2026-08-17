terraform {
  source = "../../../modules/halbana_server"
}

include "root" {
  path = find_in_parent_folders("root.hcl")
}

inputs = {
  instance_name    = "halbana-server"
  instance_type    = "c5d.large"
  root_volume_size = 20
  swap_size_gb     = 4

  vpc_id            = "vpc-0c5eaad2eb2976b41"
  subnet_tag_filter = "spokeSubnet"

  key_pair_name = "devtools-eks-nodes"

  # On-Demand, not Spot: validated in practice that this box's NVMe instance
  # store gets wiped on every Spot interruption's "stop" (hit twice in one
  # afternoon on il-central-1), each time costing 20-30 minutes to redo
  # whatever images/exports were staged. On-Demand for c5d.large runs
  # ~$0.114/hr vs Spot's ~$0.045-0.048/hr — worth it for a box you're
  # actively staging work on. Stop or terminate it yourself when idle
  # (there's no nightly auto-stop schedule here, unlike minikube).
  enable_spot = false
}
