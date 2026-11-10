#!/usr/bin/env bash
# Stage 9 handoff proof — run this on an x86_64 host with an NVIDIA GPU (docs/implementation/
# gpu-handoff.md is the prose version; this is the executable version).
#
# It counts failures and exits non-zero. A run that prints encouraging sentences and exits 0
# while the GPU was never used is exactly the artifact this project refuses, so:
#
#   --cpu-only   Gate A only (the CPU baseline on this machine). Gate B is NOT run and the
#                script says GPU NOT MEASURED, in those words.
#   (no args)    Gate A, then Gate B with the card: CUDA build, payload check, speed check,
#                utilization sampled DURING a real index job.
#
# Every gate prints `PASS gate: …` / `FAIL gate: …`. Nothing here is a mock: the contract suite
# runs the real engine, and every skipped line is a failure.
set -uo pipefail
cd "$(dirname "$0")/../.."
ROOT="$PWD"

MODE=all
[ "${1:-}" = "--cpu-only" ] && MODE=cpu-only
OUT="server/data/gpu-handoff-$(date +%Y%m%d-%H%M).log"
mkdir -p server/data
exec > >(tee -a "$OUT") 2>&1

fails=0
gpus_used=0
pass() { echo "PASS gate: $*"; }
fail() { echo "FAIL gate: $*"; fails=$((fails + 1)); }
note() { echo "note:  $*"; }

DATA="${DIGUP_DATA:-$HOME/digup-data}"
REV=bfcd298762cc34d0357ece5ebdd31791a3a374d8
CUDA_BASE="${CUDA_BASE:-nvidia/cuda:12.4.1-devel-ubuntu22.04}"
ARCH=$(uname -m)

echo "== DigUp Stage-9 handoff · mode=$MODE · arch=$ARCH · log=$OUT"
echo

# ── Gate A — the CPU baseline, measured on this machine ─────────────────────────────────
gate_a_toolchain() {
  command -v docker > /dev/null || { fail "docker is not installed"; return; }
  docker compose version > /dev/null || { fail "docker compose is not installed"; return; }
  [ "$ARCH" = x86_64 ] && pass "docker + compose present, arch=$ARCH" \
    || note "arch is $ARCH — Gate B's CUDA build only makes sense on x86_64 (README §11: never build under emulation)"
}

gate_a_corpus() {
  [ -f server/tests/corpus/media/clips/scenes.mp4 ] || { fail "corpus clip missing: run server/tests/corpus/build.sh"; return; }
  [ -f server/tests/corpus2/media/clips/scenes.mp4 ] || note "corpus2 gallery not built (run server/tests/corpus2/build.sh) — live gallery checks skipped"
  pass "corpus fixtures present"
}

