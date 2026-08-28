locals {
  ssm_tags = {
    Repo      = "devtools-labs"
    Module    = "terraform/modules/rds"
    ManagedBy = "GitOps"
  }
}

resource "aws_db_subnet_group" "this" {
  name       = "${var.identifier}-subnet-group"
  subnet_ids = data.aws_subnets.target.ids

  tags = {
    Name = "${var.identifier}-subnet-group"
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
    Name = "${var.identifier}-rds-sg"
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

  backup_retention_period = var.backup_retention_period
  copy_tags_to_snapshot   = true
  # skip_final_snapshot=false + a fixed final_snapshot_identifier: a real,
  # Terraform-driven `terraform destroy` (the only path deletion_protection
  # leaves open — it must be disabled here first, a separate deliberate
  # commit) always leaves one last snapshot behind. Static, not timestamped,
  # to avoid a perpetual plan diff; a second destroy+recreate cycle needing
  # a fresh one can bump the suffix by hand.
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.identifier}-final-snapshot"
  deletion_protection       = var.deletion_protection
  publicly_accessible       = false

  tags = {
    Name = var.identifier
  }
}

resource "aws_ssm_parameter" "admin_username" {
  name        = var.admin_username_ssm_parameter
  description = "Category: terraform-created. Created by GitOps — devtools-labs Terraform (terraform/modules/rds). Do not edit manually; changes will be reverted on the next apply. RDS master DB username, consumed by devtool init containers (see devtools-definition/*/values.yaml's rds.usernameSsmParameter) to provision their own per-tool databases/roles. To change: edit db_username in terraform/live/devtools/rds/terragrunt.hcl and re-apply."
  type        = "SecureString"
  value       = var.db_username
  tags        = local.ssm_tags
}

resource "aws_ssm_parameter" "admin_password" {
  name        = var.admin_password_ssm_parameter
  description = "Category: terraform-created. Created by GitOps — devtools-labs Terraform (terraform/modules/rds). Do not edit manually; changes will be reverted on the next apply. RDS master DB password, consumed by devtool init containers (see devtools-definition/*/values.yaml's rds.passwordSsmParameter) to provision their own per-tool databases/roles. To set/rotate: export TF_VAR_db_password=<value> before running `terragrunt apply` in terraform/live/devtools/rds (Terraform prompts interactively if not exported)."
  type        = "SecureString"
  value       = var.db_password
  tags        = local.ssm_tags
}
