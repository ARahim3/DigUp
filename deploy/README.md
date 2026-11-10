# DigUp server — Docker Compose deployment

The shipped compose app in one page: what each file is for, every env var it reads,
the launch chains, and the API surface. The API contract itself is
[`server/docs/API.md`](../server/docs/API.md) — this page never restates schemas, only
points at them. Live measured chronicle: [`server/IMPLEMENTATION_STATUS.md`](../server/IMPLEMENTATION_STATUS.md).

---

## 60-second standalone

```bash
cd deploy
mkdir -p data/{index,models,config,media} && sudo chown -R 990:990 data   # uid 990 = the image's user
docker compose up -d --build                                               # CPU build, default chain
# → http://127.0.0.1:8787/  (UI + /api/v1)
```

Open the page, paste a key if the server has tokens (the gear shows it keylessly on a
tokenless box), press **Estimate** then **Index now**. Indexing never auto-starts.

Three measured rules before anything else:

- **The `chown 990` is not optional.** Docker creates bind dirs root-owned on first up;
  the server then dies on the writer lock (`EACCES`). Measured, not folklore.
- **Index rows carry the roots they were crawled from.** Moving a mount to a new path
  makes answers thin + ghost rows; cure with `POST /api/v1/index {"prune":true}`.
- **Exactly one server process**: media ids and the job runner live inside one uvicorn.
  `--workers >1`, replicas, or a LB in front of two containers 404s media ids.
  Concurrency *within* the process is fine.

## Which compose file for which shape

| File | Shape |
|---|---|
| `docker-compose.yml` | standalone server, CPU build — the whole product on its own |
| `docker-compose.ghcr.yml` | skip the build, pull the published `ghcr.io` image |
| `docker-compose.nvidia.yml` | NVIDIA box: CUDA build target + GPU device reservation (`--profile nvidia`) |
| `docker-compose.lan.yml` | LAN bind for the server port (`DIGUP_LAN_BIND`, opt-in by design) |
| `docker-compose.app-targets.yml` | add one named index target for an application's own data |
| `docker-compose.nextcloud.yml` | full Nextcloud + server stack, self-contained (dav service behind `--profile dav`) |
| `docker-compose.nextcloud.lan.yml` | LAN bind for the Nextcloud web port |
| `docker-compose.all-in-one.yml` | **example**: all of the above merged into one file (peel instructions in its header) |

Overlay files merge onto the base — the chain order is the merge order, and every
shape below is `docker compose -f …[-f …] [--profile …] up -d`. CI schema-validates
each of these chains (see `.github/workflows/server.yml`), so the lines printed here
are exactly the CI-checked ones.

**Recreation rule (measured, it costs hours if ignored):** every `up -d` on an existing
stack repeats the FULL file chain AND every env var used at first boot. A launch with
defaults silently remounts media one level short — the index goes out of scope, the API
answers 0 hits, health stays green.

## Launch chains (example values only)

```bash
# standalone, CPU
docker compose up -d --build

# published image, no build step (x86_64)
DIGUP_IMAGE_TAG=latest \
docker compose -f docker-compose.yml -f docker-compose.ghcr.yml up -d

# NVIDIA box (toolkit installed; match CUDA_BASE to `nvidia-smi`'s CUDA Version,
# CUDA_ARCHS a PLAIN number: 61 Pascal, 89 Ada — apt cmake 3.22.1 rejects `6.1`/native)
CUDA_BASE=nvidia/cuda:12.4.1-devel-ubuntu22.04 CUDA_ARCHS=89 \
docker compose -f docker-compose.yml -f docker-compose.nvidia.yml --profile nvidia up -d --build

# home LAN (no auth — home-LAN trust model, see the overlay's header)
DIGUP_LAN_BIND=192.0.2.1 \
docker compose -f docker-compose.yml -f docker-compose.lan.yml up -d

# a named index for an application's data, beside the media index
DIGUP_APP_TARGET_NAME=photos DIGUP_APP_TARGET_HOST_DIR=/srv/photos-data \
docker compose -f docker-compose.yml -f docker-compose.app-targets.yml up -d --build

# Nextcloud + server, one stack (data shape: Nextcloud's own data dir is the media tree)
DIGUP_NEXTCLOUD_DATA=$PWD/data/nextcloud/html \
DIGUP_NEXTCLOUD_ADMIN_USER=admin DIGUP_NEXTCLOUD_ADMIN_PASSWORD='pick-a-password' \
DIGUP_NEXTCLOUD_INSTANCE_ID=<from occ after install> \
DIGUP_NEXTCLOUD_READ_TOKEN=<secret for the Nextcloud app> \
DIGUP_SERVER_ADMIN_TOKEN=<secret for the operator> \
docker compose -f docker-compose.nextcloud.yml up -d
# → Nextcloud http://127.0.0.1:8081/ · server http://127.0.0.1:8787/
# Add --profile dav + DAV_USERS/DAV_APPPW/NEXTCLOUD_URL for the remote-WebDAV data shape
# (per-user roots, rslave bind — the dav container mounts, the server reads, no restart
# for (re)mounts). The Nextcloud app itself is its own repository: Ocean572/digup_nextcloud.

# everything at once (example, one file)
docker compose -f docker-compose.all-in-one.yml --profile nvidia --profile dav up -d --build
```

