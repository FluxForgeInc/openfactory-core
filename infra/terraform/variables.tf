variable "region" {
  type    = string
  default = "eu-west-2"
}

variable "prefix" {
  type    = string
  default = "openfactory"
}

# Fargate sandbox sizing. The heavy load is the target project's build/test suite,
# not the agent (Claude runs on Anthropic's servers). Bump per project as needed.
variable "task_cpu" {
  type    = string
  default = "1024" # 1 vCPU
}

variable "task_memory" {
  type    = string
  default = "2048" # 2 GB
}

# The smoke/proof image (public ECR, no auth, no push needed). The real sandbox
# task will use the ECR image built from base-python.Dockerfile.
variable "smoke_image" {
  type    = string
  default = "public.ecr.aws/amazonlinux/amazonlinux:2023"
}

# --- real sandbox task sizing + bot identity (non-secret env) ---
variable "sandbox_cpu" {
  type    = string
  default = "2048" # 2 vCPU — matches the local ContainerSandbox
}

variable "sandbox_memory" {
  type    = string
  default = "4096" # 4 GB
}

# Per-deployment identity — set these in YOUR deployment.tfvars (see deployment.tfvars.example
# + docs/DEPLOYMENT.md). No defaults: a fresh deployment MUST provide its own GitHub App and
# Temporal namespace, so terraform fails loud rather than silently targeting the wrong one.
variable "bot_app_id" {
  type        = string
  description = "Your GitHub App's App ID (the private key lives in SSM, not here)."
}

variable "bot_installation_id" {
  type        = string
  description = "The installation id after you install your GitHub App on your org."
}

variable "bot_name" {
  type    = string
  default = "OpenFactory Bot"  # cosmetic (git commit author); override for your brand
}

variable "bot_email" {
  type    = string
  default = "openfactory-bot@localhost"
}

# --- the always-on Temporal worker (connects to Temporal Cloud, launches Fargate jobs) ---
variable "temporal_endpoint" {
  type        = string
  description = "Your Temporal Cloud namespace endpoint (the API key lives in SSM)."
}

variable "temporal_namespace" {
  type        = string
  description = "Your Temporal Cloud namespace."
}

variable "worker_count" {
  type    = number
  default = 1 # v1 is one worker, one job at a time
}

variable "worker_cpu" {
  type    = string
  default = "512" # the worker only orchestrates — the heavy work is the sandbox job
}

variable "worker_memory" {
  type    = string
  default = "1024"
}

# The image tag both task defs reference. Deploy passes an immutable tag (a git sha) so a
# new image produces a new task-def revision and the service actually rolls out the new
# code — a plain `:latest` push is a no-op to Terraform (M16). infra/deploy.sh handles it.
variable "image_tag" {
  type        = string
  description = <<-EOT
    Immutable git-sha image tag. REQUIRED — there is deliberately no default: a bare
    `terraform apply` must FAIL rather than silently revert the running services to a
    stale `:latest` image (that once un-deployed the poller mid-session). infra/deploy.sh
    always passes the current sha; ad-hoc applies must pass it too.
  EOT
  validation {
    condition     = var.image_tag != "latest" && length(var.image_tag) > 0
    error_message = "Pass an explicit immutable image tag (git sha), never 'latest'. Use infra/deploy.sh."
  }
}

# A model PER ROLE in the two-stage agent: plan cheap/fast, execute strong. Injected into
# the sandbox task env as OPENFACTORY_PLANNER_MODEL / OPENFACTORY_EXECUTOR_MODEL. Empty → the CLI default.
variable "planner_model" {
  type    = string
  default = "opus"
  # Opus, not sonnet: planning is the highest-leverage judgment per token — a wrong plan wastes
  # the whole execute/test/review chain — and the same knob drives the sizer's split/blocked
  # decisions, where the stronger model matters most (owner decision).
  description = "Model for the planner + sizer roles (judgment-heavy: plan draft, INVEST sizing, blocked/assume decisions). '' = CLI default."
}

variable "executor_model" {
  type        = string
  default     = "opus"
  description = "Model for the executor role (implement with TDD). '' = CLI default."
}

# --- optional push-notification channel (A4): set both to enable Telegram pushes ---
variable "telegram_bot_token" {
  type      = string
  default   = ""
  sensitive = true
}

variable "telegram_chat_id" {
  type    = string
  default = ""
}

# --- alerting (O1): where operational alarms go. Empty = no email subscription ---
variable "alert_email" {
  type    = string
  default = ""
}
