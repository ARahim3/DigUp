# Implementation status

One document, kept current (docs/implementation/README.md §10). Newest first.

## 2026-11-02 — UI reorganized around the search (the user's layout brief), in the browser

* **The page is a search:** centered search box with the hit-limit select at its right
  end (arrow evenly spaced off the edge — selects render their own chevron per theme),
  theme-colored kind chips in one evenly spaced centered row beneath it (filled in the
  kind's color when ticked), results bottom-left, preview right, keys footer. Header:
  title + searchable count + activity + a gear.
* **Settings panel (the gear):** Appearance, Index now + prune missing, Estimate, and the
  engine's counts (vectors, encoder, kinds, index size, build tag, roots). Estimate stays
  honest and short — one note line, the forecast renders above the results, the long
  paragraph the user pointed at is gone. The panel closes on Esc, outside click, and on
  opening the estimate. `#settings[hidden]{display:none}` — the same `[hidden]` lesson as
  `#big`.
* **`el()` fixed:** the helper took an element as its text arg at three call sites and
  stringified it — the "[object HTMLElement]" text the user saw (estimate rows, preview
  messages). Children are real nodes/text nodes now; verified clean in the browser
  (`[object HTMLElement]` = false, zero console errors).
* **"water shows only the harbor photo" is the engine, not the UI:** `Searcher.zGate = 2.0`
  (`Sources/DigUpKit/Searcher.swift:116`) filters sub-2σ candidates inside the binary —
  the Linux app with the same index answers the same single hit. Measured live: 1 hit,
  z 2.09. The UI publishes the engine's answer unchanged (the server's core rule).
  Panel parity re-audited against `panel.js`: `limit: 40` (the engine default — the
  select is a superset), the WEAKER fold, groups, keyboard flow, footer summary.
* Browser battery re-run: typing → 5 hits (4 strong) → click → preview, settings open,
  estimate clean, theme flip, 0 console errors; layout verdict from the vision model:
  all checks pass (header tidy, centered search, chips even, panel neat).
* **Geometry pass (the "all off centered" complaint) — measured, not eyeballed:**
  bounding-box audit in Playwright at 1280 px and 390 px. After: search input center
  offset **0 px**, chips row **0 px**, statusline −5 px, gear's icon **0/0** in its circle
  (inline SVG, theme-colored via `currentColor`), settings panel anchored under the gear
  (right edges equal at 1196) with **all control left edges at one x (911)**, footer text
  box aligned to the content column, `overflowX: 0` at both widths, search row stacks
  centered on mobile. One axis, verified by numbers. The single-column system: header
  grid (title/gear, centered status row), search row `1fr auto 1fr` (the input's center
  IS the page's center; limit + code at its right end), settings as a label/control
  grid with section rules. Caught by the same audit: the gear's **svg child** broke the
  outside-click close (`target !== gear`) — `closest("#gear")` now; the panel-open
  geometry proved it (a collapsed 0×0 rect = the click had opened and re-closed it).

## 2026-11-02 — Dark theme made readable, in a real browser (Playwright is up)

* **The complaint ("The UI is way too dark. I cannot see anything for the dark theme") had a
  root cause found in the browser, not in the palette:** the big-look overlay `#big` set
  `display: flex`, which outranks the UA's `[hidden] { display: none }` — so a `position: fixed`
  layer at 78% black covered the whole page permanently, dimming everything under it and
  intercepting every click (Playwright: "div#big intercepts pointer events"). Fixed with
  `#big[hidden] { display: none }`; click → preview, Space big-look, Esc all verified live.
* **Palettes are now explicit per theme — no system colors, no OS dependence:** light/dark var
  blocks per `data-theme` (+ a `prefers-color-scheme` block for System), each setting its own
  `color-scheme`, so checkboxes, selects and scrollbars render *in* the theme;
  `accent-color` on the checkboxes. The text pairs are measured WCAG ratios, not eyeballed:
  on dark, text `#e8eaed` on `#202124` = 13.4:1, muted `#b7bbc1` = 8.4, accent `#8ab4f8` = 7.6,
  kind colors ≥ 6.4; on light, text `#1a1a1a` on white = 17.4, muted `#5f6368` = 5.9. Panels
  got surfaces (`--panel` + `--edge` borders) so structure stops dissolving — hairlines stay
  deliberately quiet (~1.8:1, they are separators, not text). Screenshot verdict from the
  vision model after the fix: 9/10 readable, both themes, results + preview + estimate.
* **The UI ships `cache-control: no-cache` (`UIFiles` in `api.py`):** measured in the browser —
  without it, Chrome answered reloads from its memory cache for minutes, serving a stylesheet
  the server no longer had, so a deploy never reached the page. Etag in, 304 out, revalidation
  is cheap. Pinned by a test.
* **`EngineRefused` — the engine's refusal is a 503, in its words:** the Stage-10 battery hit
  the searcher mid-transition right after a done job: the engine answers `{"ok":false,
  "error":…}` (`SearchService.swift:106,115`) and `api.py` crashed `KeyError: 'hits'` (500).
  Now `SearchService._checked` raises `EngineRefused` on any `ok:false` reply, the API answers
  503 with the engine's sentence, the job runner survives a refused post-job refresh (the job
  stays *done*, with a "searcher refresh deferred" note), and startup's prewarm is best-effort
  the same way. Proven by the API pair of tests — a refusing injected service, a stub refusal
  reply, no engine mocks; the proof battery gates on "searchable == files · encoder ready" and
  retries 503s, printing each refusal it met.
