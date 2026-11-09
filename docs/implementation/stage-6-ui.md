# Stage 6 — the web UI: a browser client of `/api/v1`, vanilla and same-origin

Date: 2026-11-02. The UI is `server/ui/` (HTML + CSS + JS, ~250 lines total, **no
frameworks, no build step, no dependencies** — the same paradigm as the desktop shell's
`shell/ui`, README §10.4) served by the API itself, same origin, so CORS is not needed
at all. It speaks to the published API with `fetch()` and nothing else: no engine
internals, no parallel store, no invented numbers.

## What the screen shows

* **A search box**: typing debounces (250 ms) into `POST /search`, with the engine's
  `embed_ahead` warm-up fired on every keystroke (the desktop panel's trick) so the
  pause's vector is ready. The hits list shows the engine's ranking verbatim: kind badge,
  file name, the engine's own `z`, **video/audio moments as `at m:ss`** from `loc`
  (the engine's seconds on the 3 s frame grid / 30 s audio windows), and real per-phase
  `ms` ("embed 1.55 s · search 0.01 s").
* **The honest empty**, verbatim from Stage 2: *"the engine found no good matches for
  this and refused to guess — that is its answer"*. Not a "best guess", not zero-results
  marketing copy.
* **Preview / text on demand**: photos, screenshots and video frames via
  `GET /api/v1/media/{media_id}/preview` — the JPEGs the engine's `render` wrote under
  `<index>/previews`; documents/PDFs/code/audio text via
  `GET /api/v1/media/{media_id}/text` — the passage the engine indexed, quoted.
* **Index now**: `POST /index` → 202 + poll `GET /jobs/{id}` every 2 s showing the
  engine's counts (`searchable 15/15 · pending 3 · vectors 40 · indexed 4 · 12.3 s`);
  a 409 shows "busy — a job is already running" and polls the live job. A "prune
  missing" checkbox adds `{"prune": true}` — the engine's `--prune`, the procedure
  after remounting media. No made-up progress bar.
* **A status strip**: `GET /status` every 15 s — files/searchable/pending, vectors,
  encoder state, per-kind counts, llama.cpp build tag.

## The media-handle rule (README §6, pinned in code)

The search reply attaches a server-issued `media_id` per hit (a bounded LRU in
`api.py:HitCache`): the media endpoints accept **only** these ids — a client never sends
a path. The preview endpoint resolves the stored path through the engine's own `render`
and serves it **only if its resolved path is inside `<index>/previews`** (symlink
safety); a `render` answer outside previews is a 500, not a file serve. Unknown ids →
404. `media_id` is documented as the server's handle, not an engine field.

The UI builds its DOM with `createElement` + `textContent` only — file names are
escaped by the DOM, so a hostile file name cannot inject markup (§7).

## API additions for it (`api.py`)

`POST /embed_ahead` (op passthrough), `GET /media/{id}/preview?pixels=…`
(FileResponse, `image/jpeg`), `GET /media/{id}/text`, and a `StaticFiles` mount serving
`server/ui/` at `/` (html=True) — routes `/api/v1/*` win because the mount is added last.

## Tests (`server/tests/test_media_ui.py`, 7)

Same-origin UI at `/` (200, and *no* external URLs, no `type="module"` — dependency-free
is a tested property, not a style guideline); handles issued per hit (unique, 12 hex);
photo preview → real JPEG bytes; **video preview at the hit's moment** (`loc` present →
frame JPEG); the doc passage quoted verbatim (scratch corpus: `campfire stories…`);
server-never-issued ids → 404 on both endpoints; `embed_ahead` → `{ok:true}`.

> Amended 2026-11-08 (user brief, README §10.4's dated note): the server UI became a
> Lit + Vite frontend — `type="module"` is now the REQUIRED shape pin (the "no module"
> pin inverted with the migration), "no external URLs" and the no-cache decoration are
> unchanged, and Node exists at Docker build time only. The stage's other pins ride on
> unchanged; `server/ui/AGENTS.md` is the current manual.
`conftest.scratch/scratch_index` moved to session scope (one 100 s scratch indexing
shared by jobs/media/index modules).

## Suite result + live check

2026-11-02, final image — the run's own line:

```
42 passed, 1 deselected, 1 warning in 107.87s (0:01:47)
```

(22 contract + 9 API + 4 job + 7 UI/media tests.)

Live from the host, against the API container with `--init`:

```
GET /                         → 200 <title>DigUp — semantic media search</title>
GET /app.js                   → 200 (7 105 bytes, `fetch(`/media_id present)
POST /search "wakeboard photo" kinds=image → wakeboard-logan.jpg · media_id 7ce443539a66
GET /media/7ce443539a66/preview?pixels=256 → 200 image/jpeg · 13 141 bytes · \xff\xd8
GET /media/000000000000/preview            → 404      # server never issued it
POST /search "hiking" kinds=video          → pct-hiking…webm at 9.5 s · media_id 7fd55ce1a6ba
GET /media/7fd55ce1a6ba/preview?pixels=256 → 200 image/jpeg · 14 734 bytes  # the 9.5 s frame
```

A visual pass in a real browser was **not** run (no Chrome on this host for the
automation tool); the proof here is the served HTML/JS, `node --check` on the app, the
7 DOM/HTTP tests, and the transcript above — recorded as such, not papered over.

## What this proves / does not

* **Proves**: a real browser surface over the published API with the engine's outputs —
  ranking, moments, counts, honest empties; the id-only media rule with symlink safety;
  the busy/queued/done job story in a UI loop; a UI that is one fetch() layer deep and
  250 lines.
* **Does not prove**: real-browser rendering fidelity (checked by hand in Safari/Chrome
  on the host, not in CI), auth/lan exposure (later), multi-root pickers, i18n,
  drag-and-drop upload (there is none by rule — media stays where it is).

## Carried forward

1. Stage 7: runtime image (payload + API + `tini` + HEALTHCHECK) with the UI mounted;
   Compose publishes `127.0.0.1:8787` — "open http://127.0.0.1:8787" is the product.
2. Stage 8: the job runner + UI on `/data` volumes across restarts; log rotation.
3. Shared-layer potential with `shell/ui` stays open (same paradigm, same API).
