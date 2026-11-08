"""Stage 13 — named indexes and minted application keys (targets.py, mint_tokens,
target-scoped BearerAuth, the API's per-target supervision).

The promise under test is the user's flow, end to end: the compose server runs
standalone over its media index; an application (Nextcloud's bridge) gets its own minted
key, pastes it into its settings, and every call that carries it — status, search, index,
jobs, media — answers the application's OWN index. The media index is untouched by that
application's crawl, one writer per index keeps both crawls independent, and no token
ever answers a target it was not minted for.
"""
from __future__ import annotations

import json
import os
import stat
import time

import pytest
from fastapi.testclient import TestClient

from conftest import _cfg
from digup_server.security import Auth, BearerAuth, PrincipalLog, mint_tokens, read_tokens_from_env
from digup_server.targets import MAIN_TARGET, build_registry, load_targets_file, parse_app_targets

CANARY = "A red canoe rests on a glass-still lake under northern lights.\n"


# ── registry: parsing, validation, merging ─────────────────────────────────────────────

def test_the_registry_parses_the_env_shape_exactly_as_documented():
    targets = parse_app_targets("nc=/media/nc:/media/nc2:/idx/nc;dc=/media/dc:/idx/dc")
    assert targets["nc"].roots == ("/media/nc", "/media/nc2")
    assert targets["nc"].index == "/idx/nc"
    assert targets["dc"].roots == ("/media/dc",) and targets["dc"].index == "/idx/dc"


def test_the_registry_refuses_every_shape_that_could_silently_break_a_target():
    for bad in ("x=/media/a",                       # no index folder
                "media=/media/a:/idx",              # reserved name
                "nc=relative/path:/idx/nc",         # root not absolute
                "nc=/media/a:relative-index",       # index not absolute
                "nc=/media/a:",                     # empty index
                "=/media/a:/idx",                   # empty name
                "nc=/media/a:/idx/nc;;dc=/media/b"):    # a later entry is broken
        with pytest.raises(ValueError):
            parse_app_targets(bad)


def test_registry_merges_the_file_and_the_env_with_env_winning(tmp_path):
    (tmp_path / "targets.json").write_text(json.dumps({
        "dc": {"roots": ["/media/from-file"], "index": "/idx/file-dc"},
        "fl": {"roots": ["/media/fl"], "index": "/idx/fl"},
    }), encoding="utf-8")
    reg = build_registry({"DIGUP_SERVER_APP_TARGETS": "dc=/media/env:/idx/env-dc"},
                         main_roots=("/media/photos",), main_index="/idx/main",
                         config_dir=str(tmp_path))
    assert reg[MAIN_TARGET].main and reg[MAIN_TARGET].roots == ("/media/photos",)
    assert reg["dc"].roots == ("/media/env",) and reg["dc"].index == "/idx/env-dc"
    assert reg["fl"].roots == ("/media/fl",)          # file-only target joins the registry


def test_a_target_may_not_be_the_main_index_itself(tmp_path):
    (tmp_path / "targets.json").write_text(
        json.dumps({"x": {"roots": ["/media/a"], "index": "/idx/main"}}), encoding="utf-8")
    with pytest.raises(ValueError, match="separate indexes"):
        build_registry({}, main_roots=("/media/photos",), main_index="/idx/main",
                       config_dir=str(tmp_path))


# ── minted keys: inert alone, stable once, env-authoritative, 0600 ─────────────────────

def test_minting_is_inert_without_targets_a_standalone_server_stays_exactly_it_was(tmp_path):
    auth = mint_tokens({}, str(tmp_path), ())
    assert not auth.enabled
    assert not (tmp_path / "tokens.json").exists()    # nothing written, nothing minted


