"""The UI and media surface (Stages 6 and 10): same-origin vanilla UI, server-issued
handles, and the file itself with ranges honored.

The rules this pins (README §6, §7, §10.4): the UI is dependency-free vanilla (no
external URLs, no build step); the media endpoints accept **only ids the server issued
from published hits**, never client paths; previews are the engine's own JPEGs from
`render`, served only from `<index>/previews`; the text endpoint quotes the passage the
engine indexed, verbatim.
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


def test_root_serves_the_vanilla_ui(media_client):
    page = media_client.get("/")
    assert page.status_code == 200
    html = page.text
    assert "DigUp" in html and "app.js" in html and "style.css" in html
    # Dependency-free (README §10.4): no external scripts/styles, no module bundler hints.
    assert not re.search(r'(src|href)="(https?:)?//', html), "UI must not load external URLs"
    assert not re.search(r'type="module"', html)
    appjs = media_client.get("/app.js")
    assert appjs.status_code == 200 and "fetch(" in appjs.text
    assert "media_id" in appjs.text                          # it uses the server's handles
    assert media_client.get("/style.css").status_code == 200
    # Stage-10 parity with the desktop panel: appearance choice, kind filters, code mode,
    # keyword-first typing (prefix_last then the meaning upgrade), the keys footer.
    assert 'data-theme="system"' in html and 'id="theme"' in html
    assert 'data-kind="screenshot"' in html and 'id="code"' in html
    assert "prefix_last" in appjs.text and "embed_ahead" in appjs.text
    assert "localStorage" in appjs.text                      # the theme is kept in the browser
    assert "↑↓" in html and "Space" in html


def test_the_space_key_keeps_buttons_and_links_activated(media_client):
    """The reviewer found the hijack: the document-level Space handler (Quick Look)
    `preventDefault()`ed for every focused element except a few tags — and native
    button activation fires on keyup, so the keydown kill disabled the gear, the ✕,
    Index now, Estimate, "all", the Esc close, and the Open/Download links for every
    keyboard user, while opening the big-look over the page. The guard is a closest()
    over the activation targets, kept pinned here."""
    appjs = media_client.get("/app.js").text
    assert 'closest("button, a, [role=\'button\'], input, select, textarea")' in appjs


def test_the_layout_is_gated_on_the_pages_own_state(media_client):
    """The preview pane takes space only when it has something to show.

    `body[data-page]` — set by app.js render(), read by style.css — is the ONE switch:
    the results grid, the hit counter and the preview pane exist in `results` only; idle,
    busy and none center a panel and reserve nothing. Pinned on the source, because a
    stylesheet edit is exactly what quietly puts the empty panel back (measured before this
    change: a 574×192 px empty preview box with nothing typed, at 1280 px)."""
    html = media_client.get("/").text
    css = media_client.get("/style.css").text
    appjs = media_client.get("/app.js").text
    for panel in ('id="idle"', 'id="idle-note"', 'id="no-results"', 'id="no-results-why"',
                  'id="suggest"'):
        assert panel in html, f"the state panel {panel} is gone from index.html"
    assert 'id="no-results" hidden' not in html        # CSS gates it: one mechanism, not two
    assert 'body:not([data-page="results"]) #results' in css
    assert 'body:not([data-page="results"]) #engine-says' in css   # "0 hits" waits for a search
    assert 'body[data-page="idle"] #idle' in css and 'body[data-page="none"] #no-results' in css
    assert 'body[data-page="busy"] #suggest' in css                # busy is not a shopping list
    assert "document.body.dataset.page = mode" in appjs
    assert "grid-template-columns: minmax(0, 2fr) minmax(0, 3fr)" in css    # 40 % list, 60 % preview
    assert "grid-template-columns: minmax(0, 1fr)" in css                   # narrow screens: one column
    assert "body #preview { position: static; }" in css   # a sticky pane on one column covers the list
    assert "@media (prefers-reduced-motion: no-preference)" in css          # the state fade is guarded


def test_the_first_paint_is_a_state_and_a_missing_preview_says_so(media_client):
    """Two failures this pins, both found by measuring the page rather than reading it:
    `render()` must run at startup (without it `body[data-page]` is unset and EVERY panel is
    gated off — the blank page), and a preview the engine has not rendered is a message plus
    the file's metadata, never an empty pane."""
    appjs = media_client.get("/app.js").text
    assert re.search(r"^render\(\);", appjs, re.M), "render() must run at startup: the first paint is a state"
    assert re.search(r"groups: \[\]", appjs), "the initial state needs groups: the first render() iterates it"
    assert "noPreview" in appjs
    assert appjs.count("image.onerror = () => frame.replaceChildren(noPreview(hit)") >= 2, "photo and PDF previews must announce a missing preview"
    assert "video.onerror = () => frame.replaceChildren(noPreview(hit), moment)" in appjs
    assert "pane.append(picture(hit), facts(hit))" in appjs, "the metadata sits beside the preview, not behind it"
    # the centered "no results" panel quotes the engine's own sentence, the same string the
    # counter line uses — one definition, both publishers
    assert appjs.count("emptyAnswer(") == 2
    # suggestions take the ONE search route (queryChanged), and replaceChildren is variadic:
    # passing an array arrives as a text node (measured: "[object HTMLButtonElement]" on screen)
    assert "replaceChildren(...SUGGESTIONS.map" in appjs
    assert appjs.count('chip.onclick = () => { $("q").value = phrase; queryChanged();') == 1


def test_the_ui_survives_a_failed_job_poll(media_client):
    """S1: the job poll loop died on its first failed fetch (server restart, engine
    mid-respawn 503) — unhandled rejection, the job line froze at its last state,
    and "indexing…" stayed in the footer forever. It now answers honestly and clears
    the indexing state; repeated busy-clicks poll one loop, not N (the dedupe token),
    and every settings-close path keeps aria-expanded true to the panel's state."""
    appjs = media_client.get("/app.js").text
    assert "job poll failed" in appjs
    assert "state.jobPoll" in appjs                          # one poll loop per live job
    html = media_client.get("/").text
    assert 'id="settings-close"' in html
    assert media_client.get("/style.css").text.count("color-mix(in srgb, var(--kc) 10%") == 1


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


def test_ui_files_revalidate_never_go_stale(media_client):
    """Measured in a live browser during the Stage-10 proof: without a `cache-control`,
    Chrome served a stylesheet the server no longer had for minutes — reload answered
    from its memory cache, and a UI fix never reached the page. UIFiles answers every
    UI byte `cache-control: no-cache` (the etag makes the revalidation a cheap 304)."""
    for path in ("/", "/style.css", "/app.js"):
        reply = media_client.get(path)
        assert reply.status_code == 200
        assert reply.headers["cache-control"] == "no-cache"
        assert "etag" in reply.headers


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
