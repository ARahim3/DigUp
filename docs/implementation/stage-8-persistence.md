# Stage 8 — persistence and reliability under load: stop mid-job, rotation, resume

Date: 2026-11-02. Stage 7 shipped the image; Stage 8 makes the **long-running reality**
safe: a container stopped while a real 4-minute job is embedding files, a job log that
never grows without bound, restarts under load. Rules: README §5 (interrupted is
interrupted; SQLite keeps the index whole; state outlives containers) — implemented in
`server/digup_server/jobs.py` and proven live in Compose.

## The three upgrades (`jobs.py`)

1. **Stop-at-the-safe-point (the mid-job SIGTERM fix).** `shutdown()` now sends the
   engine's own `stop` command to the live `index-service`: the writer ends its stream
   at the next safe point — **between files**, never mid-embed — and the job records
   *interrupted*, never success. Which record lands depends on the container's stop
   grace, and Stage 8 measured **both** paths live in Compose: with **90 s**
   (`stop_grace_period`, set in the Compose file — one photo embed on 7 CPU cores
   fits) the lifespan finishes inside the grace: the job records *interrupted*
   **with its partial counts**, `Application shutdown complete` in the log, exit 143.
   With Docker's default **15 s** a photo embed cannot finish in time: SIGKILL ends
   the container as 137 (after 16 s), the log's `running` line with no ending replays
   as *interrupted* ("server restart: job never finished") at the next boot, and the
   next job **resumes the walk to `done`** — measured. SQLite stays whole in both
   paths (WAL); the rule holds in both: *interrupted, never success*. `reload →
   prewarm` is skipped on the stopping path (the searcher quits right behind us).
2. **The job log rotates at size** (`DIGUP_SERVER_JOB_LOG_SIZE`, default 1 MiB):
   a rotation is **one rename** to a timestamp-suffixed file (`jobs.jsonl.1730…`,
   `time.time_ns()`; a same-nanosecond collision bumps an `x` on the suffix and the
   order still holds), and the live log — the one with no suffix — is newest by
   construction. Replay reads **all** rotations oldest-first, a sort.
   The first shape chained `.1 … .N` (higher = older) and shifted every file by one on
   each rotation: O(rotations) renames per rotation, and a kill in the middle of the
   shift left the chain out of order — a `running` line read *after* its own `done`
   would report a finished job as *interrupted*. A crash can no longer scramble the
   history, and the history outlives any rotation either way: a long-lived server
   never grows one unbounded file, and never loses the `interrupted` rule along the way.
3. **The backfill knob is env-driven** (`DIGUP_SERVER_BACKFILL`, default on — the
   engine's `--backfill`: sync, then keep embedding the long tail of long PDFs and
   documents in the same job). `0` = sync only. Pinned by a test that reads the knobs
   from the environment into the runner and the engine argv.

The resume story the suite pins (no mocks, real engine): a fresh scratch index gets a
job, shutdown lands mid-walk → record *interrupted* with partial counts → **the next
writer takes the flock, resumes the walk (files already embedded are unchanged —
SQLite kept the index whole) and finishes it** → `done` with `searchable 6, pending 0`
and `files_done` at least the partial's. The Stage-5 promise ("a cut-short job is
re-synced by the engine — the server just says so") is now tested at the walk level.

## Tests (`server/tests/test_jobs.py`, 13 job tests — 8 at Stage 8, +5 in the review round)

* `test_a_stop_mid_job_is_interrupted_and_the_next_job_resumes` — the full cycle above,
  real embedding, real kill-window, real resume.
* `test_the_job_log_rotates_and_history_survives_rotation` — six jobs with a 900-byte
  rotate: rotated files exist, and a fresh runner's replay sees every job id, all
  `done` — nothing ghosted, nothing lost.
* `test_the_knobs_are_read_from_the_environment` — backfill/rotation-size/prewarm env
  reach the runner; `--backfill` appears in the engine argv only when enabled.
* `test_shutdown_mid_job_finishes_and_marks_the_job_interrupted` — the review round's
  repro of a **self-deadlock**: `shutdown()` called `_mark()` from inside
  `with self._lock:` and `_mark` takes that same plain (non-reentrant) Lock, so a
  `docker stop` whose job outlived the worker's join grace hung the lifespan forever
  (job never logged *interrupted*, `service.quit()` never ran, and every job poll kept
  consuming a threadpool thread). The fix reads `_active` under the lock and marks it
  outside. A fake `_run_one` sleeping 25 s (one long file's embed, past the 20 s join
  grace) proves `shutdown()` returns in seconds with the job *interrupted* and
  `why "server stopped"`.