def test_minted_keys_fire_for_targets_are_restart_stable_and_live_0600(tmp_path):
    first = mint_tokens({}, str(tmp_path), ("nc",))
    assert first.enabled and first.admin and first.readers["app:nc"]
    assert set(first.minted) == {"admin", "app:nc"}
    second = mint_tokens({}, str(tmp_path), ("nc",))  # a restart re-reads the file
    assert second.admin == first.admin and second.readers["app:nc"] == first.readers["app:nc"]
    # File-backed keys are server-generated keys: displayable on every boot, not only
    # the boot that generated them (the UI shows what the operator never typed).
    assert set(second.minted) == {"admin", "app:nc"}
    mode = stat.S_IMODE(os.stat(tmp_path / "tokens.json").st_mode)
    assert mode == 0o600
    stored = json.loads((tmp_path / "tokens.json").read_text(encoding="utf-8"))
    assert stored["admin"] == first.admin and stored["readers"]["app:nc"] == first.readers["app:nc"]


def test_environment_tokens_are_authority_mint_only_fills_the_gaps(tmp_path):
    env = {"DIGUP_SERVER_ADMIN_TOKEN": "adm", "DIGUP_SERVER_READ_TOKENS": "app:nc:toknc"}
    auth = mint_tokens(env, str(tmp_path), ("nc", "dc"))
    assert auth.admin == "adm" and "admin" not in auth.minted       # env admin kept, not echoed
    assert auth.readers["app:nc"] == "toknc" and "app:nc" not in auth.minted
    assert "app:dc" in auth.minted                                  # gap filled for the rest
    stored = json.loads((tmp_path / "tokens.json").read_text(encoding="utf-8"))
    assert "admin" not in stored                                    # env secrets never stored
    assert stored.get("readers", {}).get("app:nc") is None          # ditto
    assert stored["readers"]["app:dc"] == auth.readers["app:dc"]


def test_rotating_minted_keys_mints_new_values_and_leaves_env_keys_intact(tmp_path):
    from digup_server.security import rotate_minted
    d = str(tmp_path)
    first = mint_tokens({"DIGUP_SERVER_ADMIN_TOKEN": "adm-env",
                         "DIGUP_SERVER_READ_TOKENS": "app:dc:tokdc"}, d, ("nc", "dc"))
    rotated = rotate_minted(first, d)
    assert rotated is not None
    assert rotated.admin == "adm-env"                               # env admin: kept, never rotated
    assert rotated.readers["app:dc"] == "tokdc"                     # env app key: never rotated
    assert rotated.readers["app:nc"] != first.readers["app:nc"]     # minted: a fresh value
    assert rotated.minted == ("app:nc",)
    stored = json.load(open(os.path.join(d, "tokens.json"), encoding="utf-8"))
    assert stored["readers"]["app:nc"] == rotated.readers["app:nc"]
    assert "admin" not in stored and stored["readers"].get("app:dc") is None
    assert rotated.token_names(first.readers["app:nc"]) == ()      # the old key dies at the live auth
    assert rotated.token_names(rotated.readers["app:nc"]) == ("app:nc",)
    assert stat.S_IMODE(os.stat(os.path.join(d, "tokens.json")).st_mode) == 0o600


def test_rotation_offers_nothing_where_nothing_is_minted(tmp_path):
    from digup_server.security import rotate_minted
    assert rotate_minted(mint_tokens({"DIGUP_SERVER_TOKEN": "plain"}, str(tmp_path), ()),
                         str(tmp_path)) is None


def test_read_token_names_may_carry_colons_the_last_one_is_the_separator():
    readers = read_tokens_from_env({"DIGUP_SERVER_READ_TOKENS": "nc-a:tokA,app:nc:tokB"})
    assert readers == {"nc-a": "tokA", "app:nc": "tokB"}


# ── the bearer gate binds tokens to targets (unit, no engine) ──────────────────────────

async def _echo(scope, receive, send):
    body = json.dumps({"target": scope.get("digup.target"),
                       "principal": scope.get("digup.principal")}).encode()
    await send({"type": "http.response.start", "status": 200,
                "headers": [(b"content-type", b"application/json")]})
    await send({"type": "http.response.body", "body": body})


