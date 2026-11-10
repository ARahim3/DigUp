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
                 log_rotate_bytes: int = 1_048_576,
                 log_name: str = JOB_LOG):
        self._config = config
        self._log_path = os.path.join(config_dir, log_name)   # named indexes keep their own
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
        # `_mark` takes `self._lock` for itself — calling it from inside `with self._lock:`
        # self-deadlocks a plain Lock (docker stop mid-job hung the lifespan: the reviewer's
        # repro showed `_mark` at jobs.py:248 waiting on line 138, forever).
        with self._lock:
            active = self._active
        if active is not None:
            self._mark(active, STATE_INTERRUPTED, "server stopped")

    # ── the worker ─────────────────────────────────────────────────────────────────────

    def _run_jobs(self) -> None:
        # Honors `_stopping` on every wake: shutdown must not sit in `_wake.wait()` for
        # its join timeout (a container stop is a 10 s grace, not 30).
        while not self._stopping:
            self._wake.wait()
            self._wake.clear()
            while self._queue and not self._stopping:
                job_id = self._queue.pop(0)
                try:
                    self._run_one(job_id)
                except Exception as exc:   # any escape from _run_one (TimeoutError from a
                    # 60 s prewarm, OSError from spawn, …) would kill this thread silently,
                    # leave `_active` set forever, and wedge all indexing behind a job that
                    # can never run — every later request answering 409 until a restart.
                    self._mark(job_id, STATE_INTERRUPTED, f"job runner: {exc}")
                finally:
                    self._service = None
                    with self._lock:
                        self._active = None

    def _run_one(self, job_id: str) -> None:
        with self._lock:
            job = self._jobs[job_id]
            job["state"] = STATE_RUNNING   # the worker has picked it up: GET /jobs says so
        # Counters exist from the first moment of the walk, at zero. `shutdown()` can land
        # during the model load — before the engine has emitted a single `file` event — and
        # then the honest answer is "0 done", never an absent counter. Measured: that exact
        # timing made the suite's stop-mid-job test read a record with no counts at all.
        self._progress(job_id, files_done=0, files_failed=0, errors=0)
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
        # Progress is published AS IT ARRIVES, onto the live job record: whichever path ends
        # the job (`EngineExited`, a timeout, `shutdown()`'s "server stopped", an escaped
        # exception) then answers with the counts the engine really emitted. Measured: a job
        # stopped by `shutdown()` published *interrupted* with NO counts, because the counts
        # lived only in this thread's local list and `shutdown()` marks from its own thread.
        done = failed = errors = 0
        try:
            service.sync()
            for event in service.events(timeout=self._timeout):
                kind = event.get("event")
                if kind == "file":
                    if event.get("state") == "done":
                        done += 1
                    elif event.get("state") is not None:
                        failed += 1
                    self._progress(job_id, files_done=done, files_failed=failed)
                elif kind == "error":
                    errors += 1
                    self._progress(job_id, errors=errors)
                elif kind == "idle":
                    # The engine's own batch totals, a handful per job: these ride into the log
                    # too (see `_progress`), so a record recovered after a hard kill carries the
                    # last totals the engine published.
                    self._progress(job_id, log=True, files_done=done, files_failed=failed,
                                   errors=errors,
                                   **{k: event.get(k)
                                      for k in ("files", "searchable", "pending", "vectors")})
        except (EngineExited, TimeoutError) as exc:
            with self._lock:
                self._active = None   # the writer is done; a new job may queue
            self._service = None
            service.finish()
            self._mark(job_id, STATE_INTERRUPTED, str(exc), **self._live_counts(job_id))
            return
        finally:
            service.finish()          # idempotent: releases the writer lock
        self._service = None
        # The writer being finished IS the job being done: clear `_active` first, so a
        # client that reads `done` can always start the next job — never a done-409 window.
        with self._lock:
            self._active = None
        counts = self._live_counts(job_id)
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
            except (RuntimeError, TimeoutError) as exc:
                # The job is done and stays done — a refusal on the refresh (ok:false,
                # EngineExited, restart races, a prewarm that outlives its 60 s window)
                # must not kill the runner thread. The next search will get the searcher
                # back through the adapter's own respawn.
                self._mark(job_id, STATE_DONE, f"searcher refresh deferred: {exc}",
                           ended=ended, seconds=round(ended - started, 1), **counts)

    # The engine's own totals, read from the live job record: `_progress` merged every
    # counter as it arrived — the per-file `done`/`failed` counts, the `error` count, and
    # the engine's own `idle` batch totals (last one wins, exactly as the event stream
    # produced them). Keys the engine never published read as None. One source, and a
    # 1.8 M-file job carries no second copy of every event in a list.
    _COUNT_KEYS = ("files", "searchable", "pending", "vectors",
                   "files_done", "files_failed", "errors")

    def _live_counts(self, job_id: str) -> dict:
        with self._lock:
            job = self._jobs.get(job_id) or {}
        return {key: job.get(key) for key in self._COUNT_KEYS}

    # ── the log (append-only JSON-lines, rotated at size; replay reads ALL of it) ──────

    def _log_files(self) -> list[str]:
        """Every job log, oldest first. Rotations are timestamp-suffixed (`jobs.jsonl.1730...`),
        so a rotation is ONE rename and a replay order is a sort — the old `.k → .k+1` chain
        was O(rotations) renames per rotation, and a kill mid-shift could leave the chain out
        of order (a `running` line read after its `done` reported finished jobs as
        *interrupted*). The live log (no suffix) is last, by construction the newest."""
        try:
            siblings = os.listdir(os.path.dirname(self._log_path) or ".")
        except OSError:
            siblings = []
        rotated = sorted(name for name in siblings
                         if name.startswith(os.path.basename(self._log_path) + ".")
                         and name != os.path.basename(self._log_path))
        files = [os.path.join(os.path.dirname(self._log_path) or ".", name) for name in rotated]
        if os.path.exists(self._log_path):
            files.append(self._log_path)
        return files

    def _append(self, record: dict) -> None:
        if self._rotate and os.path.exists(self._log_path) \
                and os.path.getsize(self._log_path) > self._rotate:
            stamp = f"{time.time_ns()}"           # ns-clock: two rotations in one second sort right
            rotated = f"{self._log_path}.{stamp}"
            while os.path.exists(rotated):        # same clock twice in one run: bump the suffix
                rotated = f"{rotated}x"
            os.replace(self._log_path, rotated)
        with open(self._log_path, "a", encoding="utf-8") as log:
            log.write(json.dumps(record, separators=(",", ":")) + "\n")

    def _progress(self, job_id: str, *, log: bool = False, **counts) -> None:
        """Merge the engine's counts into the live record while the job runs, so every ending
        publishes them (interrupted by shutdown, by the writer exiting, by a timeout, by an
        escaped exception — the counts are never only this thread's local knowledge).

        In-memory by default: a per-file log line is not worth a 50 k-line log. `log=True`
        rides the engine's own `idle` events (its batch totals, a handful per job), so a
        record recovered from the log after a hard kill carries the last totals it saw."""
        with self._lock:
            job = self._jobs.get(job_id)
            if job is not None:
                job.update(counts)
        if log:
            self._append({"id": job_id, "state": STATE_RUNNING, **counts})

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
                        continue   # a torn tail: half a line is not a record
                    if not isinstance(record, dict) or "id" not in record:
                        continue   # valid JSON that is not a job record (a hand-merged log)
                    seen[record["id"]] = record["state"]
                    self._jobs[record["id"]] = record
        for job_id, state in seen.items():
            if state == STATE_RUNNING:
                self._mark(job_id, STATE_INTERRUPTED, "server restart: job never finished")
