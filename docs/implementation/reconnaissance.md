# Stage 1 — reconnaissance

Date: 2026-11-02. Everything below was verified by reading the repository and probing this
machine, not by reading the README alone. Commands are listed in §14.

## 1. Repository identity

| | |
|---|---|
| Working directory | `~/Projects/digup` |
| Remote | `origin https://github.com/ARahim3/DigUp.git` (fetch and push) — **a clone of upstream, not a fork** |
| Branch | `main`, tracking `origin/main`, in sync (`## main...origin/main`) |
| HEAD | `dc2651a Merge pull request #142 from Nagi-Inaba/fix/ime-composition-search` |
| Local changes | **none** (`git status --short` is empty) |
| License | MIT |
| Latest release | `v0.7.0-beta.3` (Mac `.dmg` releases stop at `v0.6.2`; `v0.7.0-beta.3` ships Windows + Linux) |
| Package manifest | `swift-tools-version: 6.2`, single Swift package |

So: this working copy is pristine upstream code. Anything the server adds must stay additive.

## 2. Where the engine lives (the packaging fact that matters)

- `Package.swift` products: `.executable(name: "digup")` from the Swift targets `digup` +
  `DigUpKit` + `LlamaRuntime`, plus `.library(name: "DigUpKit")`. On macOS only, also
  `DigUpApp` (SwiftUI menubar app, Sparkle updates).
- `Sources/DigUpKit` — "the engine: crawler, extractors, index store, the embedder interface
  and worker client, search. No UI." (its own comment in `Package.swift`).
- `Sources/LlamaRuntime` — EmbeddingGemma 2 on llama.cpp (`LlamaEmbedder`, `LlamaModels`).
- `Sources/CLlama` (macOS, static + Metal), `Sources/CLlamaShared` (Linux, shared libs +
  `$ORIGIN` rpath), `Sources/CLlamaWindows` (Windows).
- The **Linux/Windows application is a shell, not the engine**: `shell/src-tauri` is Rust/Tauri
  and `shell/ui` is dependency-free vanilla JS. `shell/src-tauri/src/helper.rs` line 1:
  *"DigUp's helper processes, which do all the work: `digup search-service` answers the panel
  … and `digup index-service` keeps the index current."* Every feature of the Linux app is the
  Swift CLI answering JSON lines.
- Consequence for us: a headless server = the Swift `digup` binary + a thin HTTP layer. Swift
  is needed **only to build**. `scripts/package-linux.sh` proves it: it builds
  `swift build -c release --product digup --static-swift-stdlib` (with Swift's runtime archives
  re-listed after the link) so "no Swift libraries ship".

`worker/digup_worker.py` is the **mlx-vlm reference runtime** for evals (`WorkerConfig.python`,
`$DIGUP_WORKER_DIR`). mlx-vlm needs Apple Silicon. It is not a server engine.

## 3. Layout

```
Package.swift            one Swift package, per-platform targets
Sources/
  DigUpKit/              engine: Crawler, Indexer, IndexStore, Database, Searcher, SearchText,
                         Estimator, Rules, FolderSelection, OfficeText, MeasuredCosts,
                         ModelFiles, PreviewImages, Vectors, Worker, Platform/ (per-OS readers)
  LlamaRuntime/          LlamaEmbedder.swift, LlamaModels.swift, ImageSizing.swift
  digup/                 main.swift, IndexService.swift, SearchService.swift, WorkerService.swift,
                         DownloadModel.swift, ModelSpeed.swift, MeasuredCosts…, Watchdog,
                         ParentWatch, SystemLoad
  DigUpApp/              macOS SwiftUI app (not built on Linux)
  CLlama*/ CPDFium/      C module maps for llama.cpp and PDFium
Tests/                   DigUpKitTests (crawler/index/search/readers, Pictures/, Videos/),
                         LlamaRuntimeTests (ReferenceVectorTests + stored reference vectors)
scripts/                 fetch-vendor.sh, build-llama.sh, build-ffmpeg.sh, package-linux.sh,
                         package-windows.sh, check-linux-package.sh, make-testbed.sh,
                         testbed/ (media/doc/lang/long generators), dev-run.sh, release.sh,
                         notices.py, appcast.py, vendor-checksums.json
evals/                   synthetic.json, multilingual.json, code.json (ground-truth queries)
shell/                   ui/ (vanilla JS: panel, window, settings, setup) + src-tauri/ (Rust)
website/                 the product site
docs/ evals/ updates/ Resources/ .github/workflows/
```

