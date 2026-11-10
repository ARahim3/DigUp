"""The search-service contract: ops, reply fields, honest empties, the idle-exit restart.

Every expectation here is what the Stage-2 proof *observed the engine saying*
(docs/implementation/stage-2-headless-proof.md) — the corpus pins, the field names, the
rankings, the refusal. If upstream changes this protocol, these tests fail loudly; the
server never papers over it.
"""

from __future__ import annotations

import os
import time
from pathlib import Path

import pytest

from digup_server.engine import EngineConfig, SearchService

BASE_FIELDS = {"path", "kind", "segment", "segment_id", "score", "modified", "size", "info"}
MAYBE_FIELDS = {"z", "cosine", "keyword_rank", "loc", "loc_end", "focus", "excerpt",
                "strong", "meaning", "ms", "warning", "id", "ok", "error"}


def paths(hits):
    return [Path(h["path"]).name for h in hits]


def test_ready_handshake(search, index):
    ready = search["ready"]
    assert ready["event"] == "ready"
    assert Path(ready["index"]).name == index.name          # the engine names the index it opened
    assert search["service"].running


def test_status_op_counts_are_the_index(search, index):
    status = search["service"].status()
    assert {"encoder", "vectors", "code_vectors", "index", "files", "searchable",
            "pending", "unfinished"} <= set(status)
    assert status["index"] == str(index / "index.sqlite")
    assert status["files"] >= 15                            # the corpus is in there
    assert status["searchable"] == status["files"]          # every file indexed `done`
    assert status["pending"] == 0
    assert status["encoder"] in {"stopped", "starting", "ready", "unavailable"}


def test_wakeboarding_ranks_the_wakeboards(search):
    reply = search["service"].search("wakeboarding", limit=10)
    assert {"hits", "strong", "meaning", "ms"} <= set(reply)
    assert reply["meaning"] is True                          # vectors were used
    assert set(paths(reply["hits"])[:3]) == {"wakeboarding-vienna.webm", "wakeboard-logan.jpg",
                                             "wakeboarding-aarhus-04.jpg"}
    # The SET is the contract (the three planted wakeboard media answer the query). The
    # order is platform-dependent (embedding matmul vs CPU features; measured 2026-11-04:
    # x86_64 logan 1.571 > vienna 1.531, arm64 vienna first — 0.040 z apart, inside noise).
    assert reply["strong"] >= 3


def test_hit_fields_are_the_engines_ones(search):
    hits = search["service"].search("wakeboarding", limit=5)["hits"]
    for hit in hits:
        assert BASE_FIELDS <= set(hit), f"missing fields in {hit}"
        assert set(hit) - BASE_FIELDS <= MAYBE_FIELDS, f"invented fields in {hit}"
    assert {"z", "cosine", "keyword_rank"} <= set(hits[0])   # the Stage-2 proof's scored hits


def test_hiking_finds_a_moment_in_the_video(search):
    reply = search["service"].search("hiking", limit=10)
    top = reply["hits"][0]
    assert Path(top["path"]).name == "pct-hiking-southern-oregon.webm"
    assert top["segment"] == "frame"
    assert 0.0 <= top["loc"] <= float(top["info"]["duration"])
    assert top["loc_end"] >= top["loc"]
    assert {"embed", "search"} <= set(reply["ms"])           # real milliseconds, per phase


def test_kind_filter_is_the_engines(search):
    hits = search["service"].search("wakeboarding", kinds=["video"], limit=10)["hits"]
    assert hits and all(h["kind"] == "video" for h in hits)


def test_no_good_matches_stays_an_empty_answer(search):
    # Stage 2's honest miss: the engine refuses to rank below its bar. The server publishes
    # the emptiness, it never fills it with the best vector it can find.
    reply = search["service"].search("a person riding a wakeboard behind a boat", limit=10)
    assert reply["hits"] == []
    assert reply["meaning"] is True
    assert "warning" not in reply                            # the encoder worked; the bar held


def test_controls_stay_below_the_matches(search):
    reply = search["service"].search("a cat sitting on a sofa", limit=10)
    hits = reply["hits"]
    assert paths(hits)[0] == "cat-sitting-on-a-sofa.jpg"
    assert not any("wakeboard" in p.lower() for p in paths(hits))


def test_summaries_count_the_corpus(search):
    roots = search["service"].summaries()["roots"]
    assert len(roots) == 1
    root = roots[0]
    assert {"path", "missing", "unreadable", "files", "indexed", "pending", "failed",
            "skipped", "unfinished", "kinds", "skipped_reasons"} <= set(root)
    assert root["missing"] is False
    assert root["files"] >= 15
    assert root["kinds"].get("image") == 12 and root["kinds"].get("video") == 3


def test_embed_ahead_answers_ok(search):
    reply = search["service"].embed_ahead("wake")
    assert reply["ok"] is True                               # the engine's own {ok:true}


def test_unknown_op_is_the_engines_error(search):
    reply = search["service"].raw({"op": "definitely-not-an-op"})
    assert reply["ok"] is False
    assert "unknown op" in reply["error"]


def test_render_makes_a_jpeg_beside_the_index(search, index):
    hit = search["service"].search("wakeboard photo", kinds=["image"], limit=3)["hits"][0]
    reply = search["service"].render(hit["path"], kind="image", pixels=256)
    image = Path(reply["image"])
    assert str(image).startswith(str(index / "previews"))     # the engine's own previews folder
    assert image.is_file()
    assert image.read_bytes()[:2] == b"\xff\xd8"              # a real JPEG, not a promise


