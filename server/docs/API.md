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
* Search is a read-only operation. Indexing, pruning and the full-tree estimate are
  administrative — see [Authentication](#authentication): the deployment splits them onto the
  admin token, so a search-only client cannot start a job.
* HTTPS is the reverse proxy's job (`nginx`/`caddy` terminating TLS in front of
  `127.0.0.1:8787`), not the API's: keep the API on loopback and proxy from there.

## Authentication

Off by default: a loopback-only server has no auth state to leak, and nothing here changes its
behavior. The deployment turns it on with environment variables
([`.env.example`](../.env.example)) — tokens are never in the repo, never in the image:

| variable | scope | what it guards |
|---|---|---|
| `DIGUP_SERVER_TOKEN` | read | every `/api/v1` endpoint except `health`, `docs`, `openapi.json` |
| `DIGUP_SERVER_ADMIN_TOKEN` | admin | `POST /api/v1/index` and `POST /api/v1/estimate`, on top of the read scope |
| `DIGUP_SERVER_READ_TOKENS` | read (named) | `name:token` pairs, comma-separated: **each entry guards the read scope**, exactly like `DIGUP_SERVER_TOKEN`, and the access log names the entry that asked (`principal=nc-a`). The separator is the LAST colon, so names may carry colons — the target-bound form `app:<target>` guards that target's index only (see "Named indexes") |

* No credential on a guarded endpoint → `401` with `WWW-Authenticate: Bearer`. A token that is
  not this server's → `401`. The **read** token on an admin endpoint → `403` saying so.
* Send it as `Authorization: Bearer <token>`. Clients that must not mutate the index (search
  apps, agents, dashboards) get the read token and nothing else; keep the admin token with the
  operator. An **admin-only** deployment (no `DIGUP_SERVER_TOKEN`) guards the mutating endpoints
  and leaves the read side open for every client on the machine.
* The **named map** is for a server answering several deployments (several Nextcloud instances,
  dashboard tiles, Immich): one secret per client, revocation per client, attribution per client.
  Names are lowercased, the first value wins per name, and a malformed entry is skipped with a
  named warning in the log — a silently-dropped token is an outage nobody asked for. The admin
  token covers the read scope too (an admin client searches like a read client); its log line
  says `admin (read scope)` when it presents on the read side.
* `GET /api/v1/health`, `/api/v1/docs` and `/api/v1/openapi.json` are deliberately unguarded:
  the container's `HEALTHCHECK` calls `/health` with no credential (a guarded health endpoint
  would mark a live container unhealthy), and the API's own documentation page is documentation,
  not media data.
* The web UI keeps the key this browser sends in `localStorage` (`digupBearer`) and sends it
  on every request. There is no paste field: in the **tokenless** shape the main page
  searches with no key at all; in the **minted-key** shape (applications registered, see
  "Named indexes") the gear's **API key** section shows the server-generated keys with
  **Copy** (for pasting into the applications) and **Regenerate** — Regenerate also adopts
  the new admin key for this browser. In the **environment-keys** shape the keys are the
  deployment's config, shown by nothing, and the `401` message says exactly that. A `401`
  with a stored key reports the server's words, so a wrong key cannot loop the page.
  (The embed widget, which has no settings panel of its own, keeps its prompt.)
* Tokens are compared with `hmac.compare_digest`. `tests/test_security.py` pins the whole table
  above, including the open health/docs/UI paths.

```sh
curl -s -X POST http://127.0.0.1:8787/api/v1/search \
  -H 'content-type: application/json' -H "Authorization: Bearer $DIGUP_READ_TOKEN" \
  -d '{"q": "wakeboarding"}'
curl -s -X POST http://127.0.0.1:8787/api/v1/index \
  -H 'content-type: application/json' -H "Authorization: Bearer $DIGUP_ADMIN_TOKEN" \
  -d '{"prune": true}'
```

## CORS for browser widgets (`DIGUP_SERVER_ALLOWED_ORIGINS`)

Off by default and needed by neither the server's own UI (same origin, `/`) nor server-to-server
clients (PHP, curl, agents: browsers do not attach `Origin` to their fetches, so nothing here
constrains them). It exists for **in-browser widgets hosted by other applications** —
`GET /embed.html`, the compact search page this server serves (docs/implementation/
stage-12-integrations.md §11.4), embedded by a host app (a Nextcloud app page, an Immich
workspace panel):

