"""The UI and media surface (Stages 6 and 10; the Lit migration of 2026-11-08):
same-origin frontend, server-issued handles, and the file itself with ranges honored.

The rules this pins (README §6, §7, §10.4's 2026-11-08 amendment): the UI is the
**built Lit + Vite frontend** served same-origin (no external URLs; Node exists at
build time only, the runtime ships static files); the stable asset names (`app.js`,
`style.css`, `embed.js`, `embed.css`) are the pinned contract FastAPI serves from
`server/ui/dist`; the media endpoints accept **only ids the server issued from
published hits**, never client paths; previews are the engine's own JPEGs from
`render`, served only from `<index>/previews`; the text endpoint quotes the passage
the engine indexed, verbatim.

The string pins moved with the migration: the vanilla UI kept ids and strings in
served HTML; the Lit UI renders them inside shadow templates, so the pins read the
served BUNDLE (Lit `html``/`css`` template literals survive minification verbatim —
the pinned strings must stay byte-identical in the templates, and the pins below
say which ones are load-bearing). Pins scoped "in html" check the thin shell;
"in bundle" checks the entry plus the hashed chunks the shell links.
"""

from __future__ import annotations

import re

import pytest
from fastapi.testclient import TestClient

from conftest import _cfg
from digup_server.api import create_app


@pytest.fixture(scope="module")
def media_client(corpus, index):
    with TestClient(create_app(_cfg(index, (corpus,)))) as c:
        yield c


@pytest.fixture(scope="module")
def doc_client(scratch, scratch_index):
    """Same app shape over the scratch corpus — the one with a text document."""
    folder, _ = scratch_index
    with TestClient(create_app(_cfg(folder, (scratch,)))) as c:
        yield c


def _page(client) -> str:
    return client.get("/").text


def _bundle(client) -> str:
    """Every JS byte the built page loads: the entry plus the hashed chunks the html
    links. Module boundaries are a build detail — the string pins read the bundle a
    browser actually runs, not one chosen file."""
    html = _page(client)
    paths = ["/app.js"]
    paths += re.findall(r'href="\./((?:chunks|assets)/[^"]+\.js)"', html)
    return "\n".join(client.get(p).text for p in paths)


def _styles(client) -> str:
    """Every CSS byte + the component CSS: Lit ships `css`` chunks as RUNTIME styles
    (template literals in the bundle, verbatim — the reason the layout pins below read
    them there, not from a static file); the static files carry tokens + the frame."""
    html = _page(client)
    css_paths = re.findall(r'href="\./(assets/[^"]+\.css)"', html)
    parts = [client.get("/style.css").text] + [client.get("/" + p).text for p in css_paths]
    return "\n".join(parts) + "\n" + _bundle(client)


