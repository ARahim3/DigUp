"""The index-job contract (Stage 5): one writer, answered busy, honest states, recovery.

Runs in the `server-test` container over the **scratch corpus** (conftest: 4 photos + the
clip + notes.txt, already indexed): a new file arrives, `POST /api/v1/index` runs the real
`index-service` under the adapter's flock, the job's counts are the engine's own events,
and after `done` the searcher answers for the new file — the `reload → prewarm` sequence
the Stage-3 suite proved, wired by the app itself. No mocks.

The interrupted-recovery test is the rule from README §5 verbatim: *an interrupted job is
recovered as interrupted, never as success* — a log line `running` with no ending becomes
`interrupted` at the next startup.
"""

from __future__ import annotations

import json
import os
import time
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from digup_server.api import create_app
from digup_server.engine import EngineConfig
from digup_server.jobs import JobRunner

from conftest import _cfg

NEW_SENTENCE = "A lighthouse stands above a stormy sea at dusk, its beam sweeping the waves.\n"


@pytest.fixture(scope="module")
def jobs_client(scratch, scratch_index, tmp_path_factory):
    """The app over the scratch corpus, with its own job log folder."""
    folder, _ = scratch_index
    config_dir = tmp_path_factory.mktemp("job-config")
    saved = os.environ.get("DIGUP_SERVER_CONFIG")
    os.environ["DIGUP_SERVER_CONFIG"] = str(config_dir)
    try:
        with TestClient(create_app(_cfg(folder, (scratch,)))) as c:
            yield c
    finally:
        if saved is None:
            os.environ.pop("DIGUP_SERVER_CONFIG", None)
        else:
            os.environ["DIGUP_SERVER_CONFIG"] = saved