def gated_client(auth: Auth) -> TestClient:
    return TestClient(PrincipalLog(BearerAuth(_echo, auth=auth)))


def test_app_tokens_answer_their_own_target_and_nothing_else():
    auth = Auth(admin="adm", readers={"app:nc": "toknc"})
    c = gated_client(auth)
    nc = {"Authorization": "Bearer toknc"}
    adm = {"Authorization": "Bearer adm"}
    # The binding IS the token's default: plain paths answer its own index (the bridge
    # needs no target parameter), and any explicit target it does not match is refused.
    r = c.get("/api/v1/status", headers=nc)
    assert r.status_code == 200 and r.json()["target"] == "nc"
    assert c.get("/api/v1/status", params={"target": "nc"}, headers=nc).status_code == 200
    assert c.get("/api/v1/status", params={"target": "media"}, headers=nc).status_code == 403
    assert c.get("/api/v1/status", params={"target": "other"}, headers=nc).status_code == 403
    assert c.post("/api/v1/index", params={"target": "nc"}, headers=nc).status_code == 200
    assert c.post("/api/v1/index", headers=nc).status_code == 200        # own target by default
    assert c.post("/api/v1/index", params={"target": "media"}, headers=nc).status_code == 403
    assert c.post("/api/v1/index", headers=adm).status_code == 200       # media: admin's own
    assert c.post("/api/v1/index", params={"target": "nc"}, headers=adm).status_code == 200
    assert c.get("/api/v1/status", params={"target": "nc"}, headers=adm).status_code == 200
    plain = gated_client(Auth(read="plain", admin="adm"))
    assert plain.get("/api/v1/status", params={"target": "nc"},
                     headers={"Authorization": "Bearer plain"}).status_code == 403
    assert plain.get("/api/v1/status", headers={"Authorization": "Bearer plain"}).status_code == 200


def test_the_principal_log_names_the_application_that_asked(caplog):
    import logging
    c = gated_client(Auth(admin="adm", readers={"app:nc": "toknc"}))
    with caplog.at_level(logging.INFO, logger="digup.auth"):
        c.get("/api/v1/status", params={"target": "nc"}, headers={"Authorization": "Bearer toknc"})
    lines = [r.message for r in caplog.records if "principal=" in r.message]
    assert any("principal=app:nc" in line for line in lines)
    # The audit line names WHICH index was addressed (named indexes, stage 13).
    assert any("target=nc" in line for line in lines)


# ── end to end: minted key → target machinery, over the real engine ────────────────────