* `DIGUP_SERVER_ALLOWED_ORIGINS` is a comma-separated list of **exact origins**
  (`http://nextcloud.lan:8081`, scheme+host+port): no wildcards, no path, no trailing slash.
* A preflight (`OPTIONS` with an allowlisted `Origin`) answers 204:
  `access-control-allow-origin: <origin>`, `allow-methods: POST, GET, OPTIONS`,
  `allow-headers: authorization, content-type`, `max-age: 600`, `vary: Origin`.
* A request from an allowlisted origin gets its response decorated with
  `access-control-allow-origin` + `vary: Origin`; any other origin gets nothing — the
  cross-origin read is refused by the browser exactly where this list says.
* The Host/Origin guard's cross-origin-POST rule keeps its teeth: the widget's POST passes
  only because CORS (installed outside the guard) blessed that exact origin first, and the
  Host allowlist still outranks everything. Non-allowlisted browsers keep the §7 rule.
* The embed widget carries the read token in `?token=`, which moves to `sessionStorage` and
  leaves the URL line (history/bookmarks/host logs never see it); previews are authorized
  blob fetches, never `<img src?token=…>`.

## Multiple clients on one index

One deployment answers many applications (Immich, Home Assistant, agents, desktop tools) from one
index and one model deployment: point them all at this API, index once, search concurrently. The
engine holds one hot `search-service` per API process (its query encoder stays warm for
`DIGUP_SERVER_ENCODER_IDLE` seconds and the adapter restarts it transparently), one writer under
the flock, and one job queue. Search is safe to hammer; index jobs are serialized and `409` while
one runs. Keep every client on the same root layout (an index folder belongs to one set of root
paths — remounting media under a new path needs one prune job), and never point two root layouts
at the same index folder.

## Named indexes — per-application indexes (`DIGUP_SERVER_APP_TARGETS`)

One server, many indexes. The deployment's own media index (`media`, the roots+index the
environment names) is what the UI and `/api/v1/*` answer by default — the standalone server,
exactly as before. An **application target** is a named pair of (roots, index folder) the same
server supervises *independently*: its own `search-service` child, its own writer (the flock
lives beside each index folder, so crawls on different indexes never queue behind each other),
its own jobs log (`jobs-<name>.jsonl`), its own previews folder, its own token. A Nextcloud
bridge pointing at this API with its target's token builds and searches **its own index** —
the media index is untouched by its crawl, and a second application gets its own target the
same way.

```
DIGUP_SERVER_APP_TARGETS=nextcloud=/media/nextcloud:/data/index-nextcloud;dc=/media/dc:/data/index-dc
```

Entries are `;`-separated, each is `name=roots:index` (the roots colon-separated, the index
the LAST folder — the same colon shape as `DIGUP_SERVER_ROOTS`); names are
lowercase slugs (`media` is reserved for the main index), paths absolute, and a target's
index may not be the main index — separate indexes are the point. A persisted
`<config>/targets.json` joins the registry the same way; env wins per name. Malformed
entries refuse startup with the entry quoted.

