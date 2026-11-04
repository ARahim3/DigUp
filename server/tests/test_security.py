"""The Host/Origin guard (server/digup_server/security.py): pure ASGI, no engine, no lifespan.

The behavior this pins is the *shape* of the opt-in: loopback default = guard off (nothing
changes for today's deployment), guard on = the named hosts only, browsers' state-changing
requests same-origin only, non-browser clients (no `Origin`) still welcome. Those are the rules
a LAN/proxy deployment must not quietly lose.
"""

from __future__ import annotations

import json

import pytest
from fastapi.testclient import TestClient

from digup_server.security import (
    Auth,
    BearerAuth,
    HostOriginGuard,
    allowed_hosts_from_env,
    auth_from_env,
)


async def echo(scope, receive, send) -> None:
    """A minimal ASGI app: answers 200 with the method and path, so a request that passes the
    guard is distinguishable from one the guard refused."""
    body = json.dumps({"ok": True, "method": scope["method"], "path": scope["path"]}).encode()
    await send({"type": "http.response.start", "status": 200,
                "headers": [(b"content-type", b"application/json")]})
    await send({"type": "http.response.body", "body": body})


def client_for(allowed: frozenset[str] | None) -> TestClient:
    return TestClient(HostOriginGuard(echo, allowed_hosts=allowed))


def test_the_guard_is_off_when_no_hosts_are_named():
    assert allowed_hosts_from_env({}) is None
    assert allowed_hosts_from_env({"DIGUP_SERVER_ALLOWED_HOSTS": "   "}) is None
    free = client_for(None)
    assert free.get("/x", headers={"Host": "anything.example"}).status_code == 200
    assert free.post("/x", headers={"Host": "anything.example",
                                    "Origin": "http://elsewhere.example"}).status_code == 200


def test_named_hosts_are_enforced_case_insensitively_without_ports():
    allowed = allowed_hosts_from_env({"DIGUP_SERVER_ALLOWED_HOSTS": "A.example, 127.0.0.1:8787"})
    assert allowed == frozenset({"a.example", "127.0.0.1"})
    guarded = client_for(allowed)
    assert guarded.get("/x", headers={"Host": "a.example"}).status_code == 200
    assert guarded.get("/x", headers={"Host": "127.0.0.1:8787"}).status_code == 200
    refused = guarded.get("/x", headers={"Host": "evil.example"})
    assert refused.status_code == 400
    assert isinstance(refused.json()["detail"], str)
    assert refused.headers["content-type"].startswith("application/json")


def test_no_wildcard_is_understood():
    """`*` is a host name here, not a wildcard: a list is the point of the setting, and a
    deployment that means "every host" leaves the setting unset."""
    assert allowed_hosts_from_env({"DIGUP_SERVER_ALLOWED_HOSTS": "*"}) == frozenset({"*"})
    assert client_for(frozenset({"*"})).get("/x", headers={"Host": "a.example"}).status_code == 400


def test_state_changing_requests_from_another_origin_are_refused():
    guarded = client_for(frozenset({"127.0.0.1"}))
    same = {"Host": "127.0.0.1:8787", "Origin": "http://127.0.0.1:8787"}
    assert guarded.post("/x", headers=same).status_code == 200
    cross = {"Host": "127.0.0.1:8787", "Origin": "http://evil.example"}
    refused = guarded.post("/x", headers=cross)
    assert refused.status_code == 403 and isinstance(refused.json()["detail"], str)
    # non-browsers send no Origin at all: curl, Immich, Home Assistant, agents
    assert guarded.post("/x", headers={"Host": "127.0.0.1:8787"}).status_code == 200
    # a read-only GET carries no Origin in browsers, and is not checked
    assert guarded.get("/x", headers={"Host": "127.0.0.1:8787",
                                      "Origin": "http://evil.example"}).status_code == 200