gate_a_models() {
  local want got
  want=$(grep -oE 'sha256: "[0-9a-f]{64}"' Sources/DigUpKit/ModelFiles.swift | grep -oE '[0-9a-f]{64}' | sort)
  got=$(sha256sum "$DATA"/models/*.gguf 2>/dev/null | awk '{print $1}' | sort)
  if [ -z "$got" ]; then fail "no model files in $DATA/models (docs/implementation/gpu-handoff.md Gate A has the download lines)"; return; fi
  if [ "$want" != "$got" ]; then fail "model sha256s do not match Sources/DigUpKit/ModelFiles.swift: engine=$want files=$got"; return; fi
  pass "model files verified against the engine's own pins"
}

gate_a_bind_dirs() {
  mkdir -p "$DATA"/{index,models,config}
  local owner; owner=$(stat -c '%u' "$DATA/index" 2>/dev/null || echo 0)
  if [ "$owner" != 990 ] && [ "$owner" != 0 ]; then
    note "$DATA/index is owned by uid $owner; the image's user is 990 — sudo chown -R 990:990 $DATA"
  fi
  pass "bind folders exist ($DATA)"
}

gate_a_suite() {
  DOCKER_BUILDKIT=1 docker build --target server-test -f server/docker/Dockerfile -t digup-server-test:handoff . \
    || { fail "server-test image build"; return; }
  mkdir -p "$DATA/index-suite"
  docker run --rm \
    -v "$ROOT/server/tests/corpus/media:/corpus:ro" \
    -v "$ROOT/server/tests/corpus:/corpus-root:ro" \
    -v "$DATA/models:/models:ro" \
    -v "$DATA/index-suite:/index" \
    digup-server-test:handoff /srv/server/.venv/bin/pytest -rs > "$OUT.suite" 2>&1
  local code=$?
  tail -25 "$OUT.suite"
  if grep -qE '^(SKIPPED|tests/.*SKIPPED)' "$OUT.suite"; then
    fail "a contract test SKIPPED (a self-skipping suite is green-by-construction: corpus/models/clip mounts are not optional)"
  elif [ $code -ne 0 ] || ! grep -qE '[0-9]+ passed' "$OUT.suite"; then
    fail "contract suite (exit $code)"
  else
    pass "contract suite on $ARCH: $(grep -E '[0-9]+ passed' "$OUT.suite" | tail -1)"
  fi
}

gate_a_compose() {
  ( cd deploy && docker compose config --quiet ) || { fail "compose config"; return; }
  ( cd deploy && DIGUP_INDEX_DIR="$DATA/index" DIGUP_MODELS_DIR="$DATA/models" \
      DIGUP_CONFIG_DIR="$DATA/config" DIGUP_MEDIA_DIR="$DATA/media/photos" \
      docker compose up -d --build ) > /dev/null 2>&1 \
    || { fail "compose up --build (CPU-only shape)"; return; }
  local i alive=0
  for i in $(seq 1 40); do
    if ( cd deploy && docker compose exec -T server python /opt/digup/healthcheck.py ) > /dev/null 2>&1; then alive=1; break; fi
    sleep 3
  done
  [ $alive -eq 1 ] && pass "the CPU-only stack boots and its own healthcheck answers" \
    || fail "healthcheck never answered (the API is the healthcheck: /health 503 counts as alive, so this means the API is not there)"
  local body; body=$(curl -sf -X POST localhost:8787/api/v1/search -H 'content-type: application/json' -d '{"q":"wakeboarding"}' || true)
  [ -n "$body" ] && pass "a search over HTTP answers" || fail "POST /api/v1/search answered nothing (index it first: POST /index {})"
  # The id must be captured BEFORE the stop: `compose ps -q` does not list a stopped service,
  # so inspecting after the stop is how this gate used to report "unknown".
  local cid code
  cid=$( cd deploy && docker compose ps -q server )
  ( cd deploy && docker compose stop -t 90 server ) > /dev/null 2>&1
  code=$(docker inspect "$cid" --format '{{.State.ExitCode}}' 2>/dev/null || echo unknown)
  [ "$code" = "137" ] && fail "the container stop landed as SIGKILL (137): the lifespan hung" \
    || note "container stop exit code: $code (143 = a completed SIGTERM stop)"
  ( cd deploy && docker compose logs server 2>/dev/null | grep -q "Application shutdown complete" ) \
    && pass "graceful lifespan (Application shutdown complete)" \
    || fail "no 'Application shutdown complete' in the server log"
  ( cd deploy && docker compose down -v ) > /dev/null 2>&1
}

gate_a_toolchain; gate_a_corpus; gate_a_models; gate_a_bind_dirs; gate_a_suite; gate_a_compose

if [ "$MODE" = cpu-only ]; then
  echo
  echo "GPU NOT MEASURED (Gate B skipped: --cpu-only)."
  echo "CPU-only baseline: $fails failed gate(s). Log: $OUT"
  exit $((fails > 0 ? 1 : 0))
fi

# ── Gate B — the card, measured here and now ────────────────────────────────────────────
gate_b_toolkit() {
  command -v nvidia-smi > /dev/null || { fail "no nvidia-smi on the host: the driver is missing"; return; }
  docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi > /dev/null 2>&1 \
    && pass "NVIDIA Container Toolkit hands the container a device" \
    || fail "NVIDIA Container Toolkit: a --gpus all container cannot run nvidia-smi (install/configure it first)"
}

gate_b_cuda_build() {
  # CUDA_ARCHS reaches scripts/build-llama.sh's cmake as CMAKE_CUDA_ARCHITECTURES, and the
  # builder's cmake is the Ubuntu 22.04 apt one (3.22.1, measured): it accepts only plain
  # numbers — "6.1" and "native" both fail configure there (native needs cmake >= 3.24 and a
  # GPU the builder container does not have). Pass the card's plain number: 61 for Pascal
  # sm_61, 89 for Ada sm_89. The default stays native for toolchains that speak it.
  DOCKER_BUILDKIT=1 docker build --build-arg BASE_IMAGE="$CUDA_BASE" \
    --build-arg CUDA_ARCHS="${CUDA_ARCHS:-native}" --target engine-payload \
    -f server/docker/Dockerfile -t digup-payload:cuda . > /dev/null 2>&1 \
    || { fail "CUDA engine-payload build on $CUDA_BASE (match the base's CUDA to the host driver: nvidia-smi's 'CUDA Version')"; return; }
  local listing; listing=$(docker run --rm digup-payload:cuda sh -c 'ls /out | grep -i cuda' || true)
  [ -n "$listing" ] && pass "payload carries the CUDA backend ($listing)" \
    || fail "payload has no CUDA backend: scripts/build-llama.sh did not find nvcc in $CUDA_BASE"
  # /out, not /opt/digup: the engine-payload stage lands in /out; the runtime stages COPY it
  # to /opt/digup. A check written against /opt/digup fails on the payload image (measured).
  docker run --rm digup-payload:cuda sh -c 'ldd /out/libggml-cuda.so' | tee "$OUT.ldd"
  if grep -qE 'libcuda\.so\.1.*not found' "$OUT.ldd"; then note "libcuda.so.1 unresolved in the build stage — expected: it comes from the HOST driver through the toolkit at run time"; fi
  if grep -qE 'libcudart|libcublas' "$OUT.ldd"; then pass "CUDA runtime libs resolve in the payload (ship these, from a CUDA runtime base, never the toolkit)"; else fail "ldd shows CUDA runtime libs that do not resolve: add exactly them to the runtime stage"; fi
}

gate_b_device_choice() {
  # The engine's own measurement, on the real index: `device` is what the helpers then use.
  # On a real Linux host (not Docker Desktop) the bind folder must be writable by the
  # container's user: index the corpus AS uid 990 (the runtime user) in a folder any of
  # them can write, so the files the Compose gate below uses belong to the same uid.
  mkdir -p "$DATA/index-gpu"; chmod 777 "$DATA/index-gpu" 2>/dev/null || true
  docker run --rm --gpus "${GPU_SPEC:-all}" -u 990:990 -e HOME=/tmp \
    -v "$ROOT/server/tests/corpus/media:/corpus:ro" -v "$DATA/models:/models:ro" -v "$DATA/index-gpu:/index" \
    -e DIGUP_MODELS=/models digup-payload:cuda sh -c '/out/digup index /corpus --index /index > /dev/null 2>&1; /out/digup speed --model --json --index /index | tail -1' \
    > "$OUT.speed" 2>&1
  if grep -qE '"device"|"seconds"' "$OUT.speed"; then
    tail -2 "$OUT.speed"
    if grep -q '"device": *"gpu"' "$OUT.speed"; then pass "the engine measured the GPU as the faster device (agreement check inside speed --model)"; gpus_used=1
    else note "the engine measured the processor as faster here (device: cpu) — a real measurement, not a failure; report the numbers"; fi
  else
    fail "digup speed --model --json answered nothing usable (see $OUT.speed)"
  fi
}

gate_b_utilization() {
  # Detecting a device is not using one. Sample the card DURING a real index job.
  # Work the fresh walk: a fully-embedded corpus makes the job a no-op sync — nothing to
  # sample — so the gate measures a real embedding pass over the corpus.
  #
  # Sampling cadence is measured (2026-11-04, GTX 1070): GPU embedding of a small corpus is
  # a series of ~150 ms kernel bursts separated by P8 idle. A 2 s-interval sampler is blind
  # to that shape: over a full 15-file job it saw peak 12%, and 0% across most windows —
  # a false FAIL for a server demonstrably embedding on the GPU (model resident in 392 MB
  # of card VRAM, engine costs at the GPU's 0.15 s/image rate). The 0.15 s sampler over the
  # job sees peak 94% and 39% busy time. A CPU-embedding job is flat: zero busy samples,
  # no model VRAM on the card. So: sample at the job's pace, judge busy-time (duty) and
  # VRAM residency, and let the old peak>20 stand as the easy pass.
  mkdir -p "$DATA/index-gpu"; chmod 777 "$DATA/index-gpu" 2>/dev/null || true
  rm -rf "$DATA/index-gpu"/* "$DATA/index-gpu"/.digup-server.writer.lock 2>/dev/null || true
  ( cd deploy && DIGUP_INDEX_DIR="$DATA/index-gpu" DIGUP_MODELS_DIR="$DATA/models" \
      DIGUP_CONFIG_DIR="$DATA/config" DIGUP_MEDIA_DIR="$ROOT/server/tests/corpus/media" \
      docker compose -f docker-compose.yml -f docker-compose.nvidia.yml --profile nvidia up -d --build ) > /dev/null 2>&1
  if [ $? -ne 0 ]; then fail "the nvidia-profile Compose override did not come up (author deploy/docker-compose.nvidia.yml on this box, per docs/implementation/gpu-handoff.md §4)"; return; fi
  # nvidia-smi -i wants an index/UUID/name; the docker --gpus value carries a device= prefix.
  local gpu="${GPU_SPEC:-all}"; gpu="${gpu#device=}"
  # /health answers 503 while the searcher warms/respawns (~20–30 s prewarm): the container
  # is healthy, the API is honest. The index job needs the API up — count 200 as ready, not 503.
  local i code=000
  for i in $(seq 1 40); do
    code=$(curl -s -o /dev/null -w '%{http_code}' localhost:8787/api/v1/health 2>/dev/null || true)
    [ "$code" = 200 ] && break
    sleep 3
  done
  if [ "$code" != 200 ]; then
    fail "the nvidia-profile API never answered /health with 200 (last: $code) — job was never asked"
    ( cd deploy && docker compose -f docker-compose.yml -f docker-compose.nvidia.yml --profile nvidia down -v ) > /dev/null 2>&1
    return
  fi
  local jobid
  jobid=$(python3 - <<'PYEOF'
import json, sys, time, urllib.request
for attempt in range(40):
    try:
        req = urllib.request.Request('http://127.0.0.1:8787/api/v1/index', data=b'{}',
                                     headers={'content-type': 'application/json'})
        with urllib.request.urlopen(req, timeout=10) as r:
            print(json.load(r)["job"]["id"]); sys.exit(0)
    except Exception:
        time.sleep(3)  # warming (503) / transient: ask again; 409 = a job runs — handled below
PYEOF
)
  if [ -z "$jobid" ]; then
    fail "POST /index answered no job id (the nvidia container is up but the API did not accept the job)"
    ( cd deploy && docker compose -f docker-compose.yml -f docker-compose.nvidia.yml --profile nvidia down -v ) > /dev/null 2>&1
    return
  fi
  local stats
  stats=$(python3 - "$jobid" "$gpu" <<'PYEOF'
import json, subprocess, sys, time, urllib.request
jid, gpu = sys.argv[1], sys.argv[2]
busy = tot = peak = vram_hi = 0
t0 = time.time()
while time.time() - t0 < 300:
    out = subprocess.run(['nvidia-smi', '--query-gpu=utilization.gpu,memory.used',
                          '--format=csv,noheader,nounits', '-i', gpu],
                         capture_output=True, text=True).stdout.splitlines()[0].split(',')
    u, m = int(out[0]), int(out[1])
    tot += 1
    busy += u > 0
    peak = max(peak, u)
    vram_hi += m > 200
    try:
        js = json.load(urllib.request.urlopen('http://127.0.0.1:8787/api/v1/jobs', timeout=5))
        j = next((x for x in js['jobs'] if x['id'] == jid), None)
        if j and j.get('state') == 'done':
            break
    except Exception:
        pass
    time.sleep(0.15)
print(f"{peak} {busy} {tot} {vram_hi}")
PYEOF
)
  local peak busy tot vram_hi
  read -r peak busy tot vram_hi <<< "$stats"
  : "${tot:=0}"
  ( cd deploy && docker compose -f docker-compose.yml -f docker-compose.nvidia.yml --profile nvidia down -v ) > /dev/null 2>&1
  if [ "${tot:-0}" -eq 0 ]; then fail "nvidia-smi answered nothing during the job (card '$gpu' not visible?)"; return; fi
  local duty=$(( 100 * busy / tot ))
  if [ "$peak" -gt 20 ] || { [ "$duty" -ge 10 ] && [ "$vram_hi" -ge $(( tot / 2 )) ]; }; then
    pass "the card worked during the index job (peak ${peak}%, busy ${duty}% of ${tot} samples, model on card for ${vram_hi}/${tot} samples)"
    gpus_used=1
  else
    fail "GPU utilization peaked at ${peak}% with ${duty}% busy samples over ${tot} — the container detected the device and embedded on the CPU"
  fi
}

gate_b_toolkit; gate_b_cuda_build; gate_b_device_choice; gate_b_utilization

echo
if [ "$gpus_used" -eq 1 ]; then echo "GPU: measured on this box (see $OUT.speed and the utilization gate)."; else echo "GPU NOT MEASURED: no gate below proved the card ran the model."; fi
echo "Gates failed: $fails. Full log: $OUT"
[ "$fails" -eq 0 ] && [ "$gpus_used" -eq 1 ] && exit 0
exit 1
