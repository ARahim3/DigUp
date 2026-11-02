"""The index-service contract: plain-line commands, JSON events, the single writer, reload.

Events are the engine's counts as it emits them (`IndexService.swift`): a sync that names
its numbers, file events that name files, a summary, and the exit event when the helper
lingers out. A missing folder is *reported* and indexing goes on — never "everything
deleted". The server's flock makes a second writer ask and lose, by design.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from conftest import _cfg
from digup_server.engine import IndexBusy, IndexService, SearchService, cli


def events_of(events, name):
    return [e for e in events if e.get("event") == name]


def test_sync_events_count_real_files(scratch, scratch_index):
    _folder, events = scratch_index
    syncs = events_of(events, "sync")
    assert syncs, "the engine emitted no sync event"
    first = syncs[0]
    # First sync counts the crawl; the engine re-syncs between batches (`new` = queued for
    # embedding), and the counts ride every count event. The post-index truth rides `idle`.
    assert first["new"] == 6                       # 4 photos + the clip + notes.txt — the engine's own count
    assert {"added", "changed", "moved", "removed", "unchanged", "ms", "started", "left_out",
            "files", "searchable", "pending", "vectors", "unfinished"} <= set(first)
    assert first["added"] == 6
    files = events_of(events, "file")
    assert len(files) == 6
    assert all(f["state"] == "done" for f in files)
    assert all({"path", "kind", "seconds", "done", "total", "new", "note", "code"} <= set(f)
               for f in files)
    kinds = {Path(f["path"]).name: f["kind"] for f in files}
    assert kinds["notes.txt"] == "doc" and kinds["scenes.mp4"] == "video"
    summaries = events_of(events, "summary")
    assert len(summaries) >= 2 and all("states" in s for s in summaries)   # batches as they land
    idle = events_of(events, "idle")[-1]
    assert idle["files"] == 6 and idle["searchable"] == 6 and idle["pending"] == 0
    assert idle["vectors"] >= 6                    # the measured totals, not an invented percent
    assert events[-1]["event"] == "exit"           # lingered out: the normal end
    assert not events_of(events, "error")


def test_counts_land_in_the_index(scratch, scratch_index):
    folder, _ = scratch_index
    status = cli.status(_cfg(folder, (scratch,)))
    assert sum(k["files"] for k in status["kinds"]) == 6
    by_kind = {k["kind"]: k["files"] for k in status["kinds"]}
    assert by_kind == {"image": 4, "video": 1, "doc": 1}
    assert status["vectors"] >= 6                 # every file embedded at least one segment


def test_a_second_writer_is_told_busy(scratch, scratch_index):
    folder, _ = scratch_index
    first = IndexService(_cfg(folder, (scratch,)), linger_s=30.0)
    first.start()
    try:
        second = IndexService(_cfg(folder, (scratch,)))
        with pytest.raises(IndexBusy):
            second.start()
    finally:
        first.stop()
        first.finish()


def test_missing_root_is_reported_not_fatal(tmp_path_factory, scratch):
    folder = tmp_path_factory.mktemp("missing-index")
    gone = str(tmp_path_factory.mktemp("gone") / "not-here")            # never existed
    service = IndexService(_cfg(folder, (scratch, gone)), linger_s=2.0)
    service.start()
    service.sync()
    events = list(service.events(timeout=900.0))
    service.finish()
    missing = events_of(events, "missing")
    assert missing and gone in missing[-1]["folders"]
    assert not events_of(events, "error")
    assert events_of(events, "file")              # the real folder was indexed regardless


def test_the_text_a_hit_points_at(scratch, scratch_index):
    folder, _ = scratch_index
    service = SearchService(_cfg(folder, (scratch,)))
    service.start()
    try:
        service.prewarm()                            # start the query encoder, load the vectors
        hits = service.search("the stories continued after midnight, long after the marshmallows",
                              kinds=["doc"], limit=5)["hits"]
        top = hits[0]
        assert Path(top["path"]).name == "notes.txt"
        text = service.text(top["segment_id"])["text"]
        assert "campfire stories" in text            # the passage the hit points at, verbatim
    finally:
        service.quit()


def test_reload_after_indexing(scratch, scratch_index):
    folder, _ = scratch_index
    service = SearchService(_cfg(folder, (scratch,)))
    service.start()
    try:
        before = service.status()["vectors"]       # 0: a fresh searcher loads vectors lazily
        # A new file arrives, indexing runs through the single writer…
        (scratch / "more").mkdir(exist_ok=True)
        (scratch / "more" / "bicycle.txt").write_text(
            "A blue bicycle leans against the garage wall in the evening light.\n", encoding="utf-8")
        writer = IndexService(_cfg(folder, (scratch,)), backfill=True, linger_s=2.0)
        writer.run_sync(timeout=900.0)
        # …`reload` reopens the index, `prewarm` loads the vectors (the shell's own sequence)
        # and the engine reports a count that moved.
        reply = service.reload()
        assert reply["ok"] is True
        warm = service.prewarm()
        assert warm["vectors"] > before
        hits = service.search("blue bicycle garage", kinds=["doc"], limit=5)["hits"]
        assert Path(hits[0]["path"]).name == "bicycle.txt"
    finally:
        service.quit()
