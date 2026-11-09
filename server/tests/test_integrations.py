"""Stage 12 integration groundwork (docs/implementation/stage-12-integrations.md): the
named-token map, the CORS allowlist, the principal log, the embed widget, and the
Nextcloud compose shape. The middleware tests are engine-free (pure ASGI, the
test_security pattern); the last test drives the token map through the real API with
the real engine. The rules they pin:

* `DIGUP_SERVER_READ_TOKENS=name:token,…` — every entry guards the read scope, each is
  attributable by name, one entry's revocation touches no other;
* the CORS allowlist is exact origins only, inert when unset, and it is the boundary
  that lets an allowlisted browser widget POST (the guard's cross-origin exception is
  set ONLY by a CORS-passed preflight, stage-12 §11.4);
* every guarded request lands in the log with its accepted principal;
* the embed widget follows the same UI rules as the full UI (no external URLs, the
  built Lit+Vite shape served same-origin, server-issued media handles, the token
  never in a `<img>`-visible URL).
"""

from __future__ import annotations

import json
import logging
import re

import pytest
from fastapi.testclient import TestClient

from digup_server.security import (
    Auth,
    BearerAuth,
    Cors,
    HostOriginGuard,
    PrincipalLog,
    allowed_origins_from_env,
    auth_from_env,
    read_tokens_from_env,
)


async def echo(scope, receive, send) -> None:
    """Minimal ASGI app: answers 200 with what the middlewares wrote on the scope, so a
    request that passed is distinguishable from one refused — and the accepted principal
    (BearerAuth) and the CORS pass-mark (Cors) are readable from the answer."""
    body = json.dumps({"ok": True, "method": scope["method"], "path": scope["path"],
                       "principal": scope.get("digup.principal"),
                       "cors_allowed": scope.get("digup.cors_allowed", False)}).encode()
    await send({"type": "http.response.start", "status": 200,
                "headers": [(b"content-type", b"application/json")]})
    await send({"type": "http.response.body", "body": body})


# ── the named-token map: parsing, scopes, revocation-isolation ───────────────────────────

def test_the_map_parses_names_and_tokens():
    assert read_tokens_from_env({}) == {}
    assert read_tokens_from_env({"DIGUP_SERVER_READ_TOKENS": "  "}) == {}
    m = read_tokens_from_env({"DIGUP_SERVER_READ_TOKENS": "nc-a:tokA, nc-b:tokB,NC-A:dup"})
    assert m == {"nc-a": "tokA", "nc-b": "tokB"}          # names lowercase; FIRST wins on dupes
    assert read_tokens_from_env({"DIGUP_SERVER_READ_TOKENS": "nc-a:tokA,broken-no-colon"}) == \
        {"nc-a": "tokA"}                                   # a typo is skipped, loudly:


def test_a_dropped_map_entry_names_itself_in_the_log(caplog):
    with caplog.at_level(logging.WARNING, logger="digup.auth"):
        read_tokens_from_env({"DIGUP_SERVER_READ_TOKENS": "nc-a:tokA,typo-entry"})
    assert any("typo-entry" in r.message for r in caplog.records), \
        "a silently-dropped token is an outage nobody asked for"


def test_auth_from_env_assembles_all_three_knobs():
    a = auth_from_env({"DIGUP_SERVER_TOKEN": "plain", "DIGUP_SERVER_ADMIN_TOKEN": "adm",
                       "DIGUP_SERVER_READ_TOKENS": "nc-a:tokA,nc-b:tokB"})
    assert a.read == "plain" and a.admin == "adm"
    assert a.readers == {"nc-a": "tokA", "nc-b": "tokB"}
    assert a.enabled is True
    assert a.token_names("tokB") == ("nc-b",)
    assert a.token_names("adm") == ("admin",)             # admin covers the read scope too
    assert a.token_names("nope") == ()


def bearer_client(auth: Auth) -> TestClient:
    return TestClient(PrincipalLog(BearerAuth(echo, auth=auth)))


def test_map_tokens_guard_reads_and_admin_stays_admins_alone():
    both = bearer_client(Auth(readers={"nc-a": "tokA", "nc-b": "tokB"}, admin="adm"))
    for token in ("tokA", "tokB"):
        assert both.post("/api/v1/search",
                         headers={"Authorization": f"Bearer {token}"}).status_code == 200
        refused = both.post("/api/v1/index", headers={"Authorization": f"Bearer {token}"})
        assert refused.status_code == 403 and "admin" in refused.json()["detail"]
    assert both.post("/api/v1/index",
                     headers={"Authorization": "Bearer adm"}).status_code == 200
    assert both.post("/api/v1/search", headers={"Authorization": "Bearer nope"}).status_code == 401
    assert both.post("/api/v1/search").status_code == 401


