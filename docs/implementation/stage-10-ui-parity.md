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

**Suite: 53 passed, 1 deselected in 190.18 s (EXIT=0)** — 48 from Stages 3–8 + 5 new.

## Proof

<!-- fill: /file 206 over HTTP on the compose stack; live UI sweep (playwright: theme light/
     dark, typing, filters, preview, open video at moment, estimate); corpus2 run: 60 photos
     indexed, searches, gallery -->

## Evidence

<!-- fill after the live run: curl transcripts, the corpus2 index job's counts, UI
     snapshots. -->