`.gitignore` keeps `.build/`, `.swiftpm/`, `build.noindex/`, `Vendor/`, `.dev/`,
`shell/src-tauri/target/`, `shell/src-tauri/helper/` out of git. Vendor dependencies are never
committed — they are fetched at pinned versions.

## 4. The CLI (from `Sources/digup/main.swift`, verbatim usage)

```
digup estimate <folder>... [--json]        what would be indexed, how long the first pass takes
digup index <folder>... [--limit N]        sync + embed what's new, then the rest of long files
digup search <words>... [--kind K,K] [-n 10] [--json]
digup status                               what's in the index
digup speed [--model [--if-needed] [--when-quiet S] [--tries N]] [--json]
digup eval <queries.json> [-n 10]          recall of known answers
digup index-service <folder>... [--backfill] [--prune] [--memory-limit MB] [--time-limit S]
digup worker [--text-only]                 the model as a process (JSON lines)
digup search-service <folder>... [--encoder-idle S]   the searcher as a process (JSON lines)
digup download-model [--to DIR]            the model files (JSON lines)

  --index DIR        index folder (default: AppPaths.defaultIndex)
  --code             the code index (code.sqlite)
  --kind K,K         screenshot, image, pdf, doc, audio, video
  --exclude DIR / --exclude-ext EXT / --include-code / --include-datasets
  --reindex          drop vectors and embed everything again
  --zgate 2.0 --word-weight 2.0 --shot-tokens 280 --code-stretch 1800
  --limit N  -n N    --new-limit  --linger  --encoder-idle  --tries  --when-quiet
```

Verified behaviours relevant to the server:

- `search --json` prints an array of hit objects built by `hitFields()`:
  `path, kind, segment, segment_id, score, modified, size, info`, plus optional
  `z, cosine, keyword_rank, loc, loc_end, focus, excerpt`. Scores are the engine's own;
  `loc`/`loc_end` are the page number, the second of a video/audio moment, the line range,
  the cell range. There is **no** percentage similarity to fake.
- `status` prints index path, vector and segment counts, per-kind per-state counts, long files
  left, the index's `fingerprint` ("built with:"), `llama.cpp <buildTag>, vectors <vectorVersion>`,
  and the index size.
- The model source and the index must agree: `queryVectors()` refuses to search when the index's
  `vectorSource` differs from the encoder's (`index vectors come from … but the query encoder is …`),
  and `SearchService` falls back to keyword-only with a `warning` in the reply.
- Non-macOS specifics: `main.swift` forces `LlamaEmbedder.cpuOnly = true` for `search-service`
  (a query is a few words: the CPU encodes faster than a cold GPU; indexing keeps the GPU), and
  uses `_exit()` for the services because glibc's `exit()` deadlocks on the stdin reader thread.
- `ParentWatch.start()` runs for `index-service`, `worker`, `search-service`, `download-model`:
  the helper exits when its parent dies. Supervision consequence: the API process must be the
  long-lived parent of the services.
- `MeasuredCosts.load(from: index).speed?.device == "cpu"` forces CPU for every command except
  `speed` — i.e. the device choice is persisted beside the index by `digup speed --model`.
  `DIGUP_DEVICE=cpu` forces CPU. `LlamaEmbedder.hasGPU` detects an actual GPU device.

## 5. Persistent services: the engine interface we want (Approach B exists, and is public)

`digup search-service` (`Sources/digup/SearchService.swift`) — one JSON request per line on
stdin, one reply per line on stdout carrying the request's `id`; lines without an `id` are
events. Ops (documented in the source header):

| op | reply |
|---|---|
| `search` (`q, code, kinds[], limit, meaning, prefix_last`) | `hits[]` (as `search --json`, plus `segment_id, modified, size, info`), `strong`, `meaning`, `ms:{embed,search}`, optional `warning` |
| `embed_ahead` (`q, code`) | `{ok:true}` — pre-embeds and caches a partial query |
| `text` (`segment`) | `{text}` — the passage/page/frame text a hit points at |
| `render` (`path, kind:pdf\|video\|image, loc, pixels`) | `{image: <path>}` — a JPEG preview/thumbnail, made beside requests, cached in `<index>/previews` |
| `reload` | `{ok, vectors, code_vectors}` — reopens the index after indexing ran |
| `summaries` (`code`) | per-root `{path, missing, unreadable, files, indexed, pending, failed, skipped, unfinished, kinds, skipped_reasons}` |
| `folders` (`roots, skipped, types, code_roots, code_skipped`) | `{ok}` — changes scope at runtime |
| `prewarm` | `{ok, encoder, vectors}` — starts encoder + loads vectors |
| `status` | `{encoder: stopped\|starting\|ready\|unavailable, vectors, code_vectors, index, files, searchable, pending, unfinished}` |
| `quit` | `{ok}` then exit |

