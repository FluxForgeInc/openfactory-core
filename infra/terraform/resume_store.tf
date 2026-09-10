# C2 (perfect resume) — the durable store for a PAUSED attempt's agent session state.
#
# When a job pauses on a rate limit, the adapter snapshots the CLI session (~/.claude) here so
# the resumed run — a fresh, ephemeral Fargate task — can CONTINUE that session (`--resume`)
# instead of replanning/re-implementing and re-burning tokens. The partial CODE rides a pushed
# git branch (no infra); this bucket carries only the session transcript. Private + short TTL:
# these snapshots are throwaway (a job resumes within hours or is abandoned), so they must never
# accumulate cost the way old container images did.

resource "aws_s3_bucket" "resume" {
  bucket = "${var.prefix}-resume-${data.aws_caller_identity.current.account_id}"
}

# Never public — session transcripts can contain code.
resource "aws_s3_bucket_public_access_block" "resume" {
  bucket                  = aws_s3_bucket.resume.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Encrypt at rest (SSE-S3 — no key management needed, no extra cost).
resource "aws_s3_bucket_server_side_encryption_configuration" "resume" {
  bucket = aws_s3_bucket.resume.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Expire snapshots after a few days: a paused job either resumes quickly or is abandoned, so a
# lingering snapshot is pure waste. Root-cause discipline (same lesson as pruning old images).
resource "aws_s3_bucket_lifecycle_configuration" "resume" {
  bucket = aws_s3_bucket.resume.id
  rule {
    id     = "expire-stale-snapshots"
    status = "Enabled"
    filter {
      prefix = "resume/"
    }
    expiration {
      days = 7
    }
    # future-proofing: today's writer uses single-part put_object, but if it ever switches to
    # multipart, an abandoned upload (task killed mid-upload) must not linger as hidden cost.
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

# The sandbox TASK role (the job's own process) may read/write ONLY under this bucket's
# resume/ prefix — least privilege; it never touches any other bucket.
data "aws_iam_policy_document" "resume_rw" {
  statement {
    actions   = ["s3:PutObject", "s3:GetObject"]
    resources = ["${aws_s3_bucket.resume.arn}/resume/*"]
  }
}

resource "aws_iam_role_policy" "task_resume_store" {
  name   = "${var.prefix}-sandbox-resume-store"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.resume_rw.json
}
