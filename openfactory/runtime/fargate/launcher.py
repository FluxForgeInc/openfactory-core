"""Host side of the Fargate sandbox — launch a task, wait, collect the RunResult.

A `RemoteBox` (see `openfactory.adapters.sandbox.registry`): the core DESCRIBES the
`fargate` box as a row of traits and this package IMPLEMENTS its runner, reached through
the `box_runner.fargate` entry point. The Temporal `run_job` activity calls `launch` when
the sandbox is `fargate`: it runs one ECS task (our image + the in-task entrypoint,
`python -m openfactory.runtime.boxed_job`), waits for it to stop, reads the single RESULT
line out of CloudWatch, and returns the RunResult. Fire-and-forget RunTask maps cleanly to
one durable activity (retry = re-attach to the running task, or reconcile a finished one;
forge idempotency covers repeats).

Config comes from env (the Terraform outputs), so nothing here is hard-coded to an
account. boto3 clients are injectable for testing.

PORTED from the old sdlc-platform `sdlc/runtime/fargate/launcher.py`, adapted to:
  - the new `RemoteBox` protocol (launch / stop / tail) the registry resolves;
  - the `OPENFACTORY_*` env namespace the new `boxed_job` entrypoint reads;
  - the new `OPENFACTORY_EVENT:` / `OPENFACTORY_RESULT_JSON:` log contract.
"""

from __future__ import annotations

import hashlib
import json
import os
import time
from collections.abc import Callable
from dataclasses import dataclass

from openfactory.adapters.sandbox.timeouts import LAUNCHER_TIMEOUT
from openfactory.contracts import RunResult
from openfactory.observability import EventSink, JobEvent
from openfactory.runtime.boxed_job import RESULT_PREFIX, BoxConfig

#: The in-task `StdoutEventSink` prefix (events.py default) — must match so the host can
#: re-journal a Fargate job's progress live.
_EVENT_PREFIX = "OPENFACTORY_EVENT:"
# only a successfully-finished prior attempt is reconciled; paused/failed → run fresh
_RECONCILABLE = {"pr_open", "merged", "done"}


def events_from_logs(text: str) -> list[JobEvent]:
    """Extract the JobEvents the in-task StdoutEventSink streamed into the logs — so the
    host can re-journal them and the panel shows a Fargate job's progress live. The prefix
    must be at the START of the line, so agent output that merely mentions it can't spoof."""
    out: list[JobEvent] = []
    for line in text.splitlines():
        s = line.strip()
        if not s.startswith(_EVENT_PREFIX):
            continue
        try:
            out.append(JobEvent.model_validate_json(s[len(_EVENT_PREFIX):].strip()))
        except ValueError:
            pass
    return out


def parse_result(text: str) -> RunResult | None:
    """Pull the RunResult out of the task's logs (the one contract line). Last wins. The
    prefix must START the line (agent text that mentions it can't forge a result), and a
    malformed line is skipped rather than crashing the host."""
    found = None
    for line in text.splitlines():
        s = line.strip()
        if s.startswith(RESULT_PREFIX):
            found = s[len(RESULT_PREFIX):].strip()
    if not found:
        return None
    try:
        return RunResult.model_validate(json.loads(found))
    except (ValueError, TypeError):
        return None  # malformed result line → treat as no result, don't crash


def build_env_overrides(box: BoxConfig) -> list[dict]:
    """The env the in-task `boxed_job.config_from_env` reads back. Names and encodings must
    match that function exactly (options as JSON), or the box rebuilds the wrong project."""
    env = {
        "OPENFACTORY_PROJECT": box.project,
        "OPENFACTORY_ISSUE": box.issue,
        "OPENFACTORY_REPO": box.repo,
        "OPENFACTORY_REVIEW": "true" if box.review else "false",
        "OPENFACTORY_TRACKER_KIND": box.tracker_kind,
        "OPENFACTORY_FORGE_KIND": box.forge_kind,
    }
    if box.board_owner and box.board_number:
        env["OPENFACTORY_BOARD_OWNER"] = box.board_owner
        env["OPENFACTORY_BOARD_NUMBER"] = box.board_number
    if box.tracker_options:
        env["OPENFACTORY_TRACKER_OPTIONS"] = json.dumps(box.tracker_options)
    if box.forge_options:
        env["OPENFACTORY_FORGE_OPTIONS"] = json.dumps(box.forge_options)
    if box.resume_handle:  # C2: only on a resume after a rate-limit pause (opaque to the launcher)
        env["OPENFACTORY_RESUME_HANDLE"] = box.resume_handle
    if box.spent_turns:  # D4: the ticket's cumulative effort so far
        env["OPENFACTORY_SPENT_TURNS"] = str(box.spent_turns)
    if box.decision:  # a resolved human choice injected into the resumed agent
        env["OPENFACTORY_DECISION"] = box.decision
    return [{"name": k, "value": v} for k, v in env.items()]