def test_an_application_key_answers_only_its_own_index_end_to_end(scratch, tmp_path, monkeypatch):
    from digup_server.api import create_app

    main_index = tmp_path / "main-index"
    app_index = tmp_path / "app-index"
    monkeypatch.setenv("DIGUP_SERVER_APP_TARGETS", f"nc={scratch}:{app_index}")
    monkeypatch.setenv("DIGUP_SERVER_CONFIG", str(tmp_path / "server-config"))
    with TestClient(create_app(_cfg(main_index, (tmp_path / "media",)))) as c:
        keys = json.loads((tmp_path / "server-config" / "tokens.json").read_text(encoding="utf-8"))
        adm, nctok = keys["admin"], keys["readers"]["app:nc"]
        nc = {"Authorization": f"Bearer {nctok}"}
        admin = {"Authorization": f"Bearer {adm}"}

        # The target's status answers the target's roots, the media index stays the app's.
        st = c.get("/api/v1/status", headers=nc).json()
        assert st["roots"] == [str(scratch)] and st["target"] == "nc"
        assert c.get("/api/v1/status", headers=admin).json()["roots"] == [str(tmp_path / "media")]

        # The application queues its OWN crawl — and never the media crawl.
        assert c.post("/api/v1/index", headers=nc).status_code == 202
        assert c.post("/api/v1/index", params={"target": "media"}, headers=nc).status_code == 403
        job_id = c.get("/api/v1/jobs", headers=nc).json()["jobs"][-1]["id"]
        assert wait_final(c, job_id, nc) == "done"
        st = c.get("/api/v1/status", headers=nc).json()
        assert st["files"] > 0 and st["searchable"] > 0
        assert c.get("/api/v1/status", headers=admin).json()["files"] == 0   # media untouched

        # Its own search answers from its own index; the media index has none of its files.
        hits = c.post("/api/v1/search", json={"q": "campfire stories", "limit": 5},
                      headers=nc).json()["hits"]
        assert hits and all(h["path"].startswith(str(scratch)) for h in hits)
        assert c.post("/api/v1/search", json={"q": "campfire stories"},
                      headers=admin).json()["hits"] == []

        # Media handles resolve their target: the app's handle previews through its
        # engine. The preview contract is the engine's: it renders image/pdf/video
        # segments, and a text doc answers the honest "unreadable: can't decode
        # image" refusal forever — so preview the IMAGE hit (and poll: right after a
        # job the searcher is mid reload→prewarm, and refusals are states, pinned
        # 503s in test_api, that clients retry).
        media_id = next(h["media_id"] for h in hits if h["kind"] == "image")
        assert wait_status(c, f"/api/v1/media/{media_id}/preview", nc, 200) == 200
        assert wait_status(c, f"/api/v1/media/{media_id}/preview", admin, 200) == 200

        # Jobs are per target: the app sees its own history; its log is its own file.
        assert all(j["state"] in ("done", "interrupted")
                   for j in c.get("/api/v1/jobs", headers=nc).json()["jobs"])
        assert c.get("/api/v1/jobs?target=media", headers=nc).status_code == 403
        assert (tmp_path / "server-config" / "jobs-nc.jsonl").exists()

        # Targets listing: admin sees both with counts; the app sees only its own.
        # The counts come from the CLI's own table (kinds total + vectors) — no engine
        # spawn for a listing.
        rows = {t["name"]: t for t in c.get("/api/v1/targets", headers=admin).json()["targets"]}
        assert set(rows) == {MAIN_TARGET, "nc"}
        assert rows["nc"]["files"] > 0 and rows["nc"]["searchable"] > 0, \
            (rows["nc"]["files"], rows["nc"]["searchable"])
        assert rows[MAIN_TARGET]["files"] == 0, rows[MAIN_TARGET]["files"]
        assert {t["name"] for t in c.get("/api/v1/targets", headers=nc).json()["targets"]} == {"nc"}

        # Tokens: minted values shown to admin only, never to an app token.
        t = c.get("/api/v1/tokens", headers=admin).json()
        assert t["admin"] == adm and t["apps"][0]["token"] == nctok
        assert c.get("/api/v1/tokens", headers=nc).status_code == 403