def test_root_serves_the_lit_ui(media_client):
    page = media_client.get("/")
    assert page.status_code == 200
    html = page.text
    bundle = _bundle(media_client)
    assert "DigUp" in html and "app.js" in html and "style.css" in html
    # Same-origin discipline (README §10.4): no external scripts/styles, ever.
    assert not re.search(r'(src|href)="(https?:)?//', html), "UI must not load external URLs"
    # ES-module entry: the built bundle (the migration's served shape; vanilla was a
    # plain classic script — the flip is pinned here so it can never silently regress).
    assert re.search(r'type="module"', html)
    appjs = media_client.get("/app.js")
    assert appjs.status_code == 200 and "fetch(" in bundle
    assert "media_id" in bundle                             # it uses the server's handles
    assert media_client.get("/style.css").status_code == 200
    # Stage-10 parity with the desktop panel: appearance choice, kind filters, code mode,
    # keyword-first typing (prefix_last then the meaning upgrade), the keys footer.
    assert 'data-theme="system"' in html                    # the thin shell carries it
    assert 'id="theme"' in bundle and "system" in bundle
    assert '"screenshot","Screenshots"' in bundle and 'id="code"' in bundle
    assert "prefix_last" in bundle and "embed_ahead" in bundle
    assert "localStorage" in bundle                          # the theme is kept in the browser
    assert "↑↓" in bundle and "Space" in bundle
    # API key lives in Settings (2026-11-08 UX brief, round 2): the section is ONLY the
    # minted-key rows with Copy and the Regenerate button — no paste field, no Save,
    # no Clear (the key is server-generated at runtime; the applications paste it into
    # THEIR settings, this browser takes the admin key itself on Regenerate). The embed
    # widget (no settings panel of its own) keeps its prompt (test_integrations covers).
    assert "API key" in bundle and "Copy" in bundle
    assert 'id="api-key"' not in html and 'id="api-key"' not in bundle
    assert 'id="api-key-save"' not in bundle and 'id="api-key-clear"' not in bundle
    assert "digupBearer" in bundle
    assert "window.prompt" not in appjs.text                # main UI: no load-time prompt
    # Stage 13 (reworked) + the 2026-11-08 round-3 brief: the minted keys render as
    # ONE label + the key in a field + icon actions (⧉ copy, ↻ regenerate). The round-4
    # brief put the index counts into the status card; the round-5 brief took the
    # "Looking in: <roots>" line out of the panel entirely (the card's two tiles carry
    # files/searchable; the roots stay in GET /status). The gear's section order is the
    # operator's reading order; the round-4 layout brief renamed the sections to
    # Appearance · Indexing · Index status · API access, each heading carrying a small
    # icon INSIDE the title span — so the order pin rides the heading ids plus the
    # heading text. Rows keep one row height, equal padding and borders (the user's
    # "clean and orderly, equal size rows").
    assert 'id="appkeys"' in bundle and "Total files" in bundle   # keys rows; the card's tiles
    assert 'id="api-key-sec"' in bundle
    assert "Set in the server's environment" in bundle      # env-keyed shape says so
    assert "Regenerate" in bundle and "/api/v1/tokens" in bundle
    assert "/api/v1/targets" in bundle
    css = _styles(media_client)
    row = css[css.index(".appkey-line"):]
    assert "grid-template-columns" in row and "min-height" in row
    # One row height for every gear control (round-3 styling ask): the panel's controls
    # and key rows share the token-defined 2rem row (`--row-height: 2rem`).
    assert "--row-height: 2rem" in css
    assert "min-height: var(--row-height)" in css
    pos = [bundle.index(f'id="{s}"') for s in
           ("set-appearance", "set-indexing", "set-status", "set-apikey")]
    assert pos == sorted(pos)
    for h in (" Appearance</span>", " Indexing</span>", " Index status</span>",
              " API access</span>"):
        assert h in bundle
    # Round-4 layout brief: ONE distinct card (the index status — directory, the two
    # counts side by side, wrapping badges); the estimates row is text + right-aligned
    # switch; the sections ride 1 px dividers, not boxes.
    assert 'class="status-card"' in bundle and 'class="stats"' in bundle
    assert 'class="set-state"' in bundle                                   # heading state (round-6)
    assert "border-top: 1px solid var(--line)" in css
    # The main page keeps no status nag (2026-11-08 UX ask): counts live in the panel.
    assert 'id="statusline"' not in html and 'id="statusline"' not in appjs.text
    assert "status unavailable" not in bundle
    # Estimate (round-6 brief): the toggle and the forecast rows are GONE — the Estimate
    # button rides the Index now row, and the INDEXING heading carries the live state:
    # a TRUE CIRCLE spinner (ring + rotating bright quadrant, no glyph) while the engine
    # walks, ✓ when it finished, the brief update beside it (the job's own words).
    # No main-page estimate popup, as always.
    assert 'id="estimate-spin"' in bundle and ".estimate-spin" in css
    assert "estimating — the engine is walking the folders…" not in bundle
    assert appjs.text.count('id="estimate"') == 0          # the forecast box is gone
    assert 'class="set-head-row"' in bundle and "state-done" in bundle
    assert "digup-settings" in bundle and "digup-big" in bundle   # panel-side, never the main page
    assert css.index(".estimate-spin") < css.index("@keyframes spin")
    assert "border-radius: 50%" in css[css.index(".estimate-spin"):css.index("@keyframes spin")]
    assert "flex-wrap: wrap" in css[css.index(".set-facts"):]   # badges wrap naturally (round-4 brief)
    # Round 7 (the layout brief): the panel NEVER scrolls — `overflow-y: auto` made a
    # clipping box (controls cut at the edges, a scrollbar stealing width, the modal
    # able to leave the viewport). The API-key row's grid is minmax()-bounded: the old
    # `9rem ... auto auto` minimum (~24.6 rem) sat ABOVE the ~21 rem control column —
    # a ~120 px overflow past the panel's right edge, growing on narrow windows.
    assert "overflow-x: clip" in css and "overflow-y: auto" not in css
    row_grid = css[css.index(".appkey-line { display: grid"):]
    assert "grid-template-columns: minmax(4rem, 6rem) minmax(0, 1fr)" in row_grid
    assert "min-content min-content" in row_grid[:220] and ".appkey-line > * { min-width: 0; }" in row_grid
    # Round 6 (the user's brief): the API-key section is the key ITSELF with Copy —
    # the keyless gear is shown the minted ticket (`GET /tokens` key-free in a minted
    # deployment) — and Regenerate rides the key row's right edge (not a loose button
    # under the section). The row grid: label | key | Copy | Regen.
    assert 'id="appkeys"' in bundle
    assert '"keys-regenerate"' in bundle and "digup:regenerate" in bundle
    assert "#keys-regenerate { margin-left: auto; }" in css
    # Round 6 (the user's brief): the estimates toggle + the forecast section were
    # removed — the Estimate button rides the Index row, the heading carries the state.
    # The CONTROLLER keeps its gate keys (object-literal keys survive minification): the
    # switch is gone, the browser key and the click-again cancel stay.
    assert 'id="estimate-toggle"' not in bundle and "estimateOn" in bundle
    assert "estimate-ctl" not in css and "select#theme { width: 100%" in css
    # A finished crawl re-reads the index list: the panel shows the targets that exist
    # NOW (no stale rows survive a completed job). Key names in an object literal
    # survive minification; the controller's export keys are pinned.
    assert "loadAccess" in bundle and "retried" in bundle
    # Round 7: the gear ADOPTS the minted admin key it is shown — its own controls
    # (Index now, Estimate, Regenerate) are admin-scope by the minted shape's design,
    # so the operator's gear uses the key the server just displayed to it. A stale
    # stored key is dropped only where a keyless main read proves the minted shape.
    assert '"digupBearer"' in bundle and "setItem" in bundle and "removeItem" in bundle


