# DigUp server API (`/api/v1`)

The REST API is the product. The web UI in [`../ui/`](../ui/) is one client of it, served
same-origin at `/`; nothing here depends on the UI. OpenAPI is generated from the app itself at
[`/api/v1/openapi.json`](http://127.0.0.1:8787/api/v1/openapi.json) and a browsable docs page at
[`/api/v1/docs`](http://127.0.0.1:8787/api/v1/docs) — this file is the human reference and the
compatibility promise. `server/tests/test_api_docs.py` fails CI if an endpoint is added without
appearing here.

* Base URL: `http://127.0.0.1:8787` (container: `127.0.0.1:8787:8787` published, host side
  movable with `DIGUP_PUBLISH_PORT`). Requests and responses are JSON UTF-8
  (`content-type: application/json` on POST bodies).
* **One API process.** The media handles ([`media_id`](#media-identifiers)) live in that
  process's LRU cache and the index job runner is a thread inside it. Running more than one
  uvicorn process (`--workers >1`, replicas, a load balancer in front of two containers
  sharing a volume) 404s media ids from another process's searches and lets two job runners
  race. Scale by giving the machine more cores, not by adding processes.
* Every answer is the engine's. `hits`, `strong`, `meaning`, `ms`, `warning` pass through
  verbatim; ranking, z-scores and timings are DigUp's, computed in the Swift engine, and the
  server adds no cap, no re-ranking and no explanation of its own. Engine failures come back
  as 5xx bodies quoting the engine (with its stderr tail), never as a server-invented message.

## Versioning

`/api/v1` is the version. Additive changes (new optional fields, new endpoints) land in v1;
a field is never renamed, retyped, removed, or given a new meaning in v1 — a breaking change
means `/api/v2` and a deprecation window. Responses are typed with Pydantic; the search reply
model is `extra="allow"`, so an engine field this API has never seen is **published**, not
dropped at the boundary. Clients should ignore unknown fields.

## `GET /api/v1/health`

Engine identity plus live counts. Cheap enough to be the container's `HEALTHCHECK` (30 s).

```sh
curl -s http://127.0.0.1:8787/api/v1/health
```

```json
{"ok": true,
 "engine": {"fingerprints": "google/embeddinggemma-2@bfcd298… | vectors1",
            "build_tag": "b11461", "vectors_version": 1,
            "index": "/data/index", "index_size": "201 KB"},
 "live": {"encoder": "ready", "vectors": 37, "files": 15, "searchable": 15, "pending": 0}}
```

`503` with the engine's own sentence means *the searcher is mid-respawn*: the container is
healthy (the healthcheck treats 503 as alive on purpose). Treat 503 as "try again in a moment",
not as a failure.

## `GET /api/v1/status`

The same live counts plus the engine's per-kind table, its fingerprints, and the server's own
configured roots (deployment config, published for display — the API never accepts paths from a
client). Polled by the UI every 15 s; answers come from a short TTL cache
(`DIGUP_SERVER_STATUS_TTL_S`, default 15) so a poll never costs a `digup status` subprocess.

```sh
curl -s http://127.0.0.1:8787/api/v1/status | jq '.kinds, .roots'
```

## `POST /api/v1/search`

One query, the engine's answer.

| field | type | default | notes |
|---|---|---|---|
| `q` | string | required | max 512 characters (422 above it) |
| `kinds` | array of `screenshot` `image` `pdf` `doc` `audio` `video` `code` | all kinds | anything else → 422 (the engine would silently drop it) |
| `limit` | int 1–100 | **40** | the engine's own default (`SearchService.swift:130`); see [Limits and pagination](#limits-and-pagination) |
| `code` | bool | `false` | the code index (`code:` searches); it is a separate index in the engine |
| `meaning` | bool | `true` | `false` = keyword-only (words, no embedding) — the desktop panel's first keystroke |
| `prefix_last` | bool | `false` | last word as a prefix; the panel's "typing a word that isn't indexed yet" path |

```sh
curl -s -X POST http://127.0.0.1:8787/api/v1/search \
  -H 'content-type: application/json' \
  -d '{"q": "wakeboarding", "limit": 5}' | jq '{strong, meaning, ms, n: (.hits|length)}'
```

```json
{"hits": [{"path": "/media/photos/clips/wakeboarding-vienna.webm",
           "kind": "video", "segment": 3, "segment_id": 41,
           "score": 0.412, "z": 4.15, "cosine": 0.61, "keyword_rank": 2,
           "loc": 9.5, "loc_end": 12.0,
           "modified": 1730000000.0, "size": 1048576, "info": "…",
           "media_id": "9f2c1a7b3e04"}],
 "strong": 3, "meaning": true,
 "ms": {"embed": 1554, "search": 8}, "warning": null}
```

Field notes (engine truth, published as the engine made it):

* `hits[].path` is the server's resolved path for the file — **for display only**. It is not an
  input to any endpoint; media access goes through `media_id` (§ [Media
  identifiers](#media-identifiers)).
* `z` is the engine's significance over the indexed set; a published hit clears `zGate = 2.0`.
  `strong` is how many hits cleared it. **A 1-hit answer is the corpus's size, not a filter, a
  cap, or a bug** — a small gallery yields few ≥2σ matches, a personal library yields many.
* `loc` / `loc_end` are the engine's seconds into an audio/video file; `segment` /
  `segment_id` identify the page, passage, frame, or 30-second window the hit is about.
* `ms` are the engine's own milliseconds. A cold first query pays the model load
  (`embed` of seconds, not milliseconds); after prewarm the same query embeds in hundreds.
* `meaning: false` requests answer without the embedding path; `warning` carries the engine's
  own warning when there is one.
* An empty answer is honest, not an error: `hits: []` with the engine's `strong`/`meaning` as
  it answered. `200` with no hits beats any invented explanation.

## `POST /api/v1/embed_ahead`

The typist's warm-up: the engine embeds and caches the text so far, so the *next* search pays
milliseconds instead of the model load. Send it alongside a `meaning: false` keyword search
while the user is typing, then send the `meaning: true` search when they pause. Same op the
desktop panel uses.

```sh
curl -s -X POST http://127.0.0.1:8787/api/v1/embed_ahead \
  -H 'content-type: application/json' -d '{"q": "wakeboa"}'
```

## `POST /api/v1/estimate`

The engine's own forecast for the configured roots — per folder: readable, kind counts, PDF
pages, audio/video durations, `calibrated` (whether the engine has measured this machine's
speed enough to trust the number), top subfolders. It walks the whole tree, so **one estimate at
a time**: a second concurrent call answers `409`.

```sh
curl -s -X POST http://127.0.0.1:8787/api/v1/estimate -H 'content-type: application/json' -d '{}' \
  | jq '.folders[0] | {folder, calibrated, files, seconds}'
```

## `POST /api/v1/index` — start a job (admin operation)

Indexing never starts by itself. An empty body is a plain sync of the server's configured roots;
`{"prune": true}` also retires rows for files no longer under those roots (the engine's
`--prune`) — run it once after remounting media at a new path, so the old scope's ghost rows stop
counting in `files`/`vectors` and diluting z.

```sh
curl -s -X POST http://127.0.0.1:8787/api/v1/index -H 'content-type: application/json' -d '{}'
# → 202 {"ok": true, "job": {"id": "1a2b3c4d5e6f", "state": "queued", "started": 1730000000.123}}
curl -s -X POST http://127.0.0.1:8787/api/v1/index -H 'content-type: application/json' -d '{"prune": true}'
# → 409 {"detail": "job 1a2b3c4d5e6f is running"} while a job is in flight
```

`202` means queued and accepted, `409` names the job that is in flight (one writer, enforced by
`flock` beside the index). A job runs in this API process, so it is not durable across a
restart: a `running` job with no ending recovers as **interrupted** on the next boot (never as
success), and the next job resumes the walk.

## `GET /api/v1/jobs` and `GET /api/v1/jobs/{id}`

Job history, replayed from the append-only job log (rotated at size; history outlives any
rotation). States: `queued`, `running`, `done`, `interrupted`, `busy`.

```sh
curl -s http://127.0.0.1:8787/api/v1/jobs | jq '.jobs[-1]'
curl -s http://127.0.0.1:8787/api/v1/jobs/1a2b3c4d5e6f
# unknown id → 404 {"detail": "no job 1a2b3c4d5e6f"}
```

A finished record carries the engine's own counts:

```json
{"job": {"id": "1a2b3c4d5e6f", "state": "done", "started": 1730000000.123,
         "ended": 1730000012.123, "seconds": 12.0, "prune": true,
         "files": 61, "searchable": 61, "pending": 0, "vectors": 65,
         "files_done": 61, "files_failed": 0, "errors": 0}}
```

`files`/`searchable`/`pending`/`vectors` ride the engine's `idle` totals (the post-index truth),
`files_done`/`files_failed` count its `file` events. After a `done` job the searcher is brought
current (`reload` → `prewarm`); if that refresh is refused mid-transition the job stays `done`
with a `why` note ("searcher refresh deferred") — a refused refresh never rewrites a finished
job.

## Media identifiers

`media_id` is the **server's** handle for one hit in one search reply, not a DigUp identifier
and not a path. It is 12 hex characters, issued when a search reply is published, and it lives
in a bounded LRU cache in this API process. Consequences a client must design for:

* Only ids from a published search reply work. An unissued, evicted, or stale id →
  `404 {"detail": "no media handle …"}`. Re-run the search and use the fresh ids.
* Ids are **not durable**: they die with the process (restart, upgrade, reindex-triggered
  reload). Store nothing long-term keyed by `media_id`; re-acquire by searching.
* Ids are **not global**: two searches of the same file issue different ids, and each is
  pinned to that hit's segment and moment. The stable identity a client should key on is
  `path` + `kind` + `segment_id` (+ `loc` for a moment), which the engine publishes.
* No endpoint accepts a path, folder, or URL from a client (§ [Security](#security)). The
  server resolves a handle inside its own configured roots and refuses symlink traversal.

### `GET /api/v1/media/{media_id}/preview?pixels=256`

The JPEG the engine's `render` wrote under `<index>/previews` (photo, PDF page, video frame at
the hit's second). `pixels` is 32–2048, default 256. Answers `image/jpeg`; `404` for a dead
handle; `500` if the engine ever answered outside the previews folder.

```sh
curl -s -o p.jpg "http://127.0.0.1:8787/api/v1/media/9f2c1a7b3e04/preview?pixels=512"
```

### `GET /api/v1/media/{media_id}/text`

The matched segment's text (PDF page, passage, transcript window, code lines) — the engine's
`text` op for that hit's `segment_id`.

```sh
curl -s http://127.0.0.1:8787/api/v1/media/9f2c1a7b3e04/text | jq -r '.text[:200]'
```

### `GET /api/v1/media/{media_id}/file`

The original bytes: the desktop app's "Open", over HTTP.

* Type comes from the file's **magic bytes**, never its name; a source file named `index.html`
  never arrives as markup. Unknown types are `application/octet-stream`; code/doc go
  `text/plain; charset=utf-8`.
* Media kinds (`image`, `screenshot`, `video`, `audio`, `pdf`) are `inline`; everything else is
  an `attachment` with an RFC 5987 filename. Every answer carries
  `x-content-type-options: nosniff`.
* `Accept-Ranges: bytes` always; `Range: bytes=a-b` answers `206` + `Content-Range`, an
  unsatisfiable range answers `416` with `bytes */size`. This is what makes
  `<video src="/api/v1/media/<id>/file#t=9.5">` seek. Single ranges only; `If-Range` is not
  honored. Open-ended ranges are **capped at 8 MiB** and streamed in 1 MiB chunks — a 20 GB
  clip streams, it is never buffered.
* The type, the size and the span all come from **one open** of the file (`fstat` on the live
  handle), so a replacement mid-request cannot make the headers lie about the bytes; a file that
  vanished is `404 {"detail": "the file is gone (it left the folders)"}`.

```sh
# a video frame at the hit's moment, seekable
curl -s -o /dev/null -w '%{http_code} %{content_type}\n' \
  "http://127.0.0.1:8787/api/v1/media/9f2c1a7b3e04/file"
# a range request, exactly as a media element sends it
curl -s -D - -o /dev/null -H 'Range: bytes=0-1023' \
  "http://127.0.0.1:8787/api/v1/media/9f2c1a7b3e04/file"
# → 206, content-range: bytes 0-1023/124177, accept-ranges: bytes
```

## Limits and pagination

`limit` is the whole pagination story: 1–100 per search, default 40 (the engine's own default,
so a client that names no limit gets the engine's answer — `tests/test_api.py` pins it). There
is **no offset and no cursor**: the engine ranks the entire index and returns the top `limit`
hits that clear its z-gate. To see more of a large library, narrow the query and re-search
(`kinds`, `code`, `meaning: false` for the keyword pass, a more specific phrase) — paging into
weak matches is not what the ranking is for. The web UI's row-count select sends `limit`
explicitly; direct API clients get 40.

## Errors

All errors are JSON with a single human-readable `detail` string, safe to show to a user:

| status | when | example body |
|---|---|---|
| `422` | validation (bad kind, over-512 `q`, `limit` out of 1–100, missing `q`) | FastAPI's list of error objects — render each item, do not show the raw array |
| `404` | unknown job id, dead media handle, file outside the configured roots, file gone | `{"detail": "no job 1a2b3c4d5e6f"}` |
| `409` | a job is already running; an estimate is already running | `{"detail": "job 1a2b3c4d5e6f is running"}` |
| `416` | unsatisfiable `Range` | empty body, `content-range: bytes */size` |
| `502` | the CLI (`status`/`estimate`/`speed`) failed | the engine's own message + its stderr tail |
| `503` | the engine refused (`ok:false`), the searcher exited, `/health` mid-respawn | the engine's own sentence, quoted |
| `504` | an adapter call timed out | the timeout the adapter hit |

`503` is not a server fault code here: it is the engine saying "not right now, in its own words".
Retry it. A `500` means a server bug — report it, and it ships with a test.

## Security

* Binds `127.0.0.1:8787` by default (`DIGUP_SERVER_HOST`/`DIGUP_SERVER_PORT` for bare metal; in
  a container uvicorn binds `0.0.0.0` inside and the `127.0.0.1:8787:8787` publish line is what
  enforces localhost). LAN exposure needs authentication first — do not publish the port on a
  routable interface unauthenticated.
* **Host and Origin validation is opt-in**: `DIGUP_SERVER_ALLOWED_HOSTS` names the URL hosts
  this deployment serves. Unset (the default) validates nothing, so loopback behavior never
  changes. When set: a request whose `Host` is not listed gets `400`, and a browser's
  state-changing request (`POST`/`PUT`/`PATCH`/`DELETE`) whose `Origin` is not that same host
  gets `403`. Non-browser clients send no `Origin` and pass; read-only `GET`s are not checked;
  ports are not compared; there is no wildcard. Set it the moment the server is reachable from a
  Docker network, a reverse proxy, or a LAN name — that is the setting that stops DNS-rebinding
  against a localhost service. `tests/test_security.py` pins all of it.
* No CORS allowance at all: the UI is served by the API on the same origin.
* No settings endpoints: the server's configuration is container configuration
  ([`.env.example`](../.env.example)), not a remote-writeable surface. No uploads, no
  client-chosen paths, no shell interpolation of input.
* Search is a read-only operation. Indexing and pruning are administrative
  (`POST /api/v1/index`) — treat them as admin scope when you add a proxy, a token, or a
  network. When token auth lands here, read-only search clients must not be able to start a
  job.
* HTTPS is the reverse proxy's job (`nginx`/`caddy` terminating TLS in front of
  `127.0.0.1:8787`), not the API's: keep the API on loopback and proxy from there.

## Multiple clients on one index

One deployment answers many applications (Immich, Home Assistant, agents, desktop tools) from one
index and one model deployment: point them all at this API, index once, search concurrently. The
engine holds one hot `search-service` per API process (its query encoder stays warm for
`DIGUP_SERVER_ENCODER_IDLE` seconds and the adapter restarts it transparently), one writer under
the flock, and one job queue. Search is safe to hammer; index jobs are serialized and `409` while
one runs. Keep every client on the same root layout (an index folder belongs to one set of root
paths — remounting media under a new path needs one prune job), and never point two root layouts
at the same index folder.

## Deploy shape (what a client can assume)

`deploy/docker-compose.yml` (CPU-only, the default) → `http://127.0.0.1:8787/`: UI at `/`,
`/api/v1`, `tini` as PID 1, non-root `uid 990`, `stop_grace_period: 90s`, healthcheck on this
endpoint, index/models/config/job-log on bind-mounted volumes (container recreation never
destroys them). The GPU (NVIDIA) override arrives as a separate opt-in Compose file; CPU-only is
the baseline everything is measured against.
