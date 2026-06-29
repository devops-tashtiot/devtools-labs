terraform {
  source = "../../../modules/windows-server"
}

include "root" {
  path = find_in_parent_folders("root.hcl")
}

inputs = {
  hostname         = "WIN-SRV-01"
  instance_type    = "t3.micro"  # Free-tier eligible: 750 hrs/month Windows (t2.micro not available in il-central-1)
  root_volume_size = 30
  instance_enabled = true

  vpc_id                    = ""
  private_subnet_tag_filter = "spokeSubnet1"

  key_pair_name = ""
}
