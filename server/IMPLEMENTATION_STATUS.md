# Implementation status

One document, kept current (docs/implementation/README.md §10). Newest first.

## 2026-11-08 — The web UI on Lit + Vite (user brief): component architecture, same page, same contract

The user's brief executed: `server/ui/` migrated from vanilla JS to **Lit + JavaScript ES
modules + Vite** — no TypeScript, no React/Vue/Angular, no router/state library, **no Node
at runtime**. The page renders the same, talks to the same `/api/v1` with the same bodies
and auth shapes, keeps every measured style value, and keeps every contract the suite
pinned. The architecture manual is `server/ui/AGENTS.md` (new, binding inside `server/ui/`);
`docs/implementation/README.md` §10.4/§10.5 carry the dated amendments recording the route
("Node at Docker build time only" — the runtime images ship static files).

**What ships.** Thin HTML shells (`index.html`, `embed.html`) + `src/` (21 modules):
one store + `storeController` (slice selectors, element-wise tuple equality), four
controllers that keep the sequencing tokens (search generation, `jobPoll`, `estimateToken`
— keyword-first typing with `prefix_last` + `embed_ahead`, the job-poll loop with its
409 dedupe and the S1 honest-failure line, the estimate with its cancel, the keys rows),
ten Lit components (`digup-app` shell · search · suggest · results · preview · big ·
footer · settings · embed; the Estimate toggle stays inline in `digup-settings` — single
use site), `services/api.js` as the ONLY `fetch()` (bearer header, the 401 shapes, the
422 detail-list, `blobOf`), `lib/format.js` + `lib/media.js`, `styles/` (tokens.css,
global.css, embed.css, `controls.js` shared Lit `css` chunks). The layout's ONE switch
survives as `body[data-page]` **mirrored onto the shell host** (`:host([data-page=…])`
— shadow panels are out of a body selector's reach); `firstUpdated` paints the first
state (the vanilla startup `render();` as a lifecycle).

**Serving, unchanged in kind.** `api.py` mounts the **built** frontend — FastAPI serves
`server/ui/dist` at `/` with the same `UIFiles` no-cache decoration; `DIGUP_SERVER_UI`
relocates the mount (an override with no `index.html` is a startup error, never a silent
404 page). Stable asset names stay the contract: `vite.config.js` maps Rollup output to
`app.js` / `style.css` / `embed.js` / `embed.css`; shared chunks/assets are content-hashed
and *linked from the html* — the contract-suite asset walks read the links, so a re-hash
never needs a pin change. `.dockerignore` keeps host `dist`/`node_modules` out of every
image; `.gitignore` keeps them out of git.

**Docker.** New `frontend-builder` stage (`node:22-slim`): `npm ci` (committed lockfile)
→ `npm test` (vitest) → `npm run build`; `server-test` and `server-runtime` COPY the dist.
A red unit test or a red build is a red image by construction; CI needs no new step (the
targets build through it; the runtime page grep — "DigUp" + "app.js" — passes on dist).

**Contract pins, moved not dropped.** `test_media_ui.py` + `test_integrations.py` read
the served **bundle** (entry + hashed chunks; `_bundle`/`_styles` helpers): Lit ships
`css`` chunks as runtime styles, so component CSS is bundle text verbatim; minification
strips whitespace between JS tokens, so pins written for the old HTML source are restated
for minified bytes (e.g. `"screenshot","Screenshots"`, `groups:\s*\[\]`). `type="module"`
is now a REQUIRED shape pin (the old "no module" pin inverted with the migration, by
design, in the same commit as the change). The Space guard, the engine's sentences, the
endpoint literals, the gear section order, the 40/60 grid, the 2 rem row, the
`prefers-reduced-motion` fade, the `overflow-x: clip` rule — all pinned, all green.
One fixture transcription fix rode with it: `doc_client` roots now point at the scratch
corpus folder, not at its index folder (the ghost-row scope trap — rows outside scope
answer 0 hits; probe-verified: doc search answers z 4.9 with correct roots).

**Measured on ai-ubuntu-computer** (x86_64, kernel 7.0.0-38-generic, Ryzen 9 7950X,
64 GiB; Node v22.22.1, npm 9.2.0):
- `npm test` — 52 unit tests, 12 files (api, store, 4 controllers, 6 components, both
  entry boots), **52 passed, 0 failed**, 1.18 s (jsdom, fake timers, stubbed fetch).
- `npm run build` — clean, 287 ms: `app.js` 61.0 kB (18.8 kB gzip), `embed.js` 10.1 kB
  (3.9 kB gzip), `chunks/vendor` 15.1 kB (5.8 kB gzip), `chunks/format` 4.0 kB,
  `assets/format.css` 2.2 kB, `style.css` 0.25 kB, `embed.css` 0.02 kB.
- Docker `--target server-test` build: green with the frontend-builder stage running
  npm ci / vitest / vite build inside the build.
- Contract suite (all four mounts, `/srv/server/.venv/bin/pytest -rs`): **137 passed,
  1 deselected (the `-m slow` timing test), 0 skipped** — the baseline count, restored
  after the fixture fix above. Every SKIPPED is a FAIL here; the run reports zero skips.
  The FINAL gate re-ran the same command on the shipped tree (legacy deleted, dist from
  the last sources): **137 passed, 1 deselected, 0 skipped, 194.06 s**.
- Runtime image (`--target server-runtime`) + CI-parity smoke: boot, `healthcheck.py` 200,
  page grep ("DigUp" + "app.js"), `docker stop --timeout 15` → exit **143** (not 137)
  with `Application shutdown complete` in the log.
- Legacy vanilla files (`app.js`, `style.css`, `embed.js`, `embed.css` at the `server/ui/`
  root) deleted after the green suite — `dist/` is the served UI.

**Not done here (disclosed):** the human browser pass (Stage-11 release step; no browser
in this harness); the visual identity was carried over value-for-value, not re-measured.
Commits: none made (README §9 — no commits/pushes without explicit ask).

**Cutover on this box (measured 2026-11-08, the user's test port):** the standing 8787
stack was recreated on the new CPU runtime image (`docker compose -f docker-compose.yml
up -d --build`, the full env chain — the media dir, roots, timeouts, minted keys — never
defaults, per the recreation rule; the GPU/LAN overlays untouched, restore path = the
standing bench bring-up script with its full chain). Measured on the live stack:
`GET /` serves the thin shell with `type="module" src="./app.js"`; `/app.js` `/style.css`
`/embed.html` `/embed.js` `/embed.css` all 200 with `cache-control: no-cache`;
`/api/v1/status` = 131 972 files · 131 758 searchable · 403 831 vectors · roots as before
(the standing index, in scope — no prune needed); `/api/v1/health` 200 `ok:true`,
encoder ready; three searches 10 hits / 10 strong each, 0.74–0.97 s, top z 5.15–7.11.
The job log's newest record predates the recreation (no job was running: nothing lost,
`interrupted` records intact from earlier runs).

**User browser pass, round 1 (2026-11-08): the double-page finding.** On the live page
two DigUp headers stacked — the declared element and a second, unwired instance. The
thin shells DECLARE `<digup-app>` / `<digup-embed>`, and the entries also
`createElement`d one: the unwired twin rendered its bare template above the working app.
Fixed in the same round: the entries now wire **the declared element** (`querySelector`,
`createElement`+append only as the fallback), and the components gate on the wiring —
`render()` paints nothing until `store`+`api` arrive, the boot (focus, the 15 s status
poll, the widget's health + `?q=` run) fires on the first update where the entry wired
them (the wiring setters `requestUpdate`). `server/ui/AGENTS.md` records the rule
(html declares, entry wires). Pins added in the same change, disclosed:
`test_media_ui` (one declared pair in the html + the entry's `querySelector` line + the
fallback append), `test_integrations` (same for the widget); the entry boot tests
`main.test.js` / `embed.test.js` declare the element first and assert exactly ONE wired
instance. Measured after the fix: unit 52 passed, build 317 ms (app.js 61.28 kB /
18.90 gzip); served page carries one `<digup-app>` pair; loopback + the box's LAN DNS name
:8787 200, status 131 972 files · 131 758 searchable · 403 831 vectors, embed page 200,
untrusted Host 400. Checkpoint gate after the fix (test image rebuilt from the fixed
tree, full suite): **137 passed, 1 deselected, 0 skipped, 189.55 s**.

**Fast iteration loop (the user's ask, documented in `server/ui/AGENTS.md`):**
a UI fix is now edit → `npm run build` (0.3 s) → browser refresh. The dev shape binds
the host `server/ui/dist` over the image's baked dist (a local-only overlay,
`DIGUP_UI_DIST`-forced) — `StaticFiles` reads per request, every UI byte is
`no-cache`, so the refresh lands the new bytes with no image build and no restart;
`npm run dev` (:5173, `/api` proxied to :8787) is the hot-reload variant. The contract
suite + the runtime image build are checkpoint gates, run per batch of fixes.

**LAN dev server (the user's ask, 2026-11-08):** `vite.config.js` dev bind + host
allowlist + watcher are env-forced, default loopback: `DIGUP_UI_DEV_HOST` (bind),
`DIGUP_UI_DEV_ALLOWED_HOSTS` (Vite host guard), `DIGUP_UI_DEV_POLL=1` (polling watcher —
this box's inotify limit is exhausted: first boot died `ENOSPC`; sudo needs a terminal
here, so polling is the fix). Measured: 0.0.0.0:5173 listening, LAN DNS name :5173 200
(0.0034 s), LAN IP 200, loopback 200, untrusted Host 403, `/api` proxy answers the real
engine counts (`changeOrigin`, so the API keeps its loopback Host). Disclosure: the dev
server is LAN-visible without auth (the standing home-LAN trust model); it is a dev
shape — the committed default is loopback, production is the built dist.

**User browser pass, round 2 (2026-11-08): four UI findings, all root-caused.**
1. *Gear clipped a quarter*: my transcribed SVG path had lost ring segments (497 chars
   vs vanilla's 622) — the geometry was missing, not the style. Restored the vanilla
   path verbatim.
2. *Results list rendered as bare bullets*: `digup-results` shipped only `badgeCss` —
   the list's layout rules (rows, group titles, thumbnails, the fold) had not moved into
   the component, so the browser drew default `<li>` discs. Ported the vanilla rules
   verbatim into the component's shadow styles (+ a row `:focus-visible` outline).
3. *Open/Download as plain links*: the pane builds `a.button-like` (lib/media.js) but
   `digup-preview` never imported `controlCss` — imported; real buttons.
4. *Settings panel rework (the brief)*: the Estimate toggle moved to the RIGHT of the
   Estimate button and lost its "on/off" caption; THE INDEX reads `Looking in: <roots>`
   first, then the fact badges, then the index rows; the API key section shows ONE label
   with the key in a readonly text box (click selects all), `⧉ Copy` and `↻ Regenerate`
   at its right (minted app keys use the same shape). Measured after the batch: unit
   **52 passed / 52** (the settings test updated for the new row shape in the same
   change, disclosed), build 283 ms (`app.js` 65.05 kB / 19.89 gzip), checkpoint suite
   **137 passed, 1 deselected, 0 skipped, 172.83 s** — the layout pins (2 rem rows, the
   minmax() key grid, `#keys-regenerate` margin-left, the estimate switch,
   `overflow-x: clip`, `.set-facts` nowrap) verified present in the bundle.
   Lesson recorded in `server/ui/AGENTS.md`: a component owns its shadow styles — the
   migration must move EVERY rule the vanilla page had for that region; a missing import
   is invisible to unit tests and shows up in the browser as an unstyled region.