def test_the_space_key_keeps_buttons_and_links_activated(media_client):
    """The reviewer found the hijack: the document-level Space handler (Quick Look)
    `preventDefault()`ed for every focused element except a few tags — and native
    button activation fires on keyup, so the keydown kill disabled the gear, the ✕,
    Index now, Estimate, "all", the Esc close, and the Open/Download links for every
    keyboard user, while opening the big-look over the page. The guard is a closest()
    over the activation targets, kept pinned here — in shadow DOM it runs over the
    event's composed path, the selector string verbatim."""
    bundle = _bundle(media_client)
    assert 'closest("button, a, [role=\'button\'], input, select, textarea")' in bundle


def test_the_layout_is_gated_on_the_pages_own_state(media_client):
    """The preview pane takes space only when it has something to show.

    `body[data-page]` — written by the shell at every render — is the ONE switch: the
    results grid, the hit counter and the preview pane exist in `results` only; idle,
    busy and none center a panel and reserve nothing. The shell MIRRORS the switch onto
    its host attribute (the panels live in its shadow, where a body selector cannot
    reach), so the pins below ride on `:host([data-page=…])` in style.css plus the
    `document.body.dataset.page` write in the bundle. Pinned on the source, because a
    stylesheet edit is exactly what quietly puts the empty panel back (measured before
    this change: a 574×192 px empty preview box with nothing typed, at 1280 px)."""
    html = _page(media_client)
    css = _styles(media_client)
    bundle = _bundle(media_client)
    appjs = media_client.get("/app.js").text
    for panel in ('id="idle"', 'id="idle-note"', 'id="no-results"', 'id="no-results-why"',
                  'id="suggest"', 'id="engine-says"'):
        assert panel in bundle, f"the state panel {panel} is gone from the templates"
    assert 'id="no-results" hidden' not in html        # CSS gates it: one mechanism, not two
    assert ':host([data-page="results"]) #results' in css
    assert ':host([data-page="idle"]) #idle' in css and ':host([data-page="none"]) #no-results' in css
    assert ':host([data-page="busy"]) #suggest' in css                # busy is not a shopping list
    assert "document.body.dataset.page" in appjs
    assert "grid-template-columns: minmax(0, 2fr) minmax(0, 3fr)" in css    # 40 % list, 60 % preview
    assert "grid-template-columns: minmax(0, 1fr)" in css                   # narrow screens: one column
    assert "#preview { position: static; }" in css   # a sticky pane on one column covers the list
    assert "@media (prefers-reduced-motion: no-preference)" in css          # the state fade is guarded


