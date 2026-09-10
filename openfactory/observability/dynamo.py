"""The deployed telemetry store — DynamoDB — the vendor twin of `SqliteMetricsSink`.

PROVENANCE. The old `sdlc` tree the Fargate runner was ported from no longer contained a DynamoDB
sink to port (its `observability/` held only the event journal). This module is RE-DERIVED from the
contract the new core already states in full, not invented: `observability/metrics.py`'s module
docstring gives the exact DynamoDB schema, `sqlite_metrics.py` is the explicit "same telemetry"
twin this mirrors method-for-method, and `observability/registry.py` + `api/metrics_view.py` name
every behaviour below. Because it was reconstructed rather than exercised against a live table, the
`box prove`/deploy path is where it earns trust — the logic here matches the documented store, but
the boto3 round-trip wants a real table to confirm.

THE FOUR BEHAVIOURS THE DASHBOARD AND THE AGENTS' MEMORY DEPEND ON (from `sqlite_metrics.py`, which
was written to match this store, not the other way round):

    put_item OVERWRITES on the key      a retried activity must not double-count a job's cost
    TTL DELETES expired rows            ADR-0024 — client conversation is retained, not kept
    numbers survive the round trip      stored as strings, parsed back by the reader
    a write failure never fails a job   telemetry is additive

SHAPE, NOT SCHEMA. The readers (`scan`, `records_of_kind`) return `list[dict]` carrying DynamoDB's
own keys, in the shape `api/metrics_view.scan_records` consumes — numbers as numbers. A read that
the store will not answer RAISES `StoreUnreadable` (#126): "nothing recorded" and "could not look"
are opposite facts on every path that gates a human decision, and the panel's human gates were
blinded for as long as a read swallowed to `[]`.

THE VENDOR ROW (ADR-0040 D3). The core ships `null`/`sqlite`/`memory` and imports nothing from here;
`dynamodb` joins through the `metrics.dynamodb` entry point declared by `openfactory-aws`.
`metrics_sink_kind()` selects it when `OPENFACTORY_METRICS_TABLE` names a table (the deployed
worker, set by terraform).
"""

from __future__ import annotations

import logging
import time
from decimal import Decimal

from openfactory.observability.metrics import MetricRecord

log = logging.getLogger("openfactory.metrics")

#: Numbers the dashboard reads. DynamoDB stores them as strings (a float is not a native item type
#: without Decimal gymnastics, and the documented store stringifies), so the reader parses them
#: back — a cost rendered as 0.00 because it stayed a string is the failure this prevents. Same
#: list as `sqlite_metrics._NUMERIC`, the twin that parses the same fields.
_NUMERIC = ("cost_usd", "total_cost_usd", "wall_s", "num_turns", "input_tokens",
            "output_tokens", "tool_calls", "repeated_calls", "refused_calls",
            "turns_to_first_edit")

#: The `by_kind` GSI (ADR-0021): partition `pk` (project), sort `kind_ts` (`<kind>#<ts>#<ticket>`).
#: One partition read answers "rows of this kind for this project" instead of a whole-table scan.
#: The name is fixed by `observability/query.INDEX`.
_BY_KIND_INDEX = "by_kind"


def _to_item(rec: MetricRecord) -> dict:
    """One DynamoDB item: the record's fields with the keys lifted in, numbers as strings, `None`s
    dropped (DynamoDB has no null-typed scalar and an absent attribute IS "not measured"). Built
    from one `model_dump()` + `dynamo_key()` so the stored columns cannot drift from the payload,
    exactly as the sqlite twin writes both from one dump."""
    item: dict = {}
    for k, v in rec.model_dump().items():
        if v is None:
            continue
        if k == "expires_at":
            # TTL needs a Number attribute in epoch seconds — DynamoDB deletes the row past it.
            item[k] = int(v)
        elif k in _NUMERIC:
            item[k] = str(v)  # stringified, parsed back on read
        elif isinstance(v, (int, float)):
            item[k] = Decimal(str(v))
        else:
            item[k] = v  # str / dict (extra) / etc.
    item.update(rec.dynamo_key())  # pk, sk, kind_ts — the keys win
    return item