def test_two_targets_crawl_independently_one_writer_per_index(scratch, tmp_path, monkeypatch):
    """The busy guarantee is per index: a running job on target A never blocks target B
    (the flock lives beside each index folder) and never blocks the media crawl."""
    from digup_server.api import create_app
    from digup_server.jobs import JOB_LOG

    app_a, app_b = tmp_path / "idx-a", tmp_path / "idx-b"
    roots_a = tmp_path / "media-a"
    roots_a.mkdir()
    monkeypatch.setenv("DIGUP_SERVER_APP_TARGETS", f"a={scratch}:{app_a};b={roots_a}:{app_b}")
    monkeypatch.setenv("DIGUP_SERVER_CONFIG", str(tmp_path / "config"))
    with TestClient(create_app(_cfg(tmp_path / "main-index", (roots_a,)))) as c:
        keys = json.loads((tmp_path / "config" / "tokens.json").read_text(encoding="utf-8"))
        adm = {"Authorization": f"Bearer {keys['admin']}"}
        tok_a = {"Authorization": f"Bearer {keys['readers']['app:a']}"}
        tok_b = {"Authorization": f"Bearer {keys['readers']['app:b']}"}

        job = c.post("/api/v1/index", headers=tok_a).json()["job"]
        assert job["state"] in ("queued", "running")
        # Same target, second request: the honest 409 (one writer per index).
        busy = c.post("/api/v1/index", headers=tok_a)
        assert busy.status_code == 409 and job["id"] in busy.json()["detail"]
        # A different target answers 202 right away — independent writers, independent logs.
        assert c.post("/api/v1/index", headers=tok_b).status_code == 202
        # The media crawl is independent of both.
        assert c.post("/api/v1/index", headers=adm).status_code == 202
        for tok in (tok_a, tok_b):
            deadline = time.monotonic() + 900
            while time.monotonic() < deadline:
                jobs = c.get("/api/v1/jobs", headers=tok).json()["jobs"]
                if jobs and jobs[-1]["state"] in ("done", "interrupted"):
                    break
                time.sleep(1)
            assert jobs[-1]["state"] == "done"
        for name in ("a", "b"):
            assert (tmp_path / "config" / f"jobs-{name}.jsonl").exists()
        assert (tmp_path / "config" / JOB_LOG).exists()


def wait_final(client, job_id, headers, timeout=900.0) -> str:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        state = client.get(f"/api/v1/jobs/{job_id}", headers=headers).json()["job"]["state"]
        if state in ("done", "interrupted", "busy"):
            return state
        time.sleep(0.5)
    pytest.fail(f"job {job_id} never reached a final state within {timeout:g} s")


def wait_status(client, url, headers, want, timeout=120.0) -> int:
    """Poll a GET until it answers `want` — a searcher mid reload→prewarm answers the
    engine's 503 refusal, which the API surfaces verbatim (test_api pins it); clients
    retry, and so does this contract test. The failure names the LAST answer's body:
    the engine's own words are the diagnosis."""
    deadline = time.monotonic() + timeout
    code, body = None, ""
    while time.monotonic() < deadline:
        r = client.get(url, headers=headers)
        code, body = r.status_code, r.text[:200]
        if code == want:
            return code
        time.sleep(1.0)
    pytest.fail(f"{url} never answered {want} within {timeout:g} s "
                f"(last {code}: {body})")


# ── POST /api/v1/tokens — the UI's Regenerate (admin scope, minted keys only) ─────────

def test_the_admin_can_regenerate_the_minted_keys_and_the_old_values_die(tmp_path,
                                                                          monkeypatch):
    from digup_server.api import create_app
    monkeypatch.setenv("DIGUP_SERVER_APP_TARGETS", f"nc={tmp_path}/media:{tmp_path}/app-index")
    monkeypatch.setenv("DIGUP_SERVER_CONFIG", str(tmp_path / "server-config"))
    with TestClient(create_app(_cfg(tmp_path / "main-index", (tmp_path / "media",)))) as c:
        keys = json.load(open(tmp_path / "server-config" / "tokens.json", encoding="utf-8"))
        adm, old_nc = keys["admin"], keys["readers"]["app:nc"]
        A = {"Authorization": f"Bearer {adm}"}
        assert c.get("/api/v1/tokens", headers=A).json()["admin"] == adm
        r = c.post("/api/v1/tokens", headers=A)
        assert r.status_code == 200 and r.json()["rotated"] is True
        new_admin, new_nc = r.json()["admin"], r.json()["apps"][0]["token"]
        assert new_admin != adm and new_nc != old_nc
        # The rotation takes effect immediately — the old values die, the new ones answer:
        assert c.get("/api/v1/status", headers={"Authorization": f"Bearer {old_nc}"}
                     ).status_code == 401
        assert c.get("/api/v1/status", headers=A).status_code == 401
        st = c.get("/api/v1/status", headers={"Authorization": f"Bearer {new_nc}"})
        assert st.status_code == 200 and st.json()["target"] == "nc"
        assert c.post("/api/v1/tokens",
                      headers={"Authorization": f"Bearer {new_nc}"}).status_code == 403
        fresh = json.load(open(tmp_path / "server-config" / "tokens.json", encoding="utf-8"))
        assert fresh["admin"] == new_admin and fresh["readers"]["app:nc"] == new_nc
        assert stat.S_IMODE(os.stat(tmp_path / "server-config" / "tokens.json").st_mode) == 0o600