## Env var reference (compose layer)

| Var | Effect |
|---|---|
| `DIGUP_INDEX_DIR` `DIGUP_MODELS_DIR` `DIGUP_CONFIG_DIR` `DIGUP_MEDIA_DIR` | move the bind targets off `deploy/data/` (defaults are inside the tree) |
| `DIGUP_PUBLISH_PORT` | host port for the server (container binds 8787) |
| `DIGUP_LAN_BIND` | the host's LAN address; adds the LAN port mapping (opt-in files) |
| `DIGUP_IMAGE_TAG` / `DIGUP_REGISTRY` | registry image selection (`ghcr` overlay) |
| `DIGUP_SWIFT_TESTS` | build-arg knob: `0` skips the engine-test stage on a builder whose env can't run them (CI keeps `1`) |
| `CUDA_BASE` `CUDA_RUNTIME_IMAGE` `CUDA_ARCHS` | CUDA build flavor — base matched to the host driver, plain arch numbers (see the GPU section) |
| `DIGUP_NVIDIA_GPU` | pin one card by UUID on multi-GPU hosts (`NVIDIA_VISIBLE_DEVICES` passthrough) |
| `DIGUP_SERVER_ROOTS` | colon-separated roots the searcher answers for (default `/media/photos`; per-user list on the WebDAV shape: `/media/dav/<uid>:…`) |
| `DIGUP_SERVER_TOKEN` | single-token deployment (read scope; admin token supersedes) |
| `DIGUP_SERVER_READ_TOKENS` | named read entries `name:token` (comma-separated; `app:<target>` binds a named index) |
| `DIGUP_SERVER_ADMIN_TOKEN` | admin scope: index, prune, estimate, targets, tokens |
| `DIGUP_SERVER_APP_TARGETS` | named targets `name=roots:index` (the app-targets overlay composes it) |
| `DIGUP_SERVER_ALLOWED_HOSTS` | Host guard additions for proxy/LAN names (empty = accept-any) |
| `DIGUP_SERVER_ALLOWED_ORIGINS` | CORS allowlist for browser widgets (see API.md §CORS) |
| `DIGUP_SERVER_ESTIMATE_TIMEOUT_S` | estimate walk ceiling (default 120 s; huge trees need more, e.g. 900) |
| `DIGUP_SERVER_JOB_TIMEOUT_S` | index job ceiling; on expiry the job records *interrupted* with its counters and resumes |
| `DIGUP_SERVER_PREWARM` `DIGUP_SERVER_BACKFILL` `DIGUP_SERVER_ENCODER_IDLE` `DIGUP_SERVER_STATUS_TTL_S` `DIGUP_SERVER_JOB_LOG_SIZE` `DIGUP_SERVER_EXTRA_EXCLUDE` `DIGUP_SERVER_EXCLUDE_EXT` | tuning, defaults sane — API.md + the Dockerfile document each |
| `DIGUP_MEDIA_BIND` `DIGUP_MEDIA_TARGET` `DIGUP_MEDIA_BIND_OPTS` `DIGUP_MEDIA_GID` | the media bind: host dir, mount point, `ro` (+`,rslave` on WebDAV), group grant via `group_add` |
| `DIGUP_NEXTCLOUD_*` `DAV_*` `NEXTCLOUD_URL` | the Nextcloud stack + dav container — each namespaced var is commented where it is used in `docker-compose.nextcloud.yml` |