def _numberize(rec: dict) -> dict:
    """Parse the stringified numbers back, and normalise DynamoDB's `Decimal`s to plain numbers so
    the dashboard's JSON and arithmetic see native types — the read-side mirror of `_to_item`."""
    out = dict(rec)
    for k in _NUMERIC:
        v = out.get(k)
        if isinstance(v, Decimal):
            out[k] = float(v)
        elif isinstance(v, str):  # a stringified number would render as zero and say nothing
            try:
                out[k] = float(v) if "." in v else int(v)
            except ValueError:
                out[k] = None
    ea = out.get("expires_at")
    if isinstance(ea, Decimal):
        out["expires_at"] = int(ea)
    return out


def _unexpired(rows: list[dict], *, now: int) -> list[dict]:
    """Drop rows past their TTL on the way out — the same read-time filter the sqlite twin applies,
    because DynamoDB's TTL sweep is eventual and a just-expired row can still be returned by a scan
    or query in the minutes before it is physically deleted."""
    kept = []
    for r in rows:
        ea = r.get("expires_at")
        ea = int(ea) if isinstance(ea, (int, Decimal)) else None
        if ea is None or ea > now:
            kept.append(r)
    return kept


class DynamoMetricsSink:
    """A `MetricsSink` that also reads (`ReadableSink`) and forgets (`ForgettingSink`). Constructs
    with no I/O: the boto3 resource and the `Table` handle are built lazily on first use, so the
    registry can offer the row without credentials or a network."""

    def __init__(self, table: str, *, region: str | None = None) -> None:
        self.table_name = table
        self._region = region
        self._table = None

    def _tbl(self):
        if self._table is None:
            import boto3

            res = (boto3.resource("dynamodb", region_name=self._region)
                   if self._region else boto3.resource("dynamodb"))
            self._table = res.Table(self.table_name)
        return self._table

    # ── write ───────────────────────────────────────────────────────────────────────────────────

    def record(self, rec: MetricRecord) -> bool:
        """Persist one record; True only when it landed. **Never raises** — telemetry is additive,
        and `put_item` overwrites on (pk, sk) so a retried activity replaces rather than
        double-counts. The failure is logged AND returned, because `messages.write` gates the
        operator's own conversation on this bool."""
        try:
            self._tbl().put_item(Item=_to_item(rec))
            return True
        except Exception as exc:  # noqa: BLE001 — never fail the job for telemetry
            log.warning("metrics write failed for %s#%s: %s", rec.project, rec.ticket, exc)
            return False

    def forget(self, project: str, *, kind: str) -> int:
        """Delete every row of one kind for one client, and say how many went. RAISES on failure —
        the one method here that does: "0 rows" from a store that threw is indistinguishable from a
        store that was already empty, and an operator answering a deletion request in good faith
        would relay it as done."""
        keys = [{"pk": r["pk"], "sk": r["sk"]}
                for r in self._rows_of_kind_raw(project, kind, limit=0)]
        tbl = self._tbl()
        with tbl.batch_writer() as batch:
            for key in keys:
                batch.delete_item(Key=key)
        return len(keys)

    def purge_expired(self, *, now: int | None = None) -> int:
        """Delete rows past their TTL, returning how many went. DynamoDB's own TTL sweep does this
        within ~48h; this is the immediate, countable version the sqlite twin also offers.
        Best-effort — a failed purge is logged and returns 0, never raising (unlike `forget`, which
        answers a legal request)."""
        cutoff = now if now is not None else int(time.time())
        try:
            tbl = self._tbl()
            gone = 0
            for r in self._scan_raw():
                ea = r.get("expires_at")
                ea = int(ea) if isinstance(ea, (int, Decimal)) else None
                if ea is not None and ea <= cutoff:
                    tbl.delete_item(Key={"pk": r["pk"], "sk": r["sk"]})
                    gone += 1
            return gone
        except Exception as exc:  # noqa: BLE001
            log.warning("metrics purge failed: %s", exc)
            return 0

    # ── read ────────────────────────────────────────────────────────────────────────────────────

    def scan(self) -> list[dict]:
        """Every live record, numbers parsed back, in the shape `metrics_view.scan_records` returns.
        RAISES `StoreUnreadable` when the table will not answer — the dashboard is the one that
        CHOOSES to read that as 'no data yet' (one caught line), so a real outage is never silently
        an empty memory."""
        from openfactory.observability.query import StoreUnreadable

        try:
            rows = self._scan_raw()
        except Exception as exc:  # noqa: BLE001 — translate every store failure to the honest one
            raise StoreUnreadable(f"metrics table {self.table_name!r} could not be scanned: "
                                  f"{exc}") from exc
        rows = _unexpired(rows, now=int(time.time()))
        rows.sort(key=lambda r: (r.get("pk", ""), r.get("sk", "")))
        return [_numberize(r) for r in rows]

    def records_of_kind(self, project: str, kind: str, *, limit: int = 500) -> list[dict]:
        """Rows of one kind for one project, **oldest first**, keeping the most RECENT `limit` — the
        ordering `query.py` also chooses, because a memory truncated to its oldest rows remembers
        the beginning of time and nothing about now. RAISES `StoreUnreadable` on a store that will
        not answer."""
        from openfactory.observability.query import StoreUnreadable

        try:
            rows = self._rows_of_kind_raw(project, kind, limit=limit)
        except Exception as exc:  # noqa: BLE001
            raise StoreUnreadable(f"metrics table {self.table_name!r} could not be read for "
                                  f"kind {kind!r}: {exc}") from exc
        rows = _unexpired(rows, now=int(time.time()))
        rows.sort(key=lambda r: r.get("sk", ""))  # sk begins with ts → chronological
        if limit and len(rows) > limit:
            rows = rows[-limit:]  # keep the most recent `limit`, still oldest-first
        return [_numberize(r) for r in rows]

    # ── raw DynamoDB ──────────────────────────────────────────────────────────────────────────────

    def _scan_raw(self) -> list[dict]:
        """Every item, paginated. Raises on a client error — the callers translate it."""
        tbl = self._tbl()
        items: list[dict] = []
        kw: dict = {}
        while True:
            resp = tbl.scan(**kw)
            items.extend(resp.get("Items", []))
            start = resp.get("LastEvaluatedKey")
            if not start:
                return items
            kw["ExclusiveStartKey"] = start

    def _rows_of_kind_raw(self, project: str, kind: str, *, limit: int) -> list[dict]:
        """One kind's rows for one project, via the `by_kind` GSI — a single partition read.

        DEGRADES TO A SCAN, BUT NEVER SILENTLY (`query.py`'s promise): before the index exists — a
        checkout ahead of its terraform apply, a local table created without the GSI — the query
        raises `ValidationException`, and this falls back to a filtered scan saying so, rather than
        failing a read the whole of the agents' memory depends on."""
        from boto3.dynamodb.conditions import Key

        tbl = self._tbl()
        try:
            items: list[dict] = []
            kw: dict = {
                "IndexName": _BY_KIND_INDEX,
                "KeyConditionExpression": (Key("pk").eq(project)
                                           & Key("kind_ts").begins_with(f"{kind}#")),
                "ScanIndexForward": False,  # newest first, so a Limit keeps the most recent
            }
            while True:
                resp = tbl.query(**kw)
                items.extend(resp.get("Items", []))
                start = resp.get("LastEvaluatedKey")
                # A positive limit caps how much of the (newest-first) partition we read.
                if not start or (limit and len(items) >= limit):
                    return items
                kw["ExclusiveStartKey"] = start
        except Exception as exc:  # noqa: BLE001 — missing index or any query failure → honest scan
            log.warning("the %r index on %s did not answer (%s) — falling back to a full scan for "
                        "%s/%s", _BY_KIND_INDEX, self.table_name, exc, project, kind)
            return [r for r in self._scan_raw()
                    if r.get("pk") == project and r.get("kind") == kind]


def build_dynamo_metrics_sink(**kw):
    """The `metrics.dynamodb` entry point. `table` is required (the registry passes
    `OPENFACTORY_METRICS_TABLE`); `region` is optional and otherwise left to the ambient AWS chain.
    A reader/deleter that names a `table=` override reaches here through `configured_metrics_sink`."""
    import os

    table = kw.get("table") or (os.environ.get("OPENFACTORY_METRICS_TABLE") or "").strip()
    if not table:
        raise ValueError("the DynamoDB metrics sink needs a table — set OPENFACTORY_METRICS_TABLE "
                         "or pass table=")
    return DynamoMetricsSink(table, region=kw.get("region"))
