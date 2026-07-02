# Nightly cost-saving stop. No matching start schedule — restart manually
# (console, `aws ec2 start-instances`, or SSM) when you need the box again.
# Uses an EventBridge Scheduler universal target to call ec2:StopInstances
# directly, so no Lambda is needed.

resource "aws_iam_role" "scheduler_stop_minikube" {
  count       = var.enable_nightly_stop ? 1 : 0
  name_prefix = "minikube-stop-schedule-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "scheduler_stop_minikube" {
  count = var.enable_nightly_stop ? 1 : 0
  name  = "stop-minikube-instance"
  role  = aws_iam_role.scheduler_stop_minikube[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "ec2:StopInstances"
      Resource = "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/${aws_instance.minikube.id}"
    }]
  })
}

resource "aws_scheduler_schedule" "stop_minikube" {
  count = var.enable_nightly_stop ? 1 : 0
  name  = "${var.instance_name}-nightly-stop"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression          = var.stop_schedule_cron
  schedule_expression_timezone = var.schedule_timezone

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:stopInstances"
    role_arn = aws_iam_role.scheduler_stop_minikube[0].arn

    input = jsonencode({
      InstanceIds = [aws_instance.minikube.id]
    })
  }
}