def test_the_first_paint_is_a_state_and_a_missing_preview_says_so(media_client):
    """Two failures this pins, both found by measuring the page rather than reading it:
    the layout must PAINT a state at startup (without it `body[data-page]` is unset and
    EVERY panel is gated off — the blank page), and a preview the engine has not
    rendered is a message plus the file's metadata, never an empty pane.

    The Lit shape: the shell paints and syncs the state in `firstUpdated` (Lit runs it
    with the first render — the vanilla startup `render();` line, carried over as a
    lifecycle), and `main.js` carries the initial results slice (its `groups: []`)."""
    appjs = media_client.get("/app.js").text
    bundle = _bundle(media_client)
    html = _page(media_client)
    assert "firstUpdated" in appjs, "the shell must paint at startup: the first paint is a state"
    # The served shape: the html DECLARES the shell element, and the entry wires THAT
    # element. A second `createElement` mount is the double page a browser shows (an
    # unwired twin renders its bare template above the working one — measured 2026-11-08):
    # exactly one declaration in the page, one wiring line in the entry, append only as
    # the fallback branch.
    assert html.count("<digup-app></digup-app>") == 1, "the shell is declared once in the page"
    assert 'document.querySelector("digup-app")' in appjs, "the entry wires the DECLARED element"
    assert "document.body.append(" in appjs, "the createElement path survives as the fallback mount"
    assert re.search(r"groups:\s*\[\]", appjs), "the initial state needs groups: the first render iterates it"
    assert "No preview of this file" in bundle
    assert bundle.count("@error=") >= 5, "photo, PDF, video and thumbnail previews must announce a missing render"
    assert 'class="facts"' in bundle, "the metadata sits beside the preview, not behind it"
    # the centered "no results" panel quotes the engine's own sentence, the same string
    # the counter line uses — both publishers carry it verbatim
    assert bundle.count("the engine found no good matches for this and refused to guess") >= 2
    # suggestions take the ONE search route: they only ever emit `digup:set-query`, the
    # shell hands the phrase to digup-search, which emits the query-change the
    # controller runs — no second route to the engine exists (AGENTS.md).
    assert "wakeboarding on a lake" in appjs
    assert appjs.count("digup:set-query") >= 1
    # Exactly two appearances of the route name in the shell graph: the emitter template
    # (digup-search) and the shell's listener — the controller is the only consumer.
    assert appjs.count("digup:query-change") == 2, "the ONE search route: one emitter, one listener"


def test_the_ui_survives_a_failed_job_poll(media_client):
    """S1: the job poll loop died on its first failed fetch (server restart, engine
    mid-respawn 503) — unhandled rejection, the job line froze at its last state,
    and "indexing…" stayed in the footer forever. It now answers honestly and clears
    the indexing state; repeated busy-clicks poll one loop, not N (the dedupe token),
    and every settings-close path keeps aria-expanded true to the panel's state."""
    bundle = _bundle(media_client)
    assert "job poll failed" in bundle
    assert "jobPoll" in bundle                              # one poll loop per live job
    assert "aria-expanded" in bundle
    html = _page(media_client)
    assert 'id="settings-close"' in bundle
    assert _styles(media_client).count("color-mix(in srgb, var(--kc) 10%") == 1


def test_ui_files_revalidate_never_go_stale(media_client):
    """Measured in a live browser during the Stage-10 proof: without a `cache-control`,
    Chrome served a stylesheet the server no longer had for minutes — reload answered
    from its memory cache, and a UI fix never reached the page. UIFiles answers every
    UI byte `cache-control: no-cache` (the etag makes the revalidation a cheap 304).

    The migration made the asset list dynamic (hashed chunks), so the walk discovers
    what the built page links and decorates EVERY byte: html, entry, chunks, styles."""
    html = _page(media_client)
    assets = ["/", "/style.css", "/app.js"]
    assets += ["/" + p for p in re.findall(r'href="\./((?:chunks|assets)/[^"]+)"', html)]
    assert len(assets) >= 5, "the built page must link its chunks/styles (the stable-name contract)"
    for path in assets:
        reply = media_client.get(path)
        assert reply.status_code == 200, path
        assert reply.headers["cache-control"] == "no-cache", path
        assert "etag" in reply.headers, path


