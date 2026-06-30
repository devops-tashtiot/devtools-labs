resource "aws_iam_role_policy_attachment" "nodes_ssm" {
  role       = module.eks.eks_managed_node_groups["larger"].iam_role_name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "nodes_ebs_csi" {
  role       = module.eks.eks_managed_node_groups["larger"].iam_role_name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}
