# DigUp server

A self-hosted search server over the **original DigUp engine** — the Swift `digup` binary
speaking its own published JSON-lines protocols. The engine is DigUp's (`Sources/**`,
untouched); this folder is a thin, additive wrapper. The binding rules, the staged plan and
the current results are in [`../docs/implementation/`](../docs/implementation/README.md).

## Layout

| path | what it is |
|---|---|
| `digup_server/engine/` | the adapter: config, JSON-lines supervision, `search-service` + `index-service` clients, the read-only CLI calls |
| `digup_server/api.py` | the FastAPI app on `/api/v1` (`health`, `status`, `search`, `estimate`, `index`, `jobs`) — on top of the adapter, never around it; localhost by default |
| `docs/API.md` | **the API reference** — schemas, media identifiers, limits and pagination, errors, curl examples, versioning and security: the compatibility promise clients code against (`tests/test_api_docs.py` fails if an endpoint is not in it) |
| `digup_server/jobs.py` | the index-job runner: one writer (adapter flock), `queued/running/done/interrupted/busy`, append-only job log **rotated at size** (history replays from all rotations), stop-at-safe-point on shutdown, `reload → prewarm` after a done job |
| `ui/` | the web app: vanilla HTML/CSS/JS (no build step), served same-origin at `/`, `fetch()` to `/api/v1` only |
| `.env.example` | every setting as an environment variable (index, roots, models, excludes, bind) — no secrets, no client-chosen paths |
| `docker/Dockerfile` | multi-stage build: `engine-builder → engine-payload → engine-runtime` (+ `server-test`), one per architecture |
| `tests/corpus/` | the pinned, attributed test corpus (Commons photos committed; videos + clip fetched/built by `build.sh`) |
| `tests/proof.sh` | the Stage-2 headless proof: index + search + eval, the engine's own words |
| `tests/test_*_contract.py`, `tests/test_api.py` | contract tests against the real CLI in the container — no mocks, ever |
| `pyproject.toml` + `uv.lock` | uv project (the repo's convention from `worker/`); Python 3.12 |

## Running the contract tests

Build the test image (arm64 on this Mac, x86_64 on the server — never under emulation),
mount the corpus, models and an index folder, and run pytest inside it:

```sh
DOCKER_BUILDKIT=1 docker build --platform linux/arm64 --target server-test \
  -f server/docker/Dockerfile -t digup-server-test:local .

docker run --rm --platform linux/arm64 \
  -v "$PWD/server/tests/corpus/media:/corpus:ro" \
  -v "$PWD/server/tests/corpus:/corpus-root:ro" \
  -v "$HOME/Projects/digup-data/models:/models:ro" \
  -v "$HOME/Projects/digup-data/index-suite:/index" \
  digup-server-test:local
# Add `-rs` after the image name (with an explicit command, `… digup-server-test:local
# /srv/server/.venv/bin/pytest -rs`) to see WHY anything skips.
```

The suite skips itself when `DIGUP_SERVER_CORPUS` / `DIGUP_SERVER_MODELS` / `digup` are
absent — there is no mock path. `-m slow` runs **only** the slow marker's test (the
`speed --model` timing, several minutes) — plain `uv run pytest` already includes it;
CI deselects it (`-m "not slow"`) to keep the run under its ceiling.

The test image's ENTRYPOINT is `tini` for a real reason: the suite's app spawns
`search-service` as a child of the test process, and ParentWatch ends a helper whose parent
is PID 1 (it means "the app is gone"). Run the image bare and pytest IS PID 1 — every helper
dies at once, `exit 0`, no stderr (measured, this project's own suite did it). tini as PID 1
makes the test process a live parent, the production shape, so no `--init` flag is needed.

An index folder belongs to **one root layout** (rows carry the absolute paths they were
crawled from): the suite/dev roots (`/corpus`) get `index-suite`, the Compose roots
(`/media/photos`) get `index`. Sharing one index folder across two root scopes makes
ghost rows — see the root-scope note under "Running the server (Compose)". Build a
fresh suite index with `digup index /corpus --index <folder>` (engine container, ~2 min
CPU for the 15-file corpus).

## Running the API (dev)

The API is `digup_server.api` on `/api/v1`: `GET /health`, `GET /status`,
`POST /search`, `POST /estimate`, `POST /index`, `GET /jobs`, `GET /jobs/{id}`, and the
media endpoints `GET /media/{id}/preview|/text|/file` (Stage 6/10: **server-issued
`media_id` handles only**, never client paths; `/file` serves the real bytes — magic-bytes
type, `Accept-Ranges`/206 so `<video>` seeking works, inline for media kinds, attachment
`text/plain` for code/docs) — config from [`.env.example`](.env.example); binds
`127.0.0.1:8787` by default.

```sh
docker run --rm --init --platform linux/arm64 \
  -p 127.0.0.1:8787:8787 \
  -v "$PWD/server/tests/corpus/media:/corpus:ro" \
  -v "$HOME/Projects/digup-data/models:/models:ro" \
  -v "$HOME/Projects/digup-data/index-suite:/index" \
  -e DIGUP_SERVER_INDEX=/index -e DIGUP_SERVER_ROOTS=/corpus -e DIGUP_SERVER_MODELS=/models \
  -e DIGUP_SERVER_CONFIG=/index/server-config \
  digup-server-test:local uv run uvicorn --factory digup_server.api:app_factory \
    --host 0.0.0.0 --port 8787
```

Then open `http://127.0.0.1:8787/` (the UI, served by the API) or go direct:
`curl http://127.0.0.1:8787/api/v1/health` and
`curl -X POST http://127.0.0.1:8787/api/v1/search -H 'content-type: application/json' -d '{"q":"wakeboarding"}'`.

The `--init` is not cosmetic: `estimate --json` / `search-service` / `index-service` are
ParentWatch helpers that exit the moment their parent is PID 1 ("the app is gone",
reconnaissance §15 item 8). `docker run --init` (and `tini` in the runtime image, Stage 7)
gives uvicorn a non-PID-1 parent, so the API *is* a parent the helpers accept, and a
stopped API takes its helpers with it. Inside the container uvicorn binds `0.0.0.0`
because the publish line (`127.0.0.1:8787:8787`) is what enforces localhost-only (§7).

## Running the server (Compose)

The shipping shape (`deploy/docker-compose.yml`, CPU-only base; the GPU override arrives at
Stage 9 for the box that has the card — README §11):

```sh
cd deploy
# A fresh host needs the bind folders to exist AND to be writable by uid 990 (the image's
# user). Docker would create them as root on the first up, and the server then crashes on
# a locked index (EACCES) — measured. On macOS Docker Desktop maps this transparently;
# on a real Linux host, do it plainly:
mkdir -p "$HOME/Projects/digup-data/"{index,models,config} && sudo chown -R 990:990 "$HOME/Projects/digup-data"
DIGUP_INDEX_DIR="$HOME/Projects/digup-data/index" \
DIGUP_MODELS_DIR="$HOME/Projects/digup-data/models" \
DIGUP_MEDIA_DIR="$HOME/Projects/digup-data/media/photos" \
docker compose up -d --build
# → open http://127.0.0.1:8787/  (UI + /api/v1), index with "Index now"
# The first searches wait on the startup prewarm (~20–30 s of model load); /health answers
# 503 until the searcher is up — the container is healthy, the API is honest.
```

The runtime image is `server-runtime`: engine payload + API + UI, `tini` as PID 1 (the
ParentWatch chain: helpers' parent is uvicorn, never PID 1), non-root (`uid 990`), a
HEALTHCHECK that asks the API's own `/health`. SIGTERM (even mid-job): the runner sends
the engine's `stop` — the writer ends between files. Two truthful paths, both measured:
with the Compose `stop_grace_period: 90s` the lifespan finishes inside the grace — the
job records *interrupted* **with its partial counts**, exit 143,
`Application shutdown complete` in the log; a shorter grace (Docker's default 10–15 s)
ends mid-embed as 137 SIGKILL, and the log replays the job as *interrupted* at the next
boot — never success. SQLite stays whole; the next job resumes the walk. CI asserts the
idle contract (exit ≠ 137 + shutdown-complete). Index/model/config/job-log live in
bind-mounted volumes — container
recreation never destroys them (§5). On Linux hosts, `chown -R 990` the bind folders so
the image's user can write them. `restart: unless-stopped` brings the stack back with the
daemon (a reboot, an upgrade) and stays down after a manual `docker stop`. The published
port is `127.0.0.1:8787:8787` — localhost-only — and `DIGUP_PUBLISH_PORT=…` moves the host
side when 8787 is taken (the container keeps binding 8787). The Compose project has an
explicit `name:` (`digup-server`)
so this stack never entangles with other stacks living in the same folder name.

One engine semantic the compose proof pinned, worth knowing: **index rows carry the
absolute paths of the roots they were built from, and the searcher answers only for
files under the roots it was started with**. Mounting the same folder under a new path
(`/media/photos` vs a dev `/corpus`) is a *root change*: search returns thin answers
until one `Index now` re-scopes the index. What happens to the rows: a plain sync
walks the *current* roots and retires rows for files missing **inside them** — rows
whose paths lie **outside** the current roots (the old scope) keep counting in
`files`/`vectors` and **dilute the z-normalization of live hits** (a 15-file index
with 15 ghost rows answered 3 strong matches as 1). The cure is the job's `prune`
knob (`POST /index {"prune": true}`, the "prune missing" checkbox in the UI — the
engine's own `--prune`): it retires every row for a file not found under the current
roots, ghost rows included. One job, honest counts, and the ranking is back to the
engine's own numbers. Both behaviors are pinned by tests in `test_jobs.py`.

## The web app (desktop parity, Stage 10)

`server/ui/` is a browser client of the published API — vanilla HTML/CSS/JS, no build step,
no external URLs (pinned by test) — with the desktop panel's behavior (`shell/ui/panel.js`
is the reference, `Sources/DigUpApp/SearchPanel.swift` the Mac one):

| Desktop (shell / Mac app) | Web UI | How |
| --- | --- | --- |
| keyword-first typing: words at once (last word as prefix), meaning after 120 ms | same | `POST /search` `meaning:false, prefix_last:true`, `POST /embed_ahead`, then the `meaning:true` upgrade; generation guards, like panel.js |
| strong vs weaker results, folded | same | `strong` hits grouped by kind; "N weaker matches" row, click/↩/Space unfolds |
| kind filters (the window's checkboxes) | same | the kind-chip row under the search (theme-colored, filled when ticked) → `kinds: [...]` (none ticked = all = the engine's default) |
| `code:` search | same | the `code:` prefix (and a code checkbox, one state) → `code: true` |
| limit (the window's row count) | same | the limit select at the right end of the search bar → `limit` (default 40, the engine's own) |
| arrow keys, ↩ opens, Space = big look, Esc | same | ↑↓ follow the top pick until you navigate; ↩ opens the pick; Space the big look; Esc puts it away |
| preview pane: photo, frame at the moment (click plays *from* it), PDF page, heard words, matched passage | same | `GET /media/{id}/preview` (the engine's `render`, JPEG) + `/text` + `<video src=/media/{id}/file#t=loc>` |
| Open (the file itself; `placeToOpen` for video) | same | `GET /media/{id}/file` — inline media opens in the browser (H.264/AAC mp4-mov, webm, plain audio seek at `#t=` via Range); formats a browser can't stream keep the frame + words and open in the user's player; Download = attachment |
| footer: summary + keys line | same | "N results · M weaker", "Matching words…", "Words only: …", the helper's own error quoted; keys line under the results |
| activity badge ("Indexing 42%", encoder warming) | same | encoder/job state from `/status` + the polled job's counts |
| onboarding estimate (the folders' cost) | same | `POST /estimate` → per-folder forecast with kind counts, PDF pages, audio/video durations, the `calibrated` truth, top subfolders — the button lives in the settings panel, the honest note is one line |
| appearance (the desktop follows the OS) | **choice: System / Light / Dark** | a server has no OS to follow; a select in the settings panel (the gear), `data-theme` + CSS variables, kept in `localStorage` |
| roots shown (Settings → Folders) | shown | `GET /status` publishes the server's own configured roots (env-configured; the settings panel prints them with the engine's counts) — display, not path acceptance (§7) |

*Settings that don't apply, honestly:* login item, tray, global shortcut, window centering,
auto-updates, index hours, folder pickers, pause-indexing, the code editor, licenses — these
are OS/desktop concerns (a container has a deployment, not a desktop). Their server
equivalents are **deployment configuration**: roots, exclusions, model folder, prewarm,
backfill, rotation — the env knobs of [`.env.example`](.env.example) and Compose, with
"Index now"/"prune missing" in the UI as the manual index control. Two desktop behaviors
have no browser twin and are absent, not faked: *Show in Finder/Explorer* (reveal) and
*Copy file* — a browser page opening a file in the OS is a native-app privilege.

**Testing images (corpus2):** the suite's corpus is frozen at 15 files (its rankings
normalize over exactly that set), so a second corpus of **60 Commons photos** —
`server/tests/corpus2/`, pinned by sha256, fetched by its `build.sh`, out of git — is the
material for live runs: mount it (`DIGUP_MEDIA_DIR`, README's corpus2 note) and the UI has a
real gallery to search, preview, and open. See
[tests/corpus2/README.md](tests/corpus2/README.md).

Expect **fewer strong hits per query than a real library**: 61 files is a small gallery, and
the engine publishes a hit only when it clears its own z-gate of 2.0 sigma over the indexed
set (`Searcher.swift`'s `zGate`, identical on every platform: Mac app, shell, server). On a
personal library of thousands of files the same engine answers many more ≥2σ matches — the
server adds no cap of its own and the UI shows the engine's counts verbatim, so a 1-hit
answer on corpus2 is the corpus' size, not a filter, a limit, or a bug.

## Merging and tracking upstream

This directory is built to be a **clean additive PR** to [ARahim3/DigUp](https://github.com/ARahim3/DigUp):

* **Files it touches:** only additions — `server/`, `deploy/`, `docs/implementation/`,
  `.github/workflows/server.yml`, `.dockerignore`, and append-only lines in
  `.gitignore`. No upstream file's existing content is rewritten, so the PR cannot
  conflict with engine, shell, website, or CI work.
* **The engine is never linked, patched, or replaced.** The server speaks the published
  interfaces only: the `digup` CLI usage, the JSON-lines protocols
  (`search-service`, `index-service`, `worker`), and the `status`/`estimate` output.
  Refactors inside `Sources/` are invisible to the server as long as those interfaces
  hold. The builder stage uses the repository's **own** `scripts/fetch-vendor.sh`,
  `build-llama.sh`, `build-ffmpeg.sh` — upstream version bumps flow into the image
  with zero server-side edits.
* **The contract suite is the tripwire.** CI (`.github/workflows/server.yml`) runs on
  PRs touching `Sources/**`, `Package.swift`, `scripts/**`, and `server/**`, so a
  protocol rename, a field drop, or a CLI change shows up as failed tests quoting the
  engine's own output — a loud CI red, not a silent runtime drift. 75 tests (76 collected,
  CI deselects the slow model-timing test) pin every reply field, event, and exit path the
  server uses — and **any SKIPPED line is red in CI**, because a suite that skips itself
  (missing corpus, models, or clip) is green by construction, which is the opposite of a
  tripwire.
* **The pins to bump with upstream** (the complete list): `ARG SWIFT_VERSION` in
  `server/docker/Dockerfile` (Swift toolchain), and the model sha/revision in
  `server.yml`'s download step — the *drift-guard* step compares those against
  `ModelFiles.swift`'s own `sha256:` constants, so a model bump upstream fails CI
  until the pins match. llama.cpp, PDFium, and ffmpeg pins ride upstream scripts.
* **State lives outside the image, protocol outside the repo, versions inside both:**
  `/api/v1` is versioned, the UI is dependency-free, and index/models/config/job-log
  are bind-mounted volumes. Upgrades are `docker compose up -d --build` on the new
  commit: recreation never destroys state, and the job log's `interrupted` rule makes
  an upgrade during indexing honest.

## Status

[IMPLEMENTATION_STATUS.md](IMPLEMENTATION_STATUS.md) — what runs, what's proven, what's open.
Stages 3–8, 10, and the Stage-11 review round are **done: 75 tests green** (76 collected,
1 slow deselected, **zero skipped**, 235.15 s on the final tree — reproduced 228.12 s two
runs earlier) in the container against the shipped engine
payload (17 search-contract + 19 API + 6 index-contract + 13 job/persistence + 17 UI/media
+ 4 CLI), and the shipping
shape runs live: `docker compose up -d` in `deploy/` boots `digup-server:local` (engine + API
+ UI, tini, non-root, healthy via its own `healthcheck.py`) on `http://127.0.0.1:8787/` with the desktop panel's behavior
in the web UI (keyword-first typing, filters, code mode, preview pane, Open at the video's
moment, Estimate, System/Light/Dark — the dark palette measured for WCAG contrast and the
whole flow driven through a real browser, Playwright, in both themes — Space, Esc, focus,
aria, the big look, the job line, the estimate, all verified on the live stack), prewarm, index jobs,
prune, `stop_grace_period: 90s`,
and a mid-job stop measured both ways — graceful *interrupted* with partial counts
(8 + 7 = 15 resumed exactly), and SIGKILL recovered by replay to resume. The parity probe —
the app's own adapter (`SearchService`) on a snapshot of the live index answering the same
queries with the same hits, strong counts and z-scores as the HTTP API — is in
[docs/implementation/stage-11-review-round.md](../docs/implementation/stage-11-review-round.md).
The GPU override
(Stage 9, on the prod box) comes next.
