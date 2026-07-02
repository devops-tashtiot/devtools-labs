resource "aws_db_subnet_group" "this" {
  name       = "${var.identifier}-subnet-group"
  subnet_ids = data.aws_subnets.target.ids

  tags = {
    Name    = "${var.identifier}-subnet-group"
    Project = var.project_name
  }
}

resource "aws_security_group" "rds" {
  # name_prefix (not a fixed name) + create_before_destroy: the RDS instance
  # still holds an ENI on this SG, and this session's role can't detach ENIs
  # directly (AuthFailure on ec2:DetachNetworkInterface) — the DB instance
  # must be moved onto the new SG first so RDS itself detaches the ENI,
  # which requires the new SG to exist (and thus be uniquely named) before
  # the old one is destroyed.
  name_prefix = "${var.identifier}-rds-sg-"
  description = "Allow PostgreSQL from the spoke subnets"
  vpc_id      = data.aws_vpc.selected.id

  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.identifier}-rds-sg"
    Project = var.project_name
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_db_instance" "this" {
  identifier = var.identifier

  engine                      = "postgres"
  engine_version              = var.postgres_version
  instance_class              = var.instance_class
  allow_major_version_upgrade = true
  apply_immediately           = true

  db_name  = var.db_name
  username = var.db_username
  password = var.db_password

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage
  storage_type          = "gp2"

  backup_retention_period = 0
  skip_final_snapshot     = true
  deletion_protection     = false
  publicly_accessible     = false

  tags = {
    Project = var.project_name
  }
}
