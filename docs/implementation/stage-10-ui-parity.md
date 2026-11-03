# Stage 10 — the web UI reaches desktop parity (theme, filters, opening files)

The user's brief: *"the webUI should function similar to the digup application … add option
for light and dark mode … run through the desktop application and make sure all functions
are also in the docker application … find a way to download more images for testing."*
Stage 6 shipped a minimal honest UI; this stage makes it behave like the app, adds the one
endpoint the app's "Open" needs, and grows the test material — with the desktop's own
source (`shell/ui/panel.js`, `results.js`, `settings.js`, `settings.html`,
`Sources/DigUpApp/SearchPanel.swift`) read through first, feature by feature.

## What changed

**`GET /api/v1/media/{media_id}/file` — the app's "Open", over HTTP** (`api.py`):

* the same discipline as `/preview`: only a server-issued handle resolves; the path it
  names must resolve **inside the server's configured roots** (the engine produced it;
  the roots are the deployment's, never a client's) and must be a file that is there now
  (404 for unissued ids, out-of-roots paths, and files that left the folders);
* the media type comes from the file's **magic bytes**, not its name, and code/doc content
  is served `text/plain` **as an attachment** — a source file named `index.html` never
  arrives as markup that could run script on the server's origin;
* media kinds (image/screenshot/video/audio/pdf) arrive `inline` so the browser opens
  them; everything else `attachment` (Download keeps the name via `filename*=UTF-8''`);
* **`Accept-Ranges: bytes` + Range parsing**: `bytes=a-b`, open ranges, suffix ranges →
  206 with `Content-Range`, 416 with `bytes */size` for an unsatisfiable span. That is
  what makes `<video src=…#t=loc>` seek in the browser; `If-Range` is deliberately not
  honored (a 304 teaches the UI nothing; video seeking never sends it).

**The UI (`server/ui/`, rewritten) — the desktop panel's behavior, vanilla JS:**

keyword-first typing on every keystroke (`meaning:false, prefix_last:true` → `embed_ahead`
→ the `meaning:true` upgrade after 120 ms, generation + final-generation guards, like
`panel.js`); strong/weaker split with the "N weaker matches" fold; kind checkboxes →
`kinds` (none ticked = all = the engine's default); the `code:` prefix and a code checkbox
as one state; a limit select (default 40, the engine's own default); grouped rows with
lazy engine thumbnails (images/screenshots/PDF pages — video keeps its frame in the
preview pane at the moment, so a list of videos doesn't spend the engine extracting
frames nobody is looking at); a preview pane for the selection (photo, video frame that
plays *from* `#t=loc`, PDF page, audio player at the moment, matched passage via `/text`),
its facts line (`kind · size · date · z · cosine · keyword #n · segment`), a plain-language
reason line built from the engine's own fields, Open + Download; Space for the big look
(Esc away, arrows keep navigating under it, as Quick Look); the footer's summary + keys
line, quoting the helper's own error when there is one; the activity dot for
encoder-warming and job-running; the Estimate panel (`POST /estimate`): per-folder
forecast with kind counts, PDF pages, audio/video durations, bytes, top subfolders, and
the honest `calibrated` badge ("measured here" vs "reference times"); roots published by
`/status` and printed under the search box.

**Appearance (the theme ask):** the desktop follows the OS; a headless server has no OS to
follow, so the UI offers **System / Light / Dark** (a select, `data-theme` on `<html>`,
CSS variables, kept in `localStorage`). "System" tracks `prefers-color-scheme` exactly as
the desktop does; Light/Dark force it. The desktop shell has no theme UI to copy — its
`panel.css`/`settings.css` use system colors (`canvas`, `field`, `canvastext`) and follow
the OS; the web UI keeps that paradigm for the System setting and adds the choice.

**Settings mapping (the honest "not entirely apply"):** the desktop settings are OS
integrations — login item, tray click, global shortcut, window centering, auto-update,
index hours, folder pickers, pause-indexing, the code editor, licenses. For a server,
those are *deployment configuration*: roots, exclusions, models, prewarm, backfill, log
rotation — the env knobs (`.env.example`, Compose) — with Index now / prune missing as the
manual index control in the UI. Two native-app behaviors are **absent, not faked**:
*Show in Finder/Explorer* (reveal) and *Copy file* (clipboard with the file) — a browser
page opening files in the OS is a native privilege.

**More test images (corpus2):** the suite's corpus must stay exactly 15 files (z
normalizes over the live candidate set, so its rankings are pinned to that set), so new
test photos go to `server/tests/corpus2/`: 60 Wikimedia Commons photographs (3 per subject
across 20 subjects, enumerated from the Commons API, curated by hand), fetched as 1400 px
renders by `build.sh`, **sha256-pinned** in `manifest.tsv`, kept out of git like the
corpus's videos. README there documents provenance, licenses, and the Compose mount for
live runs.

## Tests (suite16)

* UI surface: theme attribute + select, kind checkboxes, code checkbox, `prefix_last` +
  `embed_ahead` in app.js, localStorage, the keys line — on top of the Stage-6 dependency-
  free rules (no external URLs, no modules);
* `/file`: the photo's real JPEG bytes with `Accept-Ranges` and an inline disposition;
  Range → 206 (`bytes=0-99` = the first 100 bytes, `bytes=-40` = the last 40, open range =
  the last 10, `bytes=size-` → 416 `bytes */size`); a document arrives `text/plain`
  attachment with its words; unissued handle → 404;
* `/status` publishes the server's own roots (`roots == [corpus]`).

Added after the browser pass (the lessons the live browser taught):

* refusal pair: an `ok:false` reply raises `EngineRefused` in the adapter; `/search` and
  `/status` answer **503 with the engine's own sentence** — no engine mocks (an injected
  refusing service, a stub refusal reply);
