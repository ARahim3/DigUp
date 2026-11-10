# Stage 5 — index jobs: one writer, answered busy, honest states

Date: 2026-11-02. `POST /api/v1/index` starts a real `index-service` stretch through the
adapter; `GET /api/v1/jobs/{id}` reports what the engine said. The rules are README §5's,
implemented exactly: one job at a time, OS-level lock, interrupted jobs recovered as
*interrupted*, progress counted from the engine's own events.

## The runner (`server/digup_server/jobs.py`)

* **One at a time, twice over**: jobs are serialized in a single worker thread *and*
  guarded by the adapter's `flock` on `<index>/.digup-server.writer.lock` (Stage 3). A
  `POST` while a job is queued/running answers **409 with the live job's id** — answered,
  never queued blind; a writer that sneaks past the queue (two servers sharing a volume)
  hits the flock and its job records `busy`.
* **The job log is append-only JSON-lines** (`<config>/jobs.jsonl`, default
  `<index>/server-config`, Compose: `/data/config`): a `running` line at spawn, a final
  `done/interrupted/busy` line at the end. At startup the log is replayed: any `running`
  line with no ending becomes **`interrupted`** — never success (README §5). A crash, a
  kill, a container stop all end up as a truthful `interrupted`.
* **The job's numbers are the engine's**: per-file `file` events counted `done`, the last
  `idle` event's totals (`files/searchable/pending/vectors`), an `errors` tally. No
  percentages, no ETA guesses.
* **After a `done` job** the searcher is brought current — `reload()` → `prewarm()`, the
  sequence the Stage-3 contract suite proved — wired in the app's lifespan, so a client
  that indexed a file and then searches finds it; nothing else to remember.
* ParentWatch: `index-service` is spawned by the API process (direct child, no shell
  wrapper); a killed API takes the writer with it; `shutdown()` marks a live job
  `interrupted` before the searcher quits. The worker loop honors `_stopping` on every
  wake — container stop is a 10 s grace, not 30.
* **A client never sees `done` and gets 409**: the writer finishing *is* the job being
  done, so the runner clears its active-job marker when the writer releases the lock,
  **before** publishing the `done` record. (The suite caught the inverse order in its
  second run — 34/1: a poll that read `done` mid-log-append hit 409. Fixed in the
  adapter, not in the test.)

## API additions (`server/digup_server/api.py`)

`POST /api/v1/index` (202 `{"ok":true,"job":…}` / 409), `GET /api/v1/jobs` (list),
`GET /api/v1/jobs/{id}` (404 for unknown). Indexing never starts by itself. Bodies are
empty models: roots are the server's configuration — a client names no paths (§7).

## Tests (`server/tests/test_jobs.py`, 4)

Live over the scratch corpus (4 photos + the clip + notes.txt, indexed once by the
fixture through `IndexService`):

1. `POST /index` → 202 `queued`; a second `POST` → **409 naming the live job**; poll to
   `done`. Then a new file arrives (`lighthouse.txt`), a second job runs to `done` with
   `files_done ≥ 1`, `errors == 0`, `idle` totals `searchable == 7, pending == 0` — and
   the same client, over HTTP, immediately searches `"lighthouse stormy sea at dusk"`
   and gets the new file: the `reload → prewarm` after `done`, proven end-to-end.
2. The done job's record carries the engine's fields (`started/ended/seconds/files/
   searchable/pending/vectors/files_done/files_failed/errors`), `vectors ≥ 7`.
3. Unknown job id → 404.
4. Recovery, from a log line `running` with no ending: the next `JobRunner` startup marks
   it `interrupted` and appends that to the log — the README §5 rule, tested.

## Suite result

2026-11-02, final image, warm index mount — the run's own line:

```
35 passed, 1 deselected, 1 warning in 128.69s (0:02:08)
```

(31 from Stages 3–4 + the 4 job tests; the scratch-corpus indexing of the fixture is most
of the extra wall time.)

Live check, API container with `--init`, real corpus index:

```
POST /api/v1/index  → 202 {"job": {"id": "80aa17aeeb6b", "state": "queued"}}
POST /api/v1/index  → 409                       # answered busy, names the live job
GET  /api/v1/jobs   → done: files 15, searchable 15, pending 0, vectors 37,
                      files_done 0, errors 0, seconds 0.1   # a quiet sync, engine's counts
GET  /api/v1/status → encoder ready · vectors 37 · searchable 15 · pending 0
```

## What this proves / does not

* **Proves**: jobs are real engine stretches with the engine's counts; the single-writer
  rule is enforced at the API (409), in the adapter (flock), and in the log; the honest
  `interrupted` recovery works; searcher-after-job freshness (reload→prewarm) is
  automatic and verified by search.
* **Does not prove**: jobs across container restart under load (Stage 7/8 — compose +
  `tini` make the restarts real), multi-root job semantics, per-root `sync code`, job
  cancellation API, auth.

## Carried forward

1. Stage 6 (UI): the search panel polls `GET /jobs/{id}` while a job runs, showing the
   engine's counts verbatim — no made-up progress bar; a busy answer is shown as busy.
2. Stage 7: `tini` in the runtime image; SIGTERM → `runner.shutdown()` → `quit()`.
3. Stage 8: job log on the `/data/config` volume; log rotation at size; the `backfill`
   knob (`backfill on/off` lines) exposed as a setting.
