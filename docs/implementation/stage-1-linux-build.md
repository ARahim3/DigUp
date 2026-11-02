# Stage 1 — the original DigUp CLI, built and tested for Linux

Date: 2026-11-02. Built in a Linux container on this machine (arm64), from the repository's own
scripts, with the pinned versions the repository pins. Stage 2 is complete: the headless index +
semantic-search proof on the corpus is documented in [stage-2-headless-proof.md](stage-2-headless-proof.md).

## What was built

| part | result |
|---|---|
| Swift toolchain | `swift-6.4.0-RELEASE-ubuntu22.04-aarch64`, GPG-verified in the image build (`Good signature from "Swift 6.x Release Signing Key"`) |
| base image | `ubuntu:22.04` — the same base upstream's Linux CI builds in, so binaries ask for glibc ≤ 2.35 |
| vendor libraries | `scripts/fetch-vendor.sh`: SQLite 3.54.0 (FTS5), stb @ `2c980bb`, miniz 3.1.2, PDFium `chromium/8086` (`pdfium-linux-arm64`) — every download verified against `scripts/vendor-checksums.json` |
| ffmpeg | `scripts/build-ffmpeg.sh`: dav1d 1.5.2 + ffmpeg 9.0.2, 8.9 MB binaries (HEIC-capable, which the picture reader needs) |
| llama.cpp | `Built llama.cpp b11461 (patched, cpu, clang) into Vendor/llama` — shared libraries, `GGML_BACKEND_DL=ON`, `GGML_CPU_ALL_VARIANTS=ON`, `GGML_NATIVE=OFF`, mtmd on |
| compiler | Ubuntu 22.04's stock `cc` (gcc 12) does **not** accept `-march=armv9.2-a+sme`; `clang` (clang 14) does, so the build set `CC=clang CXX=clang++` and the arm64 CPU variants (SME included) built |
| engine build | `swift build -c release` — succeeded |
| **tests** | **`swift test` on Linux: 116 tests in 16 suites passed (`DigUpKitTests`) and 7 tests in 2 suites passed (`LlamaRuntimeTests`), 0 failures.** `vectorsMatchTheReference()` skipped itself: the model files are not in the build image by design (exactly what upstream's CI comment describes) |
| build time | 256 s for vendor + ffmpeg + llama.cpp + `swift build -c release` + `swift test` on 7 cores (BuildKit cache mounts on `Vendor/` and `.build/`) |

## Commands

```sh
# build (arm64, native: the image's architecture is the host's)
docker builder prune -f; docker container prune -f; docker image prune -f
DOCKER_BUILDKIT=1 docker build --platform linux/arm64 --target engine-builder \
  -f server/docker/Dockerfile -t digup-builder:local .
DOCKER_BUILDKIT=1 docker build --platform linux/arm64 --target engine-runtime \
  -f server/docker/Dockerfile -t digup-engine:local .

# inside the build container
docker run --rm -w /src digup-builder:local bash -c \
  'export PATH=/src/Vendor/ffmpeg/bin:$PATH; .build/release/digup --help; swift --version'
```

The image is a three-stage build (`engine-builder` → `engine-payload` → `engine-runtime`):
Swift, CMake, compilers and headers exist only in the builder; the runtime image carries
`digup`, llama.cpp's shared libraries, `libpdfium.so`, `ffmpeg`, `ffprobe`, `libcurl4`,
`libgomp1`, `libstdc++6` — no compiler, no Swift toolchain, no Tauri, no GTK/WebKit, no display
server, running as the `digup` user. `engine-payload` links the CLI the way
`scripts/package-linux.sh` does (`--static-swift-stdlib` plus Swift's archives re-listed at the
end of the link line) and re-points every rpath at `$ORIGIN`.

## The runtime image, verified

`digup-engine:local` — **296 MB**, `engine-runtime` stage, non-root user `digup` (uid 990):

```
$ docker run --rm digup-engine:local bash -c 'id; ls /opt/digup; digup --help; command -v ffmpeg; ffmpeg -version | head -1'
uid=990(digup) gid=990(digup) groups=990(digup)
/opt/digup: digup  ffmpeg  ffprobe  libpdfium.so  libllama.so.0  libmtmd.so.0  libggml.so.0
            libggml-base.so.0  libggml-cpu-armv8.0_1.so  libggml-cpu-armv8.2_1.so
            libggml-cpu-armv8.2_2.so  libggml-cpu-armv8.2_3.so  libggml-cpu-armv8.6_1.so
            libggml-cpu-armv8.6_2.so  libggml-cpu-armv9.2_1.so  libggml-cpu-armv9.2_2.so
digup --help → prints the engine's own usage (the CLI runs with no Swift toolchain installed)
/opt/digup/ffmpeg  →  ffmpeg version 9.0.2
```

Same payload shape as upstream's `.deb` helper folder (reconnaissance §11), minus Vulkan (this
is the CPU baseline), minus the shell. The apt deps are `libcurl4 libgomp1 libstdc++6` only.
A container run with `-v …/index:/index` writes `index.sqlite` to the host mount as uid 990
(verified with a touch test), which is how the server's `/data` volume will work.

