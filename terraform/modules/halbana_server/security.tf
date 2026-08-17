resource "aws_security_group" "halbana_server" {
  name_prefix = "halbana-server-"
  description = "Halbana scratch staging server - SSM access, VPC-internal only"
  vpc_id      = data.aws_vpc.horizon.id

  tags = { Name = "${var.instance_name}-sg" }

  lifecycle {
    create_before_destroy = true
  }
}

# NOTE: a new security group gets AWS's default "allow all outbound" egress
# rule automatically. Do not add-then-revoke a duplicate of this rule by hand
# (e.g. while testing in the console/CLI) — doing that once removed the real
# default rule instead of a duplicate, silently cutting all outbound traffic
# (including SSM's own connection back to AWS) until it was manually restored.
resource "aws_vpc_security_group_egress_rule" "all_out" {
  security_group_id = aws_security_group.halbana_server.id
  description       = "Allow all outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}
