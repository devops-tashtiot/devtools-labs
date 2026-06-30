resource "aws_security_group" "minikube" {
  name_prefix = "minikube-"
  description = "Minikube node - SSM access, VPC-internal only"
  vpc_id      = data.aws_vpc.horizon.id

  tags = { Name = "${var.instance_name}-sg" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_egress_rule" "all_out" {
  security_group_id = aws_security_group.minikube.id
  description       = "Allow all outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}
