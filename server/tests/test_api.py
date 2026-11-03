"""The API contract (Stage 4): `/api/v1` over the real adapter, the real engine, no mocks.

Runs in the `server-test` container: TestClient drives the FastAPI app in-process; the
app's lifespan spawns `search-service` as a **direct child of pytest** — a live parent,
which is the ParentWatch rule (reconnaissance §15 item 8) the API must keep in production.

Every assertion here is about *pass-through*: the API invents nothing and hides nothing —
the engine's ranking, fields, timings, empties and errors reach the client as the engine
made them, minus the protocol's own `id` bookkeeping.
"""

from __future__ import annotations

from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from digup_server.api import create_app

WAKEBOARD_TOP3 = ["wakeboarding-vienna.webm", "wakeboard-logan.jpg", "wakeboarding-aarhus-04.jpg"]


@pytest.fixture(scope="module")
def client(corpus, index):
    from conftest import _cfg
    app = create_app(_cfg(index, (corpus,)))
    with TestClient(app) as c:          # lifespan: spawn search-service, quit() on exit
        yield c


def paths(hits):
    return [Path(h["path"]).name for h in hits]


def test_health_publishes_the_engines_identity(client):
    body = client.get("/api/v1/health").json()
    assert body["ok"] is True
    eng = body["engine"]
    assert "embeddinggemma-2@" in eng["fingerprints"]
    assert eng["build_tag"].startswith("b")           # llama.cpp b11461
    assert eng["vectors_version"] == 1
    live = body["live"]
    assert live["files"] >= 15 and live["searchable"] == live["files"]
    assert live["pending"] == 0
    assert live["encoder"] in {"stopped", "starting", "ready", "unavailable"}


def test_status_adds_the_cli_kind_table(client):
    body = client.get("/api/v1/status").json()
    kinds = {k["kind"]: k["files"] for k in body["kinds"]}
    assert kinds.get("image") == 12 and kinds.get("video") == 3
    assert body["build_tag"].startswith("b")


def test_search_answers_with_the_engines_ranking(client):
    reply = client.post("/api/v1/search", json={"q": "wakeboarding", "limit": 10}).json()
    assert paths(reply["hits"])[:3] == WAKEBOARD_TOP3
    assert reply["meaning"] is True and reply["strong"] >= 3
    assert {"embed", "search"} <= set(reply["ms"])    # the engine's own milliseconds
    assert "id" not in reply                          # protocol bookkeeping stays inside
    top = reply["hits"][0]
    assert {"path", "kind", "segment", "segment_id", "score", "modified", "size", "info"} \
        <= set(top)                                    # hitFields(), verbatim


def test_the_honest_empty_survives_the_http_leg(client):
    reply = client.post("/api/v1/search",
                        json={"q": "a person riding a wakeboard behind a boat"}).json()
    assert reply["hits"] == []                         # the refusal is published, not filled
    assert reply["meaning"] is True


def test_keyword_only_search_when_meaning_is_off(client):
    reply = client.post("/api/v1/search",
                        json={"q": "wakeboarding", "meaning": False}).json()
    assert reply["meaning"] is False
    assert reply["hits"]                               # keyword-only still answers


def test_kind_filter_is_the_engines(client):
    reply = client.post("/api/v1/search",
                        json={"q": "wakeboarding", "kinds": ["video"]}).json()
    assert reply["hits"] and all(h["kind"] == "video" for h in reply["hits"])


def test_the_api_validates_what_the_engine_would_silently_drop(client):
    bad = client.post("/api/v1/search", json={"q": "x", "kinds": ["not-a-kind"]})
    assert bad.status_code == 422                      # engine drops; API says so
    assert client.post("/api/v1/search", json={"q": "x" * 513}).status_code == 422
    assert client.post("/api/v1/search", json={"q": "x", "limit": 0}).status_code == 422
    assert client.post("/api/v1/search", json={}).status_code == 422


def test_estimate_is_the_engines_forecast_as_json(client, corpus):
    reply = client.post("/api/v1/estimate", json={}).json()
    folder = reply["folders"][0]
    assert folder["readable"] is True
    assert folder["folder"] == str(corpus)
    assert folder["files"]["image"] == 12              # the engine's own counts


def test_openapi_is_the_versioned_public_surface(client):
    spec = client.get("/api/v1/openapi.json").json()
    assert all(p.startswith("/api/v1/") for p in spec["paths"])
    assert {"health", "status", "search", "estimate"} <= \
        {p.rsplit("/", 1)[1] for p in spec["paths"]}


def test_engine_refusal_becomes_a_503_not_a_keyerror(corpus, index):
    """A searcher mid-transition answers `{"ok":false,"error":…}` — the Stage-10 battery
    hit exactly that as a 500 (`KeyError: 'hits'` in `api.py`). The refusal is the
    engine's own words; they surface verbatim as a 503, and nothing reads `hits`/`files`
    out of an answer that has none. No lifespan, no engine: the injected service refuses."""
    from conftest import _cfg
    from digup_server.engine.protocol import EngineRefused

    app = create_app(_cfg(index, (corpus,)))

    class RefusingSearch:
        def search(self, *args, **kwargs):
            raise EngineRefused("search", "index is reloading, try again")
        def status(self):
            raise EngineRefused("status", "index is reloading, try again")

    app.state.search = RefusingSearch()
    c = TestClient(app)                      # no `with`: no lifespan — the state stays
    r = c.post("/api/v1/search", json={"q": "anything", "limit": 1})
    assert r.status_code == 503
    assert "index is reloading" in r.json()["detail"]
    assert c.get("/api/v1/status").status_code == 503


def test_a_refusal_reply_is_raised_in_the_adapter(index, corpus):
    """The same fact one layer down: `SearchService` raises `EngineRefused` on an
    `ok:false` reply (the engine's refusal, `SearchService.swift:106,115`) — stub proc,
    no engine, the reply is the engine's refusal shape verbatim."""
    from conftest import _cfg
    from digup_server.engine.protocol import EngineRefused
    from digup_server.engine.search import SearchService

    svc = SearchService(_cfg(index, (corpus,)))

    class StubProc:
        alive = True
        def request(self, fields, *, timeout=None):
            return {"id": 1, "ok": False, "error": "index is reloading"}

    svc._proc = StubProc()
    with pytest.raises(EngineRefused) as raised:
        svc.search("anything")
    assert "index is reloading" in str(raised.value)

def test_status_shows_the_servers_own_roots(client, corpus):
    """Stage 10: the UI shows *where this server looks*. These are the deployment's own
    configured paths (env) — publishing them is presentation, not path acceptance (§7)."""
    assert client.get("/api/v1/status").json()["roots"] == [str(corpus)]


def test_startup_prewarms_the_searcher(client):
    """Stage 7: the lifespan prewarms at startup (the engine's `prewarm` op), so a
    freshly booted server answers the first search with meaning + real z-scores —
    no cold-encoder keyword fallback in front of a first-time user."""
    status = client.get("/api/v1/status").json()
    assert status["vectors"] > 0                 # vectors opened at startup, not lazily
    reply = client.post("/api/v1/search", json={"q": "wakeboarding", "limit": 3}).json()
    assert reply["meaning"] is True and reply["strong"] >= 3