**User browser pass, round 3 (2026-11-08):** (1) every panel line is one row height (the
2rem token) and the one-line target rows are gone — the index's counts ride beside
`Looking in: <roots>` in parentheses, abbreviated, from `/api/v1/status` verbatim (the
shell's status slice gained `files`/`searchable`); the named-app-index counts left the
panel with them (disclosed to the user; `GET /api/v1/targets` unchanged). (2) The API key
field widened (label column `minmax(4rem, 6rem)`, field `minmax(0, 1fr)`) and the actions
became icon-only `⧉` / `↻` with `aria-label` + `title`. (3) The estimate knob is centered
in the oval (`top: 50%` + `translateY(-50%)`). Measured: unit **52/52** (the settings test
updated for the new shapes in the same change), build 286 ms (`app.js` 66.20 kB /
20.18 gzip), bundle pins verified (`roots-sum`, `key-icon` ×3, knob centering,
`minmax(4rem, 6rem)` grid, `id="targets"` → 0 occurrences), checkpoint suite
**137 passed, 1 deselected, 0 skipped, 172.44 s** (two contract pins restated in the same
change, disclosed: `appkeys` + `roots-sum`; the key-grid prefix).

**User browser pass, round 4 (2026-11-08) — Settings redesign (the user's ChatGPT
 layout brief):** the gear panel's internals were reorganized in the SAME component into
 four stacked sections — **Appearance · Indexing · Index status · API access** — each with
 a small inline-SVG icon (palette / database / activity / key: 15 px, accent-colored,
 `aria-hidden`) and a 15.2 px semibold heading, 22 px section rhythm around 1 px dividers
 (`--space-md` above and below), 12 px radii on every panel box (the key rows + field get
 it panel-scoped — the shared `keyRowCss` leaves the embed widget's rows as measured),
 muted descriptions, restrained blue accents, no box-around-every-section. The modal frame
 is untouched: same width, anchor under the gear, overlay order, the five close paths.
 INDEXING: Index now + prune missing on one row; Automatic estimates on its own row,
 switch right-aligned, muted description beneath; the forecast box scrolls inside its own
 bounds only. INDEX STATUS is the one distinct card: folder icon + `Looking in: <roots>`,
 **Total files / Searchable files** as two side-by-side stat tiles (the `/api/v1/status`
 slice verbatim, `—` when no data), the capability badges wrapping naturally with semantic
 tones from the engine's own strings (`vectors > 0` and `encoder ready` → green,
 `starting` → amber, `unavailable` → red, `stopped` → muted). API ACCESS keeps the round-3
 shape (wide field, icon-only `⧉`/`↻`). Preserved verbatim: the store slice, all six
 events, `focusFirst()`, the empty-section collapse, every control id. Measured: unit
 **52/52**, build 283 ms (`app.js` 68.83 kB / 20.89 gzip), bundle bytes verified
 (heading-id order, heading texts, `status-card`/`stats`/`toggle-row`, `border-top: 1px
 solid var(--line)`, `flex-wrap: wrap`, `overflow-y: auto` → 0); four contract pins in
 `test_media_ui.py` restated in the same change, disclosed: the section-order pin rides
 the heading ids + texts (the icons now live inside the title spans), `.set-facts`
 nowrap → wrap (badges wrap by brief), and the new card/stats/toggle-row/divider pins.
 Checkpoint suite: image unpack 2.7 s, **137 passed, 1 deselected, 0 skipped, 183.24 s**
 — the restated pins are in that green run.

**User browser pass, round 5 (2026-11-08):** (1) The `Looking in: <roots>` line left the
 status card (the roots stay in `GET /status`; the card's two tiles carry the counts).
 (2) The estimates description line left with the rename: the row is now **Estimate** +
 right-aligned switch (the description span and its `.set-desc` rule are gone; the toggle
 keeps its `title`). (3) The copy buttons now work where the panel is served over **http**
 on the LAN — an insecure context has no `navigator.clipboard` at all: `#copy()` uses the
 async clipboard when present, falls back to hidden-textarea `execCommand("copy")`, and
 the button answers `✓`/`—` for a moment. New unit test covers the fallback (jsdom has no
 clipboard — the exact LAN shape): unit **53/53**. The regenerate chain was proven on the
 live dev stack (8787, minted shape): keyless `GET /tokens` → ticket, `POST /tokens`
 (admin) → rotated 200 with a new key, `POST /tokens` with the dead key → **403** ("the
 keys answer the admin token only"), keyless `GET /tokens` after rotate → the ticket is
 the new key (the gear adopts it, the panel shows it, copy copies it). Disclosure: the
 proof rotated the dev stack's minted keys — browsers self-heal on the next gear open.
 (4) Main-page layout (the user's layout brief): the header bar bleeds to the **screen**
 edges (`margin-inline: calc(50% - 50vw)` + 1.25 rem padding, `overflow-x: clip` on body
 absorbing the scrollbar sliver) — DigUp left, gear right, settings panel re-anchored at
 `right: 1.25rem` so its edge lines up with the gear; the footer strip bleeds the same way
 — summary left, keyboard instructions **right edge**; the search input is centered on the
 exact axis of the chips under it (the limit select + code box leave the row's flow above
 1000 px, riding the input's right; below it they drop back as a centered row — new 1000 px
 fold, 720 px fold kept). Measured: unit 53/53, build 307 ms (`app.js` 69.24 kB / 21.18
 gzip), bundle verified (`roots-sum`/`rootsline` → 0, bleed/`right: 1.25rem`/`grid-column:
 1 / -1` present, pinned strings intact); one contract pin restated (`roots-sum` →
 `Total files`, disclosed); status card/stats/toggle-row pins kept green unchanged.
 Checkpoint suite: image unpack 2.3 s, **137 passed, 1 deselected, 0 skipped, 172.65 s**
 — the restated pin and the 53-test frontend gate (frontend-builder stage) are in that
 green run.

**User browser pass, round 6 (2026-11-08) — the estimate flow compacted:** the estimates
 toggle and the whole estimate section (forecast box + its rows) are **removed**; the
 Estimate button rides the row **left of Index now** (with `prune missing`). The INDEXING
 heading now carries the live state at its right edge: the true-circle spinner while the
 engine works (index job **or** estimate), ✓ (green) when it finished, `!` (warn) for an
 interrupted/busy job or a failed estimate (the full engine message rides the `title`),
 and the brief update beside it — the job's own words verbatim, or for an estimate the
 engine's seconds summed brief (`estimate ≈ 4 min 10 s · 3 folders`; disclosed: the sum is
 arithmetic over the engine's `folders[].seconds`, the per-folder rows left the UI, `POST
 /estimate` unchanged). Disclosed mechanics: the estimate CONTROLLER keeps its gate +
 click-again-cancel + `digupEstimateOn` browser key, and the shell now forces `on` on
 every Estimate click — a browser that had the old toggle switched off would otherwise be
 left with a dead button (measured in the code path). Measured: unit **53/53** (the
 forecast-rows test became the heading-summary test; the toggle event test is gone),
 build 284 ms (`app.js` 65.30 kB / 20.27 gzip — the panel shrank 4 kB), bundle verified
 (`estimate-toggle`/`estimate-switch`/`estimate-ctl`/`toggle-row` → 0, `set-head-row`/
 `set-state`/`state-done`/`state-err` present, `id="estimate"` count 0); contract pins
 restated in the same change, disclosed: `id="estimate"` count 1→0, `estimate-toggle`
 presence → absence, `estimate-ctl` → `not in css`, the `.estimate-switch` checked-selector
 pin dropped, `toggle-row` → `set-state`. Checkpoint suite: image unpack 2.3 s, **137
 passed, 1 deselected, 0 skipped, 191.10 s** — all round-6 restatements are in that
 green run.

**User browser pass, round 7 (2026-11-08) — `all` toggle + Nextcloud app filter &
 progress:** (1) Standalone: the `all` button in the kind row is a TOGGLE — all six ticked
 → click clears all → click restores all; `aria-pressed` + an accent border mark the
 all-on state. Engine semantics verbatim (all ticked = every kind; cleared = the engine's
 answer over an empty kinds list — 0 hits is the honest filter answer). Unit gate added a
 toggle test: **54/54**. (2) Nextcloud app **0.4.3**: the same six chips + the same
 all-toggle under the search bar; the ticked set rides the engine's `kinds` filter
 verbatim (PHP whitelists the list to the server's Kind literals — `ApiController` gained
 the `kinds` param, `DigupService` forwards it, routes/shapes unchanged). The activity
 spinner now stays visible for as long as the server reports a job `running`, with the
 live `files_done / total (pct %)` counts beside it — the progress poll re-arms itself on
 every `running` answer (user: "how many indexed out of how many remaining"). Deployed on
 the pilot (`docker cp` onto the bind-mounted app dir — the install tree is www-data-owned;
 `php -l` ×3 in-container clean; the registered version needed `occ upgrade` — the pilot
 instance had `needsDbUpgrade: true`, which blocked `app:update`; upgrade clean, integrity
 OK, maintenance off). Pilot live gate over the LAN name (session as the user the index
 covers): `[image]` → 8 hits all image · `[audio]` → 3 hits · all six → mixed ·
 progress `ok: true` `files_done 10,254 / index_files 131,973` · served `app.js` carries
 the new code (cache-bust verified). Measured on this box (ai-ubuntu-computer): unit
 54/54, build 285 ms (`app.js` 65.67 kB / 20.39 gzip). README history entry 13.

**Cleanup audit after the redesign storm (2026-11-08, the user's "did we clean up?"
 ask):** audited the whole frontend — every CSS selector in every `css`` chunk and
 global file against every class/id rendered anywhere, every `lib/format.js` export,
 every store slice's writers vs readers, every controller export, every shell listener.
 Result: **zero dead CSS selectors, zero unused helpers, zero unused controller exports**
 (the estimate controller's gate/cancel/`resetRetried` are all live code paths).
 Removed the three residues the rounds left: the shell's `roots` store write (its
 consumer, the panel's roots line, left in round 5 — writer without a reader), the
 shell's `@digup:estimate-toggle` listener (no dispatcher since the round-6 switch
 removal), and the rule-less `class="set-lines"` on the keys block. Kept by contract,
 disclosed: `keys-controller`'s `GET /targets` + its `s.targets` slice (the panel no
 longer renders the rows, but the endpoint literal and the reload-after-a-job behavior
 are pinned by the contract suite) and the estimate controller's on/gate state (the
 shell forces it on click so a browser with the old persisted toggle-off is never left
 with a dead button). Measured: unit **54/54**, build 287 ms (`app.js` 65.53 kB /
 20.36 gzip), bundle strings `digup:estimate-toggle`/`set-lines`/`roots: st.roots` → 0
 occurrences. Audit recorded in `server/ui/AGENTS.md` §State. Checkpoint suite: image
 unpack 2.3 s, **137 passed, 1 deselected, 0 skipped, 172.19 s** — the frontend-builder
 stage ran the unit gate (54/54) on the cleaned tree on its way in.

**Refactoring pass (2026-11-09, the user's cleanup+audit brief — full-surface audit,
then small verifiable changes):** the whole server reviewed — 2,776 Python lines
(api/security/jobs/targets + engine adapter), 2,447 UI JS, HTML, CSS, the 367-line
Dockerfile, all 9 compose files, the 507-line CI workflow. **Audit result: the
implementation was disciplined** — AST scan found zero unused imports/functions/classes
(every flagged name is decorator- or import-consumed: routes, exception handlers,
middleware); zero dead CSS selectors and zero unused UI exports; every Dockerfile stage
referenced (`engine-runtime` is CI-built, `cuda-libs` by the CUDA target); no engine
duplication (the server is passthrough — status parsing is the published CLI surface,
jobs count the engine's own events); embed widget intentionally separate (contract
pins); chronicle docs binding (§-refs in code comments) — kept. **Applied** (each a
small verifiable change): (1) removed `IndexService.sync_code` (zero refs, product and
tests) and `SearchService.folders()` + `_folders_fields` respawn replay (the server's
scope is argv at spawn — the replay existed only for a wrapper nothing called);
(2) **jobs.py counter consolidation**: the live job record already carries every
counter as the engine emits it (`_progress`), so the per-event `events` list + the
`_counts` re-scan were a second source of the same numbers — a 1.8 M-file job no
longer keeps a full copy of every event in memory; endings now read `_live_counts`
(keys the engine never published = None, same published shape; the unit pin that
called `JobRunner._counts([])` was adapted to assert the same guarantee through
`_progress` seeding + `_live_counts` — same assertions, no weakening);
(3) **api.py `make_runner`**: the JobRunner construction (config_dir, per-target log
name, reload→prewarm, ceiling, rotation) existed twice verbatim (lifespan + app
target spawn) — now one source; (4) **CI vendor-seeding consolidation**: the 18-line
vendor step was byte-identical in both jobs (server + publish) — now one YAML anchor
referenced by both (merge key; PyYAML-verified: parsed, one step per job, run scripts
md5-identical); (5) **UI export hygiene**: 11 internal-only `export` keywords demoted —
2 helpers in `media.js` + the 9 self-registering component classes (every component
file ends in its own `customElements.define`; zero importers in the app and in the
unit tests); (6) docs: `DIGUP_SERVER_STATUS_TTL_S` documented in `.env.example` +
the deploy README env table (code read it, docs never named it). **Kept by design,
disclosed**: `estimate_json/estimate_text/speed_model` (test-pinned CLI surface),
`raw()` (contract-pinned), the tokens-file merge logic, all security guards. **Gates:**
py_compile all modules + adapted test; UI unit gate 54/54 (host, and again inside the
`frontend-builder` stage at image build); vite build clean; workflow YAML parsed with
md5-identical merged vendor steps; **full contract suite twice on the refactored tree —
first on the Python batch: 137 passed, 1 deselected, 0 skipped, 195.70 s; then on the
exact final tree (image rebuilt with the UI export demotions): 137 passed, 1 deselected,
0 skipped, 173.56 s.** Changes left uncommitted per the user's rule (no commits/pushes
for this task).

**All-in-one compose example + operator README (2026-11-09, the user's asks):**
`deploy/docker-compose.all-in-one.yml` merges the shipped chain
(`docker-compose.nextcloud.yml` + `nvidia` + `lan` + `nextcloud.lan` + `app-targets`)
into ONE file with the env names unchanged — Nextcloud + server (CUDA build target) +
LAN binds on both web ports + a named app target + the `--profile dav` mount container.
The header prints the launch chain and how to peel each layer (CPU-only = five named
line deletions; loopback = two port lines; data vs WebDAV shape; no app target).
`deploy/README.md` is the operator page the compose app needed: file map, every env var
with its effect, the launch chains (example values), the measured operator rules
(chown 990, ghost-row prune, single uvicorn, 503-warming honesty, 409 one-writer lock,
143/137 stop semantics, GPU-is-measured honesty), and the API surface table with scopes,
pointing at `server/docs/API.md` as the canonical contract (test-pinned; this page never
restates schemas). Measured on this box: host schema checks for the all-in-one —
full (`--profile nvidia --profile dav`), no-profile, dav-only — all OK; the resolved
config carries `target: server-runtime-cuda`, the nvidia device reservation,
`DIGUP_SERVER_APP_TARGETS app=/media/app:/data/index-app`, four port mappings
(8787 loopback+LAN, 8081 loopback+LAN), the ro media bind + ro app bind + shared dav
propagation. The exact CI line was run on the host (OK): the compose-schema step now
validates the merged shape with the full synthetic env chain (15th shape; RFC 5737
example addresses and `/srv/…` paths only). Privacy grep over the three files: zero
personal hits; the app-repo URL reference follows the tracked-docs precedent.

## 2026-11-08 — Stage 13: named indexes + minted keys — one compose app, standalone AND serving applications

The user's ask, built end to end: the compose server keeps running standalone over its own
media index, AND acts as a server for other applications — it mints their access tokens,
and each application's calls build and search a SEPARATE index, never the media one. The
engine changes nothing: it already answers for any (roots, `--index`) pair.

**Registry (`server/digup_server/targets.py`).** `DIGUP_SERVER_APP_TARGETS=nc=/media/nc:/idx/nc;…`
(entries `;`-separated, each `name=roots=index`, roots colon-separated) merged with a persisted
`<config>/targets.json` (env wins per name). Validation refuses at startup with the entry
quoted: non-slug names, the reserved name `media`, relative roots/index, and a target whose
index IS the main index (separate indexes are the point).

**Per-target supervision (`api.py`).** Every guarded endpoint addresses a target (`?target=name`;
default `media`). The main scope is the lifespan's, exactly as before. App targets spawn
**lazily** — first request addressing them pays the spawn, so registered-but-idle targets cost
zero engines: each gets its own `search-service` child, its own `JobRunner` (its own jobs log
`jobs-<name>.jsonl`), and its own writer lock for free (the flock lives beside each index
folder — "one writer at a time" is per index, so a bridge crawl never queues behind the media
crawl). Media handles resolve their target from the path's owning roots (longest-root match),
so `/preview`, `/text`, `/file` work across indexes unchanged. `GET /api/v1/targets` lists the
registry with counts from the CLI status (no engine spawn for a listing).

**Minted application keys (`security.mint_tokens`).** When targets exist and env left a target
unbound, the server mints `secrets.token_urlsafe(24)` keys (`app:<name>`), plus an admin key
when the deployment has none, stored 0600 in `<config>/tokens.json` (config folder =
recreation-safe; a recreation never silently revokes a connected app; restart-stable and
displayable from any boot). Minting fires ONLY when targets exist — a target-less standalone
deployment runs exactly as it has, unguarded. Env secrets are never stored, never echoed.
`GET /api/v1/tokens` shows minted values to the admin principal only; the UI's gear → Settings
→ Access gained **Application keys** (copy buttons) and **Indexes** sections (hidden for
non-admin keys).

**The bearer gate binds tokens to targets.** `admin` answers every target; `read` and plain
named tokens answer the main index — their pre-stage-13 contract, unchanged. An `app:<name>`
token answers its target and nothing else, **by default**: plain paths (`/search`, `/index`)
address its own index (the binding is what the token carries — the bridge's code path needs no
target parameter), and any explicit target it does not match answers `403`. Mutating routes
accept an app token only for its own target: the bridge queues its own crawl, never anyone
else's. Review caught and fixed: a plain-named-token 403 regression, the injected-searcher
seam the 503 contract pins (the main scope now resolves `app.state.search` at call time), the
tokens-file write before the config folder existed, the main-index clash for env entries, a
cross-target counts bleed in the single-slot status cache (now keyed per index folder), and
the tokens endpoint refusing an admin token presented on the read side
(`principal="admin (read scope)"`).

**Surfaces:** `server/docs/API.md` "Named indexes" (+ auth bullets), `server/.env.example`
(`DIGUP_SERVER_APP_TARGETS`), `deploy/docker-compose.app-targets.yml` (opt-in `-f`; the
target's index rides its OWN bind mount, so indexing survives recreation like the media
index's), CI validates the fragment with and without the nvidia profile.
`server/tests/test_targets.py` pins the registry, the mint rules (inert/stable/0600/env-
authority), the binding table, and the flow end to end on the real engine (minted key → own
status → own crawl 202, media 403, own search, cross-target media preview, per-target busy
409, parallel crawls on two targets, tokens visibility).

**Suite (this box, container, `-rs`, zero skips):** run 3 (new suite in): 6 failed / 123
passed / 1 deselected / 0 skipped → review-pass fixes above; run 4: 2 failed / 127 passed —
the two were a stale binding-default expectation (superseded by design) and a render
mid-reload answering the engine's honest 503 (the pinned refusal state — the contract now
polls, like clients do, and names the last answer's body: the engine's own words are the
diagnosis); run 5: 1 failed / 128 — the preview poll's own bug (it picked `hits[0]`, a text
doc: the engine's render refuses text docs permanently, "unreadable: can't decode image" —
the contract previews the image hit); runs 7 and 8: **129 passed / 1 deselected / 0 failed /
0 skipped**, twice.

Two more findings from the demo bring-up, both fixed in code:

1. **Registry shape:** the parser demanded `name=roots=index` (two `=`) while the docs,
   the compose fragment, and `.env.example` all shipped the house shape `name=roots:index`
   (roots colon-separated, index LAST — the same shape as `DIGUP_SERVER_ROOTS`). The demo
   container crashed at startup quoting its own entry — the parser moved to the documented
   shape (entry → `name=`, then colon-split: ≥ 2 parts, last is the index), the tests and
   docs pin it, and the env path now enforces the main-index clash too.
2. **`/api/v1/targets` counts:** the CLI status has no `files`/`searchable` keys (those are
   the searcher's live fields), and a store whose writer has exited can keep its fresh rows
   in the WAL pinned by the searcher's reads (measured in the suite: main db 4096 B + live
   `-wal`, searcher 12 rows, a fresh CLI read 0). The listing now takes counts from a
   running target's live searcher (the authority on a store it has open), from the CLI's
   own table (`kinds` totals + `vectors`) for unspawned targets, `null` for an empty index
   folder — no engine is ever spawned for a GET, and no number is ever invented.

`server/docker/Dockerfile` gained `ARG SWIFT_TESTS=1` gating the engine `swift test` inside
the builder stage: CI never passes the arg (gate unchanged); local suite builds use
`--build-arg SWIFT_TESTS=0` after the measured box fact — a from-scratch engine build on
this box dies in the engine's own test `gitListingNeverRunsRepositoryFsmonitor`
(`CodeTests.swift:203`, the fsmonitor hook never runs in this box's builder), and the
server's gate is the contract suite (`swift test` belongs to ci.yml/packages.yml on their
supported environments).

**Live demo gate (this box, compose stack project `digup-demo`, port 8792, CPU flavor,
public Wikimedia corpus photos only):** tokens file `0600` with minted admin + app key; UI
200 with both sections; unkeyed API `401`; admin answers `target media` roots `/media/photos`;
the app key answers `target nextcloud` roots `/media/app` and is `403` on `?target=media`;
its `POST /index` → `202`, a second one → `409` naming the live job; the job `done`; app
status **36 files / 36 searchable**; the media index untouched (**0 files**, 0 hits); app
search 3 hits all under `/media/app`; targets visibility (admin: both, app: only its own);
`GET /tokens` shows minted values to admin, `403` to the app key. Audit lines carry
`principal=… target=…`. Final suite run with these fixes: **129 passed / 1 deselected /
0 failed / 0 skipped in 160.04 s** (2026-11-08, this box, container, four mounts, `-rs` —
zero SKIPPED lines in the log).

**The Nextcloud bridge (app repo `digup_nextcloud` 0.4.0).** `DigupService::serverStatus()`
(GET `/api/v1/status`) and `startIndex()` (POST `/api/v1/index`) ride the same
server-to-server path as the search — the key never reaches the browser, every number is the
server's verbatim. Admin-only routes `api#status`/`api#indexnow`; the settings form gained the
index line (target + counts) and an **Index now** button; the token field is now "Access key"
with the Application-keys page named. Deployed on the pilot (occ `installed_version 0.4.0`,
files bind-swapped, `php -l` green in the container, `node --check` green on both JS files).
Gates on this box (measured, pilot stack, session as the admin user): status → 200,
`target: media`, files **131,973**, searchable **115,098**, roots `['/media/photos']` (the
live GPU run's counts, mid-embed); index-now with the pilot's read-scope key → the server's
own words passed through verbatim ("that is this server's read-scope token; indexing and
estimating need the admin token") — the honest state until the pilot's image carries
stage-13; non-admin user → 403 on both routes. The pilot's full named-index flow (minted key
→ its own index) lands with the image rebuild after the running embed job finishes — a GPU
run is never interrupted for a redeploy.

**Bench + pilot move onto the stage-13 CUDA image (2026-11-08, measured).** CUDA rebuild:
`server-runtime-cuda`, bases 11.8.0 devel/runtime, `CUDA_ARCHS=61` (the server-pinned
GTX 1070, sm_61), `SWIFT_TESTS=0` (the local build knob; compose's `DIGUP_SWIFT_TESTS`
added with default 1, so CI/standard flows keep the engine-test gate unchanged). Bench
`:8787` recreated on the full chain (chain files + boot env verbatim — media index
untouched): health 200; status `target media` **131,972 files / 131,758 searchable** (the
bind-mounted index survived recreation, the jobs log intact); UI 200; unkeyed API 401;
read-token status 200 / its index POST 403 (the pre-stage-13 token contract, unchanged);
`targets(admin) → [('media', 131972, 131758)]` live counts; `tokens(admin) → 200` with the
env admin flagged `configured` and its value never echoed, `apps: []` — **minting is inert
with no targets registered: no `tokens.json` in the config folder**; search 5 hits, 5
strong, 0.751 s. Standalone behavior is unchanged, exactly as designed. The pilot's GPU
embed job hit its 10-hour ceiling (`DIGUP_SERVER_JOB_TIMEOUT_S=36000`) and recorded
`interrupted` at **118,206** files (searchable 120,693, index 753.9 MB) — the pinned stop
semantics working: the resume `POST /index` answered 202 with a fresh job continuing from
the interruption; the 10-query battery across the partial index: 10 hits / 10 strong on
every query (top z 3.67–7.33), latencies 0.43–1.63 s; the app settings line (status 200)
showed the same counts live.

**UI rework (2026-11-08, the user's layout brief): the main page nag is gone; the gear is
Appearance · Index · Estimate · The index · API key.** The front page keeps no status
indicator (the "status unavailable: … paste your key" line is deleted — counts live in
`The index`); the gear's old Access/Application-keys/Indexes sections collapse into two:
`The index` (per-target rows with the engine's counts + roots, then the badges) and
**`API key`** — the minted keys as plain rows (`API key`, `API key — <target>`) each with
**Copy**, a **Regenerate** button behind a confirm dialog, and the small paste field for
deployments whose keys come from the environment (env keys are never shown, and never
rotated). `POST /api/v1/tokens` (admin scope) is the rotation: minted values (admin +
app keys) get fresh `secrets.token_urlsafe(24)` strings, persisted 0600, live immediately
— old values answer 401 from that call on, which is exactly what the confirm warns about
("the applications that have these keys lose access"); env-configured keys are kept
untouched (a rotation must not silently override the deployment's own config), and a
deployment with nothing minted answers 400 honestly. The rotation swaps the bearer gate's
auth reference through the built middleware chain (the stack is built at the first
request; `Auth` stays frozen). The admin-scope check also accepts a direct admin-bearer
match: an admin-token-only deployment deliberately leaves reads open (principal `none`),
and the keys surface exists to answer the admin key's owner. The Nextcloud bridge follows
the same shape: its settings section is ONE field, labeled **API key** — paste it (app
0.4.1, deployed on the pilot: files bind-swapped, `php -l` green, occ `installed_version
0.4.1`). Suite: three new contracts pin the rotation (minted values rotate + file 0600 +
old keys die at the live auth; env keys never rotate; endpoint e2e: old key 401 → new key
200 target `nc`, non-admin POST 403, env deployment 400 with honest words), and the UI
contract asserts the new panel (sections in reading order, no main-page nag,
Regenerate + Copy wired). Measured: suite run 13 on this tree — **133 passed / 1 deselected
/ 0 failed / 0 skipped, 224.61 s**; the demo stack (:8792, rebuilt on this tree) passes the
full flow gate (minted file 0600, unkeyed 401, app key → target `nextcloud` roots
`/media/app`, 403 on `?target=media`, 202→409→done, app 36/36, media 0 untouched, targets
`media 0` + `nextcloud 36`, tokens admin-only) and the rotate gate live: `POST` 200
`rotated: true` with fresh admin + app values shown, **old app key → 401 and old admin key
→ 401 on the same call**, new app key → 200 target `nextcloud` (files 36), 403 cross-target,
403 rotate by app key, tokens file 0600 carrying exactly the new values, media untouched
(0), app search after rotate 3 hits all under `/media/app`; served UI markup carries the
new sections (`appkeys`, `targets`, `keys-regenerate` present, main-page `statusline`
absent). The bench stack (:8787, the real tree) rebuilt on the same CUDA image (11.8.0-devel
base, `CUDA_ARCHS=61`, `SWIFT_TESTS=0`, engine layer cache hit) and recreated on the full
chain: index intact (131,972 files / 131,758 searchable / 403,831 vectors / pending 0),
contract unchanged (tokenless 401, read-token index 403, admin search 200), 10/10 queries
10 hits + 10 strong at 0.83–1.09 s (top_z 2.86–7.14), and stage 13 inert on an env-keyed
standalone: no keys file minted, `targets` shows `media 131,972`, `GET /tokens` 200 with no
value echoed, `POST /tokens` 400.

**Round 2 (same day, the user's live test of :8787 and :8090): the minted shape opens the
main index's reads; the gear's API key section is Copy + Regenerate only.** The user's test
hit the guarded shape (`status unavailable` nag on the main page) and the gear's paste field
bothered them — the brief: the standalone app searches with no key, keys exist for the
applications. The bearer gate now distinguishes the sources: keys the deployment TYPED in its
environment keep guarding every call (test_security's shape, untouched); keys the server MINTED
guard the index operations, the keys surface, and each application's own index — the main
index's reads (status/search/status targets/embed_ahead) answer key-less on the operator's box.
The media-id side is scoped with it: a handle owned by an application's roots answers `403` to
the open principal and `200` to that application's key (preview/text/file). The gear's section
lost the paste field, Save, Clear: rows = label | value | Copy in a uniform grid (one row
height, equal padding/border, ellipsis-clipped key text, Copy carries the whole value), plus
Regenerate; the browser adopts its admin key on Regenerate. The app got the matching shape
(0.4.2): the preview pane's `display: flex` out-specified `[hidden]` — the pane, its bar
(‹ ›, ✕, Open-in-Files) and the border rendered on the empty page and ✕ "did nothing";
`#digup-detail[hidden] { display: none; }` (the line the lightbox already had) fixes all
three complaints at once. Measured: suite run 14 — **135 passed / 1 deselected / 0 failed /
0 skipped, 164.25 s** (two new contracts: open main reads with guarded mutations/keys/app
target; open principal never previews an application's files); demo flow gate 4 on the
rebuilt minted stack (`status no key 200 target media`, `index/estimate no key 401`,
`tokens no key 403`, app-target read `401` key-less, app key `200` own target + `403`
cross-target, 202→409→done, app 36/36, media untouched) and rotate gate 2 (rotated 200, old
keys 401 on the same call, new keys answer, file 0600 carrying new values, media untouched,
search after rotate all under the app's roots); bench :8787 relaunched TOKENLESS on the new
CUDA image: "wakeboarding" un-keyed 10 hits 10 strong 0.72 s, 10/10 queries strong
0.73–0.92 s, served UI: no paste field, grid rows live, search works with no key.

**Rounds 3–4 (the user's live test of the gear panel): one row height for the whole panel,
the API-key section collapses when there is nothing to show, and Estimate shows a spinning
wheel in the gear instead of a main-page popup.** The user's live-test report: the panel
looked uneven, the API-key section held only a lone Regenerate button, and the estimate's
main-page progress line was noise. Measured behavior now: every panel control — the
appearance select, Index now, the prune row, Estimate, Regenerate, every key/index row — is
exactly 2rem tall (`#settings select, #settings button, … { min-height: 2rem }`), titles
align to the first row, key rows are `label | value | Copy` in the grid with the key text
ellipsis-clipped (Copy carries the whole value). The section logic tells the truth per
shape: minted keys render as rows; an environment-keyed deployment renders the honest row
"Set in the server's environment" (the server never echoes typed keys — so it says so); a
tokenless deployment has NO keys (minting fires when an application registers) and the
whole section collapses — no title-only fragment. Estimate: a ⟳ beside the gear's button
spins while the engine walks (CSS keyframe spin), the main-page
"estimating — the engine is walking the folders…" popup is deleted, the forecast fills the
panel when the answer lands, and the failure line stays honest. Measured: suite runs 15 and
16 — **135 passed / 1 deselected / 0 failed / 0 skipped** (205.85 s and 164.51 s; module run
mid-round: 37 passed on targets + media_ui); served UI on both stacks (:8787 tokenless,
:8792 minted): `api-key-sec` present, `estimate-spin` present, paste field absent, grid-row
CSS + 2rem rule + spin keyframe live; "wakeboarding" un-keyed 10 hits 10 strong.

**Stage 14 (the user's plug-in model made real at runtime): the standalone mints its API key
at boot (`DIGUP_SERVER_MINT_KEYS=1`) and applications REGISTER AT RUNTIME (`POST /api/v1/targets`).**
The box mints its admin key with no application registered — the gear's Copy row is the ticket.
An application brings it to `POST /api/v1/targets` with `{name, roots, index?}` (the startup
validator runs at runtime: slug rules, absolute paths, not-the-main-index, `media` reserved,
duplicates `409`): the server mints its PRIVATE key (returned once, persisted 0600), gives it
its own index folder (default `<config>/index-<name>`), persists the registration
(`targets.json` — restarts keep it), and the application's key answers only its target from
then on: own status/search/previews/crawl, `403` on the main index, `403` on registering,
and its crawl runs in the background, invisible to the main page; the open principal never
previews its files. Compose passes the knob; the env-fragment registration (stage 13) stays
the declarative shape, env wins per name. Measured (suite run 17 — **137 passed / 1 deselected /
0 failed / 0 skipped, 199.60 s**, module run 37 mid-round; live on :8787): minted file 0600,
`tokens` admin 200 key shown / key-less 403, `index` key-less 401, wakeboarding un-keyed 10 hits
10 strong; registration flow: `POST /targets` 200 with key + default index `/data/config/index-<name>`,
app key 200 its own target + 403 media + 403 register, targets list `media 131,972` + app rows;
test registrations then wiped and the stack force-recreated to a pristine standalone (fresh mint,
un-keyed search 10/10 strong).

**Round 7 (the settings-layout brief): the panel's grid arithmetic, measured.** The API-key
row was `9rem minmax(0,1fr) auto auto`: label (144 px) + 3 gaps (24) + two padded buttons
(Copy ≈ 70, Regenerate ≈ 138) + row padding/border (18) ≈ **394 px minimum inside a control
column of 271 px** (25 rem panel − label column) → the row sat ~120 px past the panel's right
edge, worse with the `overflow-y: auto` scrollbar. Every track is now `minmax()`-bounded
(`minmax(6rem,9rem) | minmax(0,1fr) | min-content min-content` + `min-width: 0`), the panel is
`min(27rem, 100vw − 2rem)` with `overflow-x: clip` and NO scroller, `#settings .set-sec > *`
carries `min-width: 0`, the Appearance select fills its control column, the section folds to
one column under 720 px. The Estimate control is a REAL switch (native checkbox + track/knob,
2.6rem×1.5rem, rides the 2rem row system) gating the Estimate button, its rows stacked
directly above the control line (`#estimate-ctl`). The gear ADOPTS the minted key it is shown
(the panel's own controls are admin-scope: Index now / Estimate / Regenerate work with zero
typing; a stored key the server no longer recognizes is replaced by the value shown now) and a
finished crawl re-reads the index list. The engine's own-words line (`#engine-says`) — lost by
my round-6 line-deletion — is restored (its absence threw at first paint).
Measured (suite run 19b — **137 passed / 1 deselected / 0 failed / 0 skipped, 189.48 s**;
module runs 50 green; geometry gate 34 PASS lines; round-7 layout gate 42 PASS at 1280/900/640;
live :8787 27 PASS): panel right 1196/1280, key row right 1182.2 inside the panel; control
column aligned in all five sections (878.6 = 562.6 = 25.8 px folding); select fills the column
(303.6 px wide at 1280, 580.4 at 640); toggle measures 41.6×24 px = 2.6rem×1.5rem; no inner
scrollers, no page horizontal scroll at any width; toggle flips by click and Space; Estimate
runs keyless from the gear (adoption) and renders rows in the panel, main page clean; Copy
puts the full key on the clipboard; Regenerate mints a new key (row + browser updated, old key
401); wakeboarding un-keyed 10 hits 10 strong; index/estimate un-keyed 401.

**Round 6 (the gear as the ticket — the user's brief of 2026-11-08, "there is no api key
with a copy button").** `GET /api/v1/tokens` is **key-free in a minted deployment**: the gear
shows `API key | value | Copy` with **no key in the browser** — the same open shape as the
main page's keyless reads (new `env_secrets(auth)` in security.py draws the line: typed
secrets = guarded shape, keys never displayed, calls 401 at the gate as test_security pins;
server-MINTED keys = the ticket, displayed). An `app:` key is refused the surface (403 —
applications get their own key at registration, they never list the server's). Regenerate
moved INTO the key row's right edge (grid: label | key | Copy | Regen, `margin-left: auto`) —
no loose button under the section. The estimate forecast div moved beside the button (a plain
row column — the stray empty box near Estimate is gone); a finished crawl re-reads the index
list, so no stale target rows survive a job. Measured (suite run 18 — **137 passed /
1 deselected / 0 failed / 0 skipped, 197.37 s**; module run 50 green; live on :8787): keyless
`tokens` 200 shows the minted admin value (equals the 0600 file's value), wakeboarding
un-keyed 10 hits 10 strong, `index`/`estimate` un-keyed 401, admin `tokens` 200; app-connect
flow on the live box: register → app row shows in the keyless list (ticket model), app key on
the surface 403, app key answers its own target; test registration wiped → pristine standalone
(fresh mint keyless-shown, media 131,972 only).
## 2026-11-08 — Pilot: live progress, Access UI, the excludes fix, and the engine picks GPU

**The excludes fix (b81e9e8).** The index job path was the gap: `estimate_argv` and
`search_argv` carried `--exclude`/`--exclude-ext`, `index_argv` did not. Measured: the
pilot's job walked **1,643,492 files** (the Nextcloud data dir's preview folders =
1,470,439 files) against a 131,973-file forecast. Engine proof that the flag works on
`index-service`: a scratch run reports `left_out: {"folders excluded folder": 1}`.
Recovery as designed: graceful stop (`Application shutdown complete`, the running job
recorded *interrupted* at files_done 34,931 / 1,643,492), the contaminated index wiped,
image rebuilt with the fix, chain re-queued. The job log lives at `<config>/jobs.jsonl`
(jobs.py §header), so it **survives an index wipe** — boot replay restored the
interrupted record, and the newest record drives the app's progress line. The suite
asserts the job path carries the excludes (test_integrations).

**Fresh run (measured):** estimate walk 1,762 s → **131,973 files** (106,346 image,
19,818 video, 2,868 pdf, 2,817 doc, 85 audio, 39 screenshot); forecast 8.78 h (the
engine's own `seconds` 31,614, `calibrated: false` → M4 Pro baseline). The walk total
131,973 = the excludes honored in the job. On the CPU-flavor image the default chain
measured 1.68 files/s (255→431 in 105 s) → 130,742 ÷ 1.68 ≈ 21.6 h.

**GPU switch (config only, Stage 9 procedure):** the ghcr CUDA image predates the
excludes fix, so the CUDA image was built on the box from the current tree
(`--target server-runtime-cuda`, CUDA 11.8.0 devel + runtime bases, `CUDA_ARCHS=61`)
→ 2.42 GB. A compose fragment swaps the pilot server's image, pins
`NVIDIA_VISIBLE_DEVICES` to the server card (UUID `GPU-a733…e630`) and reserves the
device; the full chain validates `config --quiet` with and without the fragment, and
the recreation passed the full file chain + boot env (never defaults).

**The engine's verdict** (`speed --model --json` on the CUDA image):
`device: "gpu"`, `agreement: 0.99977` (≥ 0.999 required). Model times GPU vs CPU on
this card: picture **0.145** vs 0.668 s, frame 0.079 vs 0.364 s, screen 0.313 vs
1.440 s, text 0.029 vs 0.151 s. The CUDA chain ships inside `/opt/digup`
(libcublasLt.so.11 → 11.11.3.6, libcudart 11.8.89, libnccl 2.15.5, libnvrtc 11.8) —
`libcuda.so.1` comes from the host driver through the toolkit, as always. The job
resumed from checkpoint: searchable 2,279 carried over, no re-embedding of completed
files. Utilization sampling during a real embedding stretch (0.15 s interval, 300 s,
pinned card): **1,567 samples, 720 busy, peak 95 %, duty 45.9 %, VRAM peak 1,697 MiB**
— passes the gate on both thresholds (peak > 20 %; duty ≥ 10 % with the model resident).
Throughput window 3,151 → 3,383 files in 120 s = **1.93 files/s** vs 1.68 files/s on
the CPU flavor: the GPU model time is 4.6× faster, the net is +15 % — the per-file CPU
pipeline (video decode, PDF parsing, HDD streaming) dominates end to end. Finish
forecast: 128,590 ÷ 1.93 = 66,512 s ≈ **18.5 h**. Index on disk: 1 MB at 3,383 files
(quantized vectors) → the full run lands ≈ 40 MB; disk is not the constraint.

**UI (suite-asserted):** the access key moved from a load-time `window.prompt` into
the gear's panel — Settings → Access: a field + Save/Clear kept in localStorage, sent
as a bearer header only, never in a URL; a 401 with no stored key pulses the gear; the
embed widget (no settings panel) keeps its prompt. Suite with the new assertions:
**117 passed, 1 deselected, 0 skipped** (121.57 s, then 125.84 s).

**App (digup_nextcloud 0.2.2):** the progress line rides right of the spinner circle
(one flex group; bar-wrap can't split them); during a live run the denominator is the
engine's own `index_files` — the job record's total arrives at sync end (`files: null`
mid-walk), and the app invents no numbers.

## 2026-11-07 — WebDAV shape: the dav mount container, zero host sudo, gates green

**Shape (stage-12 §11.7, the user's no-sudo directive):** compose `--profile dav` runs a
`dav` service (`deploy/dav/`, davfs2 + tini, privileged, `/dev/fuse`) that mounts each
user's dav view read-only at `/mnt/dav/<uid>`; the bind rides the server's media bind
`:ro,rslave`, so mounts propagate live. `docker compose up -d --build --profile dav` **is**
the setup — no fstab, no host davfs2, no host secrets file, no sudo. The script
`deploy/nextcloud-webdav.sh` stays as the documented host-mount alternative.

**Pilot (ai-ubuntu-computer, x86_64, kernel 7.0; corpus2 public fixtures, users
alice/bob/carol):** stack = nextcloud :8090 + server :8791 + dav, project
`digup-server-nextcloud`, roots `DIGUP_SERVER_ROOTS=/media/dav/alice:/media/dav/bob:/media/dav/carol`,
index `data/ncdav-index`.

Measured facts (numbers only):

- **davfs2 image fixes:** (1) the mounting env needs a passwd entry for the tree owner
  (uid 990) — "can't read user data base" without it (image carries `useradd -r -u 990`);
  (2) reads die with "reading directory: Invalid argument" on this kernel with davfs2
  1.7.x defaults — `buf_size 64` in `davfs2.conf` fixes it (Launchpad #2129131);
  (3) `printf '%s\n' a b` splits config lines — literal-`\n` printf required.
- **Engine walk does not cross mount points:** `estimate /media/dav` = 0 files in
  590 ms; `estimate /media/dav/alice` = 62 files in 2 043 ms. Roots are therefore the
  per-user colon list (§11.5's shape).
- **Mount state after bring-up:** 3 mounts; server sees 65/56/50 files; estimate 153
  files; full index job → `done`; ACL battery over dav roots: alice 6/3/3, bob 4/6,
  carol 2/3/3 hits (shared dog deduped to the viewer's own mount path; carol's "dog
  running" answers document-only hits — no shared photos), preview 200 + open 200 for
  the recipient / 404 unshared, token scopes 401/200/403 + admin estimate 200, z-order
  descending, token never in HTML.
- **Mount-flap, no server restart:** dav stop → unmount trap line → server sees 0 files
  → estimate 0 files (readable all true); dav start → 3 mounts back → 65/56/50 files,
  estimate 153 — same running server process, index untouched.
- **Graceful stop (compose 90 s grace):** server exit **143** + `Application shutdown
  complete`; dav exit 0 + `OK all dav views unmounted`; restart → health 200 at 10 s,
  search "dog running" 5 hits, top z 5.0 (index on the bind survived; no prune needed).
- **No mutation:** fixture checksums 36/36 identical after the whole session; the only
  churn was Nextcloud's own appdata preview cache (28 entries, regenerated by Nextcloud).
- **App passwords (NC 28 measured):** `user:resetpassword --password-from-env` reads
  `OC_PASS`; `user:auth-tokens:add --password-from-env` reads `NC_PASS`; failed dav
  logins throttle the source IP (429) — `security:bruteforce:reset <ip>` clears it;
  trusted_domains must include the compose service name the dav container dials
  (400 "Bad Request" refusal otherwise).
- **Suite re-run on this disk after the dav work:** 117 passed, 1 deselected, **0
  skipped**, 110.88 s (image `digup-server-test:local` unchanged — server code untouched
  by this shape).
- Compose merge shapes validated: plain, `--profile dav`, lan merge (both env shapes),
  nvidia+lan, base — all `docker compose config --quiet` green; CI carries the dav lines.

## 2026-11-07 — Stage 12 field pilot green: Nextcloud 28 + DigUp server, one box, ACL measured

**Stack (ai-ubuntu-computer, measured numbers):** `nextcloud:28-apache` (loopback :8090) +
`digup-server:local` (loopback :8791), compose project `digup-server-nextcloud`; corpus2
fixtures only (36 photos under three users, 25 planted junk copies inside
`appdata_<instanceid>`), public content, no personal data anywhere in the run.

Gates, in the order `docs/implementation/stage-12-integrations.md` lists them:

- **Junk exclusion:** `POST /estimate` (admin token) → 37 indexable of the mounted tree
  (36 images + 1 document; appdata and the skeleton seeds counted 0, `left_out: 2`) — after
  the fix that matters: `estimate_argv` now carries the job's `--exclude` flags (an estimate
  without them promised 120 files against a 36-file job; pinned by a new suite test).
- **Index:** job `736362e4a1c0` `done` in 40 s → 45 searchable, 45 vectors, 1 failed file
  (the engine's own counts, relayed).
- **Search:** five queries, 3 hits / 3 strong each, 12.9–28.6 ms.
- **Token scopes:** tokenless search 401; read-token index/estimate 403; admin estimate 200;
  health 200; principal log lines land (`principal=nextcloud`, `principal=admin`) — after
  the audit logger got its own stdout handler (uvicorn's config leaves application loggers
  handlerless).
- **App ACL (the §11.1 boundary, over the app's own API, session-authenticated):** alice 3
  dog hits (own), bob 3 office hits (own), carol 1 tabby (own); **shared files map**: bob
  1 shared dog hit, alice 1 shared office hit (recipient-view paths); carol 0 for dogs /
  office; bob 0 leakage on the office-desk keyword that names alice's tree. Preview of a
  mapped hit serves `image/jpeg` to the recipient; the same file id answered **404** for a
  user it was not shared with (core's own check, not ours).
- **App surfaces:** page 200 with the top-bar entry in core's app state; admin settings
  section + form render (non-admin 403 on both the form and the save route); Test
  connection answers 200 with the engine's live counts (46 files, 45 searchable, 45 vectors,
  build_tag b11461); the token appears in **no** page or settings HTML.
- **Read-only contract:** 36/36 user files byte-identical to the pre-pilot baseline
  (`sha256 -c`); the only changed tree content is Nextcloud's own preview cache under
  `appdata_*`; the DB diff over `oc_appconfig` is appconfig rows only
  (`enabled`, `installed_version`, `types`, four app keys) — no new tables, no file writes
  (source grep: no Filesystem/DB/write API in `lib/`).
- **Restart/stop:** `docker restart` (Nextcloud) and stop/start (server, `stop_grace_period
  90s`) survive: exit **143** + `Application shutdown complete`, health 200 after, search +
  preview green post-restart.

**Suite with the two fixes: 117 passed, 1 deselected, 0 skipped, 111.09 s** (the new
estimate-argv test included; the deselected test remains the `-m slow` timing run).

Measured Nextcloud 28 facts (the app repo documents them): the bootable class is
`OCA\<ns>\AppInfo\Application` (a class elsewhere never boots); section/setting registration
goes through `IManager::registerSection/registerSetting` at boot (the info.xml `<settings>`
map is not read); the public section interface is `IIconSection`; page and form responses are
`TemplateResponse` (`AppTemplate` and `OCP\AppFramework\Template` do not exist at 28);
`getSharedWith`'s recipient list crashes on a non-null node (limit `-1`, node `null`);
`IShare::getTarget()` is the source path, not a recipient-view path (the mapping reads the
share's node id out of the asking user's view root); `Node::getRelativePath()` is not in the
Node API; the SSRF guard's per-request flag is inert on 28 for app requests —
`allow_local_servers => true` in config.php is the deployment shape (the app's probe detail
says so); the core preview route is `/core/preview.php?fileId=…`.

## 2026-11-05 — 1.8M-tree bench run COMPLETE: 131,972-file library indexed, job record `done`

**LAN opt-in shape added + field-proven (same day):** `deploy/docker-compose.lan.yml`
appends a LAN host binding (env-forced `DIGUP_LAN_BIND`; the loopback mapping stays —
compose merges `ports` lists). Merged with the GPU override on the live stack: healthy,
UI + searches served on the host's LAN address, 10 hits/10 strong in 0.71–0.81 s. Three
new merge shapes (base+lan, lan+nvidia, ghcr+lan, RFC 5737 addresses) pinned in the
workflow's schema-check step. The field run also **measured the ghost-row trap live**:
a recreation launched with a subset of the compose chain and default env moved the media
bind one folder off the roots the index rows carry — every row fell out of scope, the
API answered 0 hits (keyword queries included, 0 hits/0 strong, `meaning:true`) while
health/files/vectors/job-log all stayed normal. Diagnosis: `ls /media/photos` showed the
tree's folders one level deeper than the row roots in the index (`files/` nesting vs
131,972 rows rooted at the mount top). Fix by semantics, no reindex, no prune: relaunch
with the **same file chain and same env as the original boot** — mount back at the rows'
level → 10/10 strong restored, all three job records intact. Lesson pinned in
`server/README.md`: recreations must always pass the full chain + env, never defaults.

**Run #13 (`7c2329b`, the LAN shape): `server` SUCCESS 12 min 58 s (15:48:50→16:01:48,
now schema-checking all seven merge shapes) + `publish` SUCCESS 1 h 21 m 44 s
(16:01:51→17:23:35) — both tags republished carrying the LAN override file. The
operator-facing compose family is fully green on CI at the LAN tip: CPU, GPU, pull-CPU,
pull-GPU, LAN, LAN+GPU, LAN+pull.

Measured on this box (GTX 1070 pinned, compose stack `deploy/`, engine untouched; full
sampler table + arithmetic in `server/data/bench-18m-stats.md`, git-ignored):

* **Job 3 `ab6686ba178a` ended `done`** (engine's own fields): 20,225.0 s = 5 h 37 m 05 s,
  files_done 7,097, files_failed 1, errors 0; final index: **files 131,972 · searchable
  131,758 · pending 0 · unfinished 0 · vectors 403,831 · 1.39 GB on disk**.
* Whole library: three job records — 19,007 + 105,439 + 7,097 = **131,543 files completed**,
  **421 failed** (video decode refusals the engine recorded), **0 server-side errors**;
  engine working time 3,611 + 36,104 + 20,225 = **59,940 s = 16 h 39 min**, average
  **2.195 files/s**; wall clock 16 h 50 m 27 s with ≈8 min idle gaps. Stop/resume proven
  **3×** (ceiling → `interrupted` kept → one `POST /index` → walk continues).
* Cost-model check: estimate forecast 31,613.6 + 145,961.7 = 177,575.3 s; measured 59,940 s
  = 33.75% of forecast (2.96× the forecast rate, GPU-assisted).
* GPU (sampler, during jobs): peak 99% util (job 2) / 90% (job 3), model resident
  1,780–1,802 MiB on the 1070; container peak 207.75% CPU, 3.436 GiB RAM.
* Search latency at the finished index (limit 10): **0.6875–0.8004 s**, five queries,
  all **10 hits / 10 strong / meaning true**.
* Disk watch at end: `/` 7.0 G free (99% used) — the index fit with room; no pruning ran.

## 2026-11-05 (night) — CI `server` job green end-to-end; `:feat-server` live in ghcr, pull-and-run proven

**Run #9 (`6d97cd5`): `server` SUCCESS + `publish` SUCCESS — the whole pipeline is green**
(CPU + CUDA images pushed off the warm caches, hygiene step green with the fixed heredoc).
CI/publish objective closed. Registry: `feat-server` (568 MB) + `feat-server-cuda` (3.67 GB).
**Run #10 (`19b21d1`, docs-only tip): `server` SUCCESS + `publish` SUCCESS again** —
CPU + CUDA pushed off the warm caches, hygiene green. The branch tip is green
end-to-end; the ghcr tags now embed exactly the pushed engine.

Measured on the fork's Server workflow (branch `feat/server`), runs #2–#6 (all numbers from
the run timelines):

* **Run #6 (commit `ad4b682`): `server` job SUCCESS, 12 min 52 s, all 17 steps green** —
  drift guard, Vendor-in-base-image seed 4 m 47 s (cache warm), model pins, engine +
  `swift test` in the builder 2 m 05 s, CLI headless 34 s, corpus 15 s, clip gate, test
  image 12 s, **contract suite 3 min 03 s with zero skips**, **headless proof 1 min 27 s**,
  all four compose merge shapes, boot + `/api/v1/health` + UI + graceful stop (exit 143),
  logs as artifacts.
* Four environment failures were diagnosed on the runner and fixed in server-side scope,
  each reproduced on this box first: (1) Vendor-seed ABI trap → build Vendor in the
  builder's own base image (`6b9d9a4`); (2) Wikimedia blocks Azure ranges → the two pinned
  corpus videos joined the pinned photos in git (`808826f`); (3) hosted runner images ship
  **no ffmpeg** (Tools list has MediaInfo, apt list jumps `ftp`→`g++`) → corpus step
  installs apt's ffmpeg, and `build.sh` now capability-probes libx264 + mp4, probing out
  the engine's decode-only Vendor ffmpeg (`b6235a7`, `7b65454`); (4) the engine/server
  images run as uid 990 and `$RUNNER_TEMP` dirs deny them writes → CI scratch dirs get
  777 and the proof got its own hermetic index (`ad4b682`).
* **`publish` (run #6): CPU image built and pushed — `ghcr.io/ocean572/digup-server:feat-server`
  is live** (public repo, anonymous pulls verified: token flow + tags list + manifest 200).
  **Pull-and-run proved on this box:** `docker pull` → compose merge of
  `docker-compose.yml + docker-compose.ghcr.yml` with `DIGUP_IMAGE_TAG=feat-server` on port
  8788 → Up **(healthy)**, `/api/v1/health` `ok:true` (engine b11461, encoder ready, index
  created), UI served at `/` (7,197 bytes with DigUp/app.js), `docker stop --time 15` →
  **exit 143 + `Application shutdown complete`**, compose down clean.
* **CUDA image (`-cuda`) fix (run #6 died at 2 m 44 s):** `build-llama.sh` passes
  `CUDA_ARCHS` verbatim to `-DCMAKE_CUDA_ARCHITECTURES`, CMake lists are **semicolon**-
  separated, and the publish step's `61,70,75,80,86,89,90` is ONE invalid arch token —
  configure died ~35 s × 3 retries + 60 s sleeps = 164 s, matching the step to the second.
  Fix lives at the server's boundary (scripts untouched): the Dockerfile's engine-builder
  RUN normalizes commas → semicolons (`tr ',' ';'`), plain/`native`/semicolon values pass
  through. Verified by configure-only probe on `nvidia/cuda:12.4.1-devel-ubuntu22.04` with
  the seeded Vendor: raw commas fail at `ggml-cuda/CMakeLists.txt:72 (enable_language)`,
  the semicolon shape prints `CONFIGURE-OK` with compiler-ID cubins for 61/70/75/80/86/89/90.
  Shipped in `7400c82`; run #7 step 10 built the CUDA image green in **1 h 28 m 57 s**
  (cold), proving the fix live.

* **CUDA image published and proven in the nvidia shape.** Run #7 step 10 (the CUDA
  build-push) went green in **1 h 28 m 57 s** — the arch normalization shipped
  `ghcr.io/ocean572/digup-server:feat-server-cuda` (anonymous pull verified; images
  on disk here: 568 MB CPU / 3.67 GB CUDA). Boot proof of the merged GPU shape
  (`docker-compose.yml + docker-compose.ghcr.yml + docker-compose.ghcr.nvidia.yml
  --profile nvidia`, `DIGUP_NVIDIA_GPU` = the box's GTX 1070 UUID, port 8789):
  **Up 11 s (healthy)**, `/api/v1/health` 200 first try, encoder `ready`, engine
  b11461, model resident on the card (**1780 MiB, 37% util** during prewarm),
  `docker stop --time 15` → **exit 143** + `Application shutdown complete`, down clean.
* **Hygiene step fixed (run #7, step 11, exit 1 in 1 s):** the python heredoc body sat
  deeper than its delimiters → IndentationError; and version deletion is
  `POST …/versions/delete` since GitHub's 2022 verb migration (old `DELETE` → 404).
  Body moved to the delimiter column, verb fixed, cleanup made best-effort: a loud
  `::warning` + exit 0 — publish has already succeeded by then, so cleanup never reds
  a run and never fails silently. Shape verified by extracting the run block from the
  YAML and running it (reaches the API: 401 with a dummy token, warning printed, 0).

## 2026-11-05 — ghcr publish + pull-and-run compose; first fully green suite on x86_64
```

**Suite (this box, suite container, fresh index): 102 passed, 0 failed, 0 skipped, 1
deselected — 128.55 s.** Two pins moved, both measured here (the engine untouched):

* **Wakeboard top-3 is pinned as a SET, not an order** (`test_api.py`,
  `test_search_contract.py`). Measured x86_64 (engine CLI, corpus index): logan 1.571 >
  vienna 1.531 > aarhus-04 0.441; the arm64-Mac measurement ranks vienna first. The top
  two are 0.040 z apart — inside the embedding matmul's cross-platform noise. The
  portable contract (which three files answer the query, `strong >= 3`, `meaning` true)
  stays pinned; the per-platform order is the engine's, and the verbatim pass-through is
  pinned by the hit-field/reply-shape tests.
* **Stop-timing window 6.0 s → 1.0 s** (`test_jobs.py`'s resume test). Measured: on a
  warm box the scratch embed (8 files) finished **inside** 6 s — the record carried
  `files_done` 8/8 at the shutdown instant, so `partial < expected` had become the same
  class of timing assumption the test itself already documents for `partial > 0`. 1.0 s
  lands inside the model load on every platform (the ~800 MB weight load is the floor
  before the first `file` event); `partial = 0` is tolerated, the resume arithmetic
  `partial + files_done >= expected` is untouched.

**Publish → ghcr (Server workflow, new `publish` job):** runs after a green `server`
job on push to `main`/`feat/**` + dispatch. `ghcr.io/<owner-lowercase>/digup-server`:
`:latest` + `:latest-cuda` from main, `:<branch>` + `:<branch>-cuda` from a feature
branch — PR #184's build is `:feat-server`. CUDA shape: build-args
`BASE_IMAGE/CUDA_RUNTIME_IMAGE = nvidia/cuda:12.4.1` + fat `CUDA_ARCHS=61,70,75,80,86,89,90`
(61 compiles deprecated on 12.4.1; CUDA 13 drops it — re-evaluate the base when the line
moves). Pinned actions (login v4.7.0, buildx v4.4.1, build-push v7.4.0, all by commit
SHA), separate gha cache scopes for CPU/CUDA, and a hygiene step that deletes untagged
versions (keep rule: anything carrying a tag). Never publishes on `pull_request`: that
context's token belongs to the BASE repo's registry. x86_64 only, §11's rule.
Server.yml's push `paths:` now includes `Sources/**`, `Package.swift`, `scripts/**` —
an engine change that passes ci.yml republishes the images, ghcr never serves a stale
engine.

**Pull-and-run (deploy/):** `docker-compose.ghcr.yml` (`build: !reset null` +
`image:`) and `docker-compose.ghcr.nvidia.yml` (profile `nvidia`, `:<tag>-cuda`, the
same device reservation + `DIGUP_NVIDIA_GPU` pin as the build override). The
`DIGUP_IMAGE_TAG` knob (default `latest`) selects the build; all DIGUP_* env, knobs and
volumes are the base file's, unchanged. Measured on this box: all four merge shapes pass
`docker compose config --quiet`, and `DIGUP_IMAGE_TAG=feat-server` resolves to
`ghcr.io/ocean572/digup-server:feat-server-cuda` in the GPU merge. CI validates the same
four shapes in the schema step.

**Registry facts (measured 2026-11-05 via the GitHub API):** `Ocean572/DigUp` is a fork
of `ARahim3/DigUp`; PR #184 is open, head `Ocean572:feat/server` ← base `ARahim3:main`,
mergeable (28 commits), **0 check-runs on head and merge commit, 0 workflow runs in the
fork** — Actions is not enabled on the fork, so no CI (including `publish`) can run
until it is switched on in the fork's Settings → Actions. The package owner will be the
fork's owner (`ghcr.io/ocean572/digup-server`); the repo is public, so images pull
anonymously once the first green publish lands them.

## 2026-11-04 — Stage 9 measured: **GPU measured on this box** (Gate B all green on x86_64 + a GTX 1070)

First x86_64 measurement round ever for this PR (merge commit `fabb2ba4` has 0 CI check-runs;
every suite number above is an arm64-Mac measurement). The box: `ai-ubuntu-computer` — x86_64,
kernel 7.0.0-38-generic, Ryzen 9 7950X (nproc 20), 64 GiB RAM, driver 580.178.04, **GTX 1070
(Pascal sm_61, pinned for all server work by UUID)**; the box's RTX 4070 serves other work and
was never touched. Full run: `server/tests/gpu-handoff.sh` with
`CUDA_BASE=nvidia/cuda:11.8.0-devel-ubuntu22.04 CUDA_RUNTIME_IMAGE=…-runtime-ubuntu22.04
CUDA_ARCHS=61 GPU_SPEC=device=GPU-a7336580-…` → `server/data/gpu-handoff-20261104-1254.log`,
wall 4 m 15.7 s, header **"GPU: measured on this box"**. Gate B's six gates:

* **PASS** NVIDIA Container Toolkit (`docker run --gpus all … nvidia-smi`);
* **PASS** CUDA engine-payload build on the devel base — `scripts/build-llama.sh` finds `nvcc`
  itself, `libggml-cuda.so` lands in the payload (`/out`);
* **PASS** `ldd libggml-cuda.so` resolves `libcudart.so.11.0`, `libcublas.so.11`,
  `libcublasLt.so.11`, `libnccl.so.2`; `libcuda.so.1` unresolved in the builder **by design** —
  it comes from the host driver through the toolkit at run time;
* **PASS** the engine measured the device: `speed --model --json` → `backends: CUDA, CPU`,
  `device: gpu`, cosine agreement **0.99972** (≥ 0.999 required); picture **0.143 s** on the
  card vs **~0.589 s** on CPU, whole run 0.39 s vs ~1.7 s;
* **PASS** the utilization gate: the card **worked during a real index job** — peak **96 %**,
  busy **37 %** of 91 samples, model resident in card VRAM (392 MB) for 91/91 samples;
* Gate A's compose gates repeated green on x86_64: healthcheck, HTTP search, `docker stop`
  exit **143** + `Application shutdown complete`.

### What it took to get there (all configuration/docs/suite — README §10: the engine untouched)

Measured root causes, each with its gate line:

1. **`CUDA_ARCHS` must be a plain number.** The builder's cmake is Ubuntu 22.04's apt 3.22.1:
   inside `nvidia/cuda:11.8.0-devel-ubuntu22.04` it rejects `6.1` **and** `native` alike
   (`native` needs cmake ≥ 3.24 *and* a GPU visible at build time, which the builder never
   has); `61` configures clean. `gpu-handoff.sh` never passed the arg at all — Gate B could
   not have passed on this base. Now: `--build-arg CUDA_ARCHS="${CUDA_ARCHS:-native}"`.
2. **The CUDA-libs copy named files that do not exist.** A CUDA *runtime* base ships SONAME
   chains (`libcublasLt.so.11 → .so.11.11.3.6`, `libcudart.so.11.0 → .so.11.8.89`,
   `libnvrtc.so.11.2 → …11.8.89`); the dotted names belong to `-dev` packages — a COPY of
   them dies "not found" (measured). The `cuda-libs` stage now assembles `/out` with
   `cp -a` globs over the five lib families **plus `libnccl.so.2`** (llama b11461's
   `libggml-cuda` links nccl; ldd asks for it): 955 M shipped, the Dockerfile's own ldd gate
   passes.
3. **Flavor-switch cache hygiene.** A CUDA build leaves `Vendor/llama-build/CMakeCache.txt`
   with `GGML_CUDA=ON`; the next CPU build reuses it and configure dies "CUDA Toolkit not
   found". The Dockerfile deletes just that file before `build-llama.sh` (the script's stamp
   embeds the flavor and wipes `lib/`; objects are kept). CPU↔CUDA alternation costs a
   configure, never a full rebuild.
4. **The nvidia Compose override built nothing CUDA.** It now declares `target:
   server-runtime-cuda` + the three build-args, so `--profile nvidia up -d --build` produces
   the CUDA image itself; Gate B's compose call runs with `--build` (a CPU image with the
   device visible is exactly the false positive the utilization gate exists to catch). All
   three compose shapes validate (`config --quiet`, base / nvidia+profile / nvidia-without).
5. **The handoff script checked `/opt/digup` on the payload image** — the `engine-payload`
   stage lands in `/out` (the runtime stages COPY it to `/opt/digup`). Checks now use `/out`.
6. **The utilization gate must be job-aware.** `/health` answers 503 during the searcher's
   ~20–30 s prewarm (the container is healthy, the API is honest) — the gate now waits for a
   200, then POSTs `/index` with retry. And sampling cadence is measured: small-corpus GPU
   embedding is ~150 ms kernel bursts between P8 idle — a 2 s sampler sees 0–12 % on a
   provably-GPU job (392 MB model in VRAM, engine costs at the GPU's 0.15 s/image rate). The
   gate samples at 0.15 s across the job and passes on peak > 20 % **or** busy-duty ≥ 10 %
   with the model on the card; a CPU-embedded job is flat — zero busy samples, ~0 VRAM.

**Estimate's ceiling is now the operator's.** Measured on the bench tree: a full crawl of
187,055 files on the 2 TB HDD crossed the endpoint's hardcoded 120 s and answered
502 "digup estimate timed out". `POST /estimate` now reads `DIGUP_SERVER_ESTIMATE_TIMEOUT_S`
(default 120 — every existing pin keeps; the suite adds `test_the_estimate_timeout_is_an_operator_knob`).
**The same for a job's ceiling: `DIGUP_SERVER_JOB_TIMEOUT_S`.** Measured on the bench: at the
default 3600 s a 131,972-file job recorded **interrupted with its partial counters**
(`files_done 19,007, files_failed 0, errors 0`) when the runner's deadline expired — README §5's
stop semantics proven on a real tree, and the next job resumed (measured: it resumed and kept
embedding on the 1070). Default 3600 kept; pinned in `tests/test_jobs.py`.

**Gate A's suite on x86_64: 2 failed, 99 passed, 1 deselected, 0 SKIPPED in 154.81 s** (101
tests with the knob pin; the two failures below). The
two failures are the wakeboard top-3 pins (`tests/test_api.py:58`, `tests/test_search_contract.py:50`):
this box ranks `wakeboard-logan.jpg` (z 1.571) above `wakeboarding-vienna.webm` (z 1.531), a
0.040 margin — the pins are arm64-Mac measurements and the 2.0σ z-gate over 15 files is the
engine's, identical on every platform (README §"fewer strong hits on tiny corpora"). The
jobs stop-timing pin passed under load (it is load-sensitive by construction). The pin
decisions (clip commit, corpus2 re-bake, ranking baseline, timing assumption) sit with the
maintainer; **no test was edited to make the suite green**.

## 2026-11-04 — The UI's state-dependent layout, and the counters an interrupted job always carries

Second round on `feat/server` (PR #184) after the API/security one: the web app's layout, plus a
job-record finding that only the suite caught. **Suite: 100 passed, 1 deselected, 0 SKIPPED in
385.33 s** (arm64, the shipped engine payload, the dev-loop mounts; 4 new tests) — `tests/test_jobs.py`
alone: 16 passed in 160.19 s; `tests/test_media_ui.py`: 19 passed in 6.99 s. **GPU NOT MEASURED:**
this machine has no CUDA/Vulkan device ([docs/implementation/gpu-handoff.md](../docs/implementation/gpu-handoff.md)).

### The layout: `body[data-page]`, one switch, four states

`render()` in `server/ui/app.js` sets `body[data-page]` to `idle | busy | results | none`, derived
by `pageMode()` from the state the renderers already use (`hits` present → `results`; nothing typed
or the `code:` hint → `idle`; words in, meaning on its way → `busy`; meaning answered zero → `none`).
`server/ui/style.css` lays out from it: the results grid, the hit counter (`#engine-says`) and the
preview pane exist in `results` **only** — `body:not([data-page="results"]) #results, … #engine-says
{ display: none }`, specificity outranking the grid rule, so there is no `hidden` juggling anywhere.
`#idle` (welcome + `#idle-note` + `#suggest` chips) and `#no-results` (`#no-results-why` + a filter
hint) are centered panels, shown by the same attribute. Measured with Playwright (geometry, not
eyes): `idle` at 1280/1024/1440/390 px → the panel's center equals the viewport center (640/512/720/195)
with `#results`, `#preview` and the counter all `display: none`; `results` → grid
**438.391 px / 657.609 px = 40 % / 60 %** at 1280 and 1440 (the 72 rem content column caps it),
**387.188 / 580.812 px** at 1024, gutter 16 px, grid axis = viewport axis, the first pick
auto-selected, the pane carrying `picture` + `facts`; `busy` → centered "Matching words now…" with
the counter and the suggestions hidden; `none` → centered message quoting the engine's own sentence
for the empty answer, plus its `warning` when the engine sent one.
Below 900 px it is one column (measured 350 px at 390 px) with the pane **below** the list and
`position: static`; `documentElement.scrollWidth == innerWidth` at 390/1024/1280/1440 — no
horizontal scroll. The state fade is inside `@media (prefers-reduced-motion: no-preference)`.
Keyboard flow unchanged and verified in the browser: ↑↓ move the selection (measured 1→2), ↩ opens,
Space opens the big look, Esc closes it, Esc-on-text returns to `idle`. Idle suggestions fill `#q`
and call `queryChanged()` — the one search route, no second path (`test_media_ui.py` pins it).

*Three bugs found by measuring, none of them visible by reading the code:* (1) `render()` did not
run at startup, so `body[data-page]` was unset and **every** panel was gated off — a blank page —
and `state.groups` did not exist for the first `render()` to iterate; (2) `replaceChildren(array)`
stringifies its argument, so the chips reached the page as the text `[object HTMLButtonElement]`
(it is variadic: spread the array); (3) the mobile `#preview { position: static }` lost to the later
`#preview { position: sticky }` at equal specificity — the override is now `body #preview`.
A preview the engine has not rendered is now a **message plus the file's metadata**: every preview
`img`/`video`/`audio` has an `onerror` that replaces the picture with `noPreview(hit)` while
`facts(hit)` (name, folder, kind, size, date, z, cosine, keyword rank, segment, Open/Download) stays
in the pane. Verified with a dead handle: `.message` + `.facts`, no blank panel.

### Jobs: counters exist from the first moment of the walk

The suite caught `test_a_stop_mid_job_is_interrupted_and_the_next_job_resumes` failing
(`assert partial is not None`), in two rounds:

1. **The counts were the worker thread's private knowledge.** `run_sync()` collected events in a
   local list, and `shutdown()` marks the job from **its own thread** — so *interrupted* was
   published with no counters at all. `IndexService.events()` is now drained in `_run_one`, and
   `_progress()` merges the engine's counts into the live record **as they arrive** (in-memory on
   every `file`/`error` event; into the job log on the engine's `idle` batch totals — a handful per
   job, so a record recovered from the log after a hard kill carries the last totals it saw).
   `_mark` merges into that record, never replaces it, so every ending (`EngineExited`, timeout,
   `shutdown()`, an escaped runner exception) publishes the counts the engine really emitted.
2. **A job stopped during the model load has completed zero files** — the truth is `files_done: 0`,
   never an absent counter, so the counters are published when the walk starts. The test's
   `assert 0 < partial < expected` was a timing assumption (this suite's stop lands 6 s into a walk
   whose first minute is the model load); it is now `0 <= partial < expected`, with the engine's own
   arithmetic kept: `partial + files_done ≥ expected` (measured 8 + 7 = 15 in Stage 8).

And one contract truth the suite surfaced under load: a writer stopped mid-model-load keeps its
flock while the engine closes its stream, and a request in that window is answered **`busy`** — the
honest 409, with `_active` cleared so the next request runs. The resume test asked for the walk
exactly once and asserted that single answer was `done`; it now asks the resume until it is
accepted, which is README §5's contract ("one writer, answered busy, the next job resumes").
`tests/test_jobs.py` (+2 unit tests: the counter merge, and log-recovery totals after a hard kill).

### Notes

* `server/README.md`: the four-state layout paragraph with the measured px.
* Dev discipline learned the hard way: **never run two container suites at once** — two model loads
  saturate the VM, widen the flock window (the `busy` race above) and starve live searches. Run the
  heavy suites one at a time, and take UI measurements on a quiet machine.
* Suite count went 96 → 100 (UI pins +2, jobs +2). The run that reported `1 failed, 99 passed,
  1 deselected in 433.99 s` used the pre-fix `jobs.py` (its container imported the module before the
  fix landed) and is superseded by the 100-passed run above.

## 2026-11-04 — The API as the product, the security seams, and the Stage-9 handoff

The overnight round on `feat/server` (PR #184): API surface, security, and the handoff the GPU
box needs. **Suite: 96 passed, 1 deselected, 0 SKIPPED in 222.11 s** (the handoff script's own
run, twice: 224.38 s / 222.11 s, EXIT=0) — 21 new tests, zero skips, arm64, the shipped engine
payload. **GPU NOT MEASURED: this machine has no CUDA/Vulkan device; see
[docs/implementation/gpu-handoff.md](../docs/implementation/gpu-handoff.md).**

* **API default `limit` = 40** (`api.py`), the engine's own default (`SearchService.swift:130`).
  The UI already sent 40; a direct API client that named no limit was quietly getting a third of
  the engine's answer. Pinned twice: the typed default, and the reply against an explicit 40.
* **`server/docs/API.md`** — the API reference as an artifact of its own (schemas, media
  identifiers, limits/pagination, the error table, curl examples, versioning, security,
  multi-client use, deploy shape), independent of the UI. `tests/test_api_docs.py` fails if an
  endpoint, the `limit` default row, or the OpenAPI/docs paths drift out of it.
* **Error shapes pinned** (`tests/test_api.py`): one `detail` string for 404/409/502/503, a
  **list of objects** for 422 (the UI renders each item; printing the raw array is the bug).
* **One API process, said out loud** (README + API.md): `media_id` handles live in this process's
  LRU and the job runner is a thread inside it, so `--workers >1`/replicas 404 handles and let
  two writers race. Searches are concurrent inside the one process; only process count is fixed.
* **Host/Origin validation** (`security.py`, opt-in, off by default):
  `DIGUP_SERVER_ALLOWED_HOSTS` names the URL hosts a deployment serves → a foreign `Host` gets
  400, a browser's state-changing request from another origin gets 403, non-browser clients (no
  `Origin`) pass, read-only GETs are unchecked, ports are not compared, no wildcard. Installed
  inert by default, so a localhost box behaves exactly as before. 11 tests in
  `tests/test_security.py` pin the whole table.
* **Bearer tokens with a read/admin split** (`DIGUP_SERVER_TOKEN`, `DIGUP_SERVER_ADMIN_TOKEN`):
  read scope covers `/api/v1` except `health`/`docs`/`openapi.json` (the container's
  `HEALTHCHECK` calls `/health` with no credential); admin scope covers `POST /index` and
  `POST /estimate`. `401` + `WWW-Authenticate: Bearer` with nothing, `401` for the wrong token,
  `403` for the read token on an admin endpoint, `hmac.compare_digest` comparison. The UI prompts
  once on a 401, keeps the token in `localStorage` (`digupBearer`), retries once, and does not
  loop. Off by default; Compose passes the three knobs through unset.
* **Media-handle semantics pinned** (`tests/test_media_handles.py` + one API test): handles are
  per-reply (two replies never share one), the cache is bounded and a true LRU, and handles die
  with the process — clients key their own records on `path` + `kind` + `segment_id` (+ `loc`).
* **The interrupted-job counts fix** (a real finding from this round's suite run):
  `run_sync()` raises `EngineExited` on EOF-without-`exit` and loses the events it collected, so
  a stop landing during the model load published an *interrupted* record with **no counts** — the
  suite caught it as `assert partial is not None` under load. The runner now drains the event
  stream as it arrives and marks *interrupted* with the engine's real partial counts. The
  resume test's arithmetic was corrected to the engine's own (measured in Stage 8: 8 + 7 = 15):
  the interrupted job embedded `partial`, the resumed job embeds the rest (`unchanged` files are
  not `done`), so `partial + files_done ≥ expected` — the old `files_done ≥ partial` was the
  lucky version and fails whenever the stop lands past the halfway point.
* **Stage-9 handoff** (`docs/implementation/gpu-handoff.md` +
  `server/tests/gpu-handoff.sh`): Gate A (the CPU baseline: pins verified against
  `ModelFiles.swift`, the contract suite with a zero-skip gate, Compose boot, the image's own
  healthcheck, a search, a non-137 stop with `Application shutdown complete`) and Gate B (the
  card: toolkit test, CUDA payload `ldd`, `speed --model --json`'s measured `device`, and
  **GPU utilization sampled during a real index job** — "detected the device, embedded on CPU"
  is a failing gate). Gate A ran green here on arm64 twice; Gate B runs on the x86_64 NVIDIA box.
  The script prints `GPU NOT MEASURED` in those words whenever Gate B did not prove it.

## 2026-11-03 — Stage 11: the review round — parity proven, suite 75, CI that can't pass by luck

Adversarial review of the whole PR (backend; UI + media; build/CI/docs), every real finding
fixed **and pinned by a test** — the finding→fix→test table is
[docs/implementation/review-round.md](../docs/implementation/review-round.md), the stage
record with all measurements is
[stage-11-review-round.md](../docs/implementation/stage-11-review-round.md).

* **Suite: 75 passed, 1 deselected, 0 SKIPPED in 235.15 s (EXIT=0)** on the final committed
  tree (`suite24.log`) — reproduced 75/1/0 in 228.12 s (`suite23.log`). Buckets 17
  search-contract + 19 API + 6 index-contract + 13 job + 17 UI/media + 4 CLI = 76 collected,
  CI deselects the slow model timing.
* **The harness fact that changed the test image:** plain `docker run` makes pytest **PID 1**,
  and ParentWatch ends every engine helper whose parent is PID 1 (`ParentWatch.swift:19`) —
  measured `7 failed, 9 passed, 59 errors`, all helpers dead `exit 0, no stderr`. The test
  image now carries `tini` as ENTRYPOINT, so the suite is PID-1-safe by construction and CI
  needs no `--init`.
* **Parity (the user's "100% like the app" question):** the app's own adapter (`SearchService`)
  on a `sqlite3 .backup` snapshot of the live corpus2 index answers the same queries as the
  live HTTP API with **identical hits/strong/z** — water 1 (2.09), harbor 2 (3.87/2.35),
  "a sunset over water" 3 (3.51/3.37/2.28), wakeboarding 3 (4.15/4.06/3.09), fractal 1
  (3.59) — plus the keyword-first path. Logs: `stage11-parity-direct.log`,
  `parity_backup.log`. Probe lesson kept: a read-only mount of a **hot WAL index** (and a
  plain `cp` of it) is not a snapshot — it answered 0 hits, a probe artifact, not a server bug.
* **"Fewer responses" quantified:** `zGate = 2.0` (`Searcher.swift:116`) and the engine's
  default limit 40 (`SearchService.swift:130`) are identical on Mac/shell/server; corpus2 is
  61 files, so 1–3 ≥2σ hits per query is the corpus's size, not a cap (documented in
  `server/README.md` + `server/tests/corpus2/README.md`).
* **Live proof battery (`stage11-proof.sh`): PASSED, 11 gates, 0 fails** — compose config
  valid; container healthy via the image's own `healthcheck.py` (503 = alive);
  `restart: unless-stopped`; published `{127.0.0.1 8787}`; healthcheck proven both
  directions (0 on live, non-zero with nothing listening); 12 health polls in 1 s (the
  StatusCache TTL, no subprocess per poll); index job `done · 61/61 · vectors 65 · 0.1 s`;
  searches with the engine's z verbatim (3-strong, to z 4.46); `nosniff` on 200 + 206;
  `Range: bytes=0-` → `206 bytes 0-124176/124177` (8 MiB cap, streamed); 416; 404;
  estimate `≈263.9 s · 61 files · calibrated true`; UI markers pinned present in served bytes.
  Log: `stage11-proof.log`.
* **UI verified in a live browser (Playwright, no vision model):** Space on the focused gear
  opens Settings (aria `true`, focus into the panel), Esc closes (aria `false`, focus back to
  the gear), Space on a focused row opens the big look with media, Space on a focused link is
  native activation; 3 hits + preview fields verbatim; video `…/file#t=12.5` ("▶ at 0:12",
  z 3.25); job line `done · searchable 61/61 · vectors 65 · 0.1 s`; estimate renders; dark
  theme applies + persists; console clean (favicon silenced with a `data:` icon — no
  external URL, the pin test stays green). Screenshot: `.playwright-mcp/stage11-dark-results.png`.
* **Backend fixes (pinned by tests):** `shutdown()` self-deadlock; runner thread surviving a
  `TimeoutError`; child reaped on a failed handshake; `ok:false` without `error` is a
  refusal; render beside the read loop (2 slots, lock-free); `Range` capped + streamed +
  `fstat` + `is_relative_to` + `nosniff`; `TimeoutExpired` → quoted 502; job-log rotation is
  one rename (timestamp suffix) and replay skips non-records; `HitCache` is a true LRU;
  `StatusCache` TTL; `SearchReply` `extra="allow"`.
* **UI fixes (browser-proven):** Space keeps native activation for buttons/links (the
  reviewer's blocker); a failed job poll answers honestly and stops (one loop per click);
  FastAPI list-`detail` renders readably; one `closeSettings()` syncs aria + focus; estimate
  generation token; roving tabindex + aria; chip contrast AA (4.54:1); `.badge.warn` cascade;
  audio control selector; mobile footer wrap; `maxlength=512`.
* **CI/images:** 180-min ceiling; vendor built host-side via the repo-pinned `actions/cache`
  and seeded through `.ci-vendor/`; drift guard FIRST (revision + names + sha256s);
  zero-skip gate + clip-exists gate; boot step polls with the image's own `healthcheck.py`;
  `proof.sh` counts failures and gates the eval ALL row (R@1 ≥ 0.60, R@5 ≥ 0.85). Measured
  honesty: base Debian 13 trixie, glibc 2.41-12+deb13u4 (newer than the payload's 2.35 —
  forward, never back); no `/data/locks`; inert host/port ENVs gone.
* **Commit shape (local, on `feat/server` — origin is upstream, nothing pushed):**
  `6ac98a3` backend+tests · `431059c` UI · `5830e8d` images/CI · docs. Additive invariant
  held: `git diff --name-status main..HEAD` = 61 A + 1 M (`.gitignore`); `Sources/`,
  `shell/`, `website/`, root README, upstream workflows untouched.
* **Open (honest):** CI's first green run is pending (no push to upstream per the git-safety
  rule — the workflow is written and YAML-validated, 17 steps); Stage 9 (GPU override) and
  Stage 10 (PhotoPrism comparison) remain.

## 2026-11-02 — UI reorganized around the search (the user's layout brief), in the browser

* **The page is a search:** centered search box with the hit-limit select at its right
  end (arrow evenly spaced off the edge — selects render their own chevron per theme),
  theme-colored kind chips in one evenly spaced centered row beneath it (filled in the
  kind's color when ticked), results bottom-left, preview right, keys footer. Header:
  title + searchable count + activity + a gear.
* **Settings panel (the gear):** Appearance, Index now + prune missing, Estimate, and the
  engine's counts (vectors, encoder, kinds, index size, build tag, roots). Estimate stays
  honest and short — one note line, the forecast renders above the results, the long
  paragraph the user pointed at is gone. The panel closes on Esc, outside click, and on
  opening the estimate. `#settings[hidden]{display:none}` — the same `[hidden]` lesson as
  `#big`.
* **`el()` fixed:** the helper took an element as its text arg at three call sites and
  stringified it — the "[object HTMLElement]" text the user saw (estimate rows, preview
  messages). Children are real nodes/text nodes now; verified clean in the browser
  (`[object HTMLElement]` = false, zero console errors).
* **"water shows only the harbor photo" is the engine, not the UI:** `Searcher.zGate = 2.0`
  (`Sources/DigUpKit/Searcher.swift:116`) filters sub-2σ candidates inside the binary —
  the Linux app with the same index answers the same single hit. Measured live: 1 hit,
  z 2.09. The UI publishes the engine's answer unchanged (the server's core rule).
  Panel parity re-audited against `panel.js`: `limit: 40` (the engine default — the
  select is a superset), the WEAKER fold, groups, keyboard flow, footer summary.
* Browser battery re-run: typing → 5 hits (4 strong) → click → preview, settings open,
  estimate clean, theme flip, 0 console errors; layout verdict from the vision model:
  all checks pass (header tidy, centered search, chips even, panel neat).
* **Geometry pass (the "all off centered" complaint) — measured, not eyeballed:**
  bounding-box audit in Playwright at 1280 px and 390 px. After: search input center
  offset **0 px**, chips row **0 px**, statusline −5 px, gear's icon **0/0** in its circle
  (inline SVG, theme-colored via `currentColor`), settings panel anchored under the gear
  (right edges equal at 1196) with **all control left edges at one x (911)**, footer text
  box aligned to the content column, `overflowX: 0` at both widths, search row stacks
  centered on mobile. One axis, verified by numbers. The single-column system: header
  grid (title/gear, centered status row), search row `1fr auto 1fr` (the input's center
  IS the page's center; limit + code at its right end), settings as a label/control
  grid with section rules. Caught by the same audit: the gear's **svg child** broke the
  outside-click close (`target !== gear`) — `closest("#gear")` now; the panel-open
  geometry proved it (a collapsed 0×0 rect = the click had opened and re-closed it).

## 2026-11-02 — Dark theme made readable, in a real browser (Playwright is up)

* **The complaint ("The UI is way too dark. I cannot see anything for the dark theme") had a
  root cause found in the browser, not in the palette:** the big-look overlay `#big` set
  `display: flex`, which outranks the UA's `[hidden] { display: none }` — so a `position: fixed`
  layer at 78% black covered the whole page permanently, dimming everything under it and
  intercepting every click (Playwright: "div#big intercepts pointer events"). Fixed with
  `#big[hidden] { display: none }`; click → preview, Space big-look, Esc all verified live.
* **Palettes are now explicit per theme — no system colors, no OS dependence:** light/dark var
  blocks per `data-theme` (+ a `prefers-color-scheme` block for System), each setting its own
  `color-scheme`, so checkboxes, selects and scrollbars render *in* the theme;
  `accent-color` on the checkboxes. The text pairs are measured WCAG ratios, not eyeballed:
  on dark, text `#e8eaed` on `#202124` = 13.4:1, muted `#b7bbc1` = 8.4, accent `#8ab4f8` = 7.6,
  kind colors ≥ 6.4; on light, text `#1a1a1a` on white = 17.4, muted `#5f6368` = 5.9. Panels
  got surfaces (`--panel` + `--edge` borders) so structure stops dissolving — hairlines stay
  deliberately quiet (~1.8:1, they are separators, not text). Screenshot verdict from the
  vision model after the fix: 9/10 readable, both themes, results + preview + estimate.
* **The UI ships `cache-control: no-cache` (`UIFiles` in `api.py`):** measured in the browser —
  without it, Chrome answered reloads from its memory cache for minutes, serving a stylesheet
  the server no longer had, so a deploy never reached the page. Etag in, 304 out, revalidation
  is cheap. Pinned by a test.
* **`EngineRefused` — the engine's refusal is a 503, in its words:** the Stage-10 battery hit
  the searcher mid-transition right after a done job: the engine answers `{"ok":false,
  "error":…}` (`SearchService.swift:106,115`) and `api.py` crashed `KeyError: 'hits'` (500).
  Now `SearchService._checked` raises `EngineRefused` on any `ok:false` reply, the API answers
  503 with the engine's sentence, the job runner survives a refused post-job refresh (the job
  stays *done*, with a "searcher refresh deferred" note), and startup's prewarm is best-effort
  the same way. Proven by the API pair of tests — a refusing injected service, a stub refusal
  reply, no engine mocks; the proof battery gates on "searchable == files · encoder ready" and
  retries 503s, printing each refusal it met.
* Statusline: `index NaN KB` — app.js ran the engine's human string through `bytes()`; now it
  shows the engine's own words verbatim (`index 201 KB`).
* **Suite: 56 passed, 1 deselected in 192.51 s (EXIT=0)** — the 53 plus the 503 pair and the
  revalidation rule. Live proof: [stage-10-ui-parity.md](../docs/implementation/stage-10-ui-parity.md).

## 2026-11-02 — Stage 10 done: the web UI reaches desktop parity; corpus2 for live testing

* **UI parity (`server/ui/`, rewritten against `shell/ui/panel.js`):** keyword-first
  typing (words at once with `prefix_last`, `embed_ahead`, the `meaning:true` upgrade
  after 120 ms, generation + final-generation guards); strong/weaker fold; kind
  checkboxes → `kinds` (none ticked = all = the engine's default); `code:` prefix +
  code checkbox as one state; limit select (40 = the engine's default); grouped rows
  with lazy engine thumbnails; a preview pane for the selection (photo, video frame
  that plays *from* `#t=loc`, PDF page, audio at the moment, matched passage via
  `/text`) with facts + a plain-language reason built from the engine's own fields;
  arrows/↩/Space/Esc keyboard flow with the big look; Open + Download; Estimate panel
  (`POST /estimate`, the `calibrated` truth); activity dot; summary + keys footer.
* **Appearance (the theme ask):** System / Light / Dark select → `data-theme` + CSS
  variables, kept in `localStorage`; System tracks `prefers-color-scheme` exactly as
  the OS-following desktop does.
* **`GET /media/{id}/file` — the app's "Open" over HTTP:** server-issued handles only,
  roots-containment on the resolved path, media type from **magic bytes**, inline for
  media kinds, attachment + `text/plain` for code/doc (a source file named `index.html`
  never arrives as markup), `Accept-Ranges: bytes` with 206/416 — what makes
  `<video …#t=loc>` seek.
* **`/status` publishes the server's own roots** (env-configured paths, shown for the
  user; display, not path acceptance).
* **Settings mapping, honestly:** OS integrations (login, tray, shortcut, updates,
  index hours, folder pickers…) are deployment env config for a server; *reveal* and
  *copy file* are absent, not faked. Documented in README's parity table.
* **corpus2:** 60 Commons photos (20 subjects × 3), 1400 px renders pinned by sha256,
  out of git, `build.sh` fetches + verifies; the H.264 clip travels with it. The suite
  corpus stays 15 files (rankings normalize over that set).
* **Suite: 53 passed, 1 deselected in 190.18 s** (48 from Stages 3–8 + 5 Stage-10:
  the parity UI surface, `/file` 200/206/416/404 + magic types, roots in status).
  Live proof + UI sweep: [stage-10-ui-parity.md](../docs/implementation/stage-10-ui-parity.md).

## 2026-11-02 — Stage 8 done: persistence and reliability under load

* **Stop-at-the-safe-point**: `shutdown()` sends the engine's `stop` to the live writer;
  the walk ends **between files**, the job records *interrupted*, never success. Both
  stop-grace paths measured live in Compose: Docker's default 15 s lands mid-embed as
  **137 + replay recovery** ("server restart: job never finished" → next job resumes
  the walk to `done` — proven); with `stop_grace_period: 90s` (now in the Compose
  file) the lifespan finishes inside the grace: *interrupted* **with partial counts**,
  `Application shutdown complete`, exit 143. SQLite stays whole in both (WAL).
  `reload → prewarm` skipped on the stopping path.
* **Job log rotates at size** (`DIGUP_SERVER_JOB_LOG_SIZE`, default 1 MiB; chain
  `.1 … .N`, higher = older); replay reads **all** rotations oldest-first — history
  outlives any rotation, the `interrupted` rule included.
* **Backfill knob** env-driven (`DIGUP_SERVER_BACKFILL`, default on = engine
  `--backfill`; 0 = sync only) — reaches the runner and the engine argv.
* Resume proven at walk level: mid-job shutdown → interrupted (partial) → **next writer
  takes the flock, resumes (embedded files unchanged, SQLite kept whole), finishes**:
  `done`, index == the walk, `files_done ≥` the partial. Assertion pattern learned:
  compare the index to the **live folder count** (session scratch grows across tests) —
  engine truth, not a frozen constant.
* **Suite: 48 passed, 1 deselected in 181.86 s** (45 from Stages 3–7 + the 3 Stage-8
  tests: stop-mid-job-resume, rotation-with-history, env knobs). Doc:
  [stage-8-persistence.md](../docs/implementation/stage-8-persistence.md).

## 2026-11-02 — Stage 7 done: the shipping image + Compose, healthy and truthful

* `server-runtime` image (`digup-server:local`, **562 MB**): engine payload + API + UI on
  `python:3.12-slim`, **no toolchain/desktop stack**, non-root (`uid 990`), `tini` PID 1 —
  chain proven live: `tini → uvicorn → digup` (helper's parent is uvicorn, ParentWatch's
  condition met). HEALTHCHECK = the API's own `/health`; Compose (`deploy/`, `name:
  digup-server` — isolated project, never `--remove-orphans`) publishes
  `127.0.0.1:8787`; all state on bind-mounted volumes. Build runs the §3 acceptance check
  (`digup --help` headless in the final image) + API imports.
* **SIGTERM contract (measured, honest):** stop takes 1–2 s; the log shows the full
  graceful lifespan (`Application shutdown complete`); recorded exit code **143** =
  completed SIGTERM. CI asserts exit **≠ 137** (137 = SIGKILL = hung shutdown) **and**
  the shutdown-complete line — replacing the wrong `= 0` assertion.
* **Startup prewarm** (finding-driven): lifespan runs the engine's `prewarm` op; fresh
  container answers `encoder ready · vectors 74` at 14 s, first search `embed 548 ms`
  (was: vectors 0, 4 257 ms). `DIGUP_SERVER_PREWARM=0` skips it.
* **The prune knob + root-scope rules** (finding-driven): ghost rows = an index folder
  shared across two root layouts; rows outside the current roots count in
  files/vectors and **dilute z** (3 strong answered as 1). `POST /index {"prune":true}`
  (UI "prune missing") → engine `--prune` → files 30→15, vectors 74→37 in 0.1 s.
  Tested truths: plain sync retires walked-root ghosts; out-of-scope ghosts survive
  plain sync, retire under prune; the job record persists the prune flag across
  restarts. Operational rule (README + Compose header): an index folder belongs to
  **one root layout** — suite/dev use `index-suite` (fresh 15-file index, 2 min build),
  Compose uses `index`.
* **Suite: 45 passed, 1 deselected in 215.60 s** (22 contract + 10 API incl. prewarm +
  6 jobs incl. the two ghost-row tests + 7 UI/media). Compose live proof on the final
  image: prune job persists `prune: True` across a restart; post-restart status
  `encoder ready · vectors 37 · files 15`. Doc:
  [stage-7-runtime-image.md](../docs/implementation/stage-7-runtime-image.md).

## 2026-11-02 — Stage 6 done: the web UI, vanilla and same-origin

* `server/ui/` (HTML/CSS/JS, no build step, no dependencies, no external URLs — a tested
  property): debounced typing → `POST /search` + `embed_ahead` warm-up; hits with kind
  badges, engine `z`, `at m:ss` moments from `loc`, real `ms`; the honest empty shown as
  the engine's refusal; preview/text via **server-issued `media_id` handles only** (never
  client paths, symlink-safe, 404 for unissued ids); Index-now with 409/busy polling and
  the engine's counts; 15 s status strip. Served by the API at `/` (same origin → no CORS).
* `api.py` additions: `media_id` on hits (bounded `HitCache`), `GET /media/{id}/preview`
  (engine `render` JPEGs from `<index>/previews` only), `GET /media/{id}/text`,
  `POST /embed_ahead`, `StaticFiles` mount.
* **Suite: 42 passed, 1 deselected in 107.87 s** (22+9+4+7). Live: UI served at `/`,
  photo preview 13 KB JPEG, video frame at the engine's 9.5 s moment, 404 on an unissued
  id. Doc: [stage-6-ui.md](../docs/implementation/stage-6-ui.md).

## 2026-11-02 — Stage 5 done: index jobs, one writer, honest states

* Job runner (`server/digup_server/jobs.py`): serialized worker + the adapter's flock;
  `POST /api/v1/index` 202s a job / 409s while one runs (names it); append-only job log
  (`jobs.jsonl`), a `running` line with no ending recovers as **interrupted** — never
  success (README §5); counts from the engine's events (`file` dones + `idle` totals);
  after `done`: `reload → prewarm`, wired in the lifespan. The active marker clears when
  the writer releases the lock, before `done` publishes — no done-409 window (the suite
  caught the inverse order in one run; fixed in the adapter).
* **Suite: 35 passed, 1 deselected in 128.69 s** (22 contract + 9 API + 4 job tests,
  real engine, no mocks). Live check: 202 queued → 409 busy → `done` with `files 15 /
  searchable 15 / pending 0 / vectors 37` → searcher `ready` with 37 vectors. Doc:
  [stage-5-jobs.md](../docs/implementation/stage-5-jobs.md).

## 2026-11-02 — Stage 4 done: the API on `/api/v1`, live and localhost-bound

* FastAPI app (`server/digup_server/api.py`) **on top of the adapter**: `GET /health`
  (engine identity: fingerprints, llama.cpp build tag, vectors version, live counts),
  `GET /status` (+ the CLI's kind table), `POST /search` (hits verbatim, `strong`,
  `meaning`, `ms`; protocol `id` stays inside; honest empties published),
  `POST /estimate` (`estimate --json` — usable because the API is a live parent, not PID 1).
  uvicorn `--factory`, bound `127.0.0.1:8787` by default; `docker run --init` gives the
  helpers a parent they accept (ParentWatch); engine failures map 503/504/502 quoting the
  engine; 422s where the engine would silently drop input. `.env.example` documents every
  setting.
* **Suite: 31 passed, 1 deselected in 92.10 s** (22 contract + 9 API tests, real engine,
  no mocks). Live check: the wakeboarding top-3, `strong 3`, `ms {embed 1554, search 8}`
  over HTTP; encoder `ready` after first query, 37 vectors, kinds 12/3; empty honest
  answer and 422 verified from the host loopback. Doc:
  [stage-4-api.md](../docs/implementation/stage-4-api.md).

## 2026-11-02 — Stage 3 done: adapter + contract tests, green

* **Suite: 22 passed, 1 deselected in 88.75 s** in `digup-server-test:local` (the shipped
  engine payload + `python:3.12-slim` + uv) against the real engine, corpus, model and
  index — no mocks; the suite self-skips without them. `pytest -m slow` (the
  `speed --model --json` timing) passes separately. Full doc:
  [stage-3-adapter.md](../docs/implementation/stage-3-adapter.md).
* Adapter in `server/digup_server/engine/`: `config.py`, `protocol.py` (JSON-lines
  supervision: replies by `id`, event queue, engine-exit semantics, `ParentWatch` respected —
  helpers are spawned directly, the supervisor is the long-lived parent), `search.py`
  (all documented ops; idle-exit = transparent restart, last `folders` change replayed),
  `index.py` (plain-line commands, event stream, single writer by `flock` on
  `<index>/.digup-server.writer.lock` — second writer gets `IndexBusy`, tested),
  `cli.py` (`status` parsed, `estimate --json` + plain, `speed --model --json`).
* uv project (`pyproject.toml` + `uv.lock`), Python 3.12, stdlib-only adapter.
* Contract tests pin, against the live engine: hit fields verbatim, honest "no good
  matches", kind filter, render → JPEG under `<index>/previews`, summaries counts, idle
  restart (encoder-idle 2 → engine self-exit → transparent respawn), sync/file/summary
  events + `idle` totals (post-index truth rides `idle`, not the transient mid-stream
  syncs), missing-root-is-reported-not-fatal, `text` of a hit's segment,
  sync → `reload` → `prewarm` → new vectors searchable, `estimate --json` answers for the
  server as parent (Stage 2's "silence" was ParentWatch's PID-1 rule — corrected finding,
  reconnaissance §15 item 8).
* CI added: `.github/workflows/server.yml` (builder incl. `swift test` → runtime CLI check
  → corpus + pinned model download → contract suite → Stage-2 proof → proof logs).

## 2026-11-02 — Stage 2 done: headless proof on Linux, CPU-only

Index 15 files / 37 vectors / 4 min; `wakeboarding`/`hiking`/campfire/… rank exactly,
video timestamps to the second (`[at 0:09]`); eval R@1 0.71, R@5 0.88 over 17 queries; the
engine's "no good matches" kept as an honest empty. Full run:
[stage-2-headless-proof.md](../docs/implementation/stage-2-headless-proof.md).

## 2026-11-02 — Stage 1 done: the engine builds and tests on Linux

`swift build -c release` + `swift test` (116 + 7 tests, 0 failures) in a multi-stage Docker
build (Swift 6.4.0 GPG-verified; llama.cpp b11461 CPU; pinned vendor); 296 MB runtime image
running `digup` with no toolchain, no desktop stack. Model files verified against
`ModelFiles.swift` pins. Details: [stage-1-linux-build.md](../docs/implementation/stage-1-linux-build.md).

## Open issues

1. **Supervision rule (from Stage 2's corrected finding, reconnaissance §15 item 8):**
   ParentWatch helpers (`index-service`, `worker`, `search-service`, `estimate --json`)
   exit within a second when their parent is PID 1. The server must be the long-lived
   parent and spawn helpers directly (`protocol.py` enforces); a PID-1 `bash -c` wrapper
   is not a parent. `estimate --json` works from the server and is pinned in
   `server/tests/test_cli.py`. Stage 4 must keep uvicorn as that parent.
2. ~~`search-service` idle-exit restart restart-wiring + `reload → prewarm`~~ — done:
   after a done job the runner does `reload → prewarm`, and the lifespan prewarms at
   startup (`DIGUP_SERVER_PREWARM`); both pinned by tests (Stage 5/7).
3. Preview exposure policy: the API will read `<index>/previews` itself, never serve the
   path (Stage 4/6).
4. GPU path (Stage 9) on the x86_64 server: Vulkan build + `digup speed --model` measurement
   with the agreement check — built and measured only where the GPU is.
5. Prod host: the x86_64 image is built natively on the production server (README §11);
   CI (`.github/workflows/server.yml`) exists and runs the same stages on `ubuntu-24.04` —
   its first green run on GitHub is the remaining proof.
6. Cosmetic, dev-only: starlette's TestClient warns that `httpx` is superseded by
   `httpx2` for in-process ASGI testing (the one pytest warning in the suite). Migrate
   the dev group when `httpx2` ships; tests pass today.
7. Visual browser pass of the UI not yet run (no Chrome on this host for the automation
   tool): the UI is proven by 7 DOM/HTTP tests + `node --check` + a curl transcript. A
   human pass in Safari/Chrome on this machine is the remaining check (Stage 11 polish).
8. **Ranking reference: confirmed current-pipeline, with a measured drift pattern.**
   Suite 12–15 (fresh 15-file `/corpus`-scoped index, built with the engine CLI)
   reproduce the Stage-2 wakeboarding top-3 and the full search contract — the frozen
   rankings are the current pipeline's truth *for a CLI-built index*. The drift,
   reproduced on every fresh Compose-side index (four builds): the same 15 files
   indexed by the **server's own job** (`index-service`, backfill on) answer
   `wakeboarding` with aarhus-04 at z ≈ 0.47 (suite-index value: 1.57), vienna 1.59,
   logan 1.58 — search stays strong 3, order of the weak one differs. Same bytes, same
   binary payload: the likely cause is CPU embedding non-determinism across process
   shapes (long-lived service vs one-shot CLI). Stage 9 (GPU on the prod box) is where
   this gets measured properly (`speed --model`, repeated embeds, backend choice) —
   the server quotes the engine's ranking either way; nothing server-side "fixes"
   z, and nothing should.

## What runs today, exactly

Updated 2026-11-08 (stage 13). The Stage-2 headless proof below stays valid evidence.

```
suite (container)       contract suite, 4 mounts, -rs               — 137 passed / 1 deselected
                        server/tests/proof.sh index+search+eval     — / 0 failed / 0 skipped
                        (EXIT=0, R@1 0.71 / R@5 0.88)                (2026-11-08, run 18,
                                                                     197.37 s); proof.sh green
digup-server-cuda:local bench compose stack, healthy, 127.0.0.1:8787 — media index 131,972 files
                        (standalone MINTS its API key at boot;      / 131,758 searchable,
                        keyless gear shows it: Copy + Regen inline; GTX 1070 (GPU 0) pinned
                        10/10 strong, round-6 UI, run 18 tree)
digup-server-nextcloud-* pilot stack :8791 API / :8090 web,         — media-resume job left
                        app 0.4.2 deployed (one "API key" field)      running (user: works)
(demo stack retired 2026-11-08 at the user's
 request — the live gates run against the
 pilot and the standalone directly)
digup-server:local      runtime image (payload+API+UI, tini, non-root — Stage 7 + 13,
                        + nvidia/cuda runtime libs for the CUDA flavor — Stage 9)
```