def test_an_env_keyed_deployment_rotates_nothing(tmp_path, monkeypatch):
    from digup_server.api import create_app
    monkeypatch.setenv("DIGUP_SERVER_ADMIN_TOKEN", "adm")
    monkeypatch.delenv("DIGUP_SERVER_APP_TARGETS", raising=False)
    monkeypatch.delenv("DIGUP_SERVER_TOKEN", raising=False)
    monkeypatch.setenv("DIGUP_SERVER_CONFIG", str(tmp_path / "server-config"))
    with TestClient(create_app(_cfg(tmp_path / "main-index", (tmp_path / "media",)))) as c:
        A = {"Authorization": "Bearer adm"}
        t = c.get("/api/v1/tokens", headers=A).json()
        assert t["admin"] is None and t["admin_configured"] is True    # never echoed
        # The typed-secrets shape stays guarded: a keyless call reaches the endpoint
        # (the gate's open door is the main index's READS; the keys surface is not a
        # read) and the endpoint refuses it — 403, keys shown to the admin token only.
        # Round 6 draws the open-DISPLAY line at SERVER-MINTED keys only.
        assert c.get("/api/v1/tokens").status_code == 403
        r = c.post("/api/v1/tokens", headers=A)
        assert r.status_code == 400 and "environment" in r.json()["detail"]
        assert not (tmp_path / "server-config" / "tokens.json").exists()


# ── the minted shape answers the MAIN index's reads openly (2026-11-08 user brief) ────

def test_a_minted_key_deployment_answers_main_reads_openly(tmp_path, monkeypatch):
    """The user's model: the standalone box is searchable with no key; the minted keys
    are what the APPLICATIONS get. Keys typed in the environment (the guarded shape)
    keep guarding every call — test_security pins that shape unchanged."""
    from digup_server.api import create_app
    monkeypatch.setenv("DIGUP_SERVER_APP_TARGETS", f"nc={tmp_path}/media:{tmp_path}/app-index")
    monkeypatch.setenv("DIGUP_SERVER_CONFIG", str(tmp_path / "server-config"))
    with TestClient(create_app(_cfg(tmp_path / "main-index", (tmp_path / "media",)))) as c:
        keys = json.load(open(tmp_path / "server-config" / "tokens.json", encoding="utf-8"))
        nc = {"Authorization": f"Bearer {keys['readers']['app:nc']}"}
        # No key: the main index answers reads (status, search, targets).
        st = c.get("/api/v1/status").json()
        assert st["target"] == MAIN_TARGET and st["files"] == 0
        assert c.post("/api/v1/search", json={"q": "wakeboarding", "limit": 5}
                      ).status_code == 200
        names = {t["name"] for t in c.get("/api/v1/targets").json()["targets"]}
        assert MAIN_TARGET in names                                   # the gear's rows
        # What the keys are FOR stays guarded: the index operations, the keys surface,
        # and the application's OWN index (the open door is the main index's reads).
        assert c.post("/api/v1/index", json={}).status_code == 401
        assert c.post("/api/v1/estimate", json={}).status_code == 401
        assert c.get("/api/v1/status", params={"target": "nc"}).status_code == 401
        # Round 6 (the ticket model): a minted deployment shows its keys to the gear
        # WITHOUT a key in the browser — the same open shape as the main page's reads;
        # an application's own key never lists the server's keys.
        tk = c.get("/api/v1/tokens").json()
        assert tk["admin"] == keys["admin"] and any(a["name"] == "nc" for a in tk["apps"])
        assert c.get("/api/v1/tokens", headers=nc).status_code == 403
        # The app key keeps answering its own target and nothing else.
        assert c.get("/api/v1/status", headers=nc).json()["target"] == "nc"
        assert c.get("/api/v1/status", params={"target": "media"},
                     headers=nc).status_code == 403


