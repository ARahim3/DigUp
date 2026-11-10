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

from digup_server.api import SearchRequest, create_app

# The three wakeboard media — the corpus's planted answer to "wakeboarding". Their ORDER
# is not portable: the embedding matmul moves with CPU features. Measured 2026-11-04 on
# x86_64 (the suite container, this box): logan 1.571 > vienna 1.531 > aarhus-04 0.441;
# the arm64-Mac measurements the strict pin carried before ranked vienna first — the top
# two are 0.040 z apart, inside cross-platform noise. What IS portable (and is exactly
# the server's contract) is WHICH three files answer the query, and that they clear the
# engine's gate: the server relays the engine's per-platform order verbatim — that
# pass-through is pinned by the hit-field and reply-shape tests, not by hard-coding one
# machine's ranking here.
WAKEBOARD_TOP3 = {"wakeboarding-vienna.webm", "wakeboard-logan.jpg", "wakeboarding-aarhus-04.jpg"}


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
    assert set(paths(reply["hits"])[:3]) == WAKEBOARD_TOP3  # the set is portable; the order is the engine's (see WAKEBOARD_TOP3)
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


def test_the_default_limit_is_the_engines_default(client):
    """The API's default `limit` equals the engine's own (40, `SearchService.swift:130`): a
    client that names no limit gets the engine's answer, not a shorter one — the server
    invents no cap of its own. Pinned twice: the typed default, and the reply on the same
    query against an explicit 40 (the UI sends 40 explicitly, so nothing client-side moves)."""
    assert SearchRequest.model_fields["limit"].default == 40
    quiet = client.post("/api/v1/search", json={"q": "wakeboarding"}).json()
    explicit = client.post("/api/v1/search", json={"q": "wakeboarding", "limit": 40}).json()
    assert paths(quiet["hits"]) == paths(explicit["hits"])
    assert quiet["strong"] == explicit["strong"]


def test_error_bodies_are_one_detail_string(client):
    """API.md's error table is a promise: every documented error is one JSON object whose
    `detail` is safe to show a user verbatim. Pinned on the cheap ones — an unknown job id,
    a dead media handle on all three media endpoints, and the validation case whose `detail`
    is a **list of objects** (the UI renders each item; a page that prints the raw array is
    the bug this pins against)."""
    unknown = client.get("/api/v1/jobs/deadbeefdeadbe")
    assert unknown.status_code == 404 and isinstance(unknown.json()["detail"], str)
    for suffix in ("preview", "text", "file"):
        dead = client.get(f"/api/v1/media/deadbeefdeadbe/{suffix}")
        assert dead.status_code == 404 and isinstance(dead.json()["detail"], str)
    invalid = client.post("/api/v1/search", json={"q": "x", "kinds": ["not-a-kind"]})
    assert invalid.status_code == 422
    assert invalid.headers["content-type"].startswith("application/json")
    detail = invalid.json()["detail"]
    assert isinstance(detail, list) and detail
    assert all({"type", "loc", "msg"} <= set(item) for item in detail)


def test_media_ids_are_per_reply_across_the_http_surface(client):
    """`docs/API.md`'s rule, pinned over HTTP: the same file in two replies carries two
    handles, so a client may not cache a `media_id` across searches (and the engine's own
    `path` + `kind` + `segment_id` + `loc` are what it should key on instead)."""
    def top(c):
        hit = c.post("/api/v1/search", json={"q": "wakeboarding", "limit": 1}).json()["hits"][0]
        return Path(hit["path"]).name, hit["media_id"]
    (name_a, id_a) = top(client)
    (name_b, id_b) = top(client)
    assert name_a == name_b and id_a != id_b


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


# ── review-round units (this file's fixtures stay real: app + engine, no mocks) ────────


def test_open_and_huge_ranges_are_capped_at_the_served_span():
    """`bytes=0-` is what every browser media element sends first. Uncapped, it read
    the whole file into RAM (a 20 GB clip asked for a 20 GB buffer). Open ranges,
    huge explicit ranges and huge suffix ranges all cap at MAX_RANGE_SPAN; the
    200 (no-range) path is untouched — `save as` still gets the whole file."""
    from digup_server.api import parse_range, MAX_RANGE_SPAN
    big, huge = (1 << 30), (2 << 30)
    assert parse_range("bytes=0-", huge) == (0, MAX_RANGE_SPAN - 1)
    assert parse_range("bytes=-5000000000", big) == (big - MAX_RANGE_SPAN, big - 1)
    assert parse_range("bytes=1000-9000000000", huge) == (1000, 1000 + MAX_RANGE_SPAN - 1)
    assert parse_range("bytes=0-99", 500) == (0, 99)              # normal spans untouched
    assert parse_range("bytes=-40", 500) == (460, 499)


