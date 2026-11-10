# syntax=docker/dockerfile:1
# DigUp engine, built from source for the container's own architecture.
#
# Mirrors the Linux job of .github/workflows/packages.yml and ci.yml, with the aarch64 Swift
# toolchain added (swift.org publishes ubuntu22.04 x86_64 and ubuntu22.04-aarch64; there is no
# arm64 Ubuntu 24.04 release). Ubuntu 22.04 is deliberate: the binaries then ask for glibc 2.35
# at most, which is what the runtime stage ships. Never build here what is meant to run there:
# a binary of the image's architecture only.
#
# The engine is Swift (Sources/DigUpKit + Sources/LlamaRuntime → the `digup` executable), and
# llama.cpp / PDFium / ffmpeg are the native libraries it calls. Swift is needed at build time
# only; the runtime stage carries no compiler.
#
#   docker build --target engine-builder -t digup-engine-builder .
#
ARG BASE_IMAGE=ubuntu:22.04
ARG SWIFT_VERSION=6.4.0
# The CUDA *runtime* base whose libraries server-runtime-cuda ships (Stage 9). It must match
# the CUDA BASE_IMAGE the payload was built with. BuildKit prunes unreferenced stages: a
# CPU-only build (target server-runtime) never pulls this image.
ARG CUDA_RUNTIME_IMAGE=nvidia/cuda:11.8.0-runtime-ubuntu22.04

# ── Toolchain, vendor libraries, llama.cpp, ffmpeg, the CLI, the tests ───────────────────────
# ── The frontend build (user brief 2026-11-08, server/ui/AGENTS.md) ─────────────────────
# Lit + Vite: Node exists HERE, at build time, and never at runtime — the stage compiles
# the UI (npm ci, vitest, vite build) and the server stages COPY the static dist. A red
# unit test or a red build is a red image by construction. npm ci reads the committed
# package-lock.json; the npm cache rides a BuildKit cache mount (the registry is
# reachable from the builder, measured 2026-11-08).
FROM node:22-slim AS frontend-builder
WORKDIR /build
COPY server/ui/package.json server/ui/package-lock.json ./
RUN --mount=type=cache,target=/npm-cache npm ci --cache /npm-cache --no-audit --no-fund
COPY server/ui ./
RUN npm test && npm run build

FROM ${BASE_IMAGE} AS engine-builder

ARG SWIFT_VERSION
# Stage 9: scripts/build-llama.sh picks CUDA when nvcc is on PATH and pins the architecture
# with CUDA_ARCHS (default native). The builder container sees no GPU device, so the CUDA
# build passes the card's architecture explicitly — plain numbers, e.g. 61 for the Pascal
# GTX 1070 (the builder's apt cmake rejects dotted `6.1`; see the cuda-libs comment below).
# Comma- or semicolon-separated fat lists (61;70;89…) are accepted; the RUN normalizes the
# separators to CMake's semicolons. Harmless on the CPU baseline: with no nvcc, the value
# is unused.
ARG CUDA_ARCHS=native
ENV CUDA_ARCHS=${CUDA_ARCHS}
ENV DEBIAN_FRONTEND=noninteractive