def test_an_open_principal_never_previews_an_applications_files(tmp_path, monkeypatch, scratch):
    """The minted shape opens the MAIN index's reads — media handles included, so the
    media-id path must stay scoped: a key-less request for a handle whose file lives in
    an application's roots is refused; the application's own key previews it."""
    from digup_server.api import create_app
    monkeypatch.setenv("DIGUP_SERVER_APP_TARGETS", f"nc={scratch}:{tmp_path}/app-index")
    monkeypatch.setenv("DIGUP_SERVER_CONFIG", str(tmp_path / "server-config"))
    with TestClient(create_app(_cfg(tmp_path / "main-index", (tmp_path / "media",)))) as c:
        keys = json.load(open(tmp_path / "server-config" / "tokens.json", encoding="utf-8"))
        nc = {"Authorization": f"Bearer {keys['readers']['app:nc']}"}
        assert c.post("/api/v1/index", headers=nc).status_code == 202
        job_id = c.get("/api/v1/jobs", headers=nc).json()["jobs"][-1]["id"]
        assert wait_final(c, job_id, nc) == "done"
        hits = c.post("/api/v1/search", json={"q": "campfire stories", "limit": 5},
                      headers=nc).json()["hits"]
        media_id = next(h["media_id"] for h in hits if h["kind"] == "image")
        assert wait_status(c, f"/api/v1/media/{media_id}/preview", nc, 200) == 200
        assert c.get(f"/api/v1/media/{media_id}/preview").status_code == 403
        assert c.get(f"/api/v1/media/{media_id}/file").status_code == 403
        assert c.get(f"/api/v1/media/{media_id}/text").status_code == 403


# ── stage 14: the standalone mints its key; applications register at runtime ─────────

def test_the_standalone_mints_its_api_key_when_asked(tmp_path, monkeypatch):
    """DIGUP_SERVER_MINT_KEYS=1: the key exists at boot with no application registered —
    the gear's Copy row. Main reads stay open; the key guards index/estimate/keys."""
    from digup_server.api import create_app
    monkeypatch.setenv("DIGUP_SERVER_MINT_KEYS", "1")
    monkeypatch.delenv("DIGUP_SERVER_APP_TARGETS", raising=False)
    monkeypatch.delenv("DIGUP_SERVER_TOKEN", raising=False)
    monkeypatch.delenv("DIGUP_SERVER_ADMIN_TOKEN", raising=False)
    monkeypatch.setenv("DIGUP_SERVER_CONFIG", str(tmp_path / "server-config"))
    with TestClient(create_app(_cfg(tmp_path / "main-index", (tmp_path / "media",)))) as c:
        path = tmp_path / "server-config" / "tokens.json"
        keys = json.load(open(path, encoding="utf-8"))
        adm = keys["admin"]
        A = {"Authorization": f"Bearer {adm}"}
        assert adm and stat.S_IMODE(os.stat(path).st_mode) == 0o600
        assert c.get("/api/v1/status").status_code == 200          # main reads: open
        assert c.post("/api/v1/index", json={}).status_code == 401  # mutations: keyed
        assert c.post("/api/v1/estimate", json={}).status_code == 401
        # Round 6: the minted key is DISPLAYED with no key in the browser — the gear's
        # Copy row is the ticket; the admin call shows the same value.
        tk = c.get("/api/v1/tokens").json()
        assert tk["admin"] == adm and tk["apps"] == []
        t = c.get("/api/v1/tokens", headers=A).json()
        assert t["admin"] == adm and t["apps"] == []
        assert c.post("/api/v1/estimate", headers=A, json={}).status_code == 200
        # An application's key never lists the server's keys.
        reg = c.post("/api/v1/targets", headers=A,
                     json={"name": "demo", "roots": [str(tmp_path / "media")]})
        assert reg.status_code == 200
        assert c.get("/api/v1/tokens",
                     headers={"Authorization": f"Bearer {reg.json()['token']}"}).status_code == 403