def test_each_request_is_attributed_to_the_principal_that_asked(caplog):
    both = bearer_client(Auth(read="plain", readers={"nc-a": "tokA", "nc-b": "tokB"}, admin="adm"))
    with caplog.at_level(logging.INFO, logger="digup.auth"):
        assert both.post("/api/v1/search", headers={"Authorization": "Bearer tokA"}).status_code == 200
        assert both.post("/api/v1/search", headers={"Authorization": "Bearer tokB"}).status_code == 200
        assert both.post("/api/v1/search", headers={"Authorization": "Bearer plain"}).status_code == 200
        assert both.post("/api/v1/search", headers={"Authorization": "Bearer adm"}).status_code == 200
        assert both.post("/api/v1/index", headers={"Authorization": "Bearer adm"}).status_code == 200
    lines = [r.message for r in caplog.records if "principal=" in r.message]
    assert "principal=nc-a" in lines[0] and "principal=nc-b" in lines[1]
    assert "principal=read" in lines[2]
    assert "principal=admin (read scope)" in lines[3]    # an admin token on the read side says so
    assert "principal=admin" in lines[4]
    # health/docs stay out of the audit line: they are the healthcheck and the docs page
    both.get("/api/v1/health")
    assert not any("/api/v1/health" in r.message for r in caplog.records)


def test_an_unguarded_deployment_still_logs_its_principals_as_none(caplog):
    open_book = bearer_client(Auth())
    with caplog.at_level(logging.INFO, logger="digup.auth"):
        assert open_book.post("/api/v1/search").status_code == 200
    assert any(r.message.endswith("principal=none") and "/api/v1/search" in r.message
               for r in caplog.records)


# ── the CORS allowlist: exact origins, inert by default, the widget's boundary ───────────

def test_the_cors_allowlist_is_exact_and_off_by_default():
    assert allowed_origins_from_env({}) is None
    assert allowed_origins_from_env({"DIGUP_SERVER_ALLOWED_ORIGINS": "  "}) is None
    origins = allowed_origins_from_env(
        {"DIGUP_SERVER_ALLOWED_ORIGINS": "http://Nextcloud.Lan:8081/, http://a.example"})
    assert origins == frozenset({"http://nextcloud.lan:8081", "http://a.example"})
    inert = TestClient(Cors(echo))
    preflight = inert.options("/api/v1/search", headers={"Origin": "http://a.example"})
    assert "access-control-allow-origin" not in preflight.headers
    plain = inert.get("/api/v1/status", headers={"Origin": "http://a.example"})
    assert "access-control-allow-origin" not in plain.headers   # off = no CORS headers, period


def test_an_allowlisted_origin_gets_preflight_and_decorated_answers():
    cors = TestClient(Cors(echo, allowed_origins=frozenset({"http://nc.example"})))
    pre = cors.options("/api/v1/search", headers={"Origin": "http://nc.example",
                                                  "access-control-request-method": "POST"})
    assert pre.status_code == 204
    assert pre.headers["access-control-allow-origin"] == "http://nc.example"
    assert "POST" in pre.headers["access-control-allow-methods"]
    assert "authorization" in pre.headers["access-control-allow-headers"]
    assert pre.headers["vary"] == "Origin"
    posted = cors.post("/api/v1/search", headers={"Origin": "http://nc.example"})
    assert posted.status_code == 200
    assert posted.headers["access-control-allow-origin"] == "http://nc.example"
    assert posted.json()["cors_allowed"] is True           # the guard's exception is marked
    # an origin NOT on the list: the middleware passes through, decorates nothing
    off = cors.post("/api/v1/search", headers={"Origin": "http://evil.example"})
    assert off.status_code == 200
    assert "access-control-allow-origin" not in off.headers
    assert off.json()["cors_allowed"] is False
    # a request with no Origin (server-to-server: PHP, curl, agents) is untouched
    assert "access-control-allow-origin" not in cors.get("/api/v1/status").headers


# ── the composed stack: Cors → Guard → Bearer, the widget's real path ───────────────────

def widget_stack() -> TestClient:
    """The stack create_app installs, over the echo app: the operator names the hosts it
    serves and the one widget origin it embeds, with the read token for the widget."""
    app = Cors(HostOriginGuard(BearerAuth(echo, auth=Auth(read="tokA")),
                               allowed_hosts=frozenset({"nc.example", "127.0.0.1"})),
               allowed_origins=frozenset({"http://nc.example"}))
    return TestClient(app)