## Semantics an operator must know (measured, and honest)

- **`/health` answers 503 while warming** (~20–30 s prewarm at boot, and during a
  searcher respawn). The container is healthy; the API is honest. The healthcheck counts
  503 as alive.
- **`POST /index` answering 409 = a job is running.** One writer flock per index (per
  named target its own). Never "fix" a 409; ask later.
- **Stop semantics:** `docker stop` with the compose `stop_grace_period: 90s` → exit
  **143**, clean shutdown, the running job recorded *interrupted* with its counters, the
  next job resumes. Docker's default 10 s grace → SIGKILL 137; log replay recovers
  *interrupted* at next boot — never success.
- **The server never invents numbers**: progress, z, timings, previews all come from the
  engine. Fewer strong hits on tiny corpora is the engine's z-gate, not a server filter.
- **GPU is configuration, not patching**: the CUDA image is the same Dockerfile, a
  different target + bases. The engine reports `device` + cosine agreement; the proof of
  use is `server/tests/gpu-handoff.sh` sampling `nvidia-smi` **during a real index job**
  (full procedure: `docs/implementation/gpu-handoff.md`). `DIGUP_DEVICE=cpu` is the CPU
  fallback — CPU winning the measurement is a result, report the numbers.

## API surface (one table — `server/docs/API.md` is the contract)

| Endpoint | Scope | Notes |
|---|---|---|
| `GET /api/v1/health` | none | 503 while warming (by design) |
| `GET /api/v1/status` | read | engine counts verbatim: files, searchable, vectors, kinds, roots |
| `POST /api/v1/search` `{q, limit, kinds, code}` | read | engine answer: hits, z, strong, ms, meaning; `kinds` = media-type filter |
| `POST /api/v1/embed_ahead` | read | seeds a preview embed (UI latency path) |
| `GET /api/v1/media/{id}/preview?pixels=` | read | core/preview shape for photos |
| `GET /api/v1/media/{id}/text` | read | extracted text page(s) |
| `GET /api/v1/media/{id}/file` | read | streamed original, HTTP range requests (206) |
| `POST /api/v1/estimate` | admin | file count + cost forecast (ceiling `DIGUP_SERVER_ESTIMATE_TIMEOUT_S`) |
| `POST /api/v1/index` `{prune?}` | admin | 202 queued · **409** busy; `{"prune": true}` drops rows outside the roots |
| `GET /api/v1/jobs` · `GET /api/v1/jobs/{id}` | read | the engine's own progress records (live + history) |
| `GET /api/v1/targets` · `POST /api/v1/targets` | admin | named indexes; POST mints the target's private key |
| `GET /api/v1/tokens` · `POST /api/v1/tokens` | admin | minted-key list / rotation (keyless read for the gear on the box) |

Bearer tokens ride `authorization: Bearer <token>`. The single-token shape
(`DIGUP_SERVER_TOKEN`) is read-scope everywhere the admin token is not set; the named
map and minted keys bind reads to their own index — API.md §Authentication +
§Named indexes state every rule, and the UI's gear (Settings → API key, Copy +
Regenerate) shows the box's own key without ever asking the browser to hold an admin one.

## Where the rest lives

- **UI/CLI/API contracts:** `server/README.md` (layout, contract suite, dev run) and
  `server/docs/API.md` (schemas, media ids, limits, errors, versioning, CORS, named
  indexes, deploy-shape promises).
- **GPU handoff:** `docs/implementation/gpu-handoff.md` + executable
  `server/tests/gpu-handoff.sh` (Gate A `--cpu-only`, Gate B with `CUDA_BASE=…`).
- **Nextcloud integration design + measured pilot gates:**
  `docs/implementation/stage-12-integrations.md`; the app:
  `github.com/Ocean572/digup_nextcloud` (its README carries its install steps, including
  the `allow_local_servers` core knob — SSRF protection stays on).
- **Images:** `ghcr.io/ocean572/digup-server` `:latest` / `:latest-cuda` (x86_64; every
  other architecture builds natively — never copy a binary across architectures).
