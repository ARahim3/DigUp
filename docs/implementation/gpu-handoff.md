# Stage 9 handoff — run it on an x86_64 host with an NVIDIA GPU

This file exists because the development machine (an arm64 Mac) has **no CUDA device and
no Vulkan device**, and building an x86_64 image under emulation is forbidden by
[README §11](README.md) ("never ship an image that was built under emulation"). So the GPU work
is *authored* here and *measured* there. Nothing in this repository claims GPU acceleration was
verified — the CPU-only path is what the contract suite, the CI workflow and
`IMPLEMENTATION_STATUS.md` measure.

Run [`../../server/tests/gpu-handoff.sh`](../../server/tests/gpu-handoff.sh) on the box. It
verifies the CPU baseline first (the thing the PR promises), then the GPU path, and writes one
log with a PASS/FAIL line per gate. Its gates count failures and exit non-zero: a script that
prints a nice sentence and exits 0 while the GPU was never used is exactly the artifact this
project refuses.

## Host prerequisites (check them, do not assume them)

```sh
uname -m                       # x86_64, and the build happens here — not copied from the Mac
docker --version && docker compose version
nvidia-smi                     # the driver, on the host
docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi   # NVIDIA Container Toolkit
```

The last line is the toolkit test. If it fails, install/configure the NVIDIA Container Toolkit
before anything else — `libcuda.so.1` and the driver's CUDA userland come from the host, and an
image cannot supply them.

## What the engine already does (reuse it, do not rebuild it)

`scripts/build-llama.sh` picks the backend by what the machine has: **CUDA when `nvcc` /
`CUDACXX` is on PATH** (`CUDA_ARCHS`, default `native`), else **Vulkan when `glslc` is present**,
else CPU — and on Linux/Windows the ggml backends are shared libraries loaded at run time
(`GGML_BACKEND_DL`). `LlamaEmbedder.loadBackends()` looks in `$DIGUP_BACKENDS`, then beside the
binary, then ggml's own search; the `engine-payload` stage copies **every**
`Vendor/llama/lib/*.so*` with `rpath=$ORIGIN`, so a CUDA-enabled builder automatically ships
`libggml-cuda.so` beside `/opt/digup/digup` — no Dockerfile change.

