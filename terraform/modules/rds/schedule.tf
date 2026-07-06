# Nightly cost-saving stop. No matching start schedule — restart manually
# (console, `aws rds start-db-instance`, or SSM) when you need the DB again.
# Uses an EventBridge Scheduler universal target to call rds:StopDBInstance
# directly, so no Lambda is needed.

resource "aws_iam_role" "scheduler_stop_rds" {
  count       = var.enable_nightly_stop ? 1 : 0
  name_prefix = "rds-stop-schedule-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

data "aws_caller_identity" "current" {}

resource "aws_iam_role_policy" "scheduler_stop_rds" {
  count = var.enable_nightly_stop ? 1 : 0
  name  = "stop-rds-instance"
  role  = aws_iam_role.scheduler_stop_rds[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "rds:StopDBInstance"
      Resource = "arn:aws:rds:${var.aws_region}:${data.aws_caller_identity.current.account_id}:db:${aws_db_instance.this.id}"
    }]
  })
}

resource "aws_scheduler_schedule" "stop_rds" {
  count = var.enable_nightly_stop ? 1 : 0
  name  = "${var.identifier}-nightly-stop"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression          = var.stop_schedule_cron
  schedule_expression_timezone = var.schedule_timezone

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:rds:stopDBInstance"
    role_arn = aws_iam_role.scheduler_stop_rds[0].arn

    input = jsonencode({
      DbInstanceIdentifier = aws_db_instance.this.id
    })
  }
}
