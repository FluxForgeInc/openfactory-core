#!/usr/bin/env bash
# Build + push the images with an IMMUTABLE git-sha tag and roll out BOTH the worker
# (ARM/Fargate) and the App Runner panel (amd64) together, in lockstep.
#
# A plain `:latest` push is a no-op to Terraform, so a versioned tag is what makes the
# task-def revision change and the service actually pick up new code (M16).
#
# SAFETY (learned the hard way): `terraform apply` with the panel vars UNSET evaluates
# `apprunner_on = 0` and DESTROYS the App Runner panel (its URL is lost forever). So this
# script ALWAYS builds the amd64 panel image and ALWAYS passes the panel vars — the token
# comes from SSM (/openfactory/panel-token) so it can never be silently forgotten. The panel and
# worker therefore stay on the SAME sha, and a bare `infra/deploy.sh` can never take the
# panel down. If the token isn't in SSM we ABORT rather than run a panel-destroying apply.
#
#   AWS creds must be in the environment.  Usage: infra/deploy.sh [tag]
set -euo pipefail

TAG="${1:-$(git rev-parse --short HEAD)}"

# never ship a red tree (O3)
echo "running tests before deploy…"
(cd "$(dirname "$0")/.." && python -m pytest -q && ruff check openfactory/) || { echo "TESTS FAILED — aborting deploy"; exit 1; }
REGION="${AWS_DEFAULT_REGION:-eu-west-2}"
ACCT="$(aws sts get-caller-identity --query Account --output text)"
ECR="$ACCT.dkr.ecr.$REGION.amazonaws.com"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# The panel token is REQUIRED (the App Runner panel gates every /api/* route on it). Read it
# from SSM so a deploy never runs without it — a missing token would make terraform destroy
# the panel. Fail loud instead. Store it once: aws ssm put-parameter --name /openfactory/panel-token
# --type SecureString --value <token> --overwrite
PANEL_TOKEN="$(aws ssm get-parameter --name /openfactory/panel-token --with-decryption --region "$REGION" --query Parameter.Value --output text 2>/dev/null || true)"
if [ -z "$PANEL_TOKEN" ] || [ "$PANEL_TOKEN" = "None" ]; then
  echo "ABORT: /openfactory/panel-token missing in SSM. A bare apply would DESTROY the App Runner panel."
  echo "  aws ssm put-parameter --name /openfactory/panel-token --type SecureString --value <token> --overwrite --region $REGION"
  exit 1
fi

echo "deploying image_tag=$TAG (worker=arm64, panel=amd64) to $ECR"
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$ECR"

# base (local, not pushed) → sandbox + worker (ARM, pushed, sha-tagged)
docker build --platform linux/arm64 --provenance=false -f "$ROOT/docker/base-python.Dockerfile" -t openfactory-python:latest "$ROOT"
docker build --platform linux/arm64 --provenance=false -f "$ROOT/docker/sandbox.Dockerfile" -t "$ECR/openfactory-python:$TAG" "$ROOT"
docker build --platform linux/arm64 --provenance=false -f "$ROOT/docker/worker.Dockerfile" -t "$ECR/openfactory-worker:$TAG" "$ROOT"
# panel: the SAME app image built for amd64 (App Runner can't run ARM), tagged <sha>-amd64
docker build --platform linux/amd64 --provenance=false --build-arg BASE_PLATFORM=linux/amd64 -f "$ROOT/docker/worker.Dockerfile" -t "$ECR/openfactory-worker:$TAG-amd64" "$ROOT"
docker push "$ECR/openfactory-python:$TAG"
docker push "$ECR/openfactory-worker:$TAG"
docker push "$ECR/openfactory-worker:$TAG-amd64"

# new task-def revisions (worker) + (re)create/update the App Runner panel — ALWAYS with the
# panel vars so the panel is never torn down. Then force the worker service to pick up the new tag.
cd "$ROOT/infra/terraform"
# A NEW deployment points terraform at its own values via OPENFACTORY_TFVARS (see
# deployment.tfvars.example + docs/DEPLOYMENT.md). Unset → terraform's built-in defaults are
# used (the reference deployment), so this stays 100% backward-compatible.
terraform apply -auto-approve \
  ${OPENFACTORY_TFVARS:+-var-file="$OPENFACTORY_TFVARS"} \
  -var "image_tag=$TAG" \
  -var "panel_apprunner_image_tag=$TAG-amd64" \
  -var "panel_token=$PANEL_TOKEN"
# Cluster/service names follow the terraform `prefix` (default "openfactory"); a deployment that changed
# the prefix sets OPENFACTORY_CLUSTER / OPENFACTORY_WORKER_SERVICE to match.
aws ecs update-service \
  --cluster "${OPENFACTORY_CLUSTER:-openfactory-sandbox}" --service "${OPENFACTORY_WORKER_SERVICE:-openfactory-worker}" \
  --force-new-deployment --region "$REGION" >/dev/null
echo "deployed image_tag=$TAG — worker rolling; panel on $TAG-amd64"
terraform output -raw panel_apprunner_url 2>/dev/null && echo "" || true

# Keep the OPERATOR's local Docker bounded too: drop dangling layers left by the multi-image
# builds above (dangling only — never named images, so build caches for the next deploy and
# any locally-used images survive). Best-effort. (audit: tens of GB/quarter otherwise)
docker image prune -f >/dev/null 2>&1 || true