Device choice is **measured, never assumed**: `digup speed --model` times GPU against processor,
keeps `device` in `costs.json` beside the index, and accepts the GPU only when its vectors agree
with the processor's (cosine ≥ 0.999 — Mesa's `lavapipe` software "GPU" made 0.94–0.97 and is
rejected by this rule). The helper that loses gets `DIGUP_DEVICE=cpu`, and `DIGUP_DEVICE=cpu`
also *unloads* the GPU backend (Vulkan's setup costs seconds). `Sources/digup/ModelSpeed.swift`
and `Sources/LlamaRuntime/LlamaEmbedder.swift` are the code to read first.

## Gate A — the CPU baseline, on this box (this part must pass)

```sh
server/tests/gpu-handoff.sh --cpu-only
```

The gates, in order, each a PASS/FAIL line in the log: build the corpus fixtures
(`server/tests/corpus/build.sh`, `server/tests/corpus2/build.sh`); create
`$HOME/digup-data/{index,models,config}` owned by uid/gid 990; fetch the two pinned model files —
the URLs carry the pinned revision from `Sources/DigUpKit/ModelFiles.swift`, and the hashes must
equal the pins duplicated in `.github/workflows/server.yml`:

```sh
curl -fL -o "$HOME/digup-data/models/embeddinggemma-2-Q8_0.gguf" \
  https://huggingface.co/ggml-org/embeddinggemma-2-GGUF/resolve/bfcd298762cc34d0357ece5ebdd31791a3a374d8/embeddinggemma-2-Q8_0.gguf
curl -fL -o "$HOME/digup-data/models/mmproj-embeddinggemma-2-Q8_0.gguf" \
  https://huggingface.co/ggml-org/embeddinggemma-2-GGUF/resolve/bfcd298762cc34d0357ece5ebdd31791a3a374d8/mmproj-embeddinggemma-2-Q8_0.gguf
sha256sum "$HOME/digup-data/models"/*.gguf
```

Then build the `server-test` target **natively**; run the contract suite with the four required
mounts (corpus, corpus-root, models, index) via `/srv/server/.venv/bin/pytest -rs` — every test
RUNS and any SKIPPED line is a FAIL; then `docker compose up -d --build`, the healthcheck, a real
search, and a `docker stop` that must end the container **not** 137, with
`Application shutdown complete` last in the log. The script echoes every command it runs; read it
for the exact invocations.

Expected on x86_64: the same suite counts as CI (all green, zero skips), `/health` answering
(the engine's fingerprints, `build_tag` b11461), a search with real `z`, a 206 on a `Range`
request. If Gate A does not pass, the GPU work is not the problem — fix this first.

## Gate B — the GPU build, measured where the card is

1. **Build the builder stage with a CUDA toolchain.** The repo's builder stage is Ubuntu 22.04
   without `nvcc`; the CUDA build is a base-image decision, not a code change:
   `docker build --build-arg BASE_IMAGE=nvidia/cuda:12.4.1-devel-ubuntu22.04 --target engine-builder …`
   (pick the CUDA version that matches the host driver; check `nvidia-smi`'s "CUDA Version").
   `scripts/build-llama.sh` finds `nvcc` by itself and builds the CUDA backend;
   `CUDA_ARCHS=…` pins the architecture. Pass the card's **plain number** (measured 2026-11-04:
   the builder's cmake is Ubuntu 22.04's apt 3.22.1, which rejects dotted `6.1` **and** `native`
   alike — `native` needs cmake ≥ 3.24 *and* a GPU visible at build time, which the builder
   container never has). `61` = Pascal sm_61 (GTX 1070), `89` = Ada sm_89.
2. **Check the payload carries the backend and nothing duplicated:**
   `docker run --rm digup-payload:x86 sh -c 'ls -l /opt/digup | grep -i cuda; ldd /opt/digup/libggml-cuda.so'`
   — the CUDA runtime libs it asks for (cudart/cublas family) must resolve: ship exactly those
   from a CUDA *runtime* base, never the toolkit, never a second copy of `libggml*`.
   `libcuda.so.1` comes from the host driver through the toolkit — it must **not** be baked in.
3. **Prove it runs on the GPU, not "sees" a GPU.** The engine's own log line
   `backends: CPU, CUDA` (from `LlamaEmbedder.loadBackends`) is necessary, not sufficient:
   * `digup speed --model --json --index <index>` reports the device it measured and the
     agreement check; the record's `device` is what every helper then uses.
   * Sample the card **while indexing**: `nvidia-smi --query-gpu=utilization.gpu,memory.used \
     --format=csv,interval=1` — utilization must move during a real index job. A container that
     only *detects* the device and embeds on CPU is a failure of this gate, and it is the easy
     false positive. Sampling cadence is measured (2026-11-04, GTX 1070): a small-corpus GPU job
     is ~150 ms kernel bursts separated by P8 idle — a 2 s-interval sampler sees 0–12% on a job
     that is provably on the GPU (model resident in the card's VRAM, engine costs at the GPU's
     image rate), while a 0.15 s sampler across the job window sees peak 94% and 39% busy time.
     Judge the busy-time fraction and VRAM residency, not only the peak: a CPU-embedded job is
     flat — zero busy samples, no model VRAM on the card. (`gpu-handoff.sh` samples the job at
     0.15 s and passes on peak > 20% or ≥ 10% busy with the model on the card.)
   * Compare `speed --model` times against the CPU-only build on the same machine, same corpus,
     same `DIGUP_THREADS`. Faster *and* agreeing vectors is the pass; the engine keeps CPU when
     CPU wins (that is not a failure, it is the engine's measurement — report the numbers).
4. **The opt-in Compose shape** (to be added on this box, in `deploy/`, keeping
   `docker-compose.yml` CPU-only as the default): an override with the `nvidia` profile and the
   device request —
   ```yaml
   services:
     server:
       profiles: ["nvidia"]
       deploy:
         resources:
           reservations:
             devices:
               - driver: nvidia
                 count: 1
                 capabilities: [cuda]
   ```
   run with `docker compose -f docker-compose.yml -f docker-compose.nvidia.yml --profile nvidia up -d`,
   documented with the toolkit prerequisite, the `DIGUP_DEVICE=cpu` CPU fallback, and startup
   diagnostics that print the backend that actually ran. Validate the config with
   `docker compose config --quiet` **with and without** the profile.
5. Vulkan (the driver-free-ish path) is the same story with `glslc` + a Vulkan ICD and
   `--device /dev/dri`; measure it the same way. Keep one GPU path, not two, in the shipped
   override.

## Report back (what goes into `IMPLEMENTATION_STATUS.md`)

`uname -a` + driver version + `nvidia-smi -L`; the CUDA base image and `CUDA_ARCHS` used;
`ldd` of the CUDA backend; the `backends:` line; `speed --model --json` for CPU and GPU with
their `device` and agreement values; `nvidia-smi` utilization sampled during a job; the suite
counts (with zero skips) on x86_64; and the honest statement of what was **not** measured.