**Minted keys — the server's "API key" rows.** When targets exist and their tokens are not
configured, the server mints them (`secrets.token_urlsafe(24)`), stores them in
`<config>/tokens.json` (0600, config folder = recreation-safe: a recreation never silently
revokes a connected application), and shows them in the UI (gear → Settings → **API key** —
the server's key is one row: **API key | value | Copy | Regenerate**) and via
`GET /api/v1/tokens`. **In a minted deployment the keys surface is key-free** (2026-11-08
UX brief, round 6 — the ticket model): the gear reads the row with no key in the browser,
exactly as the main page searches with no key. An `app:` key and an env-keyed deployment are
refused there (`403`, admin scope only — the env-shape's gate keeps 401-ing every call).
**The gear takes the key it is shown** (`app.js`): in a minted deployment the operator's own
panel runs the admin-scope controls (`index`, `estimate`, `tokens` rotate) with the displayed
value, stored in `localStorage` exactly as rotation already stores its new key; a stored key the
server no longer recognizes is replaced by the value shown now (the panel self-heals after a
rotate or re-mint). Nothing is typed, pasted, or prompted, and the main page's key-free reads
are unaffected.
Minting fires only when targets exist; a standalone, token-less deployment keeps running
unguarded and unchanged. **The minted shape keeps the main index's READS open** (2026-11-08
user brief — "the standalone app just uses the directory set in the environment"): a key-less
browser on the operator's box searches, previews, and reads status on the main index; the
minted **admin** key guards the index operations (`index`, `estimate`), the keys surface, and
`Regenerate`; each minted **app** key guards its own index. A deployment that typed its keys
in the environment is the guarded shape — there, every call needs a key, as before. The admin
key is read from the file on the operator's own config mount (`cat <config>/tokens.json`) when
this browser must administer the server (index/estimate/regenerate); ordinary browsing needs
no key. Environment-configured secrets are never copied into the file and never echoed by
the API — `/api/v1/tokens` shows `configured: true` for them and values only for minted ones.

`POST /api/v1/tokens` (admin scope) **regenerates** the minted keys — the UI's Regenerate
button, behind a confirm ("the applications that have these keys pasted lose access"):
every minted value (admin and app keys) is freshly minted, persisted 0600, and live
immediately — the old values answer `401` from this call on. Environment-configured keys
are never rotated (a rotation must not silently override the deployment's own config); a
deployment with nothing minted answers `400`.

**The standalone box mints its key at boot (`DIGUP_SERVER_MINT_KEYS=1`).** With the knob the
server mints its admin key with no application registered — the gear shows it with **Copy**,
and the box stays searchable with no key (the minted shape's open main reads). This is the
ticket the applications bring: `POST /api/v1/targets` (admin key) with
`{"name": "<slug>", "roots": ["<abs>", …], "index": "<abs, optional>"}` registers the
application at the **running** server — the startup validator runs at runtime (slug rules,
absolute paths, "not the main index", name reserved `media`, duplicates `409`), the server
mints the application's **private key** (returned once here, persisted 0600), gives it its own
index folder (default `<config>/index-<name>`), and persists the registration
(`<config>/targets.json` — a restart re-reads both files). From that call on the application's
key answers only its target: its own status, search, previews, and its own crawl
(`POST /api/v1/index` — background, one writer, never touching the main index, invisible to
the main page). Key-less and application-keyed requests cannot register.

**Endpoint scoping.** Every guarded endpoint addresses a target: `?target=name` names it
explicitly; the default is `media` — except for an `app:<name>` token, whose default is its own
target (the binding is what the token carries, so an application calls plain paths). The bearer
gate binds: `admin` answers every target; `DIGUP_SERVER_TOKEN` and plain
named tokens answer the main index (their contract, unchanged); an `app:<name>` token answers
its target's index and nothing else — any other target answers `403`. Mutating routes
(`index`, `estimate`) accept an app token **for its own target**: the bridge queues its own
crawl, and never anyone else's. One estimate runs at a time **server-wide** (a full-tree crawl
is the expensive walk, wherever its roots are); one index job at a time is **per target** —
the writer lock lives beside each index folder, so crawls of different indexes run in
parallel. `GET /api/v1/targets` lists the registry: counts come from a running target's
live searcher (the authority on a store it has open), from the read-only CLI status for a
target whose searcher is not spawned (no engine spawn for a listing), and are `null` for an
index folder with no store yet; an app token sees only its own. Media handles resolve their
target from the path's owning roots, so `/preview`, `/text`, and `/file` work identically
across indexes. `GET /api/v1/health` reports the main target (container health is the
deployment's own index). The access log carries the resolution: every audited line names the
principal **and the target it addressed** (`principal=app:nc target=nc`).

Deploy shape: `deploy/docker-compose.app-targets.yml` (opt-in `-f`) mounts the application's
data folder read-only and registers one target; bring-up needs the full chain and env
(see the file's header). `tests/test_targets.py` pins the registry, the minting rules, the
binding table, and the end-to-end flow over the real engine.

## Deploy shape (what a client can assume)

`deploy/docker-compose.yml` (CPU-only, the default) → `http://127.0.0.1:8787/`: UI at `/`,
`/api/v1`, `tini` as PID 1, non-root `uid 990`, `stop_grace_period: 90s`, healthcheck on this
endpoint, index/models/config/job-log on bind-mounted volumes (container recreation never
destroys them). The GPU (NVIDIA) override arrives as a separate opt-in Compose file; CPU-only is
the baseline everything is measured against.
