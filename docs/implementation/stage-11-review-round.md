# Stage 11 — the review round: adversarial review, parity proof, CI that can't pass by luck

Rules this stage follows: docs/implementation/README.md §1 (the engine is DigUp's, never
rewritten), §2 (tests prove the shipped payload), §9 (git safety). Findings come from
three read-only adversarial reviews (backend; UI + media; build/CI/docs), each one asked
for **concrete failure scenarios**, and every finding was verified against the code and
the live stack before anything was changed. The full finding→fix→test table is
[review-round.md](review-round.md).

## The harness fact this round discovered (and it changed the test image)

The first suite run after the backend fixes: `7 failed, 9 passed, 59 errors`, every engine
helper dying `exit 0`, no stderr. Not a code bug — `docker run` makes the test process
**PID 1**, and ParentWatch ends a helper whose parent is PID 1: "launchd took it in: the
app is gone already" (`Sources/digup/ParentWatch.swift:19`, the Linux branch checks
`getppid()` every second). The suite's app spawns `search-service` as a child of the test
process, so the test process must be a live parent. The runtime image already gets that
from tini; **the test image now carries tini as its ENTRYPOINT** — the suite is PID-1-safe
by construction, CI needs no `--init`, and the production shape is what the suite proves.
Same rule in CLI form: `--index` takes a **folder**, not the `.sqlite` file
(`IndexStore(directory:)` → `createDirectory(at:)` → EEXIST → NSCocoaError 516).

Measured after the change: **75 passed, 1 deselected, zero skipped** in
`digup-server-test:local` — 228.12 s (`suite23.log`), reproduced on the final committed tree
in 235.15 s (`suite24.log`, EXIT=0).

## Parity: the server answers exactly what the engine's own adapter answers

The user asked whether the server behaves like the DigUp app ("100% functions like the
digup application"). The honest test is: run the app's own adapter (`SearchService`, the
JSON-lines protocol client the shells use) against the index, and compare with what the
HTTP API publishes for the same queries. Same corpus2 index, same folders, same model.