def test_search_issues_media_handles(media_client):
    reply = media_client.post("/api/v1/search", json={"q": "wakeboarding", "limit": 3}).json()
    ids = [h["media_id"] for h in reply["hits"]]
    assert len(ids) == len(reply["hits"]) == len(set(ids))
    assert all(len(i) == 12 for i in ids)


def test_preview_serves_the_engines_jpeg(media_client):
    hit = media_client.post("/api/v1/search",
                            json={"q": "wakeboard photo", "kinds": ["image"], "limit": 1}
                            ).json()["hits"][0]
    reply = media_client.get(f"/api/v1/media/{hit['media_id']}/preview?pixels=256")
    assert reply.status_code == 200
    assert reply.headers["content-type"] == "image/jpeg"
    assert reply.content[:2] == b"\xff\xd8"                  # a real JPEG, from render


def test_video_preview_is_a_frame_at_the_moment(media_client):
    hit = media_client.post("/api/v1/search",
                            json={"q": "hiking", "kinds": ["video"], "limit": 1}
                            ).json()["hits"][0]
    assert hit["loc"] is not None                            # the engine's seconds
    reply = media_client.get(f"/api/v1/media/{hit['media_id']}/preview?pixels=256")
    assert reply.status_code == 200 and reply.content[:2] == b"\xff\xd8"


def test_the_passage_a_doc_hit_points_at(doc_client):
    hit = doc_client.post("/api/v1/search",
                          json={"q": "the stories continued after midnight marshmallows",
                                "kinds": ["doc"], "limit": 1}).json()["hits"][0]
    body = doc_client.get(f"/api/v1/media/{hit['media_id']}/text").json()
    assert "campfire stories" in body["text"]                # the engine's text, verbatim


def test_media_ids_the_server_never_issued_are_404(media_client):
    assert media_client.get("/api/v1/media/deadbeefcafe/preview").status_code == 404
    assert media_client.get("/api/v1/media/deadbeefcafe/text").status_code == 404


def test_embed_ahead_answers_ok(media_client):
    assert media_client.post("/api/v1/embed_ahead", json={"q": "wake"}).json()["ok"] is True


# ── Stage 10: GET /media/{id}/file — the desktop's "Open", over HTTP ───────────────────
# Same discipline as /preview: only server-issued handles; type from the file's magic
# bytes; ranges honored (that is what makes <video …#t=loc> seek); code/doc content is
# text/plain and an attachment — markup the user's own files carry never runs here.

def test_file_streams_the_photo_itself(media_client):
    hit = media_client.post("/api/v1/search",
                            json={"q": "wakeboard photo", "kinds": ["image"], "limit": 1}
                            ).json()["hits"][0]
    reply = media_client.get(f"/api/v1/media/{hit['media_id']}/file")
    assert reply.status_code == 200
    assert reply.headers["content-type"] == "image/jpeg"     # sniffed from the bytes
    assert reply.content[:3] == b"\xff\xd8\xff"              # the real file, not a render
    assert reply.headers["accept-ranges"] == "bytes"
    assert reply.headers["content-disposition"].startswith("inline;")
    assert "filename*=UTF-8''" in reply.headers["content-disposition"]


