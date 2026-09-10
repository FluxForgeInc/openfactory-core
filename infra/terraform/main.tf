# The Fargate sandbox substrate (ADR-0001 D-16): an ephemeral, isolated container
# per job, launched on-demand — no idle box, no 15-min ceiling. This is the minimal,
# reusable base; the real sandbox task definition (our ECR image, parameterized by
# ticket) and Secrets Manager wiring come in the next increment.
#
# Networking: reuse the account's DEFAULT VPC public subnets with a public IP, so the
# task reaches GitHub / ECR / Anthropic with NO NAT gateway (~$32/mo saved). Egress-only
# SG. Production gets a dedicated VPC — tracked as a follow-up.

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "map-public-ip-on-launch"
    values = ["true"]
  }
}

# --- image registry (empty now; the base-python image is pushed here next) ---
resource "aws_ecr_repository" "sandbox" {
  name                 = "${var.prefix}-python"
  image_tag_mutability = "MUTABLE"
  image_scanning_configuration {
    scan_on_push = true
  }
}

# --- cluster + logs ---
resource "aws_ecs_cluster" "this" {
  name = "${var.prefix}-sandbox"
  setting {
    name  = "containerInsights"
    value = "disabled" # keep cost minimal for the proof
  }
}

resource "aws_cloudwatch_log_group" "sandbox" {
  name              = "/ecs/${var.prefix}-sandbox"
  retention_in_days = 14
}

# --- IAM ---
data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# Execution role: pull the image + write logs (what the ECS agent needs).
resource "aws_iam_role" "execution" {
  name               = "${var.prefix}-sandbox-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Task role: what the job's own process may do in AWS. Empty now; gains
# Secrets Manager read (Claude token, bot key) in the next increment.
resource "aws_iam_role" "task" {
  name               = "${var.prefix}-sandbox-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

# --- egress-only security group ---
resource "aws_security_group" "sandbox" {
  name        = "${var.prefix}-sandbox"
  description = "Egress-only for the ephemeral sandbox task"
  vpc_id      = data.aws_vpc.default.id

  egress {
    description = "all outbound (clone, ECR pull, Anthropic API)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# --- smoke/proof task definition (public image, trivial command) ---
# Proves cluster + IAM + networking + logging end-to-end without the 2 GB image push.
# Replaced by the real sandbox task definition in the next increment.
resource "aws_ecs_task_definition" "smoke" {
  family                   = "${var.prefix}-smoke"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name      = "smoke"
      image     = var.smoke_image
      essential = true
      command = [
        "sh", "-lc",
        "echo 'hello from the openfactory fargate sandbox'; cat /etc/os-release | head -2; echo done"
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.sandbox.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "smoke"
        }
      }
    }
  ])
}