def test_the_allowlisted_widget_posts_cross_origin_with_the_bearer_token():
    stack = widget_stack()
    widget = {"Host": "nc.example:8787", "Origin": "http://nc.example",
              "Authorization": "Bearer tokA"}
    ok = stack.post("/api/v1/search", headers=widget)
    assert ok.status_code == 200 and ok.json()["principal"] == "read"
    assert ok.headers["access-control-allow-origin"] == "http://nc.example"
    # the preflight lands before the POST and passes the guard (OPTIONS is not state-changing)
    pre = stack.options("/api/v1/search", headers={"Host": "nc.example:8787",
                                                   "Origin": "http://nc.example"})
    assert pre.status_code == 204


def test_an_unallowlisted_browser_still_hits_the_same_origin_rule():
    """The guard's cross-origin POST refusal survives CORS: a page the operator never
    allowlisted gets no exception, token or no token."""
    stack = widget_stack()
    refused = stack.post("/api/v1/search", headers={"Host": "nc.example:8787",
                                                    "Origin": "http://evil.example",
                                                    "Authorization": "Bearer tokA"})
    assert refused.status_code == 403
    # server-to-server (no Origin at all) remains the normal, unblessed path
    assert stack.post("/api/v1/search", headers={"Host": "nc.example:8787",
                                                 "Authorization": "Bearer tokA"}).status_code == 200
    # the host allowlist outranks everything: a stale Host is refused before tokens
    assert stack.post("/api/v1/search", headers={"Host": "evil.example",
                                                 "Origin": "http://nc.example",
                                                 "Authorization": "Bearer tokA"}).status_code == 400


def test_the_app_installs_all_four_middlewares_knobs_from_env(monkeypatch):
    from digup_server.api import create_app
    from digup_server.engine import EngineConfig
    app = create_app(EngineConfig(index="/nonexistent-index", roots=("/nonexistent-root",)))
    classes = [m.cls for m in app.user_middleware]
    for cls in (BearerAuth, HostOriginGuard, Cors, PrincipalLog):
        assert cls in classes, f"{cls.__name__} must be installed"
    assert app.user_middleware[0].cls is PrincipalLog    # added last = outermost: logs every guarded request
    assert next(m for m in app.user_middleware if m.cls is Cors).kwargs["allowed_origins"] is None
    assert next(m for m in app.user_middleware if m.cls is BearerAuth).kwargs["auth"].enabled is False
    monkeypatch.setenv("DIGUP_SERVER_READ_TOKENS", "nc-a:tokA")
    monkeypatch.setenv("DIGUP_SERVER_ALLOWED_ORIGINS", "http://nc.example")
    app = create_app(EngineConfig(index="/nonexistent-index", roots=("/nonexistent-root",)))
    assert next(m for m in app.user_middleware
                if m.cls is Cors).kwargs["allowed_origins"] == frozenset({"http://nc.example"})
    assert next(m for m in app.user_middleware
                if m.cls is BearerAuth).kwargs["auth"].readers == {"nc-a": "tokA"}


# ── the embed widget: the same UI rules as the full UI, over the same static mount ──────

def embed_client():
    from digup_server.api import create_app
    from digup_server.engine import EngineConfig
    return TestClient(create_app(EngineConfig(index="/nonexistent-index",
                                              roots=("/nonexistent-root",))))


def test_the_embed_page_is_served_and_dependency_free():
    client = embed_client()
    page = client.get("/embed.html")
    assert page.status_code == 200
    html = page.text
    assert "DigUp" in html and "embed.js" in html and "embed.css" in html
    assert not re.search(r'(src|href)="(https?:)?//', html), "the widget must load no external URLs"
    # The built shape (2026-11-08 migration): ES-module entry, and the shared measured
    # palette rides with the widget's own CSS graph (Vite extracts the tokens into a
    # hashed stylesheet the html links — the widget page stays self-contained).
    assert re.search(r'type="module"', html)
    assert re.search(r'href="\./(assets/[^"]+\.css)"', html)
    assert 'name="referrer" content="none"' in html         # no referrer leaves the widget
    for asset in ("/embed.css", "/embed.js"):
        assert client.get(asset).status_code == 200
    # the shared static mount decorates every embed byte the same way (no stale UI)
    assets = ["/embed.html", "/embed.css", "/embed.js"]
    assets += ["/" + p for p in re.findall(r'href="\./((?:chunks|assets)/[^"]+)"', html)]
    for asset in assets:
        reply = client.get(asset)
        assert reply.status_code == 200, asset
        assert reply.headers["cache-control"] == "no-cache", asset
        assert "etag" in reply.headers, asset


