# The Temporal worker's least-privilege role (ADR-0001 D-16/D-17).
#
# ROOT-CAUSE FIX for the dev-run failure: the worker was using static temporary STS
# creds that EXPIRED mid-job. In prod the worker runs on ECS/EC2 and ASSUMES this role,
# so the AWS SDK auto-refreshes its credentials — they never expire out from under a
# running job. Scoped to exactly what the Fargate launcher does: run/stop/describe the
# sandbox task, pass the task roles, and read the job's logs. Nothing else.

data "aws_caller_identity" "current" {}

locals {
  sandbox_taskdef_any_revision = "arn:aws:ecs:${var.region}:${data.aws_caller_identity.current.account_id}:task-definition/${aws_ecs_task_definition.sandbox.family}:*"
}

resource "aws_iam_role" "worker" {
  name               = "${var.prefix}-worker"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json # runs as an ECS task
}

data "aws_iam_policy_document" "worker" {
  statement {
    sid       = "RunSandboxTask"
    actions   = ["ecs:RunTask"]
    resources = [local.sandbox_taskdef_any_revision]
    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = [aws_ecs_cluster.this.arn]
    }
  }
  statement {
    sid       = "ManageSandboxTasks"
    actions   = ["ecs:StopTask", "ecs:DescribeTasks", "ecs:ListTasks"]
    resources = ["*"]
    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = [aws_ecs_cluster.this.arn]
    }
  }
  statement {
    sid       = "PassSandboxRoles"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.execution.arn, aws_iam_role.task.arn]
  }
  statement {
    sid       = "ReadJobLogs"
    actions   = ["logs:GetLogEvents"]
    resources = ["${aws_cloudwatch_log_group.sandbox.arn}:*"]
  }
  # The panel (which shares this role) shows the agent token-pool count in its cockpit.
  # Narrowly scoped to that one parameter + the key that encrypts it; the panel returns
  # only the count/ids to clients, never a token value.
  statement {
    sid       = "ReadTokenPoolForCockpit"
    actions   = ["ssm:GetParameter"]
    resources = [data.aws_ssm_parameter.agent_tokens.arn]
  }
  statement {
    sid       = "DecryptTokenPool"
    actions   = ["kms:Decrypt"]
    resources = [data.aws_kms_alias.ssm.target_key_arn]
  }
}

resource "aws_iam_role_policy" "worker" {
  name   = "${var.prefix}-worker"
  role   = aws_iam_role.worker.id
  policy = data.aws_iam_policy_document.worker.json
}

output "worker_role_arn" {
  value = aws_iam_role.worker.arn
}
