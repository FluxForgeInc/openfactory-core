# The panel on AWS App Runner — a managed container host that gives a STABLE HTTPS URL
# out of the box, so a link shared with a partner never breaks (unlike the Fargate task's
# ephemeral public IP + plain HTTP). App Runner doesn't support ARM, so it runs a
# dedicated amd64 build of the panel image (the worker/jobs stay ARM/Graviton). OFF by
# default: created only when panel_apprunner_image_tag AND panel_token are set.

variable "panel_apprunner_image_tag" {
  type        = string
  default     = ""
  description = "amd64 image tag for the App Runner panel (e.g. abc1234-amd64). Empty → no App Runner panel. Must be amd64 — App Runner can't run our ARM images."
}

locals {
  apprunner_on = (var.panel_apprunner_image_tag != "" && var.panel_token != "") ? 1 : 0
}

# --- access role: lets App Runner pull the image from our private ECR repo ---
data "aws_iam_policy_document" "apprunner_build_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["build.apprunner.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "apprunner_access" {
  count              = local.apprunner_on
  name               = "${var.prefix}-panel-apprunner-access"
  assume_role_policy = data.aws_iam_policy_document.apprunner_build_assume.json
}

resource "aws_iam_role_policy_attachment" "apprunner_ecr" {
  count      = local.apprunner_on
  role       = aws_iam_role.apprunner_access[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSAppRunnerServicePolicyForECRAccess"
}

# --- instance role: the running panel's identity (read CloudWatch logs + resolve tasks +
#     read the injected secrets & the token pool). Same least-privilege as the worker. ---
data "aws_iam_policy_document" "apprunner_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["tasks.apprunner.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "apprunner_instance" {
  count              = local.apprunner_on
  name               = "${var.prefix}-panel-apprunner-instance"
  assume_role_policy = data.aws_iam_policy_document.apprunner_tasks_assume.json
}

data "aws_iam_policy_document" "apprunner_instance" {
  statement {
    sid       = "ReadJobLogs"
    actions   = ["logs:GetLogEvents"]
    resources = ["${aws_cloudwatch_log_group.sandbox.arn}:*"]
  }
  statement {
    # The pre-flight sizer/splitter runs on the WORKER (no Fargate task), so the panel tails
    # the worker log group, filtered to one job's OPENFACTORY_EVENT lines, to stream sizing live.
    sid       = "ReadPreflightFromWorkerLogs"
    actions   = ["logs:FilterLogEvents"]
    resources = ["${aws_cloudwatch_log_group.worker.arn}:*"]
  }
  statement {
    sid       = "ResolveJobTasks"
    actions   = ["ecs:ListTasks", "ecs:DescribeTasks"]
    resources = ["*"]
    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = [aws_ecs_cluster.this.arn]
    }
  }
  statement {
    sid     = "ReadSecretsAndPool"
    actions = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = [
      data.aws_ssm_parameter.temporal_api_key.arn,
      data.aws_ssm_parameter.botkey.arn,
      data.aws_ssm_parameter.agent_tokens.arn,
    ]
  }
  statement {
    sid       = "Decrypt"
    actions   = ["kms:Decrypt"]
    resources = [data.aws_kms_alias.ssm.target_key_arn]
  }
  statement {
    # The panel reads the cost dashboard and the agents' memory from the metrics table, and serves
    # the right-to-be-forgotten deletion (ForgettingSink) — same verbs the worker role gets.
    sid = "MetricsReadWrite"
    actions = [
      "dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:Query", "dynamodb:Scan",
      "dynamodb:DeleteItem", "dynamodb:BatchWriteItem",
    ]
    resources = [
      aws_dynamodb_table.metrics.arn,
      "${aws_dynamodb_table.metrics.arn}/index/*",
    ]
  }
}

resource "aws_iam_role_policy" "apprunner_instance" {
  count  = local.apprunner_on
  name   = "${var.prefix}-panel-apprunner"
  role   = aws_iam_role.apprunner_instance[0].id
  policy = data.aws_iam_policy_document.apprunner_instance.json
}

