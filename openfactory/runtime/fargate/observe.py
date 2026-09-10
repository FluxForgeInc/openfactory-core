"""Reading the agent-token POOL from AWS SSM Parameter Store — the `ssm` row of the token-pool axis.

`adapters/agent/token_pool.py` keeps the free row (`env`: the pool this process can see) and
describes the shape: a builder per kind answering the cockpit's dict — `{count, ids, format,
source}`, counts and ids only, never a token value. The panel used to answer this in two branches,
the second of which imported this very package by name and was gated on a vendor's cluster
variable; that coupling is what ADR-0040 forbids and what the axis replaced. Now `ssm` joins
through the `token_pool.ssm` entry point declared by `openfactory-aws`, and a deployment chooses it
with `OPENFACTORY_TOKEN_POOL_SOURCE=ssm`.

THE SANDBOX'S AUTHORITATIVE POOL. A boxed job authenticates from a JSON array of credentials kept
in an SSM SecureString (`/openfactory/agent-tokens`, injected into the task as `OPENFACTORY_AGENT_TOKENS`
— `infra/terraform/sandbox_task.tf`). The cockpit, running in the worker/panel, reads the same
parameter directly so it reports the pool the jobs actually run on rather than whatever happens to
be in the panel's own environment.

IT RAISES WHEN SSM WILL NOT ANSWER, by the axis's rule (`token_pool()` raises on "a source that
will not answer"). The panel is the one place that knows an unanswered pool is reported from the
environment instead, and says so — a fallback buried here would make the cockpit show `source:
"env"` on a deployment whose pool is in SSM and whose IAM policy had simply drifted, which is the
misconfiguration the operator most needs to see.
"""

from __future__ import annotations

import json
import os

#: The SSM parameter holding the pool, overridable for a deployment that keeps it elsewhere. The
#: default matches what the terraform provisions (`data.aws_ssm_parameter.agent_tokens`).
DEFAULT_SSM_PARAM = "/openfactory/agent-tokens"


def ssm_param_name() -> str:
    return (os.environ.get("OPENFACTORY_TOKEN_POOL_SSM_PARAM") or "").strip() or DEFAULT_SSM_PARAM


def build_ssm_token_pool(**_kw) -> dict:
    """The `token_pool.ssm` entry point — the pool as SSM holds it, as the cockpit's dict.

    RAISES (does not swallow) when the parameter cannot be read: an unreachable or unauthorized
    SSM is a source that will not answer, and the axis leaves the env-fallback decision to the
    panel so an operator sees `source: "env"` only when the deployment genuinely has no SSM pool,
    never because a read failed."""
    import boto3

    region = (os.environ.get("AWS_DEFAULT_REGION") or "").strip()
    client = boto3.client("ssm", region_name=region) if region else boto3.client("ssm")
    raw = client.get_parameter(Name=ssm_param_name(), WithDecryption=True)["Parameter"]["Value"]
    data = json.loads(raw)
    # The same credential schema the env loader uses — a JSON array of {id, token, type?}; only the
    # count, the ids and the first entry's format are surfaced, never a token value.
    return {
        "count": len(data),
        "ids": [str(t.get("id", i)) for i, t in enumerate(data)],
        "format": (data[0].get("type", "subscription") if data else "subscription"),
        "source": "ssm",
    }
