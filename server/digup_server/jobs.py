"""Index jobs: the server's single writer, one job at a time, honest states.

Rules this file lives by (docs/implementation/README.md §5):

* **One indexing job at a time.** The API serializes jobs in a worker thread *and* the
  adapter's `flock` guards the index itself — a second writer never races the first,
  and a second request is answered "busy, job X is running", never queued blind. The
  active marker clears when the writer releases the lock, *before* the `done` record is
  published: a client that can read `done` can always start the next job.
* **An interrupted job is recovered as *interrupted*, never as success.** The job log is
  append-only JSON-lines beside the index (`<config>/jobs.jsonl`), **rotated at size**
  (`DIGUP_SERVER_JOB_LOG_SIZE`, default 1 MiB; history replays from all rotations,
  oldest first). A job that starts and never finishes (crash, kill, container stop) is
  marked `interrupted` at the next startup, by replaying the log. SQLite keeps the index
  whole; the engine re-syncs what a cut-short job left — the server just says so.
* **Container stop during a job: two honest paths, both measured (Stage 8).**
  `shutdown()` sends the engine's `stop` command — the writer closes its stream at the
  next safe point (between files). Which record lands depends on the stop grace:
  **inside** the grace (Compose sets `stop_grace_period: 90s`, enough for one file's
  CPU embed) the lifespan finishes — job *interrupted* **with its partial counts**,
  `Application shutdown complete`, exit 143. Grace **shorter than the embed left**
  (Docker's 10–15 s default): SIGKILL ends the container as 137, and the log's
  `running` line with no ending replays as **interrupted** ("server restart: job
  never finished") at the next boot — never success. SQLite stays whole either way;
  the next job resumes the walk (proven: `done` after both paths).
* **Progress is counted, never invented.** The job's numbers are the engine's own events:
  `sync` (added/changed/moved/removed), per-file `done` events, and the `idle` totals
  (`files/searchable/pending/vectors`) — the semantics pinned in Stage 3.
* After a **done** job the searcher is brought current — `reload()` → `prewarm()`, the
  sequence the contract suite proved (Stage 3, `test_reload_after_indexing`).
* ParentWatch: `index-service` is spawned by this process (the API is the long-lived
  parent, spawn direct, no shell wrapper); a killed API takes the writer with it.
"""

from __future__ import annotations

import json
import os
import threading
import time
import uuid
from collections.abc import Callable

from .engine import IndexBusy, IndexService
from .engine.config import EngineConfig
from .engine.protocol import EngineExited

JOB_LOG = "jobs.jsonl"

# States the server publishes. `queued/running/done/interrupted/busy` — a job that never
# ran because the lock was held is `busy` (answered, not silently dropped).
STATE_QUEUED, STATE_RUNNING, STATE_DONE, STATE_INTERRUPTED = (
    "queued", "running", "done", "interrupted")


class JobBusy(RuntimeError):
    """A job is queued or running. The API answers 409 with the live job's id."""

    def __init__(self, job_id: str):
        self.job_id = job_id
        super().__init__(f"index job {job_id} is already queued or running")