Adapter on a `sqlite3 .backup` snapshot of the same index (`stage11-parity-direct.log`,
the log's first half — the app adapter direct, no HTTP layer):

```
READY {"event": "ready", "index": "/tmp/idx2"}
{"q": "water",              "meaning": true,  "hits": 1, "strong": 1, "top_z": [2.09]}
{"q": "harbor",             "meaning": true,  "hits": 2, "strong": 2, "top_z": [3.87, 2.35]}
{"q": "harbor",             "meaning": false, "hits": 2, "strong": 2}          // keyword-first
{"q": "a sunset over water","meaning": true,  "hits": 3, "strong": 3, "top_z": [3.51, 3.37, 2.28]}
{"q": "wakeboarding",       "meaning": true,  "hits": 3, "strong": 3, "top_z": [4.15, 4.06, 3.09]}
{"q": "wakeboarding",       "meaning": false, "hits": 3, "strong": 3}          // keyword-first
{"q": "fractal",            "meaning": true,  "hits": 1, "strong": 1, "top_z": [3.59]}
STATUS files=61 searchable=61 vectors=65
```

The same five queries over HTTP on the live server, taken in the same run:

```
{"http": "water",               "hits": 1, "strong": 1, "top_z": [2.09]}
{"http": "harbor",              "hits": 2, "strong": 2, "top_z": [3.87, 2.35]}
{"http": "a sunset over water", "hits": 3, "strong": 3, "top_z": [3.51, 3.37, 2.28]}
{"http": "wakeboarding",        "hits": 3, "strong": 3, "top_z": [4.15, 4.06, 3.09]}
{"http": "fractal",             "hits": 1, "strong": 1, "top_z": [3.59]}
```

**Identical, hits for hits and z for z** — the server publishes the engine's answers
without touching them (its rule, README §7). Keyword-first (`meaning:false`,
`prefix_last:true`) runs on both paths too, and the adapter's own counts match
`/status` (files 61, searchable 61, vectors 65).

One probe lesson worth keeping in the record: an early version of this probe mounted the
live index **read-only** and returned 0 hits for every query, which looked like a server
bug. It is a probe artifact: a WAL-mode database needs write access to its sidecars, so
a read-only mount of a *hot* index is not a snapshot (the server never does this — it
owns its index folder read-write, which is what the snapshot reproduces). A plain `cp`
of a live index is the same trap. `sqlite3 .backup` is SQLite's own online-backup API
and answers correctly, three runs in a row.

## "Less responses than the app" is the corpus, quantified

`Searcher.zGate = 2.0` (`Sources/DigUpKit/Searcher.swift:116`) is the engine's own
publish gate on every platform, and the Mac app exposes no limit parameter: the engine's
default limit (40, `Sources/digup/SearchService.swift:130`) is the server's and the UI's
default. corpus2 is **61 files**; a real library is thousands. Above 2σ, corpus2 yields
1–3 hits per query (measured: z 2.09 … 4.46); the same engine over a personal library
answers correspondingly more. The server adds no cap, and the UI prints the engine's
counts verbatim — "fewer hits" is the size of the corpus, not a filter. Recorded in
`server/README.md` and `server/tests/corpus2/README.md`.

## Live proof battery (the review round's own gates, `stage11-proof.sh`)

Against the redeployed stack (runtime image `digup-server:local`, 563 MB; corpus2
gallery, `index-corpus2`):

* `docker compose config --quiet` green; container up **healthy** via the image's own
  `healthcheck.py`; `restart: unless-stopped`; published `{127.0.0.1 8787}`.
* `healthcheck.py` exit 0 on the live `/health`, and exit non-zero with nothing listening
  (the 503-is-alive rule, checked both directions).
* 12 health polls in 1 s wall — the identity fields come from the TTL cache, not from 12
  `digup status` subprocesses.
* index job over the 61-file gallery: `done · searchable 61/61 · files_done 0 ·
  vectors 65 · 0.1 s` (idempotent rescan: the engine finds nothing new to embed, and
  says so — no invented work), gate `files 61 · searchable 61 · encoder ready`.
* searches (meaning): coral reef **3 strong** (z 4.15/4.04/4.05), snow village **3**
  (4.46/4.03/2.01), wakeboarding **3** (4.04/3.92/3.29), coffee+laptop **3**
  (3.9/3.47/3.54); keyword-first `wakeboa` → 3 hits, `meaning false`.
* `/file`: **nosniff on 200 and on 206**; `Range: bytes=0-` → `206 bytes 0-124176/124177`
  (the open range capped and streamed, the span exactly as promised); `416` with
  `bytes */size`; `404` for an unissued handle.
* estimate: `≈ 263.9 s · 61 files · calibrated true · looked 126 ms` — 0 s wall (the
  engine answers from its measured costs).
* served UI bytes carry the review fixes (markers pinned): the Space guard, the poll
  hardening, the 10 % chip mix, `.badge.warn`.
* parity block (above). **`STAGE11-PROOF PASSED` (0 failed gates).**

## Browser verification of the keyboard fixes (Playwright, no vision model)

* Space with the **gear focused** → Settings opens (not the big look), `aria-expanded="true"`,
  focus lands on the first control. Before the fix: the gear did not activate and the
  overlay flashed over the page.
* **Esc** → panel closes, `aria-expanded="false"`, focus returns to the gear.
* Space with a **result row focused** → big look opens with the selected file and its
  media; Space with the **Open link focused** is native activation (the handler returns).
* Search → 3 hits · 3 strong, preview shows the engine's fields (name, folder, kind,
  size, date, z, cosine, segment); the video hit plays at its moment
  (`src=…/file#t=12.5`, "▶ at 0:12", z 3.25).
* Index now → `done · searchable 61/61 · vectors 65 · 0.1 s`, activity badge clears.
* Estimate → the engine's forecast (`≈ 4 min 24 s`, "measured here", per-kind counts);
  settings closes on opening it, gear aria in sync.
* Dark theme applies and persists (`localStorage`), geometry sane at 1280 px, the closed
  overlay is `display: none`, `overflowX: 0`, and the console is clean (the standing
  favicon 404 silenced with a `data:` icon — no external URL).

## Files this round touched (additive-only invariant held)

`git diff --name-status main..feat/server` = **61 A + 1 M** (`.gitignore`, append-only).
`Sources/`, `shell/`, `website/`, root `README.md`, `Package.swift`, upstream workflows:
untouched. Round-specific changes: `server/digup_server/{api.py,jobs.py,engine/*}`,
`server/ui/{app.js,index.html,style.css}`, `server/tests/{test_*.py,proof.sh}`,
`server/docker/{Dockerfile,healthcheck.py}`, `.github/workflows/server.yml`,
`deploy/docker-compose.yml`, `.dockerignore`, `.gitignore`, `.ci-vendor/.gitkeep`,
`server/README.md`, `server/tests/corpus2/README.md`, `docs/implementation/{README.md,
stage-3-adapter.md,stage-7-runtime-image.md,stage-8-persistence.md,review-round.md}`.