@dataclass
class FargateConfig:
    cluster: str
    subnets: list[str]
    security_group: str
    task_definition: str
    log_group: str
    container_name: str = "sandbox"
    log_stream_prefix: str = "job"
    region: str = "eu-west-2"
    assign_public_ip: bool = True


def fargate_config_from_env(env: dict[str, str] | None = None) -> FargateConfig:
    """Read the Terraform-provided fargate coordinates. `OPENFACTORY_LOG_GROUP` is accepted
    as an alias for `OPENFACTORY_FARGATE_LOG_GROUP` because the panel's own tail path
    (`api/app.py`) reads the former — terraform sets both to the same value."""
    e = env if env is not None else dict(os.environ)
    log_group = e.get("OPENFACTORY_FARGATE_LOG_GROUP") or e.get("OPENFACTORY_LOG_GROUP")
    missing = [
        k for k, v in (
            ("OPENFACTORY_FARGATE_CLUSTER", e.get("OPENFACTORY_FARGATE_CLUSTER")),
            ("OPENFACTORY_FARGATE_SUBNETS", e.get("OPENFACTORY_FARGATE_SUBNETS")),
            ("OPENFACTORY_FARGATE_SG", e.get("OPENFACTORY_FARGATE_SG")),
            ("OPENFACTORY_FARGATE_TASKDEF", e.get("OPENFACTORY_FARGATE_TASKDEF")),
            ("OPENFACTORY_FARGATE_LOG_GROUP", log_group),
        ) if not v
    ]
    if missing:
        raise KeyError(f"missing Fargate env: {', '.join(missing)}")
    return FargateConfig(
        cluster=e["OPENFACTORY_FARGATE_CLUSTER"],
        subnets=[s.strip() for s in e["OPENFACTORY_FARGATE_SUBNETS"].split(",") if s.strip()],
        security_group=e["OPENFACTORY_FARGATE_SG"],
        task_definition=e["OPENFACTORY_FARGATE_TASKDEF"],
        log_group=log_group,
        container_name=e.get("OPENFACTORY_FARGATE_CONTAINER", "sandbox"),
        log_stream_prefix=e.get("OPENFACTORY_FARGATE_LOG_PREFIX", "job"),
        region=e.get("AWS_DEFAULT_REGION", "eu-west-2"),
        assign_public_ip=e.get("OPENFACTORY_FARGATE_PUBLIC_IP", "true").lower()
        not in ("0", "false"),
    )


class _LogEventTail:
    """A `RemoteBox.tail` result: each `fetch_new()` returns only the JobEvents logged since
    the previous call, as dicts, so the panel can poll a Fargate job it cannot see. Finds the
    job's task by its stable `startedBy` tag; before the task's first log line there is simply
    nothing new (empty list), which is the honest answer, not an error."""

    def __init__(self, launcher: "FargateLauncher", job_tag: str) -> None:
        self._launcher = launcher
        self._job_tag = job_tag
        self._token: str | None = None
        self._task_arn: str | None = None

    def _resolve_task(self) -> str | None:
        if self._task_arn:
            return self._task_arn
        running = self._launcher._find_tasks(self._job_tag, "RUNNING")
        if not running:
            # a just-finished task still has its logs for ~1h — tail the most recent stopped one
            running = self._launcher._find_tasks(self._job_tag, "STOPPED")
        if running:
            self._task_arn = running[0]
        return self._task_arn

    def fetch_new(self) -> list[dict]:
        task_arn = self._resolve_task()
        if not task_arn:
            return []
        new, self._token = self._launcher._tail(task_arn, self._token)
        if not new:
            return []
        return [ev.model_dump() for ev in events_from_logs("\n".join(new))]