class JobRunner:
    """Serialized index jobs over `IndexService`; `snapshot()` for the API, log in JSONL."""

    def __init__(self, config: EngineConfig, *, config_dir: str,
                 after_done: Callable[[], None] | None = None,
                 backfill: bool = True, linger_s: float = 8.0,
                 sync_timeout_s: float = 3600.0,
                 log_rotate_bytes: int = 1_048_576):
        self._config = config
        self._log_path = os.path.join(config_dir, JOB_LOG)
        self._after_done = after_done      # the searcher's reload→prewarm, wired by the app
        self._backfill, self._linger = backfill, linger_s
        self._timeout = sync_timeout_s
        self._rotate = log_rotate_bytes    # Stage 8: the log rotates at size; history lives on
        self._jobs: dict[str, dict] = {}
        self._lock = threading.Lock()
        self._active: str | None = None   # queued-or-running job id (the "one at a time")
        self._queue: list[str] = []
        self._wake = threading.Event()
        self._stopping = False
        self._service: IndexService | None = None   # the live writer, for `shutdown()`'s stop
        os.makedirs(config_dir, exist_ok=True)
        self._recover()
        self._worker = threading.Thread(target=self._run_jobs, name="digup-jobs", daemon=True)
        self._worker.start()

    # ── the API's surface ──────────────────────────────────────────────────────────────

    def start(self, *, prune: bool = False) -> dict:
        """Queue one job (optionally with the engine's `--prune`: retire rows for files
        missing from the roots). `JobBusy` (with the live id) when one is in flight."""
        with self._lock:
            if self._active is not None:
                raise JobBusy(self._active)
            job = {"id": uuid.uuid4().hex[:12], "state": STATE_QUEUED,
                   "started": round(time.time(), 3)}
            if prune:
                job["prune"] = True
            self._jobs[job["id"]] = job
            self._active = job["id"]
            self._queue.append(job["id"])
            record = {"id": job["id"], "state": STATE_RUNNING, "started": job["started"]}
            if prune:
                record["prune"] = True
            self._append(record)          # the log record carries the job's prune flag
            self._wake.set()
            return dict(job)

    def job(self, job_id: str) -> dict | None:
        with self._lock:
            found = self._jobs.get(job_id)
            return dict(found) if found else None

    def jobs(self) -> list[dict]:
        with self._lock:
            return [dict(j) for j in self._jobs.values()]

    def shutdown(self) -> None:
        """Stop the worker. A running job is asked to stop **at the engine's safe point**
        (the `stop` command ends the walk between files) and is logged *interrupted*.
        If the safe point falls inside the container's stop grace, this finishes the
        lifespan (143); if the embed outlives the grace, the 137 kill is recovered as
        *interrupted* by log replay at the next boot (Stage 8, both paths measured)."""
        self._stopping = True
        service = self._service
        if service is not None:
            try:
                service.stop()               # the writer ends at the next safe point
            except (EngineExited, TimeoutError, RuntimeError):
                pass                         # already gone: the join below handles the worker
        self._wake.set()
        self._worker.join(timeout=20.0)      # one file's embed at the safe point fits 15 s
        with self._lock:
            if self._active is not None:
                self._mark(self._active, STATE_INTERRUPTED, "server stopped")

    # ── the worker ─────────────────────────────────────────────────────────────────────

    def _run_jobs(self) -> None:
        # Honors `_stopping` on every wake: shutdown must not sit in `_wake.wait()` for
        # its join timeout (a container stop is a 10 s grace, not 30).
        while not self._stopping:
            self._wake.wait()
            self._wake.clear()
            while self._queue and not self._stopping:
                self._run_one(self._queue.pop(0))
                with self._lock:
                    self._active = None

    def _run_one(self, job_id: str) -> None:
        with self._lock:
            job = self._jobs[job_id]
            job["state"] = STATE_RUNNING   # the worker has picked it up: GET /jobs says so
        service = IndexService(self._config, backfill=self._backfill,
                               prune=bool(job.get("prune")), linger_s=self._linger)
        self._service = service               # live writer: shutdown() can ask it to stop
        try:
            service.start()                       # flock: the outer single-writer guarantee
        except IndexBusy as exc:
            with self._lock:
                self._active = None
            self._service = None
            self._mark(job_id, "busy", str(exc))  # answered, not queued blind
            return
        try:
            events = service.run_sync(timeout=self._timeout)
        except (EngineExited, TimeoutError) as exc:
            with self._lock:
                self._active = None   # the writer is done; a new job may queue
            self._service = None
            self._mark(job_id, STATE_INTERRUPTED, str(exc))
            return
        finally:
            service.finish()          # idempotent: releases the writer lock
        self._service = None
        # The writer being finished IS the job being done: clear `_active` first, so a
        # client that reads `done` can always start the next job — never a done-409 window.
        with self._lock:
            self._active = None
        counts = self._counts(events)
        ended = round(time.time(), 3)
        started = job.get("started") or ended
        if self._stopping:
            # Asked to stop mid-job (container stop): the engine closed the stream at the
            # safe point. Honest: *interrupted* with the partial counts, never success,
            # and no reload→prewarm — the searcher is quitting right behind us.
            self._mark(job_id, STATE_INTERRUPTED, "server stopped during job",
                       ended=ended, seconds=round(ended - started, 1), **counts)
            return
        self._mark(job_id, STATE_DONE, None, ended=ended,
                   seconds=round(ended - started, 1), **counts)
        if self._after_done is not None:
            try:
                self._after_done()                  # reload → prewarm: searcher is current
            except RuntimeError as exc:
                # The job is done and stays done — a refusal on the refresh (ok:false,
                # EngineExited, restart races) must not kill the runner thread. The next
                # search will get the searcher back through the adapter's own respawn.
                self._mark(job_id, STATE_DONE, f"searcher refresh deferred: {exc}",
                           ended=ended, seconds=round(ended - started, 1), **counts)

    # The engine's own totals: the last `idle` event's counts, the file events' `done`s.
    @staticmethod
    def _counts(events: list[dict]) -> dict:
        idle = [e for e in events if e.get("event") == "idle"]
        files = [e for e in events if e.get("event") == "file"]
        counts = {"files": None, "searchable": None, "pending": None, "vectors": None,
                  "files_done": sum(1 for f in files if f.get("state") == "done"),
                  "files_failed": sum(1 for f in files
                                      if f.get("state") not in ("done", None)),
                  "errors": sum(1 for e in events if e.get("event") == "error")}
        if idle:
            last = idle[-1]
            for key in ("files", "searchable", "pending", "vectors"):
                counts[key] = last.get(key)
        return counts

    # ── the log (append-only JSON-lines, rotated at size; replay reads ALL of it) ──────

    def _log_files(self) -> list[str]:
        """Every job log, oldest first. Rotations chain `.N … .2 .1` (higher number is
        older), the current log last — history survives rotation (Stage 8)."""
        files, n = [], 1
        while os.path.exists(f"{self._log_path}.{n}"):
            files.append(f"{self._log_path}.{n}")
            n += 1
        files.reverse()
        if os.path.exists(self._log_path):
            files.append(self._log_path)
        return files

    def _append(self, record: dict) -> None:
        if self._rotate and os.path.exists(self._log_path) \
                and os.path.getsize(self._log_path) > self._rotate:
            rotated = 1
            while os.path.exists(f"{self._log_path}.{rotated}"):
                rotated += 1
            for k in range(rotated - 1, 0, -1):        # shift .k → .k+1, oldest moved first
                os.replace(f"{self._log_path}.{k}", f"{self._log_path}.{k + 1}")
            os.replace(self._log_path, f"{self._log_path}.1")
        with open(self._log_path, "a", encoding="utf-8") as log:
            log.write(json.dumps(record, separators=(",", ":")) + "\n")

    def _mark(self, job_id: str, state: str, why: str | None, **extra) -> None:
        with self._lock:
            job = self._jobs.get(job_id)
            if job is not None:
                job.update(state=state, **extra)
                if why:
                    job["why"] = why
        record = {"id": job_id, "state": state, **extra}
        if why:
            record["why"] = why
        if job is not None and job.get("prune"):
            record["prune"] = True        # the persisted record echoes the request
        self._append(record)

    def _recover(self) -> None:
        """Replay the log (rotations included, oldest first): a `running` job with no
        final line is *interrupted*. Never success."""
        seen: dict[str, str] = {}
        for path in self._log_files():
            with open(path, encoding="utf-8") as log:
                for line in log:
                    try:
                        record = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    seen[record["id"]] = record["state"]
                    self._jobs[record["id"]] = record
        for job_id, state in seen.items():
            if state == STATE_RUNNING:
                self._mark(job_id, STATE_INTERRUPTED, "server restart: job never finished")