def test_an_application_registers_at_a_running_server_and_gets_its_own_key(tmp_path,
                                                                           scratch,
                                                                           monkeypatch):
    """The user's flow as one call: standalone key → POST /targets(name, roots) →
    private minted key + own index folder (default <config>/index-<name>) → its crawl
    runs in the background; the main page never sees it; the registration survives
    restart (targets.json + tokens.json)."""
    from digup_server.api import create_app
    monkeypatch.setenv("DIGUP_SERVER_MINT_KEYS", "1")
    monkeypatch.setenv("DIGUP_SERVER_CONFIG", str(tmp_path / "server-config"))
    with TestClient(create_app(_cfg(tmp_path / "main-index", (tmp_path / "media",)))) as c:
        keys = json.load(open(tmp_path / "server-config" / "tokens.json", encoding="utf-8"))
        A = {"Authorization": f"Bearer {keys['admin']}"}
        r = c.post("/api/v1/targets", headers=A, json={"name": "nc", "roots": [str(scratch)]})
        assert r.status_code == 200, r.text
        reg = r.json()
        assert reg["generated"] is True
        assert reg["index"] == str(tmp_path / "server-config" / "index-nc")
        N = {"Authorization": f"Bearer {reg['token']}"}
        assert c.get("/api/v1/status", headers=N).json()["target"] == "nc"
        assert c.get("/api/v1/status", params={"target": "media"},
                     headers=N).status_code == 403
        # its OWN crawl, in the background — and never anyone else's
        assert c.post("/api/v1/index", headers=N).status_code == 202
        job_id = c.get("/api/v1/jobs", headers=N).json()["jobs"][-1]["id"]
        assert wait_final(c, job_id, N) == "done"
        assert c.get("/api/v1/status", headers=N).json()["files"] > 0
        assert c.get("/api/v1/status").json()["files"] == 0            # main untouched
        # persisted: a restart re-reads both files (the keys and the registration)
        tj = json.load(open(tmp_path / "server-config" / "targets.json", encoding="utf-8"))
        assert tj["nc"]["roots"] == [str(scratch)]
        tk = json.load(open(tmp_path / "server-config" / "tokens.json", encoding="utf-8"))
        assert tk["readers"]["app:nc"] == reg["token"]
        # the startup validator runs at runtime: every refusal quotes its rule
        bad = [({"name": "media", "roots": [str(scratch)]}, 400),
               ({"name": "nc", "roots": [str(scratch)]}, 409),
               ({"name": "Bad Name", "roots": [str(scratch)]}, 400),
               ({"name": "x", "roots": ["relative/root"]}, 400),
               ({"name": "y", "roots": [str(scratch)],
                 "index": str(tmp_path / "main-index")}, 400)]
        for body, want in bad:
            assert c.post("/api/v1/targets", headers=A, json=body).status_code == want
        # key-less and application-keyed requests cannot register anything
        assert c.post("/api/v1/targets",
                      json={"name": "z", "roots": [str(scratch)]}).status_code == 403
        assert c.post("/api/v1/targets", headers=N,
                      json={"name": "z", "roots": [str(scratch)]}).status_code == 403
        # the open principal never previews the application's files
        hits = c.post("/api/v1/search", headers=N, json={"q": "campfire stories",
                      "limit": 5}).json()["hits"]
        media_id = next(h["media_id"] for h in hits if h["kind"] == "image")
        assert wait_status(c, f"/api/v1/media/{media_id}/preview", N, 200) == 200
        assert c.get(f"/api/v1/media/{media_id}/preview").status_code == 403