## Model files, verified against the repository's pins

Downloaded to `~/Projects/digup-data/models` (outside the repository) from
`ggml-org/embeddinggemma-2-GGUF` at the pinned revision
`bfcd298762cc34d0357ece5ebdd31791a3a374d8`:

```
embeddinggemma-2-Q8_0.gguf    309,855,456 B  2188ac1d…b09135  OK
mmproj-embeddinggemma-2-Q8_0.gguf  554,821,024 B  c4a8a526…0aab64f  OK
```

Both match the SHA-256 pins in `Sources/DigUpKit/ModelFiles.swift` (`shasum -a 256 -c`: `OK`).

## Corpus for Stage 2

`server/tests/corpus/` — 12 Commons pictures committed with pinned sha256 + attribution
(licenses: CC BY-SA 4.0 / CC BY 4.0 / CC BY 2.0 / Attribution / Public domain), two real videos
fetched on demand (`wakeboarding-vienna.webm` 59 MB, `pct-hiking-southern-oregon.webm` 33 MB),
`build.sh` (fetches and verifies every pin), and `corpus.json` — the ground truth in the
`evals/` file format, covering wakeboarding, hiking, campfire, dog-on-the-beach, boat-at-sunset,
fishing-from-a-dock, Christmas dinner, the three control pictures, the two real videos, and three
timestamp assertions on a synthetic 3-scene clip (`clips/scenes.mp4@0-6`, `@6-12`, `@12-18`;
sha256 `528db370…45355b`, 766,733 B). All fetched files verified against their manifest pins.

One discovery: **the engine's own ffmpeg (`scripts/build-ffmpeg.sh`) is decode-only** — encoders
`mjpeg`, `ppm`, `rawvideo`, `pcm_s16le`, no `lavfi` sources, no `libx264`, no `-preset`. It is a
reader, as designed. The synthetic clip is therefore generated with a full ffmpeg (apt's, in a
throwaway `ubuntu:22.04` container); `build.sh` says so when it cannot make the clip.

## Disk

Docker's VM disk is on the volume with 43 GB free, and a build died with
`no space left on device` before pruning. After `docker builder prune -f` + `docker container
prune -f` + `docker image prune -f` (4.0 GB reclaimed, build cache 562 MB) the build completes.
`.dockerignore` keeps host build output, `Vendor/`, the corpus media and `server/data/` out of
the build context: they are host artifacts, and the corpus media is mounted at run time.

## Known, documented limits

1. This build is **arm64 CPU-only** (no Vulkan, no CUDA): it proves the Linux engine, not the
   production GPU path. `engine-runtime` deliberately installs no `libvulkan1`; the GPU path
   arrives as the opt-in NVIDIA/Vulkan override (Stage 9), where the device is chosen by
   `digup speed --model` and the agreement check (cosine ≥ 0.999), never assumed.
2. `vectorsMatchTheReference()` skips itself without the model files (upstream's own design).
   Running it needs a model-mounted test run — Stage 2 does that, which is also the first check
   that *this* build produces the project's reference vectors.
3. `swift test` builds a debug configuration in addition to the release build; keeping it in the
   builder (never in the runtime image) is what the disk cost is about.
