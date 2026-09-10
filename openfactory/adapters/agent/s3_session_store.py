"""The paused-session store, backed by an object store — the vendor peer of `FileSessionStore`.

`session_store.py` keeps the free row (a file on the worker's state volume) and describes the
shape every row shares: one opaque blob per key, two best-effort methods, and a key this module
never mints but must still refuse to write outside of. THE BLOB IS ALREADY A GZIPPED TAR of the
harness's session directory — the adapter produces and consumes it — so this store does object I/O
and nothing else: the tarring that lived in the old `sdlc` adapter's `_snapshot_session` is the
adapter's job now, not the store's. That split is why the same key works for both stores and why a
deployment that later buys a bucket does not rewrite handles that are already parked on disk.

THE VENDOR ROW, NOT A FALLBACK (ADR-0040 D3). The core ships `file` and imports nothing from here;
`s3` joins through the `session_store.s3` entry point declared by `openfactory-aws`, exactly as a
stranger's GCS or MinIO store would. `session_store_kind()` selects it when `OPENFACTORY_RESUME_BUCKET`
names a bucket (the deployed worker, set by terraform), and a deployment that names `s3` without the
add-on installed is refused BY NAME rather than degrading to a store that keeps nothing.

BEST-EFFORT, BOTH WAYS. Losing a snapshot costs one cold run, never a failed job — so every S3 call
is wrapped and a failure is a False/None, logged, never raised. The terraform grants the task role
`s3:PutObject`/`s3:GetObject` under the bucket's `resume/` prefix only, and the bucket's own
lifecycle rule expires the object after 7 days (`infra/terraform/resume_store.tf`), which is why the
free store enforces the same window on read and this one does not have to.
"""

from __future__ import annotations

import logging
import os
from pathlib import Path

from openfactory.adapters.agent.session_store import SessionStore

log = logging.getLogger("openfactory.agent.session_store")


def resume_bucket() -> str:
    """The bucket this deployment snapshots into. Empty means "no object store" — and since the
    registry only reaches this builder when the bucket is set, an empty value here is a
    misconfiguration the methods surface as a best-effort miss rather than a crash."""
    return (os.environ.get("OPENFACTORY_RESUME_BUCKET") or "").strip()


def _safe_key(key: str) -> str | None:
    """The key, or None if it is not the shape this store issues — the same guard `FileSessionStore`
    applies, because the key reaches here round-tripped through the durable engine and the board and
    is checked rather than trusted. An absolute path or a `..` segment is not a bucket-escape on S3
    the way it is on a filesystem, but a key that is not `resume/<...>` addresses an object outside
    the prefix the task role is granted and the lifecycle rule sweeps — so it is refused here too."""
    k = (key or "").strip()
    if not k or k.startswith("/") or ".." in Path(k).parts or not k.startswith("resume/"):
        log.warning("refusing %r as a session key — not an address this store issues", key)
        return None
    return k


class S3SessionStore:
    """One object per snapshot, under the bucket's `resume/` prefix. Constructs with no I/O and no
    client — the boto3 client is built lazily on first use, so importing this (the registry does, to
    offer the row) never needs credentials or a network."""

    def __init__(self, bucket: str | None = None, *, region: str | None = None) -> None:
        self._bucket = bucket
        self._region = region
        self._client = None

    @property
    def bucket(self) -> str:
        return self._bucket if self._bucket is not None else resume_bucket()

    def _s3(self):
        """The boto3 S3 client, built once. Region is left to the ambient AWS chain
        (`AWS_DEFAULT_REGION`, the task's execution environment) unless one was passed — the old
        `sdlc` store called `boto3.client("s3")` with no region for exactly this reason."""
        if self._client is None:
            import boto3

            self._client = (boto3.client("s3", region_name=self._region)
                            if self._region else boto3.client("s3"))
        return self._client

    def put(self, *, key: str, blob: bytes) -> bool:
        safe = _safe_key(key)
        bucket = self.bucket
        if safe is None or not bucket:
            return False
        try:
            self._s3().put_object(Bucket=bucket, Key=safe, Body=blob)
            return True
        except Exception as exc:  # noqa: BLE001 — a lost snapshot costs a cold run, never the job
            log.warning("could not keep the session snapshot s3://%s/%s (%s) — the next run will "
                        "be cold", bucket, safe, exc)
            return False

    def get(self, *, key: str) -> bytes | None:
        safe = _safe_key(key)
        bucket = self.bucket
        if safe is None or not bucket:
            return None
        try:
            obj = self._s3().get_object(Bucket=bucket, Key=safe)
            return obj["Body"].read()
        except Exception as exc:  # noqa: BLE001 — a missing / unreadable object means "run cold".
            # The bucket's lifecycle rule expires the object after the resume window, so a stale key
            # simply misses here (NoSuchKey) — the free store enforces that window itself because
            # nothing sweeps its files; this store lets the bucket do it.
            log.info("no resumable session at s3://%s/%s (%s) — running cold", bucket, safe, exc)
            return None


def build_s3_session_store(**kw) -> SessionStore:
    """The `session_store.s3` entry point. `kw` may carry `bucket`/`region`; absent them the store
    reads `OPENFACTORY_RESUME_BUCKET` and the ambient region at call time."""
    return S3SessionStore(bucket=kw.get("bucket"), region=kw.get("region"))
