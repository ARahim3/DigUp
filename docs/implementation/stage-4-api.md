# Stage 4 — the API: FastAPI on `/api/v1`, on top of the adapter

Date: 2026-11-02. The HTTP surface the UI and any client will use. It sits **on top of**
the Stage-3 adapter and adds nothing to the engine's answers: ranking, fields, timings,
empties and errors pass through as the engine made them. Rules:
[README.md](README.md) §6 (API surface), §7 (localhost, no client paths), §10.6 (versioned
from day one, engine identity in `/health`).

## The app (`server/digup_server/api.py`)

* `create_app(config)` builds the FastAPI app over **one supervised `SearchService`**;
  the lifespan spawns it as a direct child of the server process and `quit()`s it on
  shutdown. uvicorn is the long-lived parent (§Supervision in
  [stage-3-adapter.md](stage-3-adapter.md): ParentWatch exits helpers whose parent is
  PID 1 — so dev runs use `docker run --init`, and the Stage-7 runtime image carries
  `tini`).
* `config_from_env()` is the only place paths are chosen (index, roots, models,
  excludes, bind) — documented in `server/.env.example`. A client never sends a path.
* Endpoints:

  | route | engine source |
  |---|---|
  | `GET /api/v1/health` | `status` op (live counts, encoder state) + `digup status` CLI (llama.cpp build tag, vectors version, fingerprints, index size) — the engine's identity, read from its own outputs |
  | `GET /api/v1/status` | `status` op + the CLI's per-kind table |
  | `POST /api/v1/search` | `search` op — hits verbatim (`hitFields()`), `strong`, `meaning`, `ms`, `warning`; the protocol's `id` stays inside |
  | `POST /api/v1/estimate` | `estimate --json` — one JSON line per root folder, streamed by the engine (usable only because the API is a live parent, not PID 1) |

* Validation where the engine is silent: `kinds` is a `Literal` of the engine's
  `FileKind` rawValues — the engine *drops* unknown kinds silently, so the API answers
  **422** instead of passing the silence through. `q` is capped (512), `limit` 1–100.
* Failure mapping, quoting the engine: `EngineExited` → 503 (with its stderr tail),
  `TimeoutError` → 504, `CLIError` → 502. No invented explanations.
* Binds `127.0.0.1:8787` by default (`DIGUP_SERVER_HOST/PORT`); in a container uvicorn
  binds `0.0.0.0` inside and the publish line `127.0.0.1:8787:8787` enforces
  localhost-only on the host. No CORS middleware: the UI (Stage 6) is served from the
  same origin; CORS arrives restricted to that origin if a separate origin ever appears.

## API tests (`server/tests/test_api.py`, 9)

In-process TestClient over the **real adapter and engine** (the lifespan spawns
`search-service` as a child of pytest — a live parent; no mocks): health identity +
live counts; status kind table (image 12 / video 3); `wakeboarding` top-3 identical to
the adapter contract test, fields verbatim, real `ms`, no `id` leak; the honest empty
survives the HTTP leg; `meaning: false` keyword-only; kind filter; 422s for what the
engine would silently drop; `estimate` forecast as JSON (folder, counts, readable);
OpenAPI paths all under `/api/v1/`.

## Run + result

The full suite (contract + API) in `digup-server-test:local` (arm64), warm index mount —
final image, the run's own line:

```
31 passed, 1 deselected, 1 warning in 92.10s (0:01:32)
```

The live check — the API container with `--init` (the parent rule) and the port published
to the host's loopback only (`-p 127.0.0.1:8787:8787`), corpus/models/index mounted:

```
$ curl http://127.0.0.1:8787/api/v1/health
{"ok": true,
 "engine": {"fingerprints": "google/embeddinggemma-2@bfcd298 llama.cpp-vectors1 …",
            "build_tag": "b11461", "vectors_version": 1,
            "index": "/index/index.sqlite", "index_size": "135 KB"},
 "live": {"encoder": "stopped", "files": 15, "searchable": 15, "pending": 0,
          "vectors": 0, …}}

$ curl -X POST http://127.0.0.1:8787/api/v1/search \
    -H 'content-type: application/json' -d '{"q":"wakeboarding","limit":3}'
meaning True · strong 3 · ms {"embed": 1554, "search": 8}
   video wakeboarding-vienna.webm · z 1.59
   image wakeboard-logan.jpg · z 1.58
   image wakeboarding-aarhus-04.jpg · z 0.47

$ curl http://127.0.0.1:8787/api/v1/status
encoder ready · vectors 37 · kinds [("image", 12), ("video", 3)]

$ curl -X POST http://127.0.0.1:8787/api/v1/estimate -d '{}' -H 'content-type: application/json'
folder /corpus · readable True · files {"image": 12, "video": 3}     # estimate --json, live parent

$ # the honest empty survives; the API refuses what the engine would silently drop:
… -d '{"q":"a person riding a wakeboard behind a boat"}' → hits [] · meaning True
… -d '{"q":"x","kinds":["not-a-kind"]}'                  → 422
```

The first search pays the CPU encoder start-up (embed 1 554 ms — the Stage-3 cost,
published honestly); after it the encoder is `ready`, vectors report 37 (the lazy-load
sequence of §Protocol in the Stage-3 doc), and `strong: 3` with the engine's own ranking
is the same top-3 the CLI and adapter tests assert.

Two fixes the live check caught before the docs went final (both mine, not the engine's):
`Literal` from `typing` (import bug, broke test collection — the suite caught it), and
uvicorn's `--factory` entry (`digup_server.api:app` needs a module-level app, which would
run `config_from_env()` at import in every context — a factory keeps module import
side-effect-free).

## What this proves / does not

* **Proves**: the published surface works against the shipped payload — pass-through is
  verifiable end-to-end (same top-3 from CLI probe, adapter test and HTTP), the
  supervision story (uvicorn-as-parent) is real, localhost binding by default, and the
  API is honest about validation and engine failure.
* **Does not prove**: index jobs and jobs API (Stage 5), previews/`render` endpoints
  (Stage 4/6 policy — `render` is tested at adapter level), the UI (Stage 6), compose
  packaging + `tini` runtime image (Stage 7), auth/LAN exposure (later), scale, GPU.

## Carried forward

1. Stage 5: `/api/v1/index` + `/api/v1/jobs/{id}` over `IndexService` — same supervision,
   flock already in the adapter; on job finish: `reload()` → `prewarm()` (tested sequence).
2. Stage 6: UI in the `shell/ui` vanilla style, `fetch()` to `/api/v1`, served same-origin.
3. Stage 7: runtime image = payload + API + `tini` PID 1, HEALTHCHECK, SIGTERM →
   `quit()`; Compose publishes `127.0.0.1:8787`.
4. Preview endpoints: `render` replies give JPEGs under `<index>/previews`; the API will
   serve them by id, never by path.
