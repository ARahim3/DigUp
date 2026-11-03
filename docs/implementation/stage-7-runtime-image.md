# Stage 7 — the shipping image: engine payload + API + UI, tini, non-root, healthy

Date: 2026-11-02. `docker compose up -d --build` → `http://127.0.0.1:8787/` — UI, API,
engine, all in one container, CPU-only. Rules:
[README.md](README.md) §3 (mandatory multi-stage shape, no Swift in runtime, verify the
CLI in the final image), §5 (volumes), §7 (localhost publish), §11 (per-architecture,
built natively).

## The `server-runtime` stage (`server/docker/Dockerfile`)

Base `python:3.12-slim` — measured in the built image: Debian 13 (trixie), glibc
2.41-12+deb13u4. The payload is compiled on Ubuntu 22.04 (glibc 2.35), so the image runs
**newer** glibc than the payload was built against: forward, never back — a binary linked
against 2.35 starts on 2.41, the reverse is what fails. The image carries only:
the engine payload (`/opt/digup`: `digup`, llama.cpp `.so`s,
`ffmpeg`/`ffprobe`, `libpdfium`, rpath `$ORIGIN` — verified by running `digup --help`
during the build, §3's acceptance rule), the runtime libs (`libcurl4 libgomp1
tzdata ca-certificates`), `tini`, `uv` + the `uv sync --frozen --no-dev` environment
(fastapi/uvicorn only — pytest/httpx stay in the test stage), the server code and UI.
**No Swift toolchain, no compiler, no dev deps, no Tauri, no desktop stack.**

The supervision chain (§15 item 8, in PID form):

```
PID 1  tini            → forwards SIGTERM to its child; reaps
 └─ uvicorn (API)      → parent of every helper — ParentWatch's condition, met
     ├─ search-service → its parent is uvicorn (≠ PID 1): accepted, watched
     └─ index-service  → same; when uvicorn dies, helpers reparent to PID 1 and end
```

* **Non-root**: `uid 990 digup`, the same engine user as the engine-runtime stage.
  `/data/{index,models,config}` exist owned by it; bind mounts supply the data. There is
  no `locks/` folder: the single-writer lock is a file beside the index
  (`<index>/.digup-server.writer.lock`, `engine/index.py`).
* **SIGTERM handling** (the §3 rule "the API process owns its child processes"):
  `docker stop` → tini forwards SIGTERM → uvicorn lifespan shutdown →
  `runner.shutdown()` (a running job is logged **interrupted**, never success) →
  `service.quit()`. Measured: the stop takes **1 s** and the log shows the full
  graceful sequence (`Shutting down → Waiting for application shutdown → Application
  shutdown complete`). The container's recorded exit code is **143 — a completed
  SIGTERM stop** (the signal that ended the PID-1 tree; the lifespan ran inside it).
  The honest contract, asserted in CI: exit code **≠ 137** (137 would mean SIGKILL —
  the shutdown hung and got killed) **and** `Application shutdown complete` present
  in the log. A job in flight at that moment is logged *interrupted*.
* **Startup prewarm** (finding-driven from the compose proof): a freshly booted
  searcher answers the first search cold — the embed pays the ~4 s model load and
  `status.vectors` reports 0. The lifespan now runs the engine's `prewarm` op right
  after spawning the searcher (`DIGUP_SERVER_PREWARM=0` skips it for dev restarts),
  so a booted container answers the first search with real z-scores, and `vectors`
  is truthful from the first `GET /status`. HEALTHCHECK's `start-period=40s` covers
  the model load. Pinned by a test (`test_startup_prewarms_the_searcher`).
* **The prune knob** (finding-driven, README's root-scope note): index rows carry the
  absolute paths of the roots they were crawled from, and rows of files that vanish
  from the roots keep counting in `files`/`vectors` — ghost rows dilute the engine's
  z-normalization, so live hits answer thin (a 15-file index with 15 ghost rows
  showed 3 strong matches as 1). `POST /index {"prune": true}` (UI checkbox "prune
  missing") passes the engine's own `--prune` through the job (`IndexService`); plain
  syncs never delete rows. Pinned by a test that grows the scratch index, deletes
  the file, shows the ghost row survives a plain sync, and retires under prune.
* **HEALTHCHECK** asks the API's own `/health` through the image's
  `server/docker/healthcheck.py` (`urllib`, no curl in the image): a healthy container is
  one whose engine answers. **503 counts as alive** — `/health` answers 503 while the
  searcher is respawning (the engine's own refusal), which is the server truthfully
  saying "not right now", not a sick container; Docker must not restart a live server
  over a respawn. The script catches `HTTPError` for exactly that (urlopen raises on
  503); every other answer — 4xx/5xx, refused connection, timeout — is exit 1. The
  build proves the script by asserting it exits non-zero with nothing listening, and
  CI proves it by polling the live server with it (`docker exec … healthcheck.py`).
* Port published `127.0.0.1:8787:8787` in Compose — localhost-only (§7);
  `DIGUP_PUBLISH_PORT` moves the host side when 8787 is taken. `restart: unless-stopped`
  brings the stack back with the daemon (a reboot, an upgrade) and stays down after a
  manual `docker stop`. Inside, the API binds `0.0.0.0` (container boundary = the
  isolation); the container's own binding is the CMD's `--host/--port`, not an env —
  `DIGUP_SERVER_HOST/PORT` feed `python -m digup_server.api`, the bare-metal entry.
* Config: the `server-runtime` ENV defaults are README §5's layout (`/data/index`,
  `/media/photos`, `/data/models`, `/data/config`); media roots and host folders come
  from Compose env, all documented in `server/.env.example`.

## Compose (`deploy/docker-compose.yml`)

One service, context = repo root, `target: server-runtime`, image `digup-server:local`.
Volumes bind-mounted from `DIGUP_INDEX_DIR / DIGUP_MODELS_DIR / DIGUP_CONFIG_DIR /
DIGUP_MEDIA_DIR` (defaults `deploy/data/…`, git-ignored): index/models/config writable,
media `:ro` — originals are never modified, container recreation never destroys state.
The GPU override (`docker-compose.nvidia.yml`) arrives at Stage 9, built and measured on
the box that has the card — §11. On Linux hosts the bind folders must be owned by
`uid 990`; documented in the Compose file header.

## Proof

2026-11-02, native arm64 build on the dev machine (the prod x86_64 build is the same
Dockerfile on the prod box, §11).

**Image**: `digup-server:local` — **562 MB**, built EXIT=0. The build itself runs the
§3 acceptance check (`digup --help` headless in the final image) and imports
`fastapi, uvicorn, digup_server.api` before naming the image.

**Compose up** (`name: digup-server`, isolated — no orphan entanglement with other
stacks; the earlier collision was answered by the explicit project name, never
`--remove-orphans`):

```
Container digup-server-server-1  Started
digup-server-server-1 · Up 14 seconds (healthy)     ← the image's own HEALTHCHECK
```

**Supervision chain, visible from `/proc` inside the container** (pid ppid comm):

```
1  0   tini        ← PID 1: forwards SIGTERM, reaps
7  1   uvicorn     ← parent of every helper — ParentWatch's condition, met
8  7   digup       ← search-service: its parent is uvicorn (≠ 1), so it is accepted
```

`whoami` → `digup` (uid 990, non-root).

**API over the real data volumes** (models + index + config bind mounts):

```
GET  /api/v1/health  → ok true · llama.cpp b11461
GET  /               → <title>DigUp — semantic media search</title>
POST /api/v1/index   → job 7aef6ffa1733 queued → done 15/15 files · 37 vectors · 144.3 s
                       (15 files under the new /media/photos roots, real CPU embeddings)
POST /index {prune}  → job 3b5f1be20ef7 done 0.1 s · files 30→15 · vectors 74→37
```

**Startup prewarm (finding-driven fix, proven live):** a fresh container 14 s after
boot answers `encoder ready · vectors 74` — vectors opened at startup, not lazily.
The first search pays `embed 548 ms`, not the 4 257 ms of the pre-fix cold start.

**SIGTERM contract (the honest version after the probe):** `docker stop --time 15`
takes **1–2 s**, the log shows the full graceful sequence —

```
INFO: Shutting down
INFO: Waiting for application shutdown.
INFO: Application shutdown complete.
```

— and the container's recorded exit code is **143** (a completed SIGTERM stop; the
signal that ended the PID-1 tree, with the lifespan finished inside it). CI asserts
the truthful contract: exit **≠ 137** (137 = SIGKILL = the shutdown hung) **and**
`Application shutdown complete` in the log. A job in flight at stop is logged
*interrupted*; the job log survives restarts on the config volume:

```
docker start … → GET /jobs → 2 jobs: 7aef6f done, 3b5f1b done (prune flag persisted)
```

**The root-scope finding, fully (this one rewrote two docs and one test):** the first
battery's thin answers (wakeboarding: 3 strong shown as 1) traced to **ghost rows** —
the index folder was shared between two root layouts (dev `/corpus` and Compose
`/media/photos`), so 15 stale rows of the old scope kept counting (files 30, vectors
74) and diluted the engine's z-normalization. Prune retired them (files 15, vectors
37, 0.1 s). Two behaviors fall out, pinned by two tests in `test_jobs.py`: a **plain
sync** walks the current roots and *does* retire rows for files missing inside them
(found by suite 11); rows **outside** the current roots survive plain syncs and retire
only under prune (the compose ghost, proven at scratch scale). The operational rule
now in README + Compose header: **an index folder belongs to one root layout** — the
suite/dev roots get `index-suite`, Compose's roots get `index`.

**Suite** (against a dedicated `/corpus`-scoped index, 15 files / 37 vectors, built
fresh with the engine container in 2 min):

```
45 passed, 1 deselected, 1 warning in 215.60s (0:03:35)
```

(22 search/index/CLI contract + 10 API incl. the startup-prewarm test + 6 job tests
incl. the two ghost-row tests + 7 UI/media tests; the wall time grew from Stage 6's
because every client fixture now prewarms — the model load the suite pays is the model
load users no longer pay.)

**Live job-log proof on the final image:** a fresh prune job answered
`done 15/15 files · 37 vectors · prune True`, and after `docker restart` the replayed
record reads `('a7175b', 'done', prune=True)` — the flag persists. The two older jobs
replay as `prune False`, honestly: they ran before the log carried it.

## What this proves / does not

* **Proves**: a runtime image with no toolchain and no desktop stack that boots the
  engine + API + UI, is healthy, publishes localhost-only, survives SIGTERM truthfully,
  and keeps all mutable state on volumes.
* **Does not prove**: prod x86_64 build (same Dockerfile, built on the prod box, §11),
  GPU (Stage 9), restarts-with-job-under-load semantics at scale (Stage 8), auth.