def test_idle_exit_is_a_restart_not_a_failure(corpus, index):
    # `--encoder-idle 2`: the engine releases the model at 2 s idle and exits itself at 4 s
    # (`{"event":"exit","reason":"idle"}`) — and the next request finds it answering again.
    service = SearchService(EngineConfig(index=str(index), roots=(str(corpus),),
                                         binary="digup",
                                         models_dir=os.environ.get("DIGUP_SERVER_MODELS"),
                                         encoder_idle=2.0))
    service.start()
    try:
        first = service.search("wakeboarding", limit=3)["hits"]
        assert first
        assert service.running
        time.sleep(6)                                        # 2 × idle: the engine ends itself
        assert not service.running
        again = service.search("wakeboarding", limit=3)["hits"]   # transparent respawn
        assert paths(again) == paths(first)
    finally:
        service.quit()


# ── adapter supervision units: what a failed spawn must never leave behind ─────────────
# (unit-level by design: these paths are about leaks and exception mapping, and a fake
# proc makes them deterministic; the live protocol above stays mock-free.)


def test_a_failed_handshake_reaps_the_child_it_spawned(monkeypatch, tmp_path):
    """`_spawn_locked` assigned `self._proc` only AFTER a successful handshake — a
    `start()` that raised (ready timeout on a huge index, a `ready` mismatch) left the
    fresh child running with its 3 pipes and 2 reader threads unreferenced until its
    own idle-exit (2 × `--encoder-idle` = 600 s), and every retried request spawned
    another one."""
    from digup_server.engine import search as search_mod
    from digup_server.engine.protocol import EngineExited

    closed = []

    class LeakProc:
        def __init__(self, argv, *, name, env=None):
            self._name = name

        def start(self):
            raise EngineExited(self._name, 1, ["handshake boom"])

        def close(self):
            closed.append(True)

    monkeypatch.setattr(search_mod, "JsonLinesProcess", LeakProc)
    service = SearchService(EngineConfig(index=str(tmp_path), roots=("/corpus",)))
    with pytest.raises(EngineExited):
        service.search("wakeboarding")
    assert closed == [True]                          # the child was reaped, not orphaned
    assert service._proc is None


def test_a_missing_engine_binary_answers_clierror(tmp_path):
    """FileNotFoundError from Popen must reach the API as a 502 quoting the spawn,
    not a bare 500 traceback (api.py:6: quote the engine, invent nothing)."""
    from digup_server.engine.cli import CLIError
    service = SearchService(EngineConfig(index=str(tmp_path), roots=("/corpus",),
                                         binary="/no/such/digup-binary"))
    with pytest.raises(CLIError, match="cannot start the engine helper"):
        service.search("wakeboarding")


def test_a_refusal_without_an_error_field_is_still_a_refusal():
    """`ok:false` ALONE: the old guard demanded `"error" in reply`, so a refusal
    shaped `{"ok":false,"id":4}` sailed through `_checked` and then api.py's
    `stripped["hits"]` raised KeyError — the exact 500 the Stage-10 battery hit.
    The guard must fire on the shape, not on one field of it."""
    from digup_server.engine.protocol import EngineRefused
    with pytest.raises(EngineRefused):
        SearchService._checked({"ok": False, "id": 4}, {"op": "search"})
    ok = {"hits": [], "strong": 0, "meaning": True, "ms": {}, "id": 5}
    assert SearchService._checked(ok, {"op": "search"})["hits"] == []


def test_renders_run_beside_searching_not_ahead_of_it(tmp_path):
    """The engine runs `render` beside its read loop on two slots, answers routed by
    `id` — "made beside the requests (typing never waits on one)" (SearchService
    .swift:52-56, 99-113). The adapter held the serialize-lock across the engine's
    120 s of ffmpeg work, undoing that design: a 1024-px preview froze every
    keystroke-search behind it, and a 40-hit gallery serialized 40 renders."""
    import threading

    class SlowRenderProc:
        """The protocol allocates the request `id` itself (`protocol.py: request()` —
        `fields` carries no id), routes the reply by it, and strips it before returning.
        This fake answers with a fresh id, out of order, like the engine does."""

        def __init__(self):
            self._ids = iter(range(1, 10_000))

        def request(self, fields, *, timeout):
            rid = next(self._ids)
            if fields["op"] == "render":
                time.sleep(1.2)                        # a slow ffmpeg frame, engine-side
                return {"id": rid, "image": "/index/previews/x.jpg"}
            return {"id": rid, "hits": [], "strong": 0, "meaning": True, "ms": {}}

    service = SearchService(EngineConfig(index=str(tmp_path), roots=("/corpus",)))
    service._proc = SlowRenderProc()
    box = {}

    def do_render():
        box["reply"] = service.render("/media/photos/x.jpg", pixels=1024)

    thread = threading.Thread(target=do_render)
    thread.start()
    time.sleep(0.15)                                   # the render is in flight
    began = time.monotonic()
    reply = service.search("wakeboarding", limit=10)
    typing_ms = time.monotonic() - began
    thread.join(10)
    assert reply["hits"] == []                         # answered — and answered FAST
    assert typing_ms < 0.9, f"typing waited {typing_ms:.2f} s behind the render"
    assert box["reply"]["image"].endswith("x.jpg")     # out-of-order id-routing intact
