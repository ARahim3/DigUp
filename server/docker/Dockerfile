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

# ── Toolchain, vendor libraries, llama.cpp, ffmpeg, the CLI, the tests ───────────────────────
FROM ${BASE_IMAGE} AS engine-builder

ARG SWIFT_VERSION
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
    scripts/build-ffmpeg.sh; \
    scripts/build-llama.sh; \
    export PATH="/src/Vendor/ffmpeg/bin:$PATH"; \
    swift build -c release; \
    swift test

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