def test_the_api_installs_the_guard_inert_by_default():
    """create_app() always installs the middleware: the switch is configuration
    (`DIGUP_SERVER_ALLOWED_HOSTS`), never a code change. No engine is spawned by building the
    app — that happens in the lifespan — so this stays a fast unit test."""
    from digup_server.api import create_app
    from digup_server.engine import EngineConfig
    app = create_app(EngineConfig(index="/nonexistent-index", roots=("/nonexistent-root",)))
    guards = [m for m in app.user_middleware if m.cls is HostOriginGuard]
    assert len(guards) == 1
    assert guards[0].kwargs.get("allowed_hosts") is None      # unset env → guard off


# ── the bearer gate: off by default, read scope everywhere, admin scope on index/estimate ──

def auth_client(read: str | None = None, admin: str | None = None) -> TestClient:
    return TestClient(BearerAuth(echo, auth=Auth(read=read, admin=admin)))


def test_no_tokens_means_no_auth_at_all():
    assert auth_from_env({}) == Auth(read=None, admin=None)
    open_book = auth_client()
    assert open_book.post("/api/v1/index").status_code == 200
    assert open_book.get("/api/v1/search").status_code == 200


def test_read_token_covers_the_search_side_and_asks_401_first():
    guarded = auth_client(read="s3cret")
    naked = guarded.post("/api/v1/search")
    assert naked.status_code == 401
    assert naked.headers["www-authenticate"] == "Bearer"
    assert isinstance(naked.json()["detail"], str)
    ok = guarded.post("/api/v1/search", headers={"Authorization": "Bearer s3cret"})
    assert ok.status_code == 200
    assert guarded.post("/api/v1/search", headers={"Authorization": "Bearer wrong"}).status_code == 401
    assert guarded.post("/api/v1/search", headers={"Authorization": "s3cret"}).status_code == 401


def test_health_and_the_docs_page_stay_open_so_the_healthcheck_and_the_openapi_work():
    guarded = auth_client(read="s3cret", admin="adm1n")
    for path in ("/api/v1/health", "/api/v1/docs", "/api/v1/openapi.json",
                 "/", "/index.html", "/app.js"):
        assert guarded.get(path).status_code == 200, path


def test_index_and_estimate_are_admin_scope():
    both = auth_client(read="s3cret", admin="adm1n")
    assert both.post("/api/v1/index").status_code == 401
    assert both.post("/api/v1/estimate").status_code == 401
    read_only = both.post("/api/v1/index", headers={"Authorization": "Bearer s3cret"})
    assert read_only.status_code == 403            # the right token, the wrong scope
    assert "admin" in read_only.json()["detail"]
    assert both.post("/api/v1/index", headers={"Authorization": "Bearer adm1n"}).status_code == 200
    assert both.post("/api/v1/estimate", headers={"Authorization": "Bearer adm1n"}).status_code == 200
    assert both.get("/api/v1/jobs", headers={"Authorization": "Bearer s3cret"}).status_code == 200


def test_an_admin_only_deployment_leaves_search_open_to_the_shared_clients():
    """A deployment that names only the admin token is a localhost box that wants a *guard on
    its mutating endpoints*: the read side stays open for every client on the machine."""
    admin_only = auth_client(admin="adm1n")
    assert admin_only.get("/api/v1/status").status_code == 200
    assert admin_only.post("/api/v1/search").status_code == 200
    assert admin_only.post("/api/v1/index").status_code == 401
    assert admin_only.post("/api/v1/index",
                           headers={"Authorization": "Bearer adm1n"}).status_code == 200


def test_the_api_installs_the_bearer_gate_inert_by_default():
    from digup_server.api import create_app
    from digup_server.engine import EngineConfig
    app = create_app(EngineConfig(index="/nonexistent-index", roots=("/nonexistent-root",)))
    gates = [m for m in app.user_middleware if m.cls is BearerAuth]
    assert len(gates) == 1
    assert gates[0].kwargs["auth"].enabled is False
