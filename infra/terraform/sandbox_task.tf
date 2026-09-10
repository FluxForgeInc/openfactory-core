# The real sandbox task definition (ADR-0001 D-17): our ECR image runs the in-task
# entrypoint, which clones → runs the JobRunner → emits the RunResult. ARM64 (Graviton,
# ~20% cheaper). Credentials arrive via SSM Parameter Store (v1 token-in-task tradeoff).

# Credentials live in SSM Parameter Store SecureString (Standard tier = free; Secrets
# Manager charges $0.40/secret/mo and we don't use its rotation). ECS injects them at
# task start exactly the same way. with_decryption=false keeps the plaintext OUT of
# terraform state — we only need the ARN for the task-def valueFrom.
data "aws_ssm_parameter" "claude" {
  name            = "/openfactory/claude-oauth-token"
  with_decryption = false
}

data "aws_ssm_parameter" "botkey" {
  name            = "/openfactory/bot-app-private-key"
  with_decryption = false
}

# The agent credential POOL (JSON array) — the agent fails over between tokens on a
# rate-limit / auth stop instead of halting the job. Falls back to the single
# claude-oauth-token when absent, so this is additive.
data "aws_ssm_parameter" "agent_tokens" {
  name            = "/openfactory/agent-tokens"
  with_decryption = false
}

# the AWS-managed key that encrypts SecureString params; the execution roles must be
# allowed to decrypt with it to read the params.
data "aws_kms_alias" "ssm" {
  name = "alias/aws/ssm"
}

# The EXECUTION role reads the params at task start → inject as env.
data "aws_iam_policy_document" "read_secrets" {
  statement {
    actions = ["ssm:GetParameters"]
    resources = [
      data.aws_ssm_parameter.claude.arn,
      data.aws_ssm_parameter.botkey.arn,
      data.aws_ssm_parameter.agent_tokens.arn,
    ]
  }
  statement {
    actions   = ["kms:Decrypt"]
    resources = [data.aws_kms_alias.ssm.target_key_arn]
  }
}

resource "aws_iam_role_policy" "execution_secrets" {
  name   = "${var.prefix}-sandbox-read-secrets"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.read_secrets.json
}

resource "aws_ecs_task_definition" "sandbox" {
  family                   = "${var.prefix}-job"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.sandbox_cpu
  memory                   = var.sandbox_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([
    {
      name      = "sandbox"
      image     = "${aws_ecr_repository.sandbox.repository_url}:${var.image_tag}"
      essential = true
      command   = ["python", "-m", "openfactory.runtime.boxed_job"]
      environment = [
        { name = "OPENFACTORY_GH_APP_ID", value = var.bot_app_id },
        { name = "OPENFACTORY_GH_APP_INSTALLATION_ID", value = var.bot_installation_id },
        { name = "OPENFACTORY_BOT_NAME", value = var.bot_name },
        { name = "OPENFACTORY_BOT_EMAIL", value = var.bot_email },
        { name = "OPENFACTORY_TELEGRAM_BOT_TOKEN", value = var.telegram_bot_token },
        { name = "OPENFACTORY_TELEGRAM_CHAT_ID", value = var.telegram_chat_id },
        { name = "OPENFACTORY_PLANNER_MODEL", value = var.planner_model },
        { name = "OPENFACTORY_EXECUTOR_MODEL", value = var.executor_model },
        # C2 (perfect resume): where the agent snapshots a paused session so a resume continues
        # it. The task role is granted read/write only under this bucket's resume/ prefix.
        { name = "OPENFACTORY_RESUME_BUCKET", value = aws_s3_bucket.resume.bucket },
      ]
      secrets = [
        { name = "CLAUDE_CODE_OAUTH_TOKEN", valueFrom = data.aws_ssm_parameter.claude.arn },
        { name = "OPENFACTORY_AGENT_TOKENS", valueFrom = data.aws_ssm_parameter.agent_tokens.arn },
        { name = "OPENFACTORY_GH_APP_KEY_CONTENT", valueFrom = data.aws_ssm_parameter.botkey.arn },
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.sandbox.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "job"
        }
      }
    }
  ])
}

output "sandbox_task_definition" {
  value = aws_ecs_task_definition.sandbox.family
}
