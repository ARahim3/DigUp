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
