# DigUp Server — implementation instructions (binding)

These are the rules this project follows. They are not suggestions. When a stage's work
violates one of them, the stage is not done.

Companion documents:

- [reconnaissance.md](reconnaissance.md) — what the existing repository is, verified by reading
  it and probing the environment. Start there.
- [review-round.md](review-round.md) — the adversarial review before the PR: every finding that
  was real, its fix, the test that pins it, and what was deliberately left alone with its reason.
- [stage-12-integrations.md](stage-12-integrations.md) — the integration contract for serving
  applications *of* the library (Nextcloud first): the shared-stack shape, the named-token map,
  the data-dir exclusion gate, the CORS allowlist and its guard exception, the embed widget,
  the multi-instance honesty. Its §11.x numbers are quoted in code comments.
- `api.md`, `deployment.md`, `operations.md` — written as those parts are implemented.

---

## 1. The engine is DigUp's. It is not rewritten.

The original Swift engine remains responsible for reading media, extracting images / frames /
audio / text, generating embeddings, storing them, searching, and ranking. The server is a
wrapper around it.

Do **not**:

- replace EmbeddingGemma 2 or llama.cpp;
- write a second embedding engine (in Python or anything else);
- change preprocessing, vector dimensions, similarity math, video frame sampling, audio
  segmentation, ranking behaviour, or the SQLite index schema;
- build a parallel/incompatible vector store;
- invent similarity scores, progress percentages, timestamps, or metadata the engine did not
  produce.

`worker/digup_worker.py` in this repo is the mlx-vlm **reference** runtime used by the evals on
Apple Silicon. It is **not** a server engine and must not be used by the server.

## 2. DigUp is a native Swift application

This is the single most important fact for packaging, and the one most often mistaken:

- The search engine is Swift (`Sources/DigUpKit`, `Sources/LlamaRuntime`), built into the
  executable product `digup` (`Package.swift`). llama.cpp is a C/C++ library that Swift calls.
- The Linux and Windows applications are **not** the engine. They are a Tauri shell (Rust +
  web UI) that starts the Swift `digup` binary as helper processes and talks to it over
  JSON-lines. `shell/src-tauri/src/helper.rs`, first sentence: *"DigUp's helper processes,
  which do all the work."*
- Therefore: a headless DigUp server **is** a Swift binary at its core. The Python layer is
  the HTTP/JSON wrapper; the web UI is a browser client. Both are thin.
- Swift is required **at build time only**. A runtime image needs no Swift compiler and no
  Swift toolchain: `scripts/package-linux.sh` links the CLI with
  `--static-swift-stdlib` (Swift 6.4's static stdlib needs its archives re-listed at the end of
  the link line — copy that list from the script), and the shipped payload is the binary plus
  native `.so` files with `rpath = $ORIGIN`.

## 3. Linux Docker build (mandatory shape)

Use a **multi-stage** build for the server image:

1. **Builder stage** (one architecture, pinned versions, pinned commits — see reconnaissance
   §9 for the exact pins):
   - official Swift Linux toolchain (`swift-6.4.0-RELEASE`, download.swift.org, GPG-verified,
     as `.github/workflows/packages.yml` does);
   - C/C++ toolchain, CMake, Ninja, Python 3, curl, git, patch;
   - the repository's own scripts: `scripts/fetch-vendor.sh` (SQLite/FTS5, stb, miniz, PDFium)
     and `scripts/build-llama.sh` (llama.cpp `b11461`, patched, shared libraries with
     `GGML_BACKEND_DL` + `GGML_CPU_ALL_VARIANTS`);
   - `swift build -c release --product digup --static-swift-stdlib …` (the exact flags live in
     `scripts/package-linux.sh`);
   - run the test suite in this stage (`swift test`), never in the runtime image.
2. **Runtime stage**: a slim Linux base with only
   `digup`, llama.cpp's shared libraries (CPU variants; Vulkan/CUDA only when that backend is
   in use), `libpdfium.so`, `ffmpeg`, `ffprobe`, the runtime libraries they need
   (`libgomp1`, `libstdc++6`, `libcurl4`; `libvulkan1` only for the Vulkan override), the
   FastAPI application, the built web frontend, and Python.
   - non-root user, no desktop environment, no Tauri, no WebKit/GTK, no X11, no Wayland, no
     systemd;
   - a Docker `HEALTHCHECK`;
   - correct SIGTERM handling: the API process owns its child processes and stops them cleanly.

