# The always-on Temporal worker as an ECS service (ADR-0001 D-16). It connects to
# Temporal Cloud, polls the task queue, and launches Fargate sandbox jobs — 24/7, no
# laptop. It assumes the least-privilege openfactory-worker role (auto-refreshing creds), reads
# the Temporal API key from Secrets Manager, and gets the sandbox config as plain env.

resource "aws_ecr_repository" "worker" {
  name                 = "${var.prefix}-worker"
  image_tag_mutability = "MUTABLE"
  image_scanning_configuration {
    scan_on_push = true
  }
}

data "aws_ssm_parameter" "temporal_api_key" {
  name            = "/openfactory/temporal-api-key"
  with_decryption = false
}

# Execution role: pull the worker image, write logs, inject the Temporal API key.
resource "aws_iam_role" "worker_execution" {
  name               = "${var.prefix}-worker-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_role_policy_attachment" "worker_execution" {
  role       = aws_iam_role.worker_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "worker_execution_secrets" {
  name = "${var.prefix}-worker-read-temporal-key"
  role = aws_iam_role.worker_execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = "ssm:GetParameters"
        Resource = [
          data.aws_ssm_parameter.temporal_api_key.arn,
          data.aws_ssm_parameter.botkey.arn,       # light forge reads (merge check, poll)
          data.aws_ssm_parameter.claude.arn,       # ADR-0013: the pre-flight sizer runs the agent
          data.aws_ssm_parameter.agent_tokens.arn, # on the WORKER, so it needs the token pool too
        ]
      },
      {
        Effect   = "Allow"
        Action   = "kms:Decrypt"
        Resource = data.aws_kms_alias.ssm.target_key_arn
      },
    ]
  })
}

resource "aws_cloudwatch_log_group" "worker" {
  name              = "/ecs/${var.prefix}-worker"
  retention_in_days = 14
}

resource "aws_ecs_task_definition" "worker" {
  family                   = "${var.prefix}-worker"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.worker_cpu
  memory                   = var.worker_memory
  execution_role_arn       = aws_iam_role.worker_execution.arn
  task_role_arn            = aws_iam_role.worker.arn # the least-privilege launcher role

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([
    {
      name      = "worker"
      image     = "${aws_ecr_repository.worker.repository_url}:${var.image_tag}"
      essential = true
      environment = [
        { name = "PYTHONUNBUFFERED", value = "1" }, # flush logs to CloudWatch live
        # The new core NO LONGER infers the box from the cluster var (ADR-0040 D2): it reads
        # OPENFACTORY_SANDBOX, else the local container. A cloud worker must say "fargate"
        # explicitly or every job would run the local docker path — which an ECS task has no
        # socket for. This is the one var the old (sdlc) tree did not need and the new one does.
        { name = "OPENFACTORY_SANDBOX", value = "fargate" },
        { name = "TEMPORAL_ENDPOINT", value = var.temporal_endpoint },
        { name = "TEMPORAL_NAMESPACE", value = var.temporal_namespace },
        { name = "AWS_DEFAULT_REGION", value = var.region },
        { name = "OPENFACTORY_FARGATE_CLUSTER", value = aws_ecs_cluster.this.name },
        # Alias the panel's tail path reads (`api/app.py` → OPENFACTORY_LOG_GROUP); the launcher
        # accepts either, but setting both keeps the worker and panel pointed at one log group.
        { name = "OPENFACTORY_LOG_GROUP", value = aws_cloudwatch_log_group.sandbox.name },
        { name = "OPENFACTORY_FARGATE_SUBNETS", value = join(",", data.aws_subnets.public.ids) },
        { name = "OPENFACTORY_FARGATE_SG", value = aws_security_group.sandbox.id },
        { name = "OPENFACTORY_FARGATE_TASKDEF", value = aws_ecs_task_definition.sandbox.family },
        { name = "OPENFACTORY_FARGATE_LOG_GROUP", value = aws_cloudwatch_log_group.sandbox.name },
        { name = "OPENFACTORY_GH_APP_ID", value = var.bot_app_id },
        { name = "OPENFACTORY_GH_APP_INSTALLATION_ID", value = var.bot_installation_id },
        { name = "OPENFACTORY_BOT_NAME", value = var.bot_name },
        { name = "OPENFACTORY_BOT_EMAIL", value = var.bot_email },
        # ADR-0013: the pre-flight sizer runs the agent (read-only) ON THE WORKER — give it the
        # same planner model as a sandbox job so sizing is cheap (sonnet, not opus).
        { name = "OPENFACTORY_PLANNER_MODEL", value = var.planner_model },
        # The cost dashboard's store. Setting this is what makes metrics_sink_kind() resolve to
        # `dynamodb` (the add-on's row) instead of Null — the worker writes job summaries here and
        # the panel reads the dashboard from it.
        { name = "OPENFACTORY_METRICS_TABLE", value = aws_dynamodb_table.metrics.name },
      ]
      secrets = [
        { name = "TEMPORAL_API_KEY", valueFrom = data.aws_ssm_parameter.temporal_api_key.arn },
        { name = "OPENFACTORY_GH_APP_KEY_CONTENT", valueFrom = data.aws_ssm_parameter.botkey.arn },
        # The sizer's agent CLI needs a credential. Same pool the sandbox uses (SSM). Without
        # this the sizer can't authenticate → pre-flight silently DEGRADED to "fit" and #37 ran
        # unsized (the live bug this fixes). The worker now carries the token pool too.
        { name = "CLAUDE_CODE_OAUTH_TOKEN", valueFrom = data.aws_ssm_parameter.claude.arn },
        { name = "OPENFACTORY_AGENT_TOKENS", valueFrom = data.aws_ssm_parameter.agent_tokens.arn },
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.worker.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "worker"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "worker" {
  name            = "${var.prefix}-worker"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.worker.arn
  desired_count   = var.worker_count
  launch_type     = "FARGATE"

  # don't start the task before the launcher IAM policy propagates (IAM is eventually
  # consistent) — else the first RunTask is AccessDenied until the next poll (M17).
  depends_on = [
    aws_iam_role_policy.worker,
    aws_iam_role_policy_attachment.worker_execution,
    aws_iam_role_policy.worker_execution_secrets,
  ]

  # roll back automatically if a bad image crash-loops on deploy (L8).
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = data.aws_subnets.public.ids
    security_groups  = [aws_security_group.sandbox.id] # egress-only is all it needs
    assign_public_ip = true                            # reach Temporal Cloud + AWS APIs
  }
}

output "worker_ecr_repository_url" {
  value = aws_ecr_repository.worker.repository_url
}

output "worker_service" {
  value = aws_ecs_service.worker.name
}
