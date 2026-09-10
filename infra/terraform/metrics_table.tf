# The cost + effort telemetry store (the product-grade cost dashboard, architecture.md §8).
#
# One row per agent invocation and one per job, read back by the panel and by the agents' own
# memory. The OSS distribution ships the SQLite twin (needs no service); a deployed worker uses
# this table, selected because OPENFACTORY_METRICS_TABLE is set below. The new core ships NO
# DynamoDB code — the sink is the `metrics.dynamodb` row the `openfactory-aws` add-on supplies
# (openfactory/observability/dynamo.py) — but the TABLE is infrastructure and lives here.
#
# Schema (matches observability/metrics.py::MetricRecord.dynamo_key and the dynamo sink):
#   pk      = project                          (partition)
#   sk      = "<iso-ts>#<ticket>#<role|kind>"  (time-sortable within a project)
#   kind_ts = "<kind>#<iso-ts>#<ticket>"       (the by_kind GSI's sort key, ADR-0021)
# A retried activity overwrites on (pk, sk) rather than double-counting. PAY_PER_REQUEST because
# volume is dozens of jobs/day — provisioned capacity would be pure waste.

resource "aws_dynamodb_table" "metrics" {
  name         = "${var.prefix}-job-metrics"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"
  range_key    = "sk"

  attribute {
    name = "pk"
    type = "S"
  }
  attribute {
    name = "sk"
    type = "S"
  }
  attribute {
    name = "kind_ts"
    type = "S"
  }

  # "what am I still waiting on?" — one partition read per (project, kind) instead of a full-table
  # scan on the path all of the agents' memory depends on. The sink's records_of_kind() queries
  # this by name ("by_kind"); without it the sink degrades to a scan, saying so.
  global_secondary_index {
    name            = "by_kind"
    hash_key        = "pk"
    range_key       = "kind_ts"
    projection_type = "ALL"
  }

  # ADR-0024: client conversation is retained, not kept for ever. Rows that carry expires_at
  # (kind="message") are deleted by DynamoDB; rows without it never expire. Safe to enable on the
  # shared table because only the message rows set the attribute.
  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }
}

# Who may touch the table: the worker (writes job summaries, reads the dashboard) and the sandbox
# task (records its own agent passes). Least privilege — the exact verbs the sink uses, on the
# table and its index only.
data "aws_iam_policy_document" "metrics_rw" {
  statement {
    actions = [
      "dynamodb:PutItem",
      "dynamodb:GetItem",
      "dynamodb:Query",
      "dynamodb:Scan",
      "dynamodb:DeleteItem",
      "dynamodb:BatchWriteItem",
    ]
    resources = [
      aws_dynamodb_table.metrics.arn,
      "${aws_dynamodb_table.metrics.arn}/index/*",
    ]
  }
}

resource "aws_iam_role_policy" "worker_metrics" {
  name   = "${var.prefix}-worker-metrics"
  role   = aws_iam_role.worker.id
  policy = data.aws_iam_policy_document.metrics_rw.json
}

resource "aws_iam_role_policy" "task_metrics" {
  name   = "${var.prefix}-sandbox-metrics"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.metrics_rw.json
}

output "metrics_table" {
  value = aws_dynamodb_table.metrics.name
}