Rules:

- **Compile for the image's architecture.** An `x86_64` image is built on/before an
  `x86_64` host. An `arm64` image is built on `arm64`. Never ship a binary of another
  architecture, and never rely on emulation for indexing/search work.
- **Do not install the Swift compiler in the runtime image.**
- **Do not use macOS binaries, macOS frameworks, or a macOS-built `digup`** in any image.
  Image work happens in Linux containers.
- **Verify the CLI inside the final runtime image** as part of the build/acceptance
  procedure, headlessly, at minimum:

  ```sh
  digup --help
  digup status --index "$DIGUP_INDEX"
  digup search "wakeboarding" --index "$DIGUP_INDEX" -n 5
  ```

  If the container cannot run the engine's own CLI, the image is not finished.
- **CPU first.** Get CPU inference indexed and searching correctly before adding any NVIDIA /
  Vulkan dependency. GPU support arrives as a separate Compose override
  (`deploy/docker-compose.nvidia.yml`), is opt-in, and the server reports the backend it
  actually measured (`digup speed --model`), never the backend it hopes for.
- Cross-check the self-built image against the upstream release payload
  (`DigUp_<ver>_amd64.deb`, `/usr/lib/DigUp/helper/`) when comparing search results, so a
  build problem is distinguishable from an engine problem. Upstream artifacts are a
  **reference**, not the shipped build.

## 4. Engine interface

`digup` already exposes persistent, documented, JSON-lines services, and they are the
interface for the server adapter (reconnaissance §5):

- `digup search-service <roots>… --index DIR` — `search`, `status`, `summaries`, `text`,
  `render`, `reload`, `folders`, `prewarm`, `quit`; keeps the index open and the query encoder
  warm; real timings; real index counts; renders preview JPEGs (photos, PDF pages, video
  frames at a second).
- `digup index-service <roots>… --index DIR` — commands `sync`, `sync code`, `stop`,
  `backfill on|off`; emits `scanning`, `sync` (added/changed/moved/removed/unchanged), `file`
  (done/total), `rest`, `summary`, `waiting`, `idle`, `error`, `exit`. Real progress counts.
- `digup status` / `digup index` / `digup search --json` / `digup estimate --json` /
  `digup download-model` — one-shot commands, useful for diagnostics.
- The adapter exposes `health() / index() / search() / status() / close()` and nothing about
  DigUp internals leaks above it. Subprocess calls use argument arrays, never shell strings.

## 5. Persistence layout

Everything mutable lives on named volumes/bind mounts outside the image:

```
/data/            index/            index.sqlite, code.sqlite, previews/, costs.json, worker logs
                  models/           embeddinggemma-2-Q8_0.gguf, mmproj-embeddinggemma-2-Q8_0.gguf
                  config/           server settings, job state (jobs.jsonl)
/media/photos/    read-only mount of the original media
```

- The single-writer lock is a file **beside the index** (`<index>/.digup-server.writer.lock`,
  `server/digup_server/engine/index.py`), not a separate folder: it travels with the volume
  that holds the index it protects, and a moved index folder carries its lock with it.

- `--index /data/index` is always explicit. `/data/models` is published as `$DIGUP_MODELS`.
- Media roots are mounted read-only, validated against an allowlist, and are never chosen by
  the browser. Original files are never modified.
- Container recreation never destroys the index, model, config, or logs.
- Indexing never starts automatically at container start.
- One indexing job at a time, protected by an OS-level `flock` beside the index file (above),
  plus the engine's SQLite locking. An interrupted job is recovered as *interrupted*, never
  as success.

## 6. API surface (`/api/v1`)

`GET /health`, `GET /status`, `POST /search`, `POST /index`, `GET /jobs/{id}`,
`POST /embed_ahead`, `GET /media/{id}/preview`, `GET /media/{id}/text`,
`GET /media/{id}/file`. Pydantic models, OpenAPI documentation, versioned from the start.

The plan's `GET /media/{id}/open` shipped as **`/file`** (the UI's Open + Download), and
the plan's `GET /settings` + `PATCH /settings` shipped as **no settings endpoints**: the
settings the UI offers (appearance, limit, kinds, code mode, prune) are browser-side
state and request parameters, and the server-side knobs (encoder idle, prewarm, backfill,
job-log size, roots) are container configuration in the environment — `server/.env.example`
— not a remote-writeable surface. A single-user localhost server writes its own config
through Compose, not through HTTP (§7: no settings endpoints to protect).