@dataclass
class FargateLauncher:
    """The `fargate` box's `RemoteBox` runner: launch a job in an ECS task, stop orphans,
    tail its journal. Registered via the `box_runner.fargate` entry point."""

    cfg: FargateConfig
    ecs: object = None  # boto3 ecs client (lazy)
    logs: object = None  # boto3 logs client (lazy)
    result_attempts: int = 8  # bounded retries reading the RESULT after STOPPED (log lag)
    result_interval: int = 4

    def _clients(self):
        if self.ecs is None or self.logs is None:
            import boto3

            self.ecs = self.ecs or boto3.client("ecs", region_name=self.cfg.region)
            self.logs = self.logs or boto3.client("logs", region_name=self.cfg.region)
        return self.ecs, self.logs

    @staticmethod
    def job_tag(box: BoxConfig, variant: str = "") -> str:
        """Stable per-job id stamped on the task (startedBy), so a retry re-attaches to
        the same task instead of launching a duplicate. `variant` distinguishes different
        task KINDS for one ticket (a run vs a promotion) so they never collide. `startedBy`
        is capped at 36 chars by ECS — keep it human-readable when it fits, else hash so a
        long project name can never truncate the issue off the end (collision-proof)."""
        tag = f"of-{box.project}-{box.issue}{variant}"
        if len(tag) <= 36:
            return tag
        digest = hashlib.sha1(  # noqa: S324 - not security, just a short stable id
            f"{box.project}|{box.issue}|{variant}".encode()).hexdigest()
        return "of-" + digest[:30]

    def _find_tasks(self, job_tag: str, desired: str) -> list[str]:
        ecs, _ = self._clients()
        return ecs.list_tasks(
            cluster=self.cfg.cluster, startedBy=job_tag, desiredStatus=desired
        ).get("taskArns", [])

    def _tasks_for_run(self, arns: list[str], run_id: str | None) -> list[str]:
        """Keep only tasks stamped with this workflow run's OPENFACTORY_RUN_ID (R8) — so a
        NEW run for a reused issue number never re-attaches to / reconciles an OLD run's
        task, while retries within one run (same run_id) still converge. No run_id → no
        filtering (panel/legacy callers see all tasks for the ticket)."""
        if not run_id or not arns:
            return arns
        ecs, _ = self._clients()
        out: list[str] = []
        for i in range(0, len(arns), 100):
            for t in ecs.describe_tasks(
                cluster=self.cfg.cluster, tasks=arns[i:i + 100]
            ).get("tasks", []):
                env = [
                    e
                    for co in (t.get("overrides") or {}).get("containerOverrides", [])
                    for e in co.get("environment", [])
                ]
                if any(e.get("name") == "OPENFACTORY_RUN_ID" and e.get("value") == run_id
                       for e in env):
                    out.append(t["taskArn"])
        return out

    def _run_task(self, box: BoxConfig, *, variant: str = "", extra_env: dict | None = None) -> str:
        # No double-launch (H6): Temporal runs one workflow per job id and the worker sets
        # max_concurrent_activities=1, so run_job never executes concurrently for the same
        # job — plus launch() re-attaches to any running task first. The stable startedBy tag
        # makes retries converge on one task.
        ecs, _ = self._clients()
        env = build_env_overrides(box)
        env += [{"name": k, "value": v} for k, v in (extra_env or {}).items()]
        resp = ecs.run_task(
            cluster=self.cfg.cluster,
            launchType="FARGATE",
            taskDefinition=self.cfg.task_definition,
            startedBy=self.job_tag(box, variant),
            count=1,
            networkConfiguration={
                "awsvpcConfiguration": {
                    "subnets": self.cfg.subnets,
                    "securityGroups": [self.cfg.security_group],
                    "assignPublicIp": "ENABLED" if self.cfg.assign_public_ip else "DISABLED",
                }
            },
            overrides={
                "containerOverrides": [{"name": self.cfg.container_name, "environment": env}]
            },
        )
        failures = resp.get("failures") or []
        if failures or not resp.get("tasks"):
            raise RuntimeError(f"run_task failed: {failures}")
        return resp["tasks"][0]["taskArn"]

    def _logs_for(self, task_arn: str) -> str:
        _, logs = self._clients()
        task_id = task_arn.rsplit("/", 1)[-1]
        stream = f"{self.cfg.log_stream_prefix}/{self.cfg.container_name}/{task_id}"
        out: list[str] = []
        token = None
        while True:
            kw = {"logGroupName": self.cfg.log_group, "logStreamName": stream,
                  "startFromHead": True}
            if token:
                kw["nextToken"] = token
            try:
                resp = logs.get_log_events(**kw)
            except Exception as exc:  # stream is created only on the task's first log line
                if "ResourceNotFound" in type(exc).__name__ or "does not exist" in str(exc):
                    return "\n".join(out)
                raise
            events = resp.get("events", [])
            out += [e["message"] for e in events]
            nxt = resp.get("nextForwardToken")
            if not events or nxt == token:
                break
            token = nxt
        return "\n".join(out)

    def _task_status(self, task_arn: str) -> str:
        ecs, _ = self._clients()
        r = ecs.describe_tasks(cluster=self.cfg.cluster, tasks=[task_arn])
        tasks = r.get("tasks") or []
        return tasks[0]["lastStatus"] if tasks else "MISSING"

    def _tail(self, task_arn: str, token: str | None) -> tuple[list[str], str | None]:
        """Fetch only NEW log messages since `token` (incremental — avoids re-reading the
        whole stream every poll, M3). Returns (new_lines, next_token)."""
        _, logs = self._clients()
        task_id = task_arn.rsplit("/", 1)[-1]
        stream = f"{self.cfg.log_stream_prefix}/{self.cfg.container_name}/{task_id}"
        out: list[str] = []
        while True:
            kw = {"logGroupName": self.cfg.log_group, "logStreamName": stream,
                  "startFromHead": True}
            if token:
                kw["nextToken"] = token
            try:
                resp = logs.get_log_events(**kw)
            except Exception as exc:  # stream created only on the first log line
                if "ResourceNotFound" in type(exc).__name__ or "does not exist" in str(exc):
                    return out, token
                raise
            events = resp.get("events", [])
            out += [e["message"] for e in events]
            nxt = resp.get("nextForwardToken")
            if not events or nxt == token:
                token = nxt
                break
            token = nxt
        return out, token

    def launch(
        self,
        box: BoxConfig,
        *,
        journal: EventSink | None = None,
        variant: str = "",
        extra_env: dict | None = None,
        timeout: int = LAUNCHER_TIMEOUT,
        run_id: str | None = None,
        poll_interval: int = 15,
        on_progress: Callable[[str, str], None] | None = None,
    ) -> RunResult:
        """Run one task and wait for it to stop, polling on a bounded WALL-CLOCK deadline
        so a stuck task raises (never hangs, even at poll_interval=0). `journal` re-emits the
        task's events to the panel's journal live; `on_progress` fires each poll.

        Idempotent by job tag: a retry (or a worker that died mid-job) RE-ATTACHES to a
        still-running task, or RECONCILES a successful result from a finished one — so
        nothing double-runs and no work is lost."""
        job_tag = self.job_tag(box, variant)
        running = self._tasks_for_run(self._find_tasks(job_tag, "RUNNING"), run_id)
        if running:
            task_arn = running[0]  # re-attach: THIS run's task is still going
        else:
            reconciled = self._reconcile(job_tag, journal, run_id=run_id)
            if reconciled is not None:
                return reconciled  # a prior attempt already finished — recover its result
            env = dict(extra_env or {})
            if run_id:
                env["OPENFACTORY_RUN_ID"] = run_id  # stamp: retries converge, reruns fresh
            task_arn = self._run_task(box, variant=variant, extra_env=env)  # fresh
        deadline = time.monotonic() + timeout
        lines: list[str] = []
        token: str | None = None

        def pump() -> None:  # tail new log lines, journal only the new ones (no re-emit, L3)
            nonlocal token
            new, token = self._tail(task_arn, token)
            if new:
                lines.extend(new)
                if journal is not None:
                    for ev in events_from_logs("\n".join(new)):
                        journal.emit(ev)

        seen_alive = False
        misses = 0
        while True:
            status = self._task_status(task_arn)
            if on_progress:
                on_progress(task_arn, status)
            pump()
            if status == "STOPPED":
                break
            if status == "MISSING":
                # Describe/List are eventually consistent: a JUST-started task can briefly
                # report no task. Only treat MISSING as terminal once the task was seen alive,
                # or after several consecutive misses (R4) — else a fresh launch could be
                # declared dead and duplicated on retry.
                misses += 1
                if seen_alive or misses >= 3:
                    break
            else:
                seen_alive = True
                misses = 0
            if time.monotonic() >= deadline:
                raise TimeoutError(
                    f"fargate task {task_arn} still {status} after {timeout}s — giving up"
                )
            time.sleep(max(1, poll_interval))
        # the awslogs driver flushes the container's FINAL stdout a few seconds AFTER the
        # task stops, so the RESULT line may not be there yet — keep tailing briefly.
        result = parse_result("\n".join(lines))
        attempts = 0
        while result is None and attempts < self.result_attempts:
            attempts += 1
            time.sleep(self.result_interval)
            pump()
            result = parse_result("\n".join(lines))
        if result is None:
            raise RuntimeError(f"task {task_arn} produced no RunResult (see logs)")
        return result

    def _emit_new(self, text: str, journal: EventSink, already: int) -> int:
        events = events_from_logs(text)
        for ev in events[already:]:
            journal.emit(ev)
        return len(events)

    def _sync_journal(self, task_arn: str, journal: EventSink, already: int) -> int:
        """Re-emit any new streamed events to the host journal; return the new count."""
        return self._emit_new(self._logs_for(task_arn), journal, already)

    def tail(self, project: str, issue: str):
        """An `EventTail` the panel polls to follow a job on a machine it cannot reach. The
        `fargate` box's traits declare `streams=False` because the task's logs carry the
        ORCHESTRATOR's events, not the harness's pulse — this tail reflects that honestly: it
        returns the job-state journal, which is what crosses back through CloudWatch."""
        box = BoxConfig(project=project, issue=issue, repo="")
        return _LogEventTail(self, self.job_tag(box))

    # every task kind one ticket can spawn — cleanup must sweep them all (R1): a cancelled
    # release task left running could tag prod uncontrolled, and an orphaned ci-repair task
    # can still push commits to the PR after the job is gone.
    VARIANTS = ("", "-ci-repair", "-adjust", "-review", "-staging", "-release")

    def stop(self, box: BoxConfig, *, reason: str = "openfactory job ended — cleanup") -> int:
        """Stop any still-running task for this job — ALL variants — called when the workflow
        ends abnormally, so nothing is left orphaned. startedBy matching is exact, hence the
        explicit sweep. Idempotent: no running task → nothing to do. Returns the count stopped."""
        ecs, _ = self._clients()
        stopped = 0
        for variant in self.VARIANTS:
            for arn in self._find_tasks(self.job_tag(box, variant), "RUNNING"):
                ecs.stop_task(cluster=self.cfg.cluster, task=arn, reason=reason)
                stopped += 1
        return stopped

    def _reconcile(
        self, job_tag: str, journal: EventSink | None, run_id: str | None = None
    ) -> RunResult | None:
        """A prior attempt for this job may have already finished (worker died before reading
        the result). If the MOST RECENT stopped task's logs carry a SUCCESSFUL RunResult,
        recover it. Newest-first matters when there were several attempts; a paused/failed
        prior result is NOT reconciled — that job runs fresh (e.g. after a rate-limit clears).
        ECS only retains stopped tasks ~1h, which bounds staleness."""
        stopped = self._tasks_for_run(self._find_tasks(job_tag, "STOPPED"), run_id)
        if not stopped:
            return None
        ecs, _ = self._clients()
        descs = ecs.describe_tasks(cluster=self.cfg.cluster, tasks=stopped[:100]).get("tasks", [])
        descs.sort(key=lambda t: str(t.get("stoppedAt") or ""), reverse=True)  # newest first
        for t in descs:
            arn = t.get("taskArn")
            if not arn:
                continue
            result = parse_result(self._logs_for(arn))
            if result is not None and result.state.value in _RECONCILABLE:
                if journal is not None:
                    self._sync_journal(arn, journal, 0)
                return result
        return None


def build_fargate_runner(**_kw) -> FargateLauncher:
    """The `box_runner.fargate` entry point: build the runner from the deployment's env.

    Called with no arguments by `registry.remote_box("fargate")` (via `runner_from_addon`),
    so every coordinate comes from the environment the Terraform stack sets on the worker."""
    return FargateLauncher(fargate_config_from_env())