def test_the_embed_widget_uses_the_published_api_and_hides_the_token():
    # The widget's bundle: the embed entry plus the chunks its html links (the api
    # service is a shared module — the pins below name the rules, and the rules are
    # tested as behavior in src/embed.test.js / src/services/api.test.js).
    client = embed_client()
    html = client.get("/embed.html").text
    js = client.get("/embed.js").text + "\n" + "\n".join(
        client.get("/" + p).text for p in re.findall(r'href="\./((?:chunks|assets)/[^"]+\.js)"', html))
    assert "fetch(" in js and "/api/v1/search" in js and "/api/v1/embed_ahead" in js
    # embed.html DECLARES the widget; the entry wires that element (the double-mount
    # bug — an unwired twin above the working widget — is pinned out, 2026-11-08).
    assert html.count("<digup-embed></digup-embed>") == 1
    assert 'document.querySelector("digup-embed")' in js
    assert "media_id" in js and "/preview" in js and "/file" in js   # server-issued handles
    assert "sessionStorage" in js and "history.replaceState" in js   # the token leaves the URL
    assert "URL.createObjectURL" in js and "IntersectionObserver" in js
    assert "postMessage" in js and "digup-host" in js                # the host drives the theme
    assert "embed_ahead" in js and "meaning" in js                   # keyword-first typing
    assert 'This DigUp server asks for its read token' in js          # 401 asks once


# ── the token map over the REAL API + engine: what the Nextcloud app's calls do ──────────

def test_estimate_argv_carries_the_excludes_the_job_will_honour():
    """Stage-12 §11.3, measured on the Nextcloud pilot: the forecast must describe the
    tree the indexer WOULD walk. An estimate that counted the folders the job excludes
    promised work nobody will do (the pilot counted 120 with 36 real files)."""
    from digup_server.engine import EngineConfig
    cfg = EngineConfig(index="/idx", roots=("/media/photos",), excluded=("/media/photos/appdata_x",),
                       excluded_extensions=("heic",))
    argv = cfg.estimate_argv()
    assert argv[:3] == ["digup", "estimate", "/media/photos"]
    assert argv.count("--exclude") == 1 and "--exclude" in argv
    assert argv[argv.index("--exclude") + 1] == "/media/photos/appdata_x"
    assert argv[argv.index("--exclude-ext") + 1] == "heic"
    assert argv[-1] == "--json"
    plain = EngineConfig(index="/idx", roots=("/r",)).estimate_argv()
    assert "--exclude" not in plain and "--exclude-ext" not in plain   # knobs inert when unset
    # Measured 2026-11-08 on the pilot: the job path was the gap — index-service ran with
    # no excludes and walked the tree's appdata (1.47M preview files) while estimate
    # (carrying them) reported 131,972. The job must carry the SAME list.
    job = cfg.index_argv()
    assert job[:3] == ["digup", "index-service", "/media/photos"]
    assert job.count("--exclude") == 1 and job.count("--exclude-ext") == 1
    assert job[job.index("--exclude") + 1] == "/media/photos/appdata_x"
    assert job[job.index("--exclude-ext") + 1] == "heic"
    plain_job = EngineConfig(index="/idx", roots=("/r",)).index_argv()
    assert "--exclude" not in plain_job and "--exclude-ext" not in plain_job


def test_the_map_protects_the_real_api_end_to_end(corpus, index, monkeypatch):
    from conftest import _cfg
    from digup_server.api import create_app
    monkeypatch.setenv("DIGUP_SERVER_READ_TOKENS", "nc-a:tokA,nc-b:tokB")
    monkeypatch.setenv("DIGUP_SERVER_ADMIN_TOKEN", "adm")
    with TestClient(create_app(_cfg(index, (corpus,)))) as c:
        assert c.get("/api/v1/health").status_code == 200          # health: open, always
        assert c.post("/api/v1/search", json={"q": "wakeboarding"}).status_code == 401
        for token in ("tokA", "tokB"):
            reply = c.post("/api/v1/search", json={"q": "wakeboarding", "limit": 3},
                           headers={"Authorization": f"Bearer {token}"})
            assert reply.status_code == 200 and reply.json()["hits"]
            assert c.post("/api/v1/index",
                          headers={"Authorization": f"Bearer {token}"}).status_code == 403
            assert c.get("/api/v1/media/deadbeefcafe/preview",
                         headers={"Authorization": f"Bearer {token}"}).status_code == 404
        # POST /index with the admin token starts a real writer job on the session index —
        # that path is pinned end-to-end in test_jobs.py over a scratch index, not here.
        assert c.post("/api/v1/estimate", json={},
                      headers={"Authorization": "Bearer adm"}).status_code == 200
        assert c.post("/api/v1/estimate", json={}).status_code == 401
        assert c.get("/api/v1/jobs", headers={"Authorization": "Bearer tokA"}).status_code == 200