* Statusline: `index NaN KB` — app.js ran the engine's human string through `bytes()`; now it
  shows the engine's own words verbatim (`index 201 KB`).
* **Suite: 56 passed, 1 deselected in 192.51 s (EXIT=0)** — the 53 plus the 503 pair and the
  revalidation rule. Live proof: [stage-10-ui-parity.md](../docs/implementation/stage-10-ui-parity.md).

## 2026-11-02 — Stage 10 done: the web UI reaches desktop parity; corpus2 for live testing

* **UI parity (`server/ui/`, rewritten against `shell/ui/panel.js`):** keyword-first
  typing (words at once with `prefix_last`, `embed_ahead`, the `meaning:true` upgrade
  after 120 ms, generation + final-generation guards); strong/weaker fold; kind
  checkboxes → `kinds` (none ticked = all = the engine's default); `code:` prefix +
  code checkbox as one state; limit select (40 = the engine's default); grouped rows
  with lazy engine thumbnails; a preview pane for the selection (photo, video frame
  that plays *from* `#t=loc`, PDF page, audio at the moment, matched passage via
  `/text`) with facts + a plain-language reason built from the engine's own fields;
  arrows/↩/Space/Esc keyboard flow with the big look; Open + Download; Estimate panel
  (`POST /estimate`, the `calibrated` truth); activity dot; summary + keys footer.
* **Appearance (the theme ask):** System / Light / Dark select → `data-theme` + CSS
  variables, kept in `localStorage`; System tracks `prefers-color-scheme` exactly as
  the OS-following desktop does.
* **`GET /media/{id}/file` — the app's "Open" over HTTP:** server-issued handles only,
  roots-containment on the resolved path, media type from **magic bytes**, inline for
  media kinds, attachment + `text/plain` for code/doc (a source file named `index.html`
  never arrives as markup), `Accept-Ranges: bytes` with 206/416 — what makes
  `<video …#t=loc>` seek.
* **`/status` publishes the server's own roots** (env-configured paths, shown for the
  user; display, not path acceptance).
* **Settings mapping, honestly:** OS integrations (login, tray, shortcut, updates,
  index hours, folder pickers…) are deployment env config for a server; *reveal* and
  *copy file* are absent, not faked. Documented in README's parity table.
* **corpus2:** 60 Commons photos (20 subjects × 3), 1400 px renders pinned by sha256,
  out of git, `build.sh` fetches + verifies; the H.264 clip travels with it. The suite
  corpus stays 15 files (rankings normalize over that set).
* **Suite: 53 passed, 1 deselected in 190.18 s** (48 from Stages 3–8 + 5 Stage-10:
  the parity UI surface, `/file` 200/206/416/404 + magic types, roots in status).
  Live proof + UI sweep: [stage-10-ui-parity.md](../docs/implementation/stage-10-ui-parity.md).

## 2026-11-02 — Stage 8 done: persistence and reliability under load

* **Stop-at-the-safe-point**: `shutdown()` sends the engine's `stop` to the live writer;
  the walk ends **between files**, the job records *interrupted*, never success. Both
  stop-grace paths measured live in Compose: Docker's default 15 s lands mid-embed as
  **137 + replay recovery** ("server restart: job never finished" → next job resumes
  the walk to `done` — proven); with `stop_grace_period: 90s` (now in the Compose
  file) the lifespan finishes inside the grace: *interrupted* **with partial counts**,
  `Application shutdown complete`, exit 143. SQLite stays whole in both (WAL).
  `reload → prewarm` skipped on the stopping path.
* **Job log rotates at size** (`DIGUP_SERVER_JOB_LOG_SIZE`, default 1 MiB; chain
  `.1 … .N`, higher = older); replay reads **all** rotations oldest-first — history
  outlives any rotation, the `interrupted` rule included.
* **Backfill knob** env-driven (`DIGUP_SERVER_BACKFILL`, default on = engine
  `--backfill`; 0 = sync only) — reaches the runner and the engine argv.
* Resume proven at walk level: mid-job shutdown → interrupted (partial) → **next writer
  takes the flock, resumes (embedded files unchanged, SQLite kept whole), finishes**:
  `done`, index == the walk, `files_done ≥` the partial. Assertion pattern learned:
  compare the index to the **live folder count** (session scratch grows across tests) —
  engine truth, not a frozen constant.
* **Suite: 48 passed, 1 deselected in 181.86 s** (45 from Stages 3–7 + the 3 Stage-8
  tests: stop-mid-job-resume, rotation-with-history, env knobs). Doc:
  [stage-8-persistence.md](../docs/implementation/stage-8-persistence.md).

## 2026-11-02 — Stage 7 done: the shipping image + Compose, healthy and truthful

* `server-runtime` image (`digup-server:local`, **562 MB**): engine payload + API + UI on
  `python:3.12-slim`, **no toolchain/desktop stack**, non-root (`uid 990`), `tini` PID 1 —
  chain proven live: `tini → uvicorn → digup` (helper's parent is uvicorn, ParentWatch's
  condition met). HEALTHCHECK = the API's own `/health`; Compose (`deploy/`, `name:
  digup-server` — isolated project, never `--remove-orphans`) publishes
  `127.0.0.1:8787`; all state on bind-mounted volumes. Build runs the §3 acceptance check
  (`digup --help` headless in the final image) + API imports.
* **SIGTERM contract (measured, honest):** stop takes 1–2 s; the log shows the full
  graceful lifespan (`Application shutdown complete`); recorded exit code **143** =
  completed SIGTERM. CI asserts exit **≠ 137** (137 = SIGKILL = hung shutdown) **and**
  the shutdown-complete line — replacing the wrong `= 0` assertion.
* **Startup prewarm** (finding-driven): lifespan runs the engine's `prewarm` op; fresh
  container answers `encoder ready · vectors 74` at 14 s, first search `embed 548 ms`
  (was: vectors 0, 4 257 ms). `DIGUP_SERVER_PREWARM=0` skips it.
* **The prune knob + root-scope rules** (finding-driven): ghost rows = an index folder
  shared across two root layouts; rows outside the current roots count in
  files/vectors and **dilute z** (3 strong answered as 1). `POST /index {"prune":true}`
  (UI "prune missing") → engine `--prune` → files 30→15, vectors 74→37 in 0.1 s.
  Tested truths: plain sync retires walked-root ghosts; out-of-scope ghosts survive
  plain sync, retire under prune; the job record persists the prune flag across
  restarts. Operational rule (README + Compose header): an index folder belongs to
  **one root layout** — suite/dev use `index-suite` (fresh 15-file index, 2 min build),
  Compose uses `index`.
* **Suite: 45 passed, 1 deselected in 215.60 s** (22 contract + 10 API incl. prewarm +
  6 jobs incl. the two ghost-row tests + 7 UI/media). Compose live proof on the final
  image: prune job persists `prune: True` across a restart; post-restart status
  `encoder ready · vectors 37 · files 15`. Doc:
  [stage-7-runtime-image.md](../docs/implementation/stage-7-runtime-image.md).

## 2026-11-02 — Stage 6 done: the web UI, vanilla and same-origin

* `server/ui/` (HTML/CSS/JS, no build step, no dependencies, no external URLs — a tested
  property): debounced typing → `POST /search` + `embed_ahead` warm-up; hits with kind
  badges, engine `z`, `at m:ss` moments from `loc`, real `ms`; the honest empty shown as
  the engine's refusal; preview/text via **server-issued `media_id` handles only** (never
  client paths, symlink-safe, 404 for unissued ids); Index-now with 409/busy polling and
  the engine's counts; 15 s status strip. Served by the API at `/` (same origin → no CORS).
* `api.py` additions: `media_id` on hits (bounded `HitCache`), `GET /media/{id}/preview`
  (engine `render` JPEGs from `<index>/previews` only), `GET /media/{id}/text`,
  `POST /embed_ahead`, `StaticFiles` mount.
* **Suite: 42 passed, 1 deselected in 107.87 s** (22+9+4+7). Live: UI served at `/`,
  photo preview 13 KB JPEG, video frame at the engine's 9.5 s moment, 404 on an unissued
  id. Doc: [stage-6-ui.md](../docs/implementation/stage-6-ui.md).

## 2026-11-02 — Stage 5 done: index jobs, one writer, honest states

* Job runner (`server/digup_server/jobs.py`): serialized worker + the adapter's flock;
  `POST /api/v1/index` 202s a job / 409s while one runs (names it); append-only job log
  (`jobs.jsonl`), a `running` line with no ending recovers as **interrupted** — never
  success (README §5); counts from the engine's events (`file` dones + `idle` totals);
  after `done`: `reload → prewarm`, wired in the lifespan. The active marker clears when
  the writer releases the lock, before `done` publishes — no done-409 window (the suite
  caught the inverse order in one run; fixed in the adapter).
* **Suite: 35 passed, 1 deselected in 128.69 s** (22 contract + 9 API + 4 job tests,
  real engine, no mocks). Live check: 202 queued → 409 busy → `done` with `files 15 /
  searchable 15 / pending 0 / vectors 37` → searcher `ready` with 37 vectors. Doc:
  [stage-5-jobs.md](../docs/implementation/stage-5-jobs.md).

## 2026-11-02 — Stage 4 done: the API on `/api/v1`, live and localhost-bound

* FastAPI app (`server/digup_server/api.py`) **on top of the adapter**: `GET /health`
  (engine identity: fingerprints, llama.cpp build tag, vectors version, live counts),
  `GET /status` (+ the CLI's kind table), `POST /search` (hits verbatim, `strong`,
  `meaning`, `ms`; protocol `id` stays inside; honest empties published),
  `POST /estimate` (`estimate --json` — usable because the API is a live parent, not PID 1).
  uvicorn `--factory`, bound `127.0.0.1:8787` by default; `docker run --init` gives the
  helpers a parent they accept (ParentWatch); engine failures map 503/504/502 quoting the
  engine; 422s where the engine would silently drop input. `.env.example` documents every
  setting.
* **Suite: 31 passed, 1 deselected in 92.10 s** (22 contract + 9 API tests, real engine,
  no mocks). Live check: the wakeboarding top-3, `strong 3`, `ms {embed 1554, search 8}`
  over HTTP; encoder `ready` after first query, 37 vectors, kinds 12/3; empty honest
  answer and 422 verified from the host loopback. Doc:
  [stage-4-api.md](../docs/implementation/stage-4-api.md).

## 2026-11-02 — Stage 3 done: adapter + contract tests, green

* **Suite: 22 passed, 1 deselected in 88.75 s** in `digup-server-test:local` (the shipped
  engine payload + `python:3.12-slim` + uv) against the real engine, corpus, model and
  index — no mocks; the suite self-skips without them. `pytest -m slow` (the
  `speed --model --json` timing) passes separately. Full doc:
  [stage-3-adapter.md](../docs/implementation/stage-3-adapter.md).
* Adapter in `server/digup_server/engine/`: `config.py`, `protocol.py` (JSON-lines
  supervision: replies by `id`, event queue, engine-exit semantics, `ParentWatch` respected —
  helpers are spawned directly, the supervisor is the long-lived parent), `search.py`
  (all documented ops; idle-exit = transparent restart, last `folders` change replayed),
  `index.py` (plain-line commands, event stream, single writer by `flock` on
  `<index>/.digup-server.writer.lock` — second writer gets `IndexBusy`, tested),
  `cli.py` (`status` parsed, `estimate --json` + plain, `speed --model --json`).
* uv project (`pyproject.toml` + `uv.lock`), Python 3.12, stdlib-only adapter.
* Contract tests pin, against the live engine: hit fields verbatim, honest "no good
  matches", kind filter, render → JPEG under `<index>/previews`, summaries counts, idle
  restart (encoder-idle 2 → engine self-exit → transparent respawn), sync/file/summary
  events + `idle` totals (post-index truth rides `idle`, not the transient mid-stream
  syncs), missing-root-is-reported-not-fatal, `text` of a hit's segment,
  sync → `reload` → `prewarm` → new vectors searchable, `estimate --json` answers for the
  server as parent (Stage 2's "silence" was ParentWatch's PID-1 rule — corrected finding,
  reconnaissance §15 item 8).
* CI added: `.github/workflows/server.yml` (builder incl. `swift test` → runtime CLI check
  → corpus + pinned model download → contract suite → Stage-2 proof → proof logs).

## 2026-11-02 — Stage 2 done: headless proof on Linux, CPU-only

Index 15 files / 37 vectors / 4 min; `wakeboarding`/`hiking`/campfire/… rank exactly,
video timestamps to the second (`[at 0:09]`); eval R@1 0.71, R@5 0.88 over 17 queries; the
engine's "no good matches" kept as an honest empty. Full run:
[stage-2-headless-proof.md](../docs/implementation/stage-2-headless-proof.md).

## 2026-11-02 — Stage 1 done: the engine builds and tests on Linux

`swift build -c release` + `swift test` (116 + 7 tests, 0 failures) in a multi-stage Docker
build (Swift 6.4.0 GPG-verified; llama.cpp b11461 CPU; pinned vendor); 296 MB runtime image
running `digup` with no toolchain, no desktop stack. Model files verified against
`ModelFiles.swift` pins. Details: [stage-1-linux-build.md](../docs/implementation/stage-1-linux-build.md).

## Open issues

1. **Supervision rule (from Stage 2's corrected finding, reconnaissance §15 item 8):**
   ParentWatch helpers (`index-service`, `worker`, `search-service`, `estimate --json`)
   exit within a second when their parent is PID 1. The server must be the long-lived
   parent and spawn helpers directly (`protocol.py` enforces); a PID-1 `bash -c` wrapper
   is not a parent. `estimate --json` works from the server and is pinned in
   `server/tests/test_cli.py`. Stage 4 must keep uvicorn as that parent.
2. ~~`search-service` idle-exit restart restart-wiring + `reload → prewarm`~~ — done:
   after a done job the runner does `reload → prewarm`, and the lifespan prewarms at
   startup (`DIGUP_SERVER_PREWARM`); both pinned by tests (Stage 5/7).
3. Preview exposure policy: the API will read `<index>/previews` itself, never serve the
   path (Stage 4/6).
4. GPU path (Stage 9) on the x86_64 server: Vulkan build + `digup speed --model` measurement
   with the agreement check — built and measured only where the GPU is.
5. Prod host: the x86_64 image is built natively on the production server (README §11);
   CI (`.github/workflows/server.yml`) exists and runs the same stages on `ubuntu-24.04` —
   its first green run on GitHub is the remaining proof.
6. Cosmetic, dev-only: starlette's TestClient warns that `httpx` is superseded by
   `httpx2` for in-process ASGI testing (the one pytest warning in the suite). Migrate
   the dev group when `httpx2` ships; tests pass today.
7. Visual browser pass of the UI not yet run (no Chrome on this host for the automation
   tool): the UI is proven by 7 DOM/HTTP tests + `node --check` + a curl transcript. A
   human pass in Safari/Chrome on this machine is the remaining check (Stage 11 polish).
8. **Ranking reference: confirmed current-pipeline, with a measured drift pattern.**
   Suite 12–15 (fresh 15-file `/corpus`-scoped index, built with the engine CLI)
   reproduce the Stage-2 wakeboarding top-3 and the full search contract — the frozen
   rankings are the current pipeline's truth *for a CLI-built index*. The drift,
   reproduced on every fresh Compose-side index (four builds): the same 15 files
   indexed by the **server's own job** (`index-service`, backfill on) answer
   `wakeboarding` with aarhus-04 at z ≈ 0.47 (suite-index value: 1.57), vienna 1.59,
   logan 1.58 — search stays strong 3, order of the weak one differs. Same bytes, same
   binary payload: the likely cause is CPU embedding non-determinism across process
   shapes (long-lived service vs one-shot CLI). Stage 9 (GPU on the prod box) is where
   this gets measured properly (`speed --model`, repeated embeds, backend choice) —
   the server quotes the engine's ranking either way; nothing server-side "fixes"
   z, and nothing should.

## What runs today, exactly

```
digup-engine:local      runs `digup` headlessly (arm64, CPU)        — image, 296 MB
server/tests/proof.sh   index + search + eval, the engine's words   — Stage 2 evidence,
                        re-run green 2026-11-02 (EXIT=0, R@1 0.71 / R@5 0.88)
digup-server-test:local adapter + contract + API + job + UI tests    — 57 passed / 236.12 s
                         (dedicated suite index, prewarm, prune pair,   — Stages 3–8 + 10,
                          stop-mid-job-resume, rotation, env knobs,       green
                          /file 200·206·416·404, roots, UI parity surface,
                          refusal 503 pair, UI no-cache revalidation,
                          MP4 sniffed by ftyp)
digup-server:local      runtime image: payload+API+UI, tini, non-root — Stage 7, rebuilt
digup-server-server-1   compose up (healthy), 127.0.0.1:8787, real    — Stages 7–8 + 10:
                         data volumes, UI+API, stop_grace_period: 90s,   prewarm, prune,
                         mid-job stop measured: 143+partial · 8+7=15,    137+replay+resume
                         corpus2 gallery (61 files) indexed and served
```