def wait_job(client, job_id, timeout=300.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        job = client.get(f"/api/v1/jobs/{job_id}").json()["job"]
        if job["state"] in ("done", "interrupted", "busy"):
            return job
        time.sleep(0.5)
    pytest.fail(f"job {job_id} never reached a final state within {timeout:g} s")


def test_job_runs_and_the_new_file_searches_back(jobs_client, scratch):
    # A busy window first: the job POSTed here is live, and a second request is answered.
    first = jobs_client.post("/api/v1/index", json={})
    assert first.status_code == 202
    live = first.json()["job"]
    assert live["state"] == "queued"
    busy = jobs_client.post("/api/v1/index", json={})
    assert busy.status_code == 409                       # answered, never queued blind
    assert live["id"] in busy.json()["detail"]
    assert wait_job(jobs_client, live["id"])["state"] == "done"   # quiet corpus: counts, 0 new

    # Now the real stretch: a new file, indexed by a job, searchable after it.
    (scratch / "lighthouse.txt").write_text(NEW_SENTENCE, encoding="utf-8")
    started = jobs_client.post("/api/v1/index", json={})
    assert started.status_code == 202
    job = wait_job(jobs_client, started.json()["job"]["id"])
    assert job["state"] == "done"
    assert job["files_done"] >= 1                        # the engine's file events, counted
    assert job["errors"] == 0
    assert job["searchable"] >= 7 and job["pending"] == 0  # the `idle` totals, the engine's
    reply = jobs_client.post("/api/v1/search",
                             json={"q": "lighthouse stormy sea at dusk", "kinds": ["doc"],
                                   "limit": 5}).json()
    assert Path(reply["hits"][0]["path"]).name == "lighthouse.txt"  # reload→prewarm happened


def test_job_log_holds_the_engines_counts(jobs_client):
    jobs = jobs_client.get("/api/v1/jobs").json()["jobs"]
    done = [j for j in jobs if j["state"] == "done"]
    assert done, "no completed job in the log"
    last = done[-1]
    assert {"id", "state", "started", "ended", "seconds", "files", "searchable",
            "pending", "vectors", "files_done", "files_failed", "errors"} <= set(last)
    assert last["vectors"] >= 7                          # every file embedded, the engine's


def test_unknown_job_is_404(jobs_client):
    assert jobs_client.get("/api/v1/jobs/not-a-job").status_code == 404


def test_a_run_never_logged_finished_recovers_as_interrupted(scratch, scratch_index, tmp_path):
    folder, _ = scratch_index
    config_dir = tmp_path / "config"
    config_dir.mkdir()
    (config_dir / "jobs.jsonl").write_text(
        json.dumps({"id": "abc123", "state": "running", "started": 0}) + "\n", encoding="utf-8")
    runner = JobRunner(_cfg(folder, (scratch,)), config_dir=str(config_dir))
    try:
        assert runner.job("abc123")["state"] == "interrupted"   # never success — README §5
        lines = [json.loads(l) for l in
                 (config_dir / "jobs.jsonl").read_text().splitlines()]
        assert lines[-1]["id"] == "abc123" and lines[-1]["state"] == "interrupted"
    finally:
        runner.shutdown()

CANARY = "A red canoe rests on a glass-still lake under the northern lights.\n"


def test_plain_sync_retires_walked_root_ghosts(jobs_client, scratch):
    """Found by suite 11: the engine's plain sync retires rows for files missing under
    the roots it walks — the walk *is* the scope, and a vanished file inside it is
    removed at sync. (Rows whose paths are outside the walked roots are a different
    animal: the next test pins them, with prune.)"""
    before = jobs_client.get("/api/v1/status").json()["searchable"]

    (scratch / "canary.txt").write_text(CANARY, encoding="utf-8")
    job = jobs_client.post("/api/v1/index", json={}).json()["job"]
    assert wait_job(jobs_client, job["id"])["state"] == "done"
    assert jobs_client.get("/api/v1/status").json()["searchable"] == before + 1
    hits = jobs_client.post("/api/v1/search", json={
        "q": "red canoe glass-still lake northern lights", "kinds": ["doc"],
        "limit": 3}).json()["hits"]
    assert any(h["path"].endswith("canary.txt") for h in hits)      # indexed, searchable

    (scratch / "canary.txt").unlink()                              # the file is gone
    job = jobs_client.post("/api/v1/index", json={}).json()["job"]  # plain sync…
    assert wait_job(jobs_client, job["id"])["state"] == "done"
    assert jobs_client.get("/api/v1/status").json()["searchable"] == before  # …row gone
    hits = jobs_client.post("/api/v1/search", json={
        "q": "red canoe glass-still lake northern lights", "kinds": ["doc"],
        "limit": 3}).json()["hits"]
    assert not any(h["path"].endswith("canary.txt") for h in hits) # row gone, hits gone


def test_out_of_scope_rows_survive_plain_sync_and_retire_under_prune(tmp_path):
    """The compose-proof ghost, at scratch scale: rows whose paths live OUTSIDE the
    server's roots (the old root scope after a remount) keep counting in
    `files`/`searchable`/`vectors` — plain syncs walk the current roots and never
    touch them; diluting z for live hits is what that dilution looked like in the
    proof. `prune: true` — the engine's `--prune` — retires them: "files no longer
    found under these roots" includes paths outside the roots. The persisted job
    record echoes the flag, and survives a runner restart (replay)."""
    s2 = tmp_path / "old-root"
    s2.mkdir()
    (s2 / "canary2.txt").write_text(CANARY, encoding="utf-8")
    idx = tmp_path / "ghost-index"
    idx.mkdir()
    nowater = {"DIGUP_SERVER_PREWARM": "0"}          # status ops don't need the model
    saved = os.environ.get("DIGUP_SERVER_PREWARM")

    os.environ["DIGUP_SERVER_PREWARM"] = "0"
    os.environ["DIGUP_SERVER_CONFIG"] = str(tmp_path / "job-config")
    try:
        # A server whose roots INCLUDE the folder: the canary is indexed, searchable.
        with TestClient(create_app(_cfg(idx, (s2,)))) as scope_a:
            job = scope_a.post("/api/v1/index", json={}).json()["job"]
            assert wait_job(scope_a, job["id"])["state"] == "done"
            assert scope_a.get("/api/v1/status").json()["searchable"] == 1

        # The server AFTER the remount: its roots no longer include that folder.
        empty = tmp_path / "new-root"
        empty.mkdir()
        with TestClient(create_app(_cfg(idx, (empty,)))) as scope_b:
            status = scope_b.get("/api/v1/status").json()
            assert status["searchable"] == 1 and status["files"] == 1  # the ghost counts

            job = scope_b.post("/api/v1/index", json={}).json()["job"]   # plain sync…
            assert wait_job(scope_b, job["id"])["state"] == "done"
            assert scope_b.get("/api/v1/status").json()["searchable"] == 1  # …row SURVIVES

            started = scope_b.post("/api/v1/index", json={"prune": True})
            job_id = started.json()["job"]["id"]
            assert started.json()["job"].get("prune") is True             # echoed live
            assert wait_job(scope_b, job_id)["state"] == "done"
            assert scope_b.get("/api/v1/status").json()["searchable"] == 0  # retired
            assert scope_b.get(f"/api/v1/jobs/{job_id}").json()["job"].get("prune") is True
    finally:
        if saved is None:
            os.environ.pop("DIGUP_SERVER_PREWARM", None)
        else:
            os.environ["DIGUP_SERVER_PREWARM"] = saved


def test_a_stop_mid_job_is_interrupted_and_the_next_job_resumes(tmp_path, scratch):
    """Stage 8: `shutdown()` sends the engine's `stop` — the writer closes its stream at
    the safe point **between files** — and the job records *interrupted* with its
    partial counts, never success. SQLite stays whole: the next writer takes the lock,
    resumes the walk (files already embedded are unchanged) and finishes it."""
    idx = tmp_path / "resume-index"
    cfg_dir = tmp_path / "resume-cfg"
    expected = sum(1 for f in scratch.rglob("*") if f.is_file())   # session scratch grows:
    runner = JobRunner(_cfg(str(idx), (scratch,)), config_dir=str(cfg_dir))  # assert vs live
    job_id = runner.start()["id"]
    time.sleep(6.0)                                   # a fresh scratch index embeds ~1 min:
    runner.shutdown()                                 # this shutdown lands mid-walk
    job = runner.job(job_id)
    assert job["state"] == "interrupted"
    assert "stopped" in job.get("why", "")            # truthful: never success
    partial = job.get("files_done")
    assert partial is not None

    runner2 = JobRunner(_cfg(str(idx), (scratch,)), config_dir=str(tmp_path / "resume-cfg2"))
    try:
        job2 = runner2.start()["id"]
        deadline = time.monotonic() + 420.0
        while time.monotonic() < deadline and runner2.job(job2)["state"] in ("queued", "running"):
            time.sleep(2.0)
        done = runner2.job(job2)
        assert done["state"] == "done"
        assert done["searchable"] == expected and done["pending"] == 0  # index == the walk
        assert done["vectors"] >= 10
        assert done["files_done"] >= partial                     # the resumed part, engine's
    finally:
        runner2.shutdown()


def test_the_job_log_rotates_and_history_survives_rotation(scratch, scratch_index, tmp_path):
    """Stage 8: the job log rotates at size (`DIGUP_SERVER_JOB_LOG_SIZE`); replay reads
    ALL rotations oldest-first, so the job history outlives any rotation."""
    folder, _ = scratch_index
    cfg = str(tmp_path / "rot-cfg")
    runner = JobRunner(_cfg(folder, (scratch,)), config_dir=cfg, log_rotate_bytes=900)
    ids = []
    for _ in range(6):
        job_id = runner.start()["id"]
        ids.append(job_id)
        deadline = time.monotonic() + 120.0
        while time.monotonic() < deadline and runner.job(job_id)["state"] in ("queued", "running"):
            time.sleep(0.5)
        assert runner.job(job_id)["state"] == "done"
    runner.shutdown()

    files = [f.name for f in (tmp_path / "rot-cfg").iterdir() if f.name.startswith("jobs.jsonl")]
    assert len(files) >= 2                                          # rotation happened
    replay = JobRunner(_cfg(folder, (scratch,)), config_dir=cfg, log_rotate_bytes=900)
    try:
        history = {j["id"]: j["state"] for j in replay.jobs()}
        assert set(ids) <= set(history)                             # every job visible
        assert all(state == "done" for state in history.values())  # none ghosted, none lost
    finally:
        replay.shutdown()


def test_the_knobs_are_read_from_the_environment(scratch, scratch_index):
    """`DIGUP_SERVER_BACKFILL=0` reaches the engine argv (IndexService's `--backfill`
    off) and `DIGUP_SERVER_JOB_LOG_SIZE` reaches the runner — the settings are env-
    driven, per `.env.example`; defaults stay the shipping ones (backfill on, 1 MiB)."""
    folder, _ = scratch_index
    saved = {k: os.environ.get(k) for k in
             ("DIGUP_SERVER_BACKFILL", "DIGUP_SERVER_JOB_LOG_SIZE", "DIGUP_SERVER_PREWARM")}
    os.environ["DIGUP_SERVER_BACKFILL"] = "0"
    os.environ["DIGUP_SERVER_JOB_LOG_SIZE"] = "5000"
    os.environ["DIGUP_SERVER_PREWARM"] = "0"
    try:
        with TestClient(create_app(_cfg(folder, (scratch,)))) as c:
            runner = c.app.state.jobs
            assert runner._backfill is False
            assert runner._rotate == 5000
        cfg = EngineConfig(index=str(folder), roots=(str(scratch),))
        assert "--backfill" not in cfg.index_argv()
        assert "--backfill" in cfg.index_argv(backfill=True)
    finally:
        for k, v in saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v


def test_shutdown_mid_job_finishes_and_marks_the_job_interrupted(scratch, scratch_index, tmp_path):
    """The reviewer's repro of a self-deadlock: `shutdown()` called `_mark()` from inside
    `with self._lock:` and `_mark` takes that same plain (non-reentrant) Lock — a docker
    stop while a job was running hung the lifespan forever (job never logged *interrupted*,
    `service.quit()` never ran, and every job poll consumed a threadpool thread until the
    API stopped answering). The shape that hits it: a job whose remaining work outlives
    the worker's join grace — one long file's embed on a 15 s stop."""
    folder, _ = scratch_index
    config_dir = tmp_path / "shutdown-cfg"
    runner = JobRunner(_cfg(folder, (scratch,)), config_dir=str(config_dir))
    runner._run_one = lambda job_id: time.sleep(25.0)     # outlives the 20 s join grace
    job = runner.start()["id"]
    time.sleep(0.5)                                       # the worker has picked it up
    began = time.monotonic()
    runner.shutdown()                                     # deadlocked: this never returns
    assert time.monotonic() - began < 30.0, "shutdown self-deadlocked (jobs.py:136/248)"
    assert runner.job(job)["state"] == "interrupted"      # README §5, on the stop path
    assert runner.job(job).get("why") == "server stopped"


def test_a_crashing_job_runner_leaves_indexing_alive(scratch, scratch_index, tmp_path):
    """`prewarm` answers with a 60 s TimeoutError — a `TimeoutError` is NOT a
    `RuntimeError`, and the old `except RuntimeError` let it (and any other escape from
    `_run_one`, e.g. an OSError from spawn) kill the worker thread silently: `_active`
    stayed set forever, every later `POST /index` answered 409 naming a job that could
    never run, and the queued job never left `queued`. Recovery was a container restart."""
    folder, _ = scratch_index
    config_dir = tmp_path / "crash-cfg"
    runner = JobRunner(_cfg(folder, (scratch,)), config_dir=str(config_dir))
    state = {"first": True}

    def crash_once(job_id):
        if state["first"]:
            state["first"] = False
            raise TimeoutError("search-service: no reply to 'prewarm' within 60 s")
        JobRunner._run_one(runner, job_id)                # the real path from here on

    runner._run_one = crash_once
    first = runner.start()["id"]
    deadline = time.monotonic() + 30.0
    while time.monotonic() < deadline and runner.job(first)["state"] == "queued":
        time.sleep(0.2)
    assert runner.job(first)["state"] == "interrupted"    # honest, not wedged
    assert "prewarm" in runner.job(first).get("why", "")
    assert runner._worker.is_alive()                      # the thread SURVIVED the crash
    second = runner.start()["id"]                         # old code: JobBusy forever here
    deadline = time.monotonic() + 300.0
    while time.monotonic() < deadline and runner.job(second)["state"] in ("queued", "running"):
        time.sleep(0.5)
    assert runner.job(second)["state"] == "done"          # indexing works after the crash
    runner.shutdown()


def test_a_prewarm_timeout_after_done_keeps_the_job_done(scratch, scratch_index, tmp_path):
    """A job is *done* when the writer finished: the refresh behind it (reload →
    prewarm) timing out is a note on a done job — never a dead runner thread, never a
    state that claims more than happened."""
    folder, _ = scratch_index
    config_dir = tmp_path / "prewarm-cfg"

    def after_done():
        raise TimeoutError("search-service: no reply to 'prewarm' within 60 s")

    runner = JobRunner(_cfg(folder, (scratch,)), config_dir=str(config_dir),
                       after_done=after_done)
    job = runner.start()["id"]
    deadline = time.monotonic() + 300.0
    while time.monotonic() < deadline and runner.job(job)["state"] in ("queued", "running"):
        time.sleep(0.5)
    done = runner.job(job)
    assert done["state"] == "done"
    assert "searcher refresh deferred" in done.get("why", "")
    assert runner._worker.is_alive()
    runner.shutdown()


def test_replay_ignores_lines_that_are_not_job_records(scratch, scratch_index, tmp_path):
    """A hand-edited/merged log must not brick the boot: the old replay did
    `record["id"]` on any parsed JSON — a bare `5` raised, `__init__` propagated, and
    the app refused to start. Torn tails and non-record lines are skipped; the one
    real `running` record still recovers as *interrupted*."""
    folder, _ = scratch_index
    config_dir = tmp_path / "junk-cfg"
    config_dir.mkdir()
    (config_dir / "jobs.jsonl").write_text(
        "[1, 2, 3]\n5\nnull\n\"a string\"\n{\"state\":\"running\"}\n"   # valid JSON, not records
        '{"id":"abc123","state":"running","started":0}\n'
        '{"id":"real", "state":"done", "ended":1}\n'
        "truncat",                                                       # torn tail
        encoding="utf-8")
    runner = JobRunner(_cfg(folder, (scratch,)), config_dir=str(config_dir))
    assert runner.job("abc123")["state"] == "interrupted"
    assert runner.job("real")["state"] == "done"
    runner.shutdown()