- Search passes DigUp's ranking through untouched; media filters map onto DigUp's kinds
  (`image`/`screenshot` → photo, `video`, `audio`, `pdf`, `doc`).
- Video hits keep DigUp's seconds (`loc`, `loc_end`) exactly as the engine produced them.
- Errors are reported as the engine reported them.
- Media endpoints accept only ids from the index, never paths from the client; they resolve
  inside configured roots and refuse symlink traversal.
  As shipped: `/file`'s type, size and span come from **one open** (`os.fstat` +
  `stat.S_ISREG`) so a replacement mid-request can't make the headers lie about the bytes;
  root confinement is `Path.is_relative_to`, not a prefix string (which matched
  `/media/photos_evil` as a child of `/media/photos`); ranged spans are capped
  (8 MiB) and **streamed** in chunks — `Range: bytes=0-` is what every media element
  sends first, and an uncapped open range buffered the whole file; every `/file` answer
  carries `x-content-type-options: nosniff` as the belt behind magic-bytes typing.

## 7. Security and privacy

- binds `127.0.0.1:8787` by default; LAN exposure only after authentication is implemented
  and enabled;
- no plaintext passwords and no settings endpoints to protect (§6): the server's own
  configuration is container configuration, and there are no uploads, no remote writes to
  settings, and no auth state to leak. CORS is same-origin by construction — the UI is
  served by the API, so no cross-origin allowance is granted at all;
- no shell interpolation of user input, no arbitrary path or URL acceptance, no cloud embedding
  APIs, no uploads of media anywhere;
- filenames and metadata are escaped in the UI;
- the model is local: documented download path plus support for an already-cached model
  directory (`$HF_HUB_CACHE`, `digup download-model --to /data/models`).

## 8. Order of work

Stage 1 reconnaissance → 2 headless proof of the engine → 3 engine adapter + tests →
4 API (health/status/search) → 5 index jobs, locking, recovery → 6 web application →
7 Docker (CPU-only) → 8 persistence and reliability → 9 GPU → 10 PhotoPrism → 11 polish.

At the end of every stage: run tests, list files changed, give exact commands, give real
results, document open issues. **A stage that fails does not proceed by substituting mocks.**

## 9. Git safety

Preserve the repository: no `git reset --hard`, no `git clean -fd`, no overwriting user
changes, no remote changes, no force-push, no commits or pushes unless explicitly asked.
Server code stays separate from upstream engine code.

## 10. Built to be merged upstream (sustainability)

This server is intended as a **pull request to `ARahim3/DigUp`**, and as the basis of a public
page. Build it so a maintainer can adopt it, and so it survives the project's next 20 releases.

1. **Additive only.** `Sources/**`, `Package.swift`, `scripts/package-*.sh`, `shell/`,
   `website/` are not edited to make the server convenient. New code lives in
   `server/` (FastAPI app + engine adapter + tests + Docker) and `docs/implementation/`, with a
   dedicated `.github/workflows/server.yml`. If the engine must expose something the protocol
   lacks, that is a separate minimal change to the documented JSON protocol — backward
   compatible with the desktop shell, tested, and justified on its own.
2. **Speak the published protocol.** Only `search-service` / `index-service` / one-shot CLI
   operations that the shipping shell already uses. Contract tests in `server/tests/` pin the
   ops and reply fields. No private fields, no side channels, no parallel store, no re-ranking.
3. **Follow the house style.** Pinned versions with committed hashes (as
   `scripts/vendor-checksums.json`), nothing vendored into git, dense comments that explain
   *why*, MIT licensing and `scripts/notices.py` notices respected, `.env.example` for
   configuration, no secrets, no large binaries. Python dependencies via `uv`
   (`pyproject.toml` + `uv.lock`) — the repository's existing convention in `worker/`.