def test_ranges_are_honored_for_video_seeking(media_client):
    hit = media_client.post("/api/v1/search",
                            json={"q": "hiking", "kinds": ["video"], "limit": 1}
                            ).json()["hits"][0]
    whole = media_client.get(f"/api/v1/media/{hit['media_id']}/file")
    size = int(whole.headers["content-length"])
    head = media_client.get(f"/api/v1/media/{hit['media_id']}/file", headers={"range": "bytes=0-99"})
    assert head.status_code == 206
    assert head.content == whole.content[:100]
    assert head.headers["content-range"] == f"bytes 0-99/{size}"
    tail = media_client.get(f"/api/v1/media/{hit['media_id']}/file", headers={"range": "bytes=-40"})
    assert tail.status_code == 206 and tail.content == whole.content[-40:]
    assert tail.headers["content-range"] == f"bytes {size - 40}-{size - 1}/{size}"
    open_end = media_client.get(f"/api/v1/media/{hit['media_id']}/file",
                                headers={"range": f"bytes={size - 10}-"})
    assert open_end.status_code == 206 and len(open_end.content) == 10
    unsatisfiable = media_client.get(f"/api/v1/media/{hit['media_id']}/file",
                                     headers={"range": f"bytes={size}-{size + 99}"})
    assert unsatisfiable.status_code == 416
    assert unsatisfiable.headers["content-range"] == f"bytes */{size}"


def test_open_serves_a_documents_text_as_plain_text(doc_client):
    hit = doc_client.post("/api/v1/search",
                          json={"q": "the stories continued after midnight marshmallows",
                                "kinds": ["doc"], "limit": 1}).json()["hits"][0]
    reply = doc_client.get(f"/api/v1/media/{hit['media_id']}/file")
    assert reply.status_code == 200
    assert reply.headers["content-type"].startswith("text/plain")   # never markup, never script
    assert reply.headers["content-disposition"].startswith("attachment;")
    assert "campfire stories" in reply.text


def test_file_for_an_unissued_handle_is_404(media_client):
    assert media_client.get("/api/v1/media/deadbeefcafe/file").status_code == 404


def test_video_file_arrives_with_a_playable_media_type(media_client):
    """scenes.mp4 (H.264, browser-streamable): the magic sniff reads `ftyp` at offset 4
    and the brand at 8-12. Measured lesson: reading the brand at 8 against `ftyp` sent
    every real MP4 to octet-stream — Chrome sniffs past that, Safari is not obliged to."""
    hit = media_client.post("/api/v1/search",
                            json={"q": "color bars test pattern", "kinds": ["video"],
                                  "limit": 3}).json()["hits"][0]
    reply = media_client.get(f"/api/v1/media/{hit['media_id']}/file")
    assert reply.status_code == 200
    assert reply.headers["content-type"] in {"video/mp4", "video/x-matroska"}
    assert reply.headers["accept-ranges"] == "bytes"


def test_open_range_streams_the_video_rather_than_buffering_it(media_client):
    """`Range: bytes=0-` is what every browser media element sends first. The old
    handler computed the full span and `read()` it — a whole-file RAM buffer (a 20 GB
    clip asked for a 20 GB read) — and answered 206 with the ENTIRE file, so seeking
    never streamed. Now: open ranges are capped at MAX_RANGE_SPAN and the span is
    streamed in chunks from its own file handle."""
    from digup_server.api import MAX_RANGE_SPAN
    hit = media_client.post("/api/v1/search",
                            json={"q": "wakeboarding", "kinds": ["video"], "limit": 1}
                            ).json()["hits"][0]
    full = media_client.get(f"/api/v1/media/{hit['media_id']}/file")
    size = len(full.content)
    open_range = media_client.get(f"/api/v1/media/{hit['media_id']}/file",
                                  headers={"range": "bytes=0-"})
    assert open_range.status_code == 206
    expected_end = min(size - 1, MAX_RANGE_SPAN - 1)
    assert open_range.headers["content-range"] == f"bytes 0-{expected_end}/{size}"
    assert len(open_range.content) == expected_end + 1     # the span, streamed, complete


def test_file_carries_nosniff(media_client):
    """The magic-bytes typing above refuses to call script script; `nosniff` is the
    cheap belt that says the browser must not guess a type on its own — including
    for the text/plain path used by code/doc hits."""
    hit = media_client.post("/api/v1/search",
                            json={"q": "wakeboard photo", "kinds": ["image"], "limit": 1}
                            ).json()["hits"][0]
    reply = media_client.get(f"/api/v1/media/{hit['media_id']}/file")
    assert reply.headers["x-content-type-options"] == "nosniff"
    ranged = media_client.get(f"/api/v1/media/{hit['media_id']}/file",
                              headers={"range": "bytes=0-2"})
    assert ranged.headers["x-content-type-options"] == "nosniff"
