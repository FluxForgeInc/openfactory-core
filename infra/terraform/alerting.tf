# Operational alerting (O1) — a silent failure is the one thing this platform must
# never have. Everything lands on one SNS topic; subscribe an email via alert_email.

resource "aws_sns_topic" "alerts" {
  name = "${var.prefix}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alert_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# 1) Any ECS task in the cluster stopping with a non-zero exit code — catches both a
#    crash-looping worker and a failed sandbox/promotion task.
resource "aws_cloudwatch_event_rule" "task_failed" {
  name = "${var.prefix}-task-failed"
  event_pattern = jsonencode({
    source      = ["aws.ecs"]
    detail-type = ["ECS Task State Change"]
    detail = {
      clusterArn = [aws_ecs_cluster.this.arn]
      lastStatus = ["STOPPED"]
      containers = { exitCode = [{ anything-but = 0 }] }
    }
  })
}

resource "aws_cloudwatch_event_target" "task_failed_sns" {
  rule = aws_cloudwatch_event_rule.task_failed.name
  arn  = aws_sns_topic.alerts.arn
}

resource "aws_sns_topic_policy" "allow_events" {
  arn = aws_sns_topic.alerts.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sns:Publish"
      Resource  = aws_sns_topic.alerts.arn
    }]
  })
}

# 2) The worker RUNNING but broken (e.g. expired Temporal key → poll failures): ECS
#    never restarts that, so watch its log for error patterns.
resource "aws_cloudwatch_log_metric_filter" "worker_errors" {
  name           = "${var.prefix}-worker-errors"
  log_group_name = aws_cloudwatch_log_group.worker.name
  pattern        = "?ERROR ?Traceback ?\"Failed to poll\""
  metric_transformation {
    name          = "WorkerErrors"
    namespace = "OPENFACTORY"
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_metric_alarm" "worker_errors" {
  alarm_name          = "${var.prefix}-worker-errors"
  namespace = "OPENFACTORY"
  metric_name         = "WorkerErrors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 5 # a burst of errors, not a single transient line
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

# 3) Cost guardrail (O6): a monthly budget alert so a runaway loop is a mail, not a bill.
resource "aws_budgets_budget" "monthly" {
  name         = "${var.prefix}-monthly"
  budget_type  = "COST"
  limit_amount = "50"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = var.alert_email == "" ? ["ops@invalid.example"] : [var.alert_email]
  }
}

# 4) ECR hygiene (O8): sha-tagged images accumulate forever without a lifecycle policy.
# 20 images = 20 deploys of history (1 push per deploy). Slack matters: deploy.sh pushes
# BEFORE terraform apply, so consecutive failed applies leave live pins on aging tags — a
# pruned pinned tag = CannotPullContainerError on the next task start (audit).
resource "aws_ecr_lifecycle_policy" "sandbox" {
  repository = aws_ecr_repository.sandbox.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "keep last 20 images"
      selection = {
        tagStatus = "any", countType = "imageCountMoreThan", countNumber = 20
      }
      action = { type = "expire" }
    }]
  })
}

# The worker repo holds TWO images per deploy (worker arm64 `sha` + panel amd64 `sha-amd64`),
# so N here = N/2 deploys of history — keep 30 = 15 deploys. A keep-10 was only FIVE deploys
# of slack for the tags the worker task-def and the App Runner panel are pinned to (audit HIGH:
# push-before-apply failures can strand live pins on aging tags).
resource "aws_ecr_lifecycle_policy" "worker" {
  repository = aws_ecr_repository.worker.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "keep last 30 images (worker+panel share this repo: 2 per deploy)"
      selection = {
        tagStatus = "any", countType = "imageCountMoreThan", countNumber = 30
      }
      action = { type = "expire" }
    }]
  })
}