4. **One frontend, not two.** The repository's UI is dependency-free vanilla HTML/CSS/JS with
   no build step (`shell/ui`, ~5 000 lines, `frontendDist: "../ui"`). The server UI is built in
   that same style talking to `/api/v1` with `fetch()`. Adding React + TypeScript + Vite for the
   server alone would leave the project maintaining two UI paradigms: not the route. (Structure
   the server UI so a shared layer with `shell/ui` stays possible later.)

   > **Amended 2026-11-08 by explicit user brief** (server/ui/AGENTS.md is the architecture
   > manual): the SERVER UI migrated to **Lit + JavaScript ES modules + Vite** — no TypeScript,
   > no other framework, no router/state library. The rule's intent survives intact and is
   > now pinned by tests: one shell/ui stays vanilla and untouched; the server UI is the
   > project's one Lit surface, same-origin to `/api/v1`, loads no external URLs, keeps the
   > visual identity and the API contracts verbatim, and Node exists at BUILD time only
   > (the Dockerfile's `frontend-builder` stage; the runtime images ship static files).
   > "Two UI paradigms" is the accepted trade, scoped by the brief; the shared layer the old
   > text hoped for (format.js, media templates, tokens) is factored so it stays possible.
5. **Reviewable from a clean clone, headless.** One command sequence in CI builds the CLI, runs
   `swift test`, verifies `digup --help` inside the runtime image, indexes a committed tiny
   corpus, asserts semantic ranking (`wakeboarding`, `hiking`), and runs the API tests. It needs
   no GUI, no GPU, no Rust, no Node, no Tauri.

   > Amended 2026-11-08 with §10.4: the review path gained **Node at Docker build time**
   > (the frontend-builder stage runs `npm ci`, vitest, and `vite build` inside the build;
   > the published image and every runtime stage stay Node-free — measured: the runtime
   > stage COPYs the static dist and nothing else). CI stays headless.
6. **Stable public surface.** API versioned at `/api/v1`; engine version, vector source, llama.cpp
   build tag and device backend published in `/health`; `IMPLEMENTATION_STATUS.md` kept current;
   server state confined to `/data` volumes; the engine's own files (`costs.json`, `speed.json`)
   are read, not rewritten, by the server.

## 11. What is universal in Docker — and what is not

Docker is universal; **images are not**. This section settles where things get built, because
it is the question that decides every later deployment.

| universal (one copy, runs anywhere) | architecture-specific (built per machine class) |
|---|---|
| `Dockerfile`, Compose files, scripts, config, docs | every compiled artifact: the `digup` binary, llama.cpp `.so` files, `ffmpeg`, the images containing them |
| Python server code, adapter, tests | the GPU backends: Vulkan/CUDA need the real device and driver present |
| the browser UI (`fetch()` to `/api/v1`) | |

So:

- An `arm64` image runs on `arm64` machines; an `x86_64` image runs on `x86_64` machines. The
  same *Dockerfile* builds the correct image on each — that is what "universal" means here.
- `docker pull` gives every machine "the same" image only when a **multi-architecture manifest
  list** is published (each machine is handed the variant built for its own architecture, each
  built natively). That is a CI feature for later (`docker buildx --platform …`), not a license
  to copy a binary across architectures.
- Running an `x86_64` container on Apple Silicon is QEMU **emulation**: fine for a shell
  script, useless for a C++/Swift compile (10–50× slower) and for embedding work. Committed
  rule: **never ship an image that was built under emulation.**

Decision (2026-11-02), given a dev Mac (Apple Silicon, no CUDA, no Vulkan device) and a
production box (x86_64 + RTX 4070):

1. **This Mac builds and proves the arm64 images natively** — Stages 1–2, all adapter/API/UI
   development, the corpus proof, the API tests, the CI-equivalent run.
2. **The x86_64 production image is built natively on the production server** from the same
   `server/docker/Dockerfile`, on that machine, where the RTX 4070 is: the Vulkan/CUDA
   override (`deploy/docker-compose.nvidia.yml`) is built and measured there, by
   `digup speed --model`, nowhere else.
3. Later, a GitHub Actions `x86_64` job can build and publish the production image to a
   registry so the server only pulls and runs Compose — same Dockerfile, same rules. Nothing
   in the repository depends on which of 2 or 3 is used.

## 12. Definition of done (first release)

`docker compose up -d --build` starts the app → the user opens the web UI, configures a media
folder, starts indexing, watches honest status, searches `wakeboarding` and `hiking`, sees real
DigUp results (photos and videos, video hits keeping their timestamps), the index and model
survive container recreation, the HTTP API works without the browser, media stays read-only,
no cloud AI service is involved. Progress and limits are recorded in
`IMPLEMENTATION_STATUS.md`.
