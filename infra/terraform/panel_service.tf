# The panel as an ECS service (O5) — the human gate (prod approval) must not depend on
# a laptop being open. OFF by default: it is only created when panel_allowed_cidr is
# set (your IP/VPN range), so nothing is ever exposed by accident. Reuses the worker
# image (fastapi/uvicorn/gh are in it) and the worker IAM roles.

variable "panel_allowed_cidr" {
  type        = string
  default     = "" # empty → panel service NOT created
  description = "CIDR allowed to reach the panel (e.g. your-ip/32). Empty disables it."
}

variable "panel_token" {
  type        = string
  default     = ""
  sensitive   = true
  description = "OPENFACTORY_PANEL_TOKEN — bearer token gating the panel's mutating endpoints."
}

variable "prod_approvers" {
  type        = string
  default     = ""
  description = "Comma-separated approver logins for the deployed panel (no manifest on disk)."
}

locals {
  panel_on = var.panel_allowed_cidr == "" ? 0 : 1
}

resource "aws_security_group" "panel" {
  count       = local.panel_on
  name        = "${var.prefix}-panel"
  description = "Panel: ingress 8787 from the allowed CIDR only"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 8787
    to_port     = 8787
    protocol    = "tcp"
    cidr_blocks = [var.panel_allowed_cidr]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_cloudwatch_log_group" "panel" {
  count             = local.panel_on
  name              = "/ecs/${var.prefix}-panel"
  retention_in_days = 14
}

resource "aws_ecs_task_definition" "panel" {
  count                    = local.panel_on
  family                   = "${var.prefix}-panel"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.worker_execution.arn # reads the same secrets
  task_role_arn            = aws_iam_role.worker.arn           # ECS/logs reads (engine view)

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([
    {
      name      = "panel"
      image     = "${aws_ecr_repository.worker.repository_url}:${var.image_tag}"
      essential = true
      command   = ["uvicorn", "openfactory.api.app:app", "--host", "0.0.0.0", "--port", "8787"]
      environment = [
        { name = "PYTHONUNBUFFERED", value = "1" },
        # New core reads OPENFACTORY_SANDBOX (ADR-0040 D2); no longer inferred from the cluster.
        { name = "OPENFACTORY_SANDBOX", value = "fargate" },
        { name = "OPENFACTORY_LOG_GROUP", value = aws_cloudwatch_log_group.sandbox.name },
        { name = "TEMPORAL_ENDPOINT", value = var.temporal_endpoint },
        { name = "TEMPORAL_NAMESPACE", value = var.temporal_namespace },
        { name = "AWS_DEFAULT_REGION", value = var.region },
        { name = "OPENFACTORY_FARGATE_CLUSTER", value = aws_ecs_cluster.this.name },
        { name = "OPENFACTORY_FARGATE_SUBNETS", value = join(",", data.aws_subnets.public.ids) },
        { name = "OPENFACTORY_FARGATE_SG", value = aws_security_group.sandbox.id },
        { name = "OPENFACTORY_FARGATE_TASKDEF", value = aws_ecs_task_definition.sandbox.family },
        { name = "OPENFACTORY_FARGATE_LOG_GROUP", value = aws_cloudwatch_log_group.sandbox.name },
        { name = "OPENFACTORY_GH_APP_ID", value = var.bot_app_id },
        { name = "OPENFACTORY_GH_APP_INSTALLATION_ID", value = var.bot_installation_id },
        { name = "OPENFACTORY_PANEL_TOKEN", value = var.panel_token },
        { name = "OPENFACTORY_PROD_APPROVERS", value = var.prod_approvers },
        # The panel reads the cost dashboard and the agents' memory from here. Its task role is
        # aws_iam_role.worker (above), which aws_iam_role_policy.worker_metrics already grants.
        { name = "OPENFACTORY_METRICS_TABLE", value = aws_dynamodb_table.metrics.name },
        # The cockpit reports the pool the sandbox jobs run on — the SSM parameter, not the panel's
        # own environment. The worker role already reads that parameter (worker_execution_secrets).
        { name = "OPENFACTORY_TOKEN_POOL_SOURCE", value = "ssm" },
      ]
      secrets = [
        { name = "TEMPORAL_API_KEY", valueFrom = data.aws_ssm_parameter.temporal_api_key.arn },
        { name = "OPENFACTORY_GH_APP_KEY_CONTENT", valueFrom = data.aws_ssm_parameter.botkey.arn },
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = "/ecs/${var.prefix}-panel"
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "panel"
        }
      }
    }
  ])
  depends_on = [aws_cloudwatch_log_group.panel]
}

resource "aws_ecs_service" "panel" {
  count           = local.panel_on
  name            = "${var.prefix}-panel"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.panel[0].arn
  desired_count   = 1
  launch_type     = "FARGATE"

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = data.aws_subnets.public.ids
    security_groups  = [aws_security_group.panel[0].id]
    assign_public_ip = true
  }
}

output "panel_note" {
  value = local.panel_on == 0 ? "panel service OFF (set panel_allowed_cidr to enable)" : "panel ON :8787 (find the task's public IP in the ECS console)"
}