Notes: search is scoped to the positional roots (and `--exclude`/`--exclude-ext`) and drops hits
whose file no longer exists. `--encoder-idle S` (default 300 s) releases the model and vectors
after idle; after `2 × S` the process exits itself (`event: exit, reason: idle`) — the adapter
must restart it. `search-service` prints `{event: ready, index}` at start and
`{event: encoder, state: ready, seconds, source}` when the encoder is up.

`digup index-service` (`Sources/digup/IndexService.swift`) — stdin commands `sync`,
`sync code`, `stop`, `backfill on`, `backfill off` (EOF = stop). Events:

`missing` (folders gone/unreadable) · `pruned` · `rescan` · `stopped` (watchdog) · `scanning`
(checked, root) · `sync` (`new, added, changed, moved, removed, unchanged, ms, started, left_out`) ·
`file` (`done, total, path, kind, state, seconds, note, new`) · `summary` (states, ms) ·
`rest` (long files: done/total) · `waiting` (for model) · `idle` · `error` (with `fatal`) ·
`exit` · `reindex` (model changed). Counts (`files, searchable, pending, vectors, unfinished`)
ride on the count events, `code_`-prefixed for the code index. Progress is real file counts,
never an invented percentage. A missing/unreadable root is skipped, never treated as "all
deleted". Limits: `--memory-limit`, `--time-limit` (Watchdog), `--new-limit` (default 50),
`--linger` (default 60 s).

`digup worker` (`Sources/digup/WorkerService.swift` + `DigUpKit/Worker.swift`) — the JSON-lines
embedding protocol (`text`, `image`, `audio`, `quit`; base64 float vectors), i.e. the same
protocol the Python reference worker speaks. Useful for testing, not needed by the server.

## 6. Index storage

- `IndexStore.mainFile = "index.sqlite"`, `IndexStore.codeFile = "code.sqlite"`, in the `--index`
  folder; plus `previews/` (rendered JPEGs, cleared at each `search-service` start),
  `costs.json` (`MeasuredCosts`: per-machine costs and the chosen `device`), `speed.json`,
  `worker.log` / `worker-query.log`, a `Watchdog` note file.
- Default index folder when `--index` is absent: macOS `~/Library/Application Support/DigUp`,
  Linux `$XDG_DATA_HOME/digup` else `~/.local/share/digup` (`AppPaths` in
  `Sources/DigUpKit/Platform/Portable.swift`), Windows `%LOCALAPPDATA%\DigUp`. **The server
  always passes `--index` explicitly.**
- SQLite: opened read-write, `PRAGMA journal_mode = WAL`, `synchronous = NORMAL`,
  `foreign_keys = ON`, `busy_timeout = 5000` (`Database.swift`); vendored SQLite **with FTS5**
  (`SQLITE_ENABLE_FTS5`, `Package.swift`) for the exact-word index. Vendor SQLite is used
  because Linux's may lack FTS5/headers.
- Fingerprints: `WorkerInfo.vectorSource = "<model>@<revision7> <runtime> <dtype>"`; the index
  stores `fingerprint` and refuses cross-source searches. `LlamaEmbedder.vectorVersion = 1`,
  `buildTag = LLAMA_BUILD_TAG` (written by `scripts/build-llama.sh` into `llama-build.h`).
- File states used in counts: `done`, `partial`, `pending`, `failed`, and skipped-with-reason
  (`no text`, `silent or shorter than 2 s`, …).

## 7. Model storage

`Sources/DigUpKit/ModelFiles.swift` pins exactly two files from
`ggml-org/embeddinggemma-2-GGUF` at revision `bfcd298762cc34d0357ece5ebdd31791a3a374d8`:

| file | bytes | sha256 |
|---|---|---|
| `embeddinggemma-2-Q8_0.gguf` (text, queries) | 309,855,456 | `2188ac1deca4b77dffefd603c2776a9d76d9d74ec01841392982ebb840b09135` |
| `mmproj-embeddinggemma-2-Q8_0.gguf` (image + audio encoders) | 554,821,024 | `c4a8a52691ecef40618438928bdf9e68379b854e24166f292592353db0aab64f` |

865 MB total, Q8_0 only (never F16 — the activations overflow float16). Lookup order
(`LlamaModels.locate`): **`$DIGUP_MODELS` — and if set, only there** → `AppPaths` models folder
(Linux: `~/.local/share/digup/Models`) → the Hugging Face cache snapshot
(`$HF_HUB_CACHE` / `$HF_HOME/hub` / `~/.cache/huggingface/hub/models--ggml-org--embeddinggemma-2-GGUF/snapshots/<revision>`).
`digup download-model [--to DIR]` fetches with resume and checksum verification, printing JSON
lines. `HF_HUB_OFFLINE=1` once files are cached (what `WorkerConfig.python` does).

## 8. Media support (Linux vs macOS)

Engine kinds: `screenshot, image, pdf, doc, audio, video, code`.

| kind | Linux reader | notes |
|---|---|---|
| images | stb (`CStb`) | JPEG/PNG/WebP/HEIC-decodable set; README: RAW photos are Mac-only |
| screenshots | stb | **no in-image OCR on Linux** (Apple Vision): found by what they show, not by the text in them |
| PDF | PDFium (`CPDFium`) | text + page renders, scans included; up to 5,000 pages, first 30 in the first pass |
| docs | `OfficeText` + miniz (`CMiniz`) | txt, md, typ, rtf, docx, odt, html, xlsx, ods, pptx, odp; legacy `.doc` is Mac-only |
| audio | ffmpeg/ffprobe + model | 30 s windows, overlapping; hits carry the second |
| video | ffmpeg/ffprobe + model | frames per shot / every few seconds + soundtrack; hits carry the second |
| code | `CodeExtractor` | separate `code.sqlite`, off unless enabled |

README FAQ confirms the Linux gaps: screenshot text, `.doc`, RAW, SVG are macOS-only. The
server's UI must therefore not promise audio/document/OCR features it cannot verify.

## 9. Build system, pinned versions

`scripts/fetch-vendor.sh` (Linux/Windows only) → `Vendor/`: SQLite amalgamation
`2026/sqlite-amalgamation-3540000.zip` (3.54.0), stb @ `2c980bb59875b0d32144a71867fbdebb2f77cd20`,
miniz `3.1.2`, PDFium `chromium/8086` prebuilt (`pdfium-linux-x64`, `pdfium-linux-arm64` for
aarch64). All downloads are verified against **committed pins** in
`scripts/vendor-checksums.json`; writes `Vendor/VENDOR` stamp. Needs curl, tar, python3.

`scripts/build-llama.sh` → `Vendor/llama/{lib,include}` + `Vendor/llama.cpp` + `Vendor/llama-build`:
llama.cpp tag `b11461` at commit `4d756bc72bf00a4aacf410ae15a2d315f3db400d`, plus
`scripts/llama.cpp-no-logits.patch`. Linux/Windows: `BUILD_SHARED_LIBS=ON`,
`GGML_BACKEND_DL=ON`, `GGML_CPU_ALL_VARIANTS=ON`, `GGML_NATIVE=OFF`, `LLAMA_BUILD_MTMD=ON`,
tools/server/examples/tests/app/ui off, `LLAMA_CURL=OFF`. GPU choice: CUDA when `nvcc`
(`CUDACXX`, `CUDA_ARCHS` default `native`), else Vulkan when `glslc` is on PATH, else CPU.
arm64 needs a compiler that accepts `-march=armv9.2-a+sme` (script probes `cc`, `gcc-14`,
`gcc-15`, `clang`); it hard-fails otherwise. macOS: static libs with Metal
(`GGML_METAL_EMBED_LIBRARY=ON`).