# The same list the Linux CI job installs, plus patchelf (the runtime stage re-points rpaths).
RUN apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends \
    ca-certificates curl git gnupg xz-utils unzip python3 binutils build-essential cmake ninja-build \
    meson nasm pkg-config patchelf file zlib1g-dev libcurl4-openssl-dev libxml2-dev libedit2 \
    libsqlite3-0 libz3-dev libpython3-dev tzdata libgomp1 \
    && rm -rf /var/lib/apt/lists/*

# The official Swift toolchain, verified by its GPG signature (as the CI jobs do). Its runtime
# dependencies are the apt packages above.
RUN set -eux; \
    # swift.org publishes Ubuntu 22.04 for x86_64 and, under its own directory, for aarch64.
    case "$(uname -m)" in \
      aarch64|arm64) arch="-aarch64" ;; \
      x86_64) arch="" ;; \
      *) echo "no Swift release for $(uname -m)"; exit 1 ;; \
    esac; \
    base="swift-${SWIFT_VERSION}-RELEASE-ubuntu22.04${arch}"; \
    url="https://download.swift.org/swift-${SWIFT_VERSION}-release/ubuntu2204${arch}/swift-${SWIFT_VERSION}-RELEASE/${base}.tar.gz"; \
    curl -fsSL -o /tmp/swift.tar.gz "$url"; \
    curl -fsSL -o /tmp/swift.tar.gz.sig "$url.sig"; \
    curl -fsSL --compressed https://www.swift.org/keys/all-keys.asc | gpg --quiet --import; \
    gpg --quiet --verify /tmp/swift.tar.gz.sig /tmp/swift.tar.gz; \
    mkdir -p /opt/swift; \
    tar -xzf /tmp/swift.tar.gz -C /opt/swift --strip-components 1; \
    rm -f /tmp/swift.tar.gz /tmp/swift.tar.gz.sig
ENV PATH=/opt/swift/usr/bin:$PATH

WORKDIR /src
COPY . .
# CI vendor seeding: `.github/workflows/server.yml` caches Vendor/ host-side (the same
# scripts ci.yml runs, the same hash keys) and passes the built result in the context as
# `.ci-vendor/`. Copying it into the cache mount below lets fetch-vendor/build-ffmpeg/
# build-llama land on their own stamps (Vendor/VENDOR, ffmpeg/BUILD, llama/BUILD) and
# skip the rebuild — hosted runners start their BuildKit cache mounts cold every job,
# and a 15-minute ffmpeg compile on every PR was overrunning the job's own ceiling.
# A local build has an empty .ci-vendor/ (the tracked .gitkeep) and pays nothing here.
COPY .ci-vendor /ci-vendor

# Vendor libraries (SQLite with FTS5, stb, miniz, PDFium) and llama.cpp, pinned by the
# repository's own scripts; then the small ffmpeg the packages carry (the image and video
# readers use it, HEIC needs ffmpeg 8.1+). No CUDA and no Vulkan here: this is the CPU baseline,
# and the GPU backends are a separate, opt-in build (see docs/implementation/README.md).
#
# scripts/build-llama.sh picks a compiler that understands armv9.2-a's SME on aarch64; when the
# distribution has none, the build goes on with the distribution compiler and ggml leaves the SME
# variant out. Setting CC/CXX is what keeps the script from refusing to start.
#
# SWIFT_TESTS gates the engine's Swift test suite inside THIS build (default 1 — CI builds
# never pass the arg, so the gate runs exactly as before). It exists for dev hosts where a
# builder-environment difference is measured and is NOT the server's business: on this box
# (measured 2026-11-08, builder cache pruned, from-scratch rebuild) `swift test` dies in the
# engine's own CodeTests `gitListingNeverRunsRepositoryFsmonitor` (the fsmonitor hook never
# runs in this box's builder; the same Dockerfile builds green on CI's runners). The server's
# own gate is the contract suite (`--target server-test` + pytest); `swift test` belongs to
# the engine's CI jobs (ci.yml, packages.yml) on their supported environments.
ARG SWIFT_TESTS=1
RUN --mount=type=cache,target=/src/Vendor \
    --mount=type=cache,target=/src/.build \
    set -eux; \
    if [ -f /ci-vendor/llama/BUILD ]; then cp -a /ci-vendor/. /src/Vendor/; fi; \
    export CC="${CC:-cc}" CXX="${CXX:-c++}"; \
    if [ "$(uname -m)" = aarch64 ]; then \
      found=""; \
      for pair in cc:c++ gcc-14:g++-14 gcc-15:g++-15 clang:clang++ clang-15:clang++-15; do \
        c=${pair%%:*}; cxx=${pair##*:}; \
        command -v "$c" > /dev/null && command -v "$cxx" > /dev/null \
          && echo 'int main(void) { return 0; }' | "$c" -x c -march=armv9.2-a+sme -c -o /dev/null - 2>/dev/null \
          && { found="$c:$cxx"; break; }; \
      done; \
      if [ -z "$found" ]; then \
        echo "no SME-capable compiler: using $(cc --version | head -1) and leaving ggml's SME variant out"; \
      else \
        export CC=${found%%:*} CXX=${found##*:}; \
      fi; \
    fi; \
    scripts/fetch-vendor.sh; \
    # Flavor-switch hygiene (measured 2026-11-04): a CUDA-flavor build leaves Vendor/llama-build/
    # CMakeCache.txt with GGML_CUDA=ON; the next CPU-flavor run reuses that cache with cmake -S -B,
    # ggml then asks for the CUDA language and configure dies with "CUDA Toolkit not found"
    # (the CUDA invocation always passes -DGGML_CUDA=ON, so it never sees this). Dropping just
    # the cache file forces a fresh configure and keeps every compiled object in place.
    rm -f Vendor/llama-build/CMakeCache.txt; \
    # CUDA_ARCHS reaches CMake as ONE -D value, and CMake lists are SEMICOLON-separated:
    # "61,70,…" is one invalid arch token and configure dies immediately (measured 2026-11-05,
    # publish run #6: three fast configure fails, 164 s). Normalize commas to semicolons here,
    # at the server's own boundary — scripts/build-llama.sh stays untouched. Plain numbers,
    # native, and semicolon lists pass through unchanged.
    export CUDA_ARCHS="$(printf %s "${CUDA_ARCHS:-native}" | tr ',' ';')"; \
    # The fetches inside scripts/build-ffmpeg.sh / build-llama.sh are single-attempt curls.
    # Build hosts behind a flaky resolver (timeouts, SERVFAIL cascades on AAAA) can stall one
    # query for seconds and fail the whole build; these scripts are stamped and idempotent,
    # so a bounded retry (3 attempts, 30 s apart) costs nothing on healthy networks and
    # survives a resolver hiccup. CI's first attempt lands on its stamp the same way.
    tries=0; until scripts/build-ffmpeg.sh; do tries=$((tries+1)); [ "$tries" -ge 3 ] && exit 1; \
      echo "build-ffmpeg: attempt $tries failed; retrying in 30 s"; sleep 30; done; \
    tries=0; until scripts/build-llama.sh; do tries=$((tries+1)); [ "$tries" -ge 3 ] && exit 1; \
      echo "build-llama: attempt $tries failed; retrying in 30 s"; sleep 30; done; \
    export PATH="/src/Vendor/ffmpeg/bin:$PATH"; \
    swift build -c release; \
    if [ "${SWIFT_TESTS}" = 1 ]; then swift test; else echo "SWIFT_TESTS=${SWIFT_TESTS}: engine swift test skipped (the contract suite is the server's gate)"; fi

# The CLI, verified in the build stage. Vendor is mounted here too: the binary's rpath points
# at Vendor/pdfium/lib and Vendor/llama/lib, so a check without them would say nothing.
RUN --mount=type=cache,target=/src/.build --mount=type=cache,target=/src/Vendor \
    export PATH="/src/Vendor/ffmpeg/bin:$PATH"; \
    .build/release/digup --help > /dev/null; \
    .build/release/digup --help | sed -n '2p;3p'

# The launch-ready payload: the CLI linked with the Swift standard library (the shape
# scripts/package-linux.sh ships, so no Swift libraries go into the runtime image) plus the
# native libraries it asks for, all finding each other beside themselves ($ORIGIN).
FROM engine-builder AS engine-payload
# bash, not /bin/sh: the link line uses a bash array, exactly as scripts/package-linux.sh does.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN --mount=type=cache,target=/src/Vendor \
    --mount=type=cache,target=/src/.build/static \
    set -euxo pipefail; \
    late=(); \
    for library in _CFURLSessionInterface curl CoreFoundation _FoundationICU FoundationEssentials \
        FoundationInternationalization _FoundationCShims _FoundationCollections swiftSynchronization \
        swift_Concurrency swift_StringProcessing swift_RegexParser swiftDispatch dispatch \
        BlocksRuntime swiftCore; do late+=(-Xlinker "-l$library"); done; \
    swift build -c release --product digup --static-swift-stdlib --scratch-path /src/.build/static \
      "${late[@]}"; \
    mkdir -p /out; \
    cp /src/.build/static/release/digup /src/Vendor/pdfium/lib/libpdfium.so \
       /src/Vendor/ffmpeg/bin/ffmpeg /src/Vendor/ffmpeg/bin/ffprobe /out/; \
    for file in /src/Vendor/llama/lib/*.so*; do \
      name=${file##*/}; \
      case "$name" in \
        *.so.[0-9]*) [ -L "$file" ] && cp -L "$file" "/out/$name" ;; \
        *.so) [ ! -L "$file" ] && cp "$file" "/out/" ;; \
      esac; \
    done; \
    for file in /out/digup /out/*.so*; do patchelf --set-rpath '$ORIGIN' "$file"; done; \
    PATH="/out:$PATH" /out/digup --help | sed -n '2p'

# ── Runtime: the server image's base. No Swift, no compiler, no desktop stack. ───────────────
FROM ${BASE_IMAGE} AS engine-runtime

RUN apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends \
    ca-certificates libcurl4 libgomp1 libstdc++6 tzdata \
    && rm -rf /var/lib/apt/lists/*

COPY --from=engine-payload /out/ /opt/digup/
# ffmpeg and ffprobe are in /opt/digup and on PATH: that is how the engine finds them
# (`executable("ffmpeg")` looks on PATH, nothing else).
ENV PATH=/opt/digup:$PATH

# The engine runs headlessly as its own user; nothing here is a desktop, a display server, or a
# service manager, and no Swift toolchain is installed. No /data/locks: the writer lock is
# beside the index (`<index>/.digup-server.writer.lock`, engine/index.py), not a folder.
RUN useradd --system --create-home --uid 990 digup \
    && mkdir -p /data/index /data/models /data/config \
    && chown -R digup:digup /data \
    && digup --help > /dev/null \
    && digup --help | sed -n '2p'

USER digup
WORKDIR /data

# ── Test harness (dev): the engine payload + the Python adapter + the contract tests ─────────
# python:3.12-slim — measured in the built image: Debian 13 (trixie), glibc 2.41. The payload
# is built on Ubuntu 22.04 (glibc 2.35), so the image runs NEWER glibc than the payload was
# compiled against — forward, never back. The same payload, the same CLI: the contract tests
# prove the *shipped* binaries, so a passing suite is a statement about the runtime image,
# not about a dev box. Runs as root: mounts arrive from the host and the scratch indexes are
# the tests' own.
FROM python:3.12-slim AS server-test

RUN apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends \
    libcurl4 libgomp1 tini \
    && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir uv

COPY --from=engine-payload /out/ /opt/digup/
COPY server /srv/server
# The built UI (the mount serves server/ui/dist; api.py): a dist that exists is what makes
# the suite's page fetches real bytes, not skips.
COPY --from=frontend-builder /build/dist /srv/server/ui/dist
WORKDIR /srv/server
ENV PATH=/opt/digup:$PATH
ENV DIGUP_BIN=digup \
    DIGUP_SERVER_CORPUS=/corpus \
    DIGUP_SERVER_CORPUS_ROOT=/corpus-root \
    DIGUP_SERVER_MODELS=/models \
    DIGUP_SERVER_INDEX=/index
RUN uv sync --frozen

# Mounts at run time: /corpus (the corpus media), /corpus-root (the corpus folder, the
# skipped files), /models (the verified model files), /index (a writable index folder; the
# first run fills it with `digup index`).
#
# tini here is not ceremony: the suite's app spawns `search-service` as a child of the test
# process, and ParentWatch ends a helper whose parent's parent is PID 1 ("the app is gone").
# Plain `docker run` makes pytest PID 1, so every helper died at once with `exit 0, no
# stderr` — measured. With tini as PID 1 the test process is a live parent, exactly the
# production shape, and the suite needs no `--init` flag to be correct.
ENTRYPOINT ["tini", "--"]
CMD ["uv", "run", "pytest"]

# ── Server runtime: the shipping image ──────────────────────────────────────────────────
# Engine payload + API + UI. No Swift, no compiler, no dev deps, no Tauri, no desktop
# stack. python:3.12-slim — measured: Debian 13 (trixie), glibc 2.41, newer than the
# payload's build glibc 2.35 (Ubuntu 22.04) — forward, never back. tini as PID 1, non-root
# user. The supervision chain (reconnaissance §15 item 8):
# tini (PID 1) → uvicorn → helpers; a helper's parent is uvicorn (never PID 1, so
# ParentWatch accepts it), and when uvicorn dies the helpers reparent to PID 1 and end —
# a stopped API takes its whole process tree with it, which is the point of the mechanism.
FROM python:3.12-slim AS server-runtime

RUN apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends \
    ca-certificates libcurl4 libgomp1 tzdata tini \
    && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir uv

COPY --from=engine-payload /out/ /opt/digup/
ENV PATH=/opt/digup:$PATH
COPY server /srv/server
COPY server/docker/healthcheck.py /opt/digup/healthcheck.py
# The built UI: FastAPI serves /srv/server/ui/dist at `/` — static files only, no Node
# in this image (the frontend-builder stage is where the build happened).
COPY --from=frontend-builder /build/dist /srv/server/ui/dist
WORKDIR /srv/server
RUN uv sync --frozen --no-dev

# The same engine user as the engine-runtime stage (uid 990); /data is README §5's layout
# (index/, models/, config/) — bind-mounted volumes, owned by the server user. The writer
# lock lives beside the index (`<index>/.digup-server.writer.lock`), not in a data folder.
# `digup --help` proves the CLI runs headless in this image; §3's full acceptance — the
# CLI answering status and searches from the mounted folders — is proven by CI's boot step
# and the proof battery, which run against a live index, not from an empty image.
RUN useradd --system --create-home --uid 990 digup \
    && mkdir -p /data/index /data/models /data/config \
    && chown -R digup:digup /data /srv/server \
    && digup --help > /dev/null \
    && /srv/server/.venv/bin/python -c "import fastapi, uvicorn, digup_server.api" \
    && ! /srv/server/.venv/bin/python /opt/digup/healthcheck.py

ENV PATH=/srv/server/.venv/bin:$PATH \
    PYTHONPATH=/srv/server \
    DIGUP_SERVER_INDEX=/data/index \
    DIGUP_SERVER_ROOTS=/media/photos \
    DIGUP_SERVER_MODELS=/data/models \
    DIGUP_SERVER_CONFIG=/data/config
# Host and port are NOT env here: the CMD below binds them (DIGUP_SERVER_HOST/PORT feed
# `python -m digup_server.api`, the bare-metal entry — uvicorn's own args win in a container).

USER digup
WORKDIR /data
EXPOSE 8787

# SIGTERM (docker stop): tini forwards it to uvicorn, whose lifespan shutdown marks a
# running job *interrupted* (the truthful state) and quit()s every helper. The healthcheck
# asks the API's own /health — a healthy container is one whose engine answers. 503 counts
# as alive: /health answers 503 while the searcher is respawning (a refused search, the
# engine's own words) — that is the server honestly saying "not right now", not a sick
# container, and docker must not restart a live server over it. urlopen raises HTTPError
# on 503, so it is caught, not propagated.
HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
    CMD python /opt/digup/healthcheck.py

ENTRYPOINT ["tini", "--"]
CMD ["uvicorn", "--factory", "digup_server.api:app_factory", "--host", "0.0.0.0", "--port", "8787"]

# ── Server runtime WITH the CUDA backend (Stage 9 — built only on the box that has the card) ──
# The same server-runtime plus exactly the CUDA runtime libraries `ldd` of libggml-cuda.so
# asks for, shipped beside the payload (its rpath `$ORIGIN` resolves them). `libcuda.so.1`
# stays unresolved by design: it comes from the HOST driver through the NVIDIA Container
# Toolkit (docs/implementation/gpu-handoff.md). Two matching build-args (the devel base that
# builds the backend, the runtime base whose libraries ship), target this stage:
#
#   docker build --target server-runtime-cuda \
#     --build-arg BASE_IMAGE=nvidia/cuda:11.8.0-devel-ubuntu22.04 \
#     --build-arg CUDA_RUNTIME_IMAGE=nvidia/cuda:11.8.0-runtime-ubuntu22.04 \
#     --build-arg CUDA_ARCHS=61 …        # plain number, or a fat list `61,70,…`: the builder's
#                                        # apt cmake 3.22.1 rejects dotted 6.1 and native alike
#                                        # (measured 2026-11-04); commas are normalized to
#                                        # CMake's semicolons in the engine-builder RUN
#                                        # (measured 2026-11-05, publish run #6)
#
# The `cuda-libs` stage is pulled only by this target: CPU builds (target server-runtime)
# prune it and never touch a CUDA image. The ldd gate below fails the build if a shipped
# library does not resolve — ship exactly these, from a CUDA *runtime* base, never the
# toolkit, never a second copy of libggml*.
FROM ${CUDA_RUNTIME_IMAGE} AS cuda-libs
# Copy by glob, never by hand-typed filenames: the CUDA 11.8 runtime image ships exactly the
# SONAMEs ggml-cuda asks for — libcublas.so.11 -> libcublas.so.11.11.3.6, libcublasLt.so.11 ->
# libcublasLt.so.11.11.3.6, libcudart.so.11.0 -> libcudart.so.11.8.89, libnvrtc.so.11.2 and
# libnvrtc-builtins.so.11.8 -> their .so.11.8.89 (measured on this box 2026-11-04, from
# nvidia/cuda:11.8.0-runtime-ubuntu22.04). The dotted names (libcublasLt.so.11.8, …) belong to
# the -dev packages and are NOT in a runtime base: a COPY of them dies with "not found" —
# measured. `cp -a` carries each symlink together with its target, and the glob travels with
# the CUDA version, so the stage needs no retyping when the base moves.
RUN set -eux; \
    dir=""; \
    for base in /usr/local/cuda /usr/local/cuda-*; do \
      for target in "$base"/targets/*/lib; do [ -d "$target" ] && { dir="$target"; break; }; done; \
      [ -n "$dir" ] && break; \
    done; \
    test -n "$dir"; \
    mkdir -p /out; \
    for lib in cudart cublas cublasLt nvrtc nvrtc-builtins; do cp -a "$dir/lib${lib}.so"* /out/; done; \
    # libnccl.so.2 (measured in the 11.8 runtime base as /usr/lib/x86_64-linux-gnu/libnccl.so.2
    # -> 2.15.5, 268 M, package libnccl2 …+cuda11.8 — outside the targets dir): libggml-cuda
    # links it (multi-GPU comms), ldd asks for it, so the ldd gate below needs it. A single
    # GPU never calls nccl, but an unresolved DT_NEEDED fails the load.
    nccl_found=""; \
    for loc in "$dir" "/usr/lib/$(uname -m)-linux-gnu" /usr/lib/x86_64-linux-gnu; do \
      if [ -e "$loc/libnccl.so.2" ]; then cp -a "$loc"/libnccl.so* /out/ && nccl_found=1 && break; fi; \
    done; \
    test -n "$nccl_found"

FROM server-runtime AS server-runtime-cuda
COPY --from=cuda-libs /out/ /opt/digup/
RUN ldd /opt/digup/libggml-cuda.so \
    && ! ldd /opt/digup/libggml-cuda.so | grep 'not found' | grep -v 'libcuda.so.1'