resource "aws_apprunner_service" "panel" {
  count        = local.apprunner_on
  service_name = "${var.prefix}-panel"

  source_configuration {
    auto_deployments_enabled = false
    authentication_configuration {
      access_role_arn = aws_iam_role.apprunner_access[0].arn
    }
    image_repository {
      image_identifier      = "${aws_ecr_repository.worker.repository_url}:${var.panel_apprunner_image_tag}"
      image_repository_type = "ECR"
      image_configuration {
        port          = "8787"
        start_command = "uvicorn openfactory.api.app:app --host 0.0.0.0 --port 8787"
        runtime_environment_variables = {
          PYTHONUNBUFFERED            = "1"
          # So the panel's remote-tail + "boxes are remote" read fargate (ADR-0040 D2): the new
          # core reads OPENFACTORY_SANDBOX and no longer infers the box from the cluster name.
          OPENFACTORY_SANDBOX         = "fargate"
          OPENFACTORY_LOG_GROUP       = aws_cloudwatch_log_group.sandbox.name
          TEMPORAL_ENDPOINT           = var.temporal_endpoint
          TEMPORAL_NAMESPACE          = var.temporal_namespace
          AWS_DEFAULT_REGION          = var.region
          OPENFACTORY_FARGATE_CLUSTER        = aws_ecs_cluster.this.name
          OPENFACTORY_FARGATE_SUBNETS        = join(",", data.aws_subnets.public.ids)
          OPENFACTORY_FARGATE_SG             = aws_security_group.sandbox.id
          OPENFACTORY_FARGATE_TASKDEF        = aws_ecs_task_definition.sandbox.family
          OPENFACTORY_FARGATE_LOG_GROUP      = aws_cloudwatch_log_group.sandbox.name
          OPENFACTORY_WORKER_LOG_GROUP       = aws_cloudwatch_log_group.worker.name
          OPENFACTORY_GH_APP_ID              = var.bot_app_id
          OPENFACTORY_GH_APP_INSTALLATION_ID = var.bot_installation_id
          OPENFACTORY_PANEL_TOKEN            = var.panel_token
          OPENFACTORY_PROD_APPROVERS         = var.prod_approvers
          OPENFACTORY_PLANNER_MODEL          = var.planner_model
          OPENFACTORY_EXECUTOR_MODEL         = var.executor_model
          # The cost dashboard's store — makes metrics_sink_kind() resolve to the add-on's
          # `dynamodb` row so the panel reads the dashboard and the agents' memory from it.
          OPENFACTORY_METRICS_TABLE          = aws_dynamodb_table.metrics.name
          # The cockpit reports the pool the sandbox jobs run on — the SSM parameter (ReadSecretsAndPool
          # above grants it), not the panel's own environment.
          OPENFACTORY_TOKEN_POOL_SOURCE      = "ssm"
        }
        runtime_environment_secrets = {
          TEMPORAL_API_KEY        = data.aws_ssm_parameter.temporal_api_key.arn
          OPENFACTORY_GH_APP_KEY_CONTENT = data.aws_ssm_parameter.botkey.arn
        }
      }
    }
  }

  instance_configuration {
    cpu               = "0.25 vCPU"
    memory            = "0.5 GB"
    instance_role_arn = aws_iam_role.apprunner_instance[0].arn
  }

  health_check_configuration {
    protocol = "TCP"
  }

  tags = { Name = "${var.prefix}-panel" }
}

output "panel_apprunner_url" {
  # the panel resource carries panel_token in its env, which taints derived attributes as
  # sensitive; the URL itself isn't secret — read it with `terraform output -raw`.
  sensitive = true
  value     = local.apprunner_on == 1 ? "https://${aws_apprunner_service.panel[0].service_url}" : "app-runner panel OFF (set panel_apprunner_image_tag + panel_token)"
}
