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

from digup_server.security import HostOriginGuard, allowed_hosts_from_env


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