* `test_a_crashing_job_runner_leaves_indexing_alive` — the runner thread survived a
  `_run_one` that raised: the refresh after a job answers `TimeoutError` on a 60 s
  prewarm, and `TimeoutError` is **not** a `RuntimeError`, so the old
  `except RuntimeError` let it kill the worker silently: `_active` stayed set, every
  later `POST /index` answered 409 naming a job that could never run, and recovery was
  a container restart. Now: mark the job interrupted with the reason, clear `_active`,
  keep the thread — the next job runs on the real path.
* `test_a_prewarm_timeout_after_done_keeps_the_job_done` — a writer that finished is
  *done*; a timed-out searcher refresh behind it is a note on the done job
  (`"searcher refresh deferred"`), never a state that claims more than happened.
* `test_replay_ignores_lines_that_are_not_job_records` — a hand-merged log with valid
  JSON that is not a record (`5`, `null`, `{"state":"running"}` with no id) must not
  brick the boot: the old replay did `record["id"]` on any parsed line, `__init__`
  propagated, and the app refused to start. Junk lines and torn tails are skipped;
  the one real `running` record still recovers as *interrupted*.

## Proof

**Suite (2026-11-02, dedicated `/corpus`-scoped suite index):**

```
48 passed, 1 deselected, 1 warning in 181.86s (0:03:01)
```

The stop-mid-job test did what Stage 8 claims: shutdown landed mid-walk on a fresh
scratch index → record `interrupted · "server stopped during job" · files_done 2`
(partial, the engine's) → the next runner took the flock, resumed, and finished
`done · searchable == live folder count · pending 0 · files_done ≥ partial`.
The rotation test rotated a 900-byte log across six jobs and replayed all of them
from the rotations; the knobs test read backfill/rotation/prewarm from the environment.

**Compose restart-under-load (both grace paths, measured live on the same 15-file corpus):**

*Run 1 — Docker's default 15 s grace (grace < remaining embed):*

```
job 40c52677ac92 (prune re-scope) running → docker stop --time 15
stop took 16 s, exit=137 (SIGKILL)        # photo embed > 15 s: safe point unreachable
next boot: job replays as interrupted · "server restart: job never finished"
mid-way status: files 15 · searchable 0 · vectors 0
resume job 80ba3f1f97f0 → done · searchable 15 · vectors 37 · files_done 15 · 122.7 s
```

*Run 2 — Compose `stop_grace_period: 90s` (safe point reachable):*

```
job 9c4877cf1f61 running 30 s into the embeds → docker stop (grace 90 s)
stop took 14 s · exit=143 · log: Shutting down → Waiting for application shutdown
           → Application shutdown complete.                       # lifespan finished
job record: interrupted · why "server stopped during job" · files_done 8 · 42.9 s
mid-way status: files 15 · searchable 8 · vectors 8               # index whole (WAL)
resume job → done · searchable 15 · files_done 7 · 98.1 s         # 8 + 7 = 15 exactly
search: wakeboarding → strong 3, 3 hits
idle stop at the end: 2 s · exit 143 · shutdown-complete   (the CI contract path)
```

`8 + 7 = 15` is the resume story in numbers: every file embedded before the kill stayed
embedded, and the next job did exactly the remaining work. The job log on the config
volume kept the whole history across all of it (timestamp-suffixed rotations at 1 MiB; the suite
proves rotation with history at 900 bytes).

## What this proves / does not

* **Proves**: container stop during a real job is graceful, truthful (interrupted with
  partial counts), and inside the stop grace; the walk resumes after restart with the
  engine's counts; the job log rotates without losing history; backfill is a knob, not
  a fork.
* **Does not prove**: crash-mid-SQLite-write stress (the engine's own journaling; the
  suite exercises the kill window), multi-replica writer contention beyond the flock,
  log shipping/centralized observability, auth, GPU (Stage 9).

## Carried forward

1. Stage 9 (GPU, prod box only): the same runner over the CUDA/Vulkan build, measured
   there (§11); the embedding-determinism item rides with it (IMPLEMENTATION_STATUS §8).
2. Stage 10 (PhotoPrism import): the import side walks the same prune/resume rules.
3. Stage 11 (polish): UI job panel shows the `interrupted (partial)` record verbatim.
