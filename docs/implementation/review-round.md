# Review round — the adversarial pass before the PR

Three read-only adversarial reviews of the whole PR (Python backend; UI + media surface;
build / deploy / CI / docs), each looking for blockers with concrete failure scenarios,
plus the empirical checks that confirmed or killed each finding. Everything the reviews
found that was real is fixed **and pinned by a test**; what is not fixed is listed with
its reason, not left silent.

## The suite and the harness rule this round exposed

The first suite run after the fixes came back `7 failed, 9 passed, 59 errors` with every
helper dying `exit 0, no stderr`. Not a code bug: `docker run` makes the test process
**PID 1**, and ParentWatch treats PID 1 as "the app is gone"
(`Sources/digup/ParentWatch.swift:19`) — so every `search-service`/`index-service`/
`estimate --json` child ended at once. The suite invocation must give the test process a
live parent. The runtime image already gets this from tini; the **test image now carries
`tini` as its ENTRYPOINT** (`server/docker/Dockerfile`), so the suite is PID-1-safe by
construction and CI needs no `--init`. Measured after the change: the full suite green
(see [IMPLEMENTATION_STATUS](../../server/IMPLEMENTATION_STATUS.md) for the run's numbers).

Same rule in CLI form, discovered while reproducing it: `digup … --index` takes a
**folder**, not the `.sqlite` file — `IndexStore(directory:)` calls
`createDirectory(at:)` on it, so a file path answers NSCocoaError 516 "a file with the
same name already exists" (`Sources/DigUpKit/IndexStore.swift:71-72`). Documented at
`server/digup_server/engine/config.py:71-75` and in reconnaissance §15 item 8.

## Backend — fixed

| Finding (severity) | Concrete failure the reviewer showed | Fix + pinning test |
| --- | --- | --- |
| `shutdown()` self-deadlock (`jobs.py:136-138`, blocker) | `_mark()` called from inside `with self._lock:`, `_mark` takes the same plain Lock: a `docker stop` while a job outlived the 20 s join grace hung the lifespan forever — job never logged *interrupted*, `service.quit()` never ran, job polls consumed threadpool threads until the API stopped answering | read `_active` under the lock, mark it outside → `test_shutdown_mid_job_finishes_and_marks_the_job_interrupted` (fake `_run_one` sleeps past the grace; asserts return < 30 s, *interrupted*, `why "server stopped"`) |
| Runner thread died on a non-`RuntimeError` (blocker) | the post-job refresh raises `TimeoutError` on a 60 s prewarm — **not** a `RuntimeError`, so `except RuntimeError` missed it: worker thread gone, `_active` stuck, every later `POST /index` answered 409 naming a job that could never run, queued jobs frozen until a restart | `except Exception` + `finally` clearing `_active`/`_service` → `test_a_crashing_job_runner_leaves_indexing_alive`, `test_a_prewarm_timeout_after_done_keeps_the_job_done` |
| `_spawn_locked` leaked the child on a failed handshake | `self._proc` was assigned only after a successful `start()`; a raised handshake left the fresh child + 3 pipes + 2 reader threads unreferenced until its own idle-exit (2 × `--encoder-idle` = 600 s), and every retry spawned another | reap on any failure, map `OSError` to `CLIError` → `test_a_failed_handshake_reaps_the_child_it_spawned`, `test_a_missing_engine_binary_answers_clierror` (502 quoting the spawn, not a 500 traceback) |
| `ok:false` without an `error` field (500) | the guard demanded `"error" in reply`, so `{"ok":false,"id":4}` passed `_checked` and `stripped["hits"]` raised KeyError — the exact 500 the Stage-10 battery hit | fire on the shape, message defaults to "no reason given" → `test_a_refusal_without_an_error_field_is_still_a_refusal` |
| `render` serialized behind the query lock | the engine runs `render` **beside** its read loop on 2 slots with replies routed by id ("typing never waits on one", `SearchService.swift:52-56, 99-113`); the adapter held the serialize lock across the engine's up-to-120 s ffmpeg work, so a big-look preview froze every keystroke-search, and a 40-hit gallery serialized 40 renders | `_render_slots = Semaphore(2)` + a lock-free `_render` (lock held only for the spawn check) → `test_renders_run_beside_searching_not_ahead_of_it` (typing answers in ms beside an in-flight 1.2 s render, reply order intact) |
| Unbounded `Range: bytes=0-` | uncapped open/suffix/huge ranges read the WHOLE file into RAM (a 20 GB clip asks for a 20 GB buffer) | `MAX_RANGE_SPAN = 8 MiB` cap + chunked streaming from the span's own handle → `test_open_and_huge_ranges_are_capped_at_the_served_span`, `test_open_range_streams_the_video_rather_than_buffering_it` |
| `subprocess.TimeoutExpired` unmapped (500) | it is a `SubprocessError`, not a `TimeoutError`: a stalled `digup status` behind the writer's WAL, or an estimate crossing 120 s, died as a bare traceback | mapped in `cli.run` (covers every one-shot call) → `test_a_cli_timeout_surfaces_as_a_quoted_502_not_a_500` |
| Job-log replay trusted any parsed JSON | `record["id"]` on a line like `5` raised in `__init__`: the app refused to boot | skip non-dict/no-id lines and torn tails → `test_replay_ignores_lines_that_are_not_job_records` |
| Rotation shifted a `.1…N` chain | O(rotations) renames per rotation, and a kill mid-shift left the chain out of order: a `running` line read after its `done` reported a finished job as *interrupted* | one rename to a `time_ns` suffix, replay = sort → `test_the_job_log_rotates_and_history_survives_rotation` |
| `HitCache.get` didn't refresh (fake LRU) | eviction was insertion-order: the UI re-searches per keystroke-pause (≤40 handles each), so after ~26 searches the handles of the rows ON SCREEN were evicted — their thumbnails, preview and file 404'd with no recovery | `get()` does `move_to_end` → `test_hit_cache_is_a_true_lru_get_refreshes` |
| Two `status` polls = two subprocesses | UI polls `/status` every 15 s, HEALTHCHECK hits `/health` every 30 s, and each spawned a `digup status` doing real SQLite counting (on the writer's hot index) | TTL cache (`DIGUP_SERVER_STATUS_TTL_S`, default 15 s) for the identity fields → `test_the_cli_identity_is_served_from_a_short_cache` |
| Parallel estimates | every full-tree crawl (120 s) ran unguarded: a second tab, a retry click, a retry during a job stacked crawls | busy-lock → 409 "an estimate is already running" → `test_a_slow_estimate_answers_busy_never_parallel` |
| Pydantic dropping engine fields | `SearchReply` (extra=ignore) dropped top-level fields this model has never seen — hits already rode raw, the reply itself must too | `model_config = ConfigDict(extra="allow")` → `test_search_reply_publishes_fields_this_model_has_never_seen` |
| Media surface hardening | size/type read from `path.stat()` (a replacement mid-request makes the headers lie about the bytes); prefix-string root matching; no `nosniff` on the `text/plain` path; events deque and timed-out replies unbounded; `close()` could fail the shutdown that called it | one open + `os.fstat` + `stat.S_ISREG`, `is_relative_to`, `x-content-type-options: nosniff` (200 and 206), `_events` `maxlen=256`, drop the timed-out reply, suppress the last post-kill `wait` → `test_file_carries_nosniff` + the range/streaming tests |

## UI — fixed

| Finding (severity) | Concrete failure | Fix |
| --- | --- | --- |
| Space hijacked every button (blocker) | native button activation fires on **keyup**; the document-level Space handler (Quick Look) `preventDefault()`ed on keydown for any focused element except a few tags — so the gear, ✕, Index now, Estimate, "all", the Esc close, and the Open/Download links stopped activating for keyboard users while the big-look flashed open over the page. Space is the standard activation key, and the footer advertises it | guard is a `closest("button, a, [role='button'], input, select, textarea")` — activation targets keep Space; bare page areas preview. Pinned by `test_the_space_key_keeps_buttons_and_links_activated` |
| A failed job poll killed the loop (blocker) | server restart / engine-mid-respawn 503 rejected the polling promise unhandled: the loop died, the job line froze at its last state, and "indexing…" stayed in the footer forever | poll in `try/catch`: honest `job poll failed: …`, clear `state.indexing`, stop. Repeated busy-clicks poll ONE loop (`state.jobPoll` dedupe), not N → `test_the_ui_survives_a_failed_job_poll` |
| FastAPI list-`detail` rendered `[object Object]` | validation errors answer a list of dicts; `new Error(list)` is that literal on the footer | `api()` renders each `{loc, msg}`, quotes a string, falls back to statusText for a non-JSON body |
| Settings panel: aria desync + dropped focus | outside-click closed the panel without syncing the gear's `aria-expanded` (a screen reader reported an open dialog whose panel was gone) and left a keyboard user at `<body>`; five close paths each did their own partial version | one `closeSettings()` everywhere (aria sync + focus return; opening focuses the first control) |
| Stale estimate reply | a second click during a slow crawl let the FIRST crawl's late reply write into a closed-and-reopened panel | generation token (`estimateToken`) |
| Space on the "weaker" row | the field handler opened the big look on the folded row the document handler toggles | same `toggleWeaker()` on both paths |
| Roving tabindex / listbox roles | every row had `tabIndex=0` — an arrow-key list of 40-100 rows turned every search into a tab storm; group titles claimed `role=option`; the folded weaker row (selectable by ↑↓/↩/Space) said nothing | selected 0 / rest −1, `aria-selected`, group titles `role=presentation`, fold gets `role=option` + `aria-expanded`/`aria-selected` |
| Ticked chip contrast (dark) | kind-color text on its own 14 % tint: the audio chip measured 4.3:1 — under AA | 10 % mix, measured 4.54:1 (the rest 5.4 and up) |
| `.badge.warn` lost the cascade | `.warn` and `.badge` share specificity, `.badge` came later: the estimate's "can't read it" badge rendered in muted grey, identical to the decorative badges beside it | `.badge.warn` rule after `.badge` |
| Audio control in the preview pane | audio hits live in `.audio-picture` (app.js) — the `#preview .picture audio` selector never matched, so the control rendered at its ~300 px default | selector covers both boxes |
| Mobile footer | 48-char keys line at 0.8rem with `white-space: nowrap` overflowed a 320 px viewport | `white-space: normal` under 720px |
| Query field vs API cap | the API rejects > 512 chars; the field accepted any length and the user only learned by an error strip | `maxlength="512"` |

## Build / CI / docs — fixed

* **CI ceiling + cache** (the suite's "tripwire" role needed it): `timeout-minutes` 90 →
  180, and the engine chain (ffmpeg, llama.cpp) is built **host-side with
  `actions/cache`** — the same repo-pinned action and hash keys `ci.yml` uses — then
  passed into the build context as `.ci-vendor/`; the Dockerfile seeds its BuildKit cache
  mount from it, so `fetch-vendor`/`build-ffmpeg`/`build-llama` land on their own stamps
  (`Vendor/VENDOR`, `ffmpeg/BUILD`, `llama/BUILD`) and skip the rebuild. Hosted runners
  start their BuildKit cache mounts cold, and a 15-minute ffmpeg compile per PR was
  measured overrunning the ceiling. A local build has an empty `.ci-vendor/` (only the
  tracked `.gitkeep`) and pays nothing.
* **Zero-skip gate**: the suite self-skips a module when `/models`, `/corpus-root` or the
  clip is missing, so `57 passed, 20 skipped` would be green-by-construction. CI fails on
  **any** SKIPPED line and requires `[0-9]+ passed`. The clip (`media/clips/scenes.mp4`,
  the video fixtures) is asserted to exist as its own step.
* **Drift guard runs FIRST** and now pins `ModelFiles.revision` and both file **names**
  as well as the two sha256s: a revision bump with unchanged hashes moves the download
  URL silently, a renamed file moves it loudly — both are red in seconds, not after an
  hour of build minutes.
* **proof.sh reports failure**: it ran each gate through `cmd | tee log` and exited 0
  unconditionally, so a run where the index died and every search answered nothing was
  "green" and CI cited its `EXIT=0`. It now counts failed gates (`pipefail` makes the
  pipeline status real), labels the gate that failed, and gates the eval ALL row
  (R@1 ≥ 0.60, R@5 ≥ 0.85 — the recorded 0.71/0.88 clear it with margin) before
  exiting non-zero.
* **Runtime image honesty** (measured, not claimed): the base is Debian 13 (trixie),
  glibc 2.41-12+deb13u4 — newer than the payload's build glibc 2.35 (Ubuntu 22.04),
  forward never back; the healthcheck is `server/docker/healthcheck.py` and accepts
  **503 as alive** (`/health` answers 503 while the searcher respawns — the engine's own
  refusal; Docker must not restart a live server over it; urlopen raises `HTTPError` on
  503 so it is caught; the build asserts the script exits non-zero with nothing
  listening, CI polls with it); `/data/locks` is gone (the writer lock is
  `<index>/.digup-server.writer.lock`); the inert `DIGUP_SERVER_HOST/PORT` ENV lines are
  gone (uvicorn's `--host/--port` args win in a container — those envs feed
  `python -m digup_server.api`); `digup --help` in the image is described as what it
  is (the CLI runs headless) with §3's full acceptance — CLI answering status and
  searches from a live index — proven by CI's boot step and the proof battery.
* **Compose**: `restart: unless-stopped` (back with the daemon, down after a manual
  stop) and `DIGUP_PUBLISH_PORT` for the host side when 8787 is taken; localhost-only
  publish unchanged; `docker compose config --quiet` is a CI step.
* **Build context**: `.dockerignore` now excludes the corpus videos/clips and corpus2
  media (the reviewer measured 45 MB of corpus2 photos riding into the build context),
  `.playwright-mcp/`; `.gitignore` ignores `.ci-vendor/*` with a `!`-exception for its
  tracked `.gitkeep` (the Dockerfile's `COPY` needs the folder).
* **Docs measured, not asserted**: test counts, image sizes, glibc, contrast, suite
  buckets, and the quick start's `mkdir -p … && sudo chown -R 990:990 …` for real Linux
  hosts (uid 990 vs Docker-created root dirs → EACCES crash loop) follow the runs that
  proved them.

## Deliberately not fixed (with reasons)

* **No auth, localhost-only publish.** Single-user loopback by design (§7); LAN exposure
  requires authentication first. Recorded in README and the compose comment.
* **`pixels` is not capped server-side.** Single-user localhost, and the engine renders on
  2 slots; a malicious client asking for a huge render costs the user their own CPU,
  which they already own.
* **No `fsync` on the job log after each line.** `fsync` per line is the classic
  performance victim; a crash loses at most the last record, and the SQLite index — the
  real state — is durable. The job log is a *journal of intent*, replayed to mark
  unfinished jobs *interrupted*: losing its tail loses a job's last note, never a lie.
* **The test image runs as root.** Its scratch indexes and host mounts are the tests'
  own; the shipping image is non-root (`uid 990`), which is what a user runs.
* **The engine's own limits are left alone** (by the PR's rule): `zGate` 2.0, default
  limit 40, render slots 2, idle-exit timings — the server speaks the published
  protocol and shows the engine's numbers verbatim, so parity with the Mac app comes
  from not adding anything.
