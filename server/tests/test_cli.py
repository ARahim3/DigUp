"""The one-shot CLI the server reads: `status`, `estimate --json` + plain, `speed --model --json`."""

from __future__ import annotations

import pytest

from digup_server.engine import cli
from conftest import _cfg


def test_status_parses_the_engines_lines(corpus, index):
    status = cli.status(_cfg(index, (corpus,)))
    assert status["index"] == str(index / "index.sqlite")
    assert status["vectors"] >= 15
    assert status["build_tag"] and status["build_tag"].startswith("b")
    assert "embeddinggemma-2@" in status["fingerprints"]
    assert status["index_size"]
    kinds = {k["kind"]: k["files"] for k in status["kinds"]}
    assert kinds.get("image") == 12 and kinds.get("video") == 3


def test_estimate_is_the_engines_own_paragraph(corpus, index):
    text = cli.estimate_text(_cfg(index, (corpus,)))
    assert "first index" in text and "images" in text
    assert "can't read" not in text


def test_estimate_json_answers_for_the_server_as_parent(corpus, corpus_root, index):
    # `estimate --json` is a ParentWatch helper: live parent (pytest here; uvicorn in prod)
    # → one JSON line per folder; parent PID 1 → it exits at once, "the app is gone", by
    # design. The Stage-2 "silent estimate --json" report was that PID-1 invocation, not an
    # engine fault (reconnaissance §15 item 8). The server is the parent, so it uses --json.
    answer = cli.estimate_json(_cfg(index, (corpus_root,)))
    assert answer["readable"] is True
    assert answer["skipped"] >= 1 and answer["left_out"]          # 29 skipped files, counted
    media = cli.estimate_json(_cfg(index, (corpus,)))
    assert media["files"]["image"] == 12


@pytest.mark.slow
def test_speed_model_json_reports_the_device(corpus, index):
    reply = cli.speed_model(_cfg(index, (corpus,)), when_quiet_s=2.0, tries=2, timeout=600.0)
    assert reply["event"] == "speed"
    assert reply["measured"] is True
    assert {"kinds", "seconds", "load", "total", "tries", "checks"} <= set(reply)
    assert reply["kinds"]                                   # per-kind multipliers, the engine's