`.github/workflows/packages.yml` (Linux job) is the authoritative dependency list: builds inside
`container: ubuntu:22.04` on `ubuntu-24.04` runners so the output needs **glibc ≤ 2.35**;
apt packages `ca-certificates curl git gnupg xz-utils unzip python3 binutils build-essential cmake
ninja-build meson nasm pkg-config patchelf file zlib1g-dev libcurl4-openssl-dev libxml2-dev
libedit2 libsqlite3-0 libz3-dev libpython3-dev tzdata … libvulkan1`; Swift
`6.4.0-RELEASE` from download.swift.org verified by GPG signature; Rust (rustup, minimal) and
Node v24.20.0 (for Tauri's CLI — **only the shell needs them, not the engine**); Vulkan SDK
`1.4.363.0` for the Vulkan backend's shader compiler. Then
`scripts/fetch-vendor.sh && scripts/build-llama.sh && scripts/package-linux.sh`.
`scripts/check-linux-package.sh` is the upstream "installed package actually launches" check.

`scripts/package-linux.sh` shows the exact release build of the CLI
(`--static-swift-stdlib` + the trailing `-Xlinker -l…` list) and the runtime payload: `digup`,
`libpdfium.so`, `ffmpeg`, `ffprobe`, llama's `.so` files, all `patchelf --set-rpath '$ORIGIN'`.

## 10. Environment probe (this machine)

| probe | result |
|---|---|
| `uname -m` | `arm64` (Apple Silicon) |
| `sw_vers` | macOS 26.5.1 |
| CPUs / RAM | 8 physical, 8 589 934 592 B (8 GB) |
| disk | 386 GB volume, **41 GB available** |
| Docker | client 28.3.0, Docker Desktop 4.43.1, engine linux/**arm64**, 7 CPUs, 6.77 GiB, root `/var/lib/docker` |
| `docker compose` | v2.38.1-desktop.1 |
| Xcode | **16.4**; `swift --version` = Apple Swift **6.1.2** |
| CMake / uv / ninja (host) | none installed |
| `swift-tools-version` needed | **6.2** (and the README asks Swift 6.4 / Xcode 26 for non-Mac builds; Xcode 26 for the app's macros) |

Consequence: **the host cannot build this package as installed** (Xcode 16.4's 6.1.2 <
tools-version 6.2), and the host is arm64 macOS so its binaries are excluded from images by the
rules in [README.md](README.md). Engine build and proof must happen in Linux containers
(arm64 here) and on the eventual x86_64 server.

Toolchain availability (HTTP probes, 2026-11-02):

| artifact | result |
|---|---|
| `swift-6.4.0-RELEASE-ubuntu22.04.tar.gz` | **200**, 1 123 431 313 B |
| `swift-6.4.0-RELEASE-ubuntu22.04-aarch64.tar.gz` | **exists** (206 on a ranged probe) |
| `swift-6.4.0-RELEASE-ubuntu24.04_arm64.tar.gz` | 404 |
| `swift-6.2.0-RELEASE-ubuntu24.04_arm64.tar.gz` | 404 |

⇒ arm64 Linux builds use **ubuntu:22.04 + the `-aarch64` Swift tarball** (which also matches
upstream's glibc-2.35 target); x86_64 builds use ubuntu:22.04 + the plain tarball. No arm64
Ubuntu 24.04 Swift release exists.

## 11. Upstream release artifacts (the runtime payload, verified by extraction)

Downloaded `DigUp_0.7.0-beta.3_amd64.deb` (41,565,124 B) and listed its payload:
`/usr/bin/digup-shell` (7.7 MB, Tauri shell), `/usr/lib/DigUp/THIRD-PARTY-NOTICES.txt`, and
`/usr/lib/DigUp/helper/`:

```
digup 81,410,360    libllama.so.0 4,825,512    libmtmd.so.0 1,896,696
ffmpeg 12,277,760    libggml.so.0 55,184        libggml-base.so.0 971,368
ffprobe 12,064,704   libggml-vulkan.so 46,010,608
libpdfium.so 7,982,296   libggml-cpu-{x64,sse42,sandybridge,ivybridge,haswell,alderlake,
                          icelake,cascadelake,cooperlake,zen4,sapphirerapids,cannonlake,piledriver}.so
```

Control file: `Depends: libcurl4t64 | libcurl4, libgomp1, libayatana-appindicator3-1,
libwebkit2gtk-4.1-0, libgtk-3-0`, `Recommends: libvulkan1`, `Installed-Size: 191747` KB.
GTK/WebKit/appindicator are the shell's; the headless payload needs `libcurl4`, `libgomp1`
(+ `libstdc++6`, and `libvulkan1` only if Vulkan is used).

Points this proves: (1) an x86_64 `digup` with static Swift stdlib runs with **no Swift
toolchain installed**; (2) llama.cpp ships CPU dispatch variants + a Vulkan backend and **no
CUDA** in upstream's Linux releases (CI has no `nvcc`); (3) the AppImage (146 MB, amd64) is the
self-contained variant. These artifacts are for **comparison only** — the server image is built
from source per [README.md](README.md).

## 12. Existing UI (reuse candidate)

`shell/ui`: `panel.js` 581, `window.js` 1212, `settings.js` 553, `setup.js` 719,
`results.js` 269, `shortcut.js` 55 (+ `panel.css` 402, `window.css` 667, `settings.css`,
`setup.css`, 4 HTML files) = ~5 000 lines, **no framework, no build step**
(`tauri.conf.json: "frontendDist": "../ui"`, `withGlobalTauri: true`). All engine access goes
through Tauri `invoke()` (22 call sites in `window.js`). The project's house style is
deliberately dependency-free. The server UI follows that style (§13): HTML + CSS + vanilla JS
talking to `/api/v1` with `fetch()`, in the same visual language. Adopting React/TypeScript/Vite
for the server only would leave the repository with two frontends in two paradigms — poor for
upstream maintenance, so it is not the route.

## 13. Sustainability / upstream-contribution constraints

This server is intended as a **pull request to ARahim3/DigUp** and as the basis of a public
page. Rules that follow from that:

1. **Additive only.** Engine, manifest, packaging scripts, shell, and website stay untouched.
   New code lives in `server/` (API + adapter + tests + Docker) with its own README, and
   `docs/implementation/` for documentation, plus a dedicated
   `.github/workflows/server.yml`. No edits to `Sources/**` for server convenience; if the
   engine genuinely must expose something new, it is a separate, minimal, tested,
   backward-compatible change to the JSON protocol — never a private field.
2. **Speak the documented protocol only.** `search-service` and `index-service` are the same
   protocol the shipping desktop shell uses, so upstream keeps them working. Contract tests in
   `server/tests/` assert the ops/fields above; a protocol doc mirrors the source header
   comments. Nothing is invented, nothing is cached in a parallel store.
3. **Upstream conventions.** Pinned versions with pinned hashes (like `vendor-checksums.json`),
   no vendored blobs in git, `uv` for Python (repo already uses `uv` + `pyproject.toml` +
   `uv.lock` in `worker/`), dependency-light frontend, dense "why" comments in the house style,
   MIT license and `scripts/notices.py` notices respected, `.env.example` for configuration,
   no secrets committed.
4. **CI-able and headless.** Everything a reviewer needs runs from a clean clone in containers:
   build → `swift test` → `digup --help` → index a generated corpus → semantic search assertions
   → API tests → Docker acceptance. The workflow must not need a GUI, a GPU, the desktop shell,
   Rust, Node, or Tauri.
5. **Long-lived compatibility surface.** Version the HTTP API (`/api/v1`), publish the engine
   version/vector source in `/health`, keep one `CHANGELOG`-style status document
   (`IMPLEMENTATION_STATUS.md`), and never break the API's published contract.
6. **Small blast radius.** Server runtime state lives in `/data` volumes; server settings are
   server-only; the engine's own settings files (`costs.json`, `speed.json`) are read, not
   rewritten, by the server.

## 14. Reproduce these findings

```sh
pwd; git status --short --branch; git remote -v; git log -1 --oneline; git branch -a
ls -la; sed -n 1,257p README.md; cat Package.swift
sed -n 1,240p Sources/DigUpKit/Worker.swift
sed -n 1,385p Sources/digup/SearchService.swift
sed -n 1,404p Sources/digup/IndexService.swift
sed -n 1,180p Sources/digup/main.swift && sed -n 300,760p Sources/digup/main.swift
grep -n "mainFile\|busy_timeout\|journal_mode" Sources/DigUpKit/IndexStore.swift Sources/DigUpKit/Database.swift
sed -n 1,80p Sources/DigUpKit/ModelFiles.swift
sed -n 1,136p scripts/build-llama.sh; sed -n 1,85p scripts/fetch-vendor.sh; cat scripts/package-linux.sh
sed -n 1,120p .github/workflows/packages.yml
head -30 scripts/make-testbed.sh; head -20 evals/synthetic.json
wc -l shell/ui/*.js; grep -c "invoke(" shell/ui/*.js
# upstream artifact inspection (reference only)
curl -L -o DigUp.deb https://github.com/ARahim3/DigUp/releases/download/v0.7.0-beta.3/DigUp_0.7.0-beta.3_amd64.deb
ar x DigUp.deb && python3 -c "import tarfile;[print(m.size,m.name) for m in tarfile.open('data.tar.xz').getmembers()]"
# environment
uname -m; sw_vers; sysctl -n hw.ncpu hw.memsize; df -h /; docker version; docker compose version
xcode-select -p; xcodebuild -version; swift --version
curl -sIL https://download.swift.org/swift-6.4.0-release/ubuntu2204/swift-6.4.0-RELEASE/swift-6.4.0-RELEASE-ubuntu22.04.tar.gz
curl -s -o /dev/null -w "%{http_code}" -L -r 0-1 https://download.swift.org/swift-6.4.0-release/ubuntu2204-aarch64/swift-6.4.0-RELEASE/swift-6.4.0-RELEASE-ubuntu22.04-aarch64.tar.gz
```

## 15. Test results so far, and open items

Ran so far: repository inspection, script/protocol/CLI reading, environment probes, toolchain
availability probes, upstream artifact extraction, the corpus build, and **the first Linux build
of the engine: `swift build -c release` and `swift test` pass in the arm64 container (116 + 7
tests, 0 failures), and the 296 MB runtime image runs `digup` headlessly**. The exact results,
commands and image layout are in [stage-1-linux-build.md](stage-1-linux-build.md). Stage 2 (the
headless index + search proof on the corpus) is running as this is written.

Open items:

1. ~~Build-host decision~~ — **decided**: Stages 1–2 build and prove natively in arm64 Linux
   containers on this Mac; the x86_64 production image is built **natively on the x86_64 Linux
   server** with the same Dockerfile (images are per-architecture; see README §11).
2. `make-testbed.sh` is macOS-specific (Xcode-run Swift generators, APFS clones, screenshot
   xattrs). The Linux-side test corpus now exists: `server/tests/corpus/` (pinned Commons
   pictures, pinned videos, a synthetic 3-scene clip, `corpus.json` ground truth).
   **Stage 2 is complete** — headless index + search + eval in the CPU runtime image
   (R@1 0.71 / R@5 0.88 over 17 labeled queries, exact video timestamps, honest
   "no good matches"): [stage-2-headless-proof.md](stage-2-headless-proof.md).
3. Index locking: SQLite is WAL + `busy_timeout`, and upstream runs one `index-service` at a
   time. Confirm the engine's behaviour with two concurrent writers and add an OS-level lock in
   the adapter so only the server ever starts indexing.
4. `search-service` self-exits after `2 × --encoder-idle`; the adapter needs supervised restart
   with a `reload` after indexing, and must never treat the idle exit as a failure.
5. `render` previews land inside `<index>/previews` (world-readable paths): the API must read
   them itself and never expose that path to clients.
6. Video search in the browser needs codecs the container doesn't control (MP4/H.264 is
   generally fine in browsers; HEIC/HEVC/ProRes is not) — decide what the preview endpoint
   transcodes (if anything) without touching DigUp's own renders.
7. No CUDA in upstream's Linux releases and no CUDA possible on this Mac; production GPU support
   starts as Vulkan (documented path) with a measured CPU/GPU comparison by
   `digup speed --model`, which also enforces vector agreement (cosine ≥ 0.999) before trusting
   a GPU.
8. **`estimate --json` and ParentWatch (Stage 3, correcting Stage 2's report).** Stage 2
   recorded "`estimate --json` prints nothing on Linux (exit 0)" as an upstream finding.
   It is not a bug: `estimate --json` calls `ParentWatch.start()` (`main.swift:699`), and on
   Linux ParentWatch treats **parent == PID 1 as "the app is gone"** (`guard parent != 1
   else { _exit(0) }`, `ParentWatch.swift`) — the helper exits within a second. Every silent
   observation came from running it as PID 1's child (`bash -c` / `proof.sh` as PID 1); with
   a live parent (the pytest/uvicorn process, direct `docker run digup …`) the same binary
   prints its JSON lines fine, skipped files included. Server rule, now binding: the API
   process is the long-lived parent of every helper (spawn direct, never through a PID-1
   shell wrapper) — which `protocol.py` enforces — and it *can* use `estimate --json`,
   tested in `server/tests/test_cli.py`.