def test_hit_cache_is_a_true_lru_get_refreshes():
    """The docstring promised LRU; eviction was insertion-order. The UI re-searches
    per keystroke-pause (up to 40 handles per search): after ~26 searches the handles
    of the rows on screen were evicted, and their thumbnails/preview/file 404'd with
    no recovery path. `get()` must move_to_end."""
    from digup_server.api import HitCache
    cache = HitCache(capacity=3)
    a = cache.put("/a.jpg", "image", 1, None, False)
    b = cache.put("/b.jpg", "image", 2, None, False)
    c = cache.put("/c.jpg", "image", 3, None, False)
    assert cache.get(a) is not None                              # refresh a
    d = cache.put("/d.jpg", "image", 4, None, False)              # evicts b, not a
    assert cache.get(a) is not None and cache.get(c) is not None
    assert cache.get(d) is not None
    assert cache.get(b) is None                                  # the LRU victim: b


def test_search_reply_publishes_fields_this_model_has_never_seen():
    """`extra="allow"`: an engine field this model has never seen rides through to
    the client, not dropped at the Pydantic boundary (hits already ride raw; the
    top level must answer the engine's growth the same way)."""
    from digup_server.api import SearchReply
    reply = SearchReply(hits=[], strong=0, meaning=True, ms={}, fresh_engine_field={"a": 1})
    assert reply.model_dump()["fresh_engine_field"] == {"a": 1}


def test_a_slow_estimate_answers_busy_never_parallel(client, monkeypatch):
    """`estimate` walks the whole tree (120 s timeout) as a sync endpoint: a second
    UI tab, a user retry, a retry during a job all stacked full-tree crawls with no
    mutual exclusion. Now the second click is a 409, the engine's one-crawl rule."""
    import threading
    import time
    import digup_server.api as api_mod

    def crawling(config, **kwargs):
        time.sleep(3.0)                                          # a slow crawl, in flight
        return [{"path": str(config.roots[0]), "files": 15}]

    monkeypatch.setattr(api_mod, "estimate_lines", crawling)
    box = []
    first = threading.Thread(target=lambda: box.append(
        client.post("/api/v1/estimate", json={})))
    first.start()
    time.sleep(0.3)                                              # crawl #1 running
    second = client.post("/api/v1/estimate", json={})
    assert second.status_code == 409
    assert "already running" in second.json()["detail"]
    first.join(30)
    assert box[0].status_code == 200                             # crawl #1 finished honest
    third = client.post("/api/v1/estimate", json={})
    assert third.status_code == 200                              # the lock released


def test_the_estimate_timeout_is_an_operator_knob(client, monkeypatch):
    """The 120 s default fits corpus-sized trees; a real media tree on a spinning disk
    needs minutes (measured 2026-11-04: 187k files on a 2 TB HDD crossed the default →
    502). The route reads DIGUP_SERVER_ESTIMATE_TIMEOUT_S per request — default 120
    keeps every existing pin, an operator's value reaches the CLI call."""
    import digup_server.api as api_mod

    seen = {}

    def counted(config, **kwargs):
        seen["timeout"] = kwargs.get("timeout")
        return [{"path": str(config.roots[0]), "files": 15}]

    monkeypatch.setattr(api_mod, "estimate_lines", counted)
    assert client.post("/api/v1/estimate", json={}).status_code == 200
    assert seen["timeout"] == 120.0                              # the default, unchanged
    monkeypatch.setenv("DIGUP_SERVER_ESTIMATE_TIMEOUT_S", "900")
    assert client.post("/api/v1/estimate", json={}).status_code == 200
    assert seen["timeout"] == 900.0                              # the operator's value


def test_a_cli_timeout_surfaces_as_a_quoted_502_not_a_500(client, monkeypatch):
    """`subprocess.TimeoutExpired` is a SubprocessError, not a TimeoutError — no
    handler covered it, so a `digup status` stalling behind the writer's WAL, or an
    estimate crossing its 120 s, died as a bare 500 traceback. This file's own rule
    (api.py:6): quote the engine. The mapping lives in cli.run, where it covers
    every one-shot call at once."""
    import subprocess
    import digup_server.engine.cli as cli_mod

    def timed_out(argv, **kwargs):
        raise subprocess.TimeoutExpired(argv, 120)

    monkeypatch.setattr(cli_mod.subprocess, "run", timed_out)
    reply = client.post("/api/v1/estimate", json={})
    assert reply.status_code == 502
    assert "timed out" in reply.json()["detail"]


def test_the_cli_identity_is_served_from_a_short_cache():
    """The UI polls /status every 15 s and the container HEALTHCHECK hits /health
    every 30 s — each one used to spawn a `digup status` doing real SQLite counting.
    The identity fields move slowly, so they ride a TTL cache: a poll costs an
    argument, not a subprocess. A TTL of 0 is the dev escape hatch (every poll
    re-reads, e.g. while watching a job's counts land)."""
    from digup_server.api import StatusCache

    calls = []

    def fetch(config):
        calls.append(config)
        return {"engine": {"fingerprints": "embeddinggemma-2@2188ac1d"}}

    cache = StatusCache(fetch, ttl_s=60.0)
    first = cache.get("cfg")
    second = cache.get("cfg")
    assert len(calls) == 1                      # the second poll: the cache, not a subprocess
    assert first is second                      # the same identity dict, unchanged
    assert first["engine"]["fingerprints"] == "embeddinggemma-2@2188ac1d"

    live = StatusCache(fetch, ttl_s=0.0)        # TTL 0: every poll re-reads
    live.get("cfg")
    live.get("cfg")
    assert len(calls) == 3                      # 1 + 2: nothing served stale