* every UI byte carries `cache-control: no-cache` + etag — measured: without it Chrome
  served a stylesheet the server no longer had;
* video `/file` carries a playable media type — the magic sniff reads `ftyp` at offset 4
  and the brand at 8 (`scenes.mp4` → `video/mp4`).

**Suite: 57 passed, 1 deselected in 241.18 s (EXIT=0)** — 48 from Stages 3–8 + 9 new
(the Stage-3 `raw()` passthrough contract — `test_unknown_op_is_the_engines_error` — keeps
pinning that refusal replies reach a caller verbatim *there*; typed ops raise).

## Proof

The layout pass (2026-11-02, after the user's layout brief): the page is a centered
search box with the hit-limit select at its right end, theme-colored kind chips in one
evenly spaced row under it, results bottom-left and the preview right; the header carries
just the title, the searchable count and a gear. **Appearance, Index now, prune missing,
Estimate and the engine's counts live in the settings panel behind the gear** — Estimate
kept as the engine's own honest forecast, one short note line, rendered *above* the
results. (`panel.js` parity re-checked: `limit: 40` fixed on desktop = the engine's
default = this UI's default, the select a superset; the WEAKER fold, group rows,
keyboard flow and footer summary are line-for-line the desktop's.) "water → only the
harbor photo" is the engine, not the UI: `Searcher.zGate = 2.0`
(`Sources/DigUpKit/Searcher.swift:116`) filters candidates below 2σ **in the binary**,
and the Linux app with the same index answers the same single hit; the server publishes
what the engine returns, unchanged. The `el()` helper now takes real child nodes — its
one-arg shape used to stringify elements, printing `[object HTMLElement]` (measured in
the estimate panel and preview messages; gone, verified in the browser).

Live battery (`stage10-proof.sh` — compose stack, corpus2 gallery, curl + python, gate on
readiness; refusals retried and printed):

* **Boot:** `digup-server-server-1 · Up About a minute (healthy)`; `status: files 61 ·
  searchable 61 · encoder ready · roots ['/media/photos']`.
* **UI surface (same origin):** theme select, kind checkboxes, code checkbox, limit,
  estimate button, keys line — all served; `style.css: cache-control: no-cache`.
* **Index job `ca0f1e90efcc`** (idempotent rescan — nothing changed since the gallery was
  indexed): `done 61 · 0 new · 65 vectors · 0.4 s`; gate: `files 61 · searchable 61 ·
  encoder ready · ok`.
* **Six meaning searches, each strong 3**, top z: coral reef **4.15**, snow village **4.46**,
  library shelves **4.05**, wakeboarding lake **4.04**, coffee+laptop desk **3.90**, autumn
  path **3.24**; embeds 2.1–10.9 s on CPU, searches 0–142 ms.
* **Kind filter (video only):** `scenes.mp4 · loc 0.5 · z 5.2`. **Keyword-first**
  (`meaning:false, prefix_last:true`) on `wakeboa`: hits `wakeboarding-lake-powell.jpg`,
  `wakeboarding-bolesworth.jpg`, `wakeboarding-lake-travis.jpg`.
* **`/file` on `calico-cat-sofa.jpg`:** 200 `inline; filename*=UTF-8''calico-cat-sofa.jpg`,
  `image/jpeg` (magic `ffd8ff`), 124,177 bytes, `accept-ranges: bytes`;
  `bytes=0-99` → **206** `bytes 0-99/124177` (100 bytes); `bytes=-40` → **206**
  `bytes 124137-124176/124177`; open range past the end → **416** `bytes */124177`;
  unissued handle → **404**.
* **Video seek path:** `bytes=100-199` → **206** `bytes 100-199/766733`;
  preview frame at the moment → JPEG (`ffd8ff`). Content type **`video/mp4`** — the
  browser check caught the magic sniff reading the MP4 brand at the wrong offset
  (every real MP4 fell to `octet-stream`), fixed and pinned by a test.
* **Estimate:** `folder /media/photos · ≈ 263.9 s · {image: 60, video: 1} · calibrated True ·
  looked 189 ms · video 18 s` — wall 0 s (the engine's own forecast, not a walk).

The browser battery (Playwright, Chromium, at `http://127.0.0.1:8787/`):

* typed `cluttered office desk` → **5 hits · 4 strong**, top `office-desk-cluttered.jpg`
  z 3.6; clicking the row opens the preview pane with facts + Open/Download; Space opens
  the big look, Esc closes it; the appearance select flips the page white↔dark live;
  statusline reads `61/61 files searchable · 65 vectors · encoder ready · index 201 KB`;
* the dark theme with results + preview, the estimate panel, and the light theme were
  screenshotted and assessed: 9/10 readable, panels/borders/selection/ticks all visible
  (the pre-fix screenshots: "essentially illegible" — the 78%-black `#big` overlay sat over
  the whole page and intercepted every click).

**Found in the browser, fixed the same session** (Stage 10's method working as intended):
the `#big[hidden]` overlay bug, the stale-CSS deploy problem (`cache-control: no-cache`),
`index NaN KB`, the MP4 magic offset — and the mid-transition refusal became
`EngineRefused` → **503 with the engine's own words** instead of the 500 the first battery
run measured (`KeyError: 'hits'`, `POST /search → 500`, six searches, then clean recovery).

## Evidence

Suite (20): **57 passed, 1 deselected in 236.12 s, EXIT=0** (`server-tests20.log`, with the
layout pass in place; suite 19 recorded the same 57 in 241.18 s before it);
the 56 before the MP4 sniff test: 192.51 s, EXIT=0 (`server-tests17.log`). Live battery
log: `stage10-proof.log` (transcripts quoted above, all numbers from that log).
Screenshots: `.playwright-mcp/`
(`dark-results.png`, `dark-estimate.png`, `dark-biglook.png`, `light-results.png`,
`v2-dark-results.png`, `v2-settings.png`, `v2-estimate.png`, `v2-light-results.png`,
`v3-settings-dark.png`, `v3-dark-home.png`).
