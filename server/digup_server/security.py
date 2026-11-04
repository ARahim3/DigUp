"""Explicit Host and Origin validation — opt-in, off by default (docs/implementation/README.md §7).

The default deployment is loopback-only and has no auth, so nothing here changes its behavior:
the guard engages only when the operator names the hosts it serves
(`DIGUP_SERVER_ALLOWED_HOSTS`). That is the shape the multi-application future needs — a server
on a Docker network, behind a reverse proxy, in front of several clients — where a request's
`Host` and `Origin` are the only cheap, reliable signals of what the client thinks it is talking
to, and a stale `Host` is how DNS-rebinding and cache-poisoning attacks reach a localhost
service.

Two rules, both deliberately narrow:

* **Host allowlist** — when the guard is on, the URL host of every HTTP request must be one of
  the named hosts. Ports are not part of the comparison: the publish line binds the port, and
  `127.0.0.1:8787` and `127.0.0.1:9000` are the same *host* for this purpose.
* **Same-origin POSTs** — a browser sends `Origin` on state-changing requests. When it does, its
  host must equal the request's host: a page on another origin may not start a job, an estimate,
  or a reindex. A missing `Origin` is allowed on purpose (curl, Immich, Home Assistant, agents:
  non-browsers send none), and read-only GETs are not checked at all.

This module knows nothing about the engine, the config, or FastAPI: it is a plain ASGI
middleware, so its tests need no engine, no container, and no lifespan.
"""

from __future__ import annotations

import hmac
import json
from dataclasses import dataclass
from typing import Iterable

STATE_CHANGING = frozenset({"POST", "PUT", "PATCH", "DELETE"})


def allowed_hosts_from_env(env: dict[str, str]) -> frozenset[str] | None:
    """`DIGUP_SERVER_ALLOWED_HOSTS` → the normalized set, or None (= guard off).

    Empty/unset means off: a localhost-only deployment validates nothing it was not asked to.
    There is no wildcard on purpose — a list is the point.
    """
    raw = (env.get("DIGUP_SERVER_ALLOWED_HOSTS") or "").strip()
    if not raw:
        return None
    return frozenset(host.strip().split(":")[0].lower()
                     for host in raw.split(",") if host.strip())


def _origin_host(origin: str) -> str:
    """`http://127.0.0.1:8787` / `https://digup.lan/` → `127.0.0.1` / `digup.lan` (no port)."""
    tail = origin.split("://", 1)[-1]
    return tail.split(":")[0].split("/")[0].strip().lower()


class HostOriginGuard:
    """ASGI middleware: Host allowlist + same-origin check on state-changing methods.

    `allowed_hosts=None` is the default deployment: the middleware is installed and passes
    everything through, so enabling it is a configuration decision, not a code change.
    """

    def __init__(self, app, allowed_hosts: Iterable[str] | None = None) -> None:
        self.app = app
        self.allowed = frozenset(allowed_hosts) if allowed_hosts is not None else None

    async def __call__(self, scope, receive, send) -> None:
        if scope["type"] != "http" or self.allowed is None:
            await self.app(scope, receive, send)
            return

        headers = {k.decode("latin-1").lower(): v.decode("latin-1")
                   for k, v in scope.get("headers", [])}
        host = headers.get("host", "").split(":")[0].strip().lower()
        if host not in self.allowed:
            await _refuse(scope, send, 400,
                          f"the Host header ({headers.get('host', 'none')}) is not one of "
                          f"this server's allowed hosts")
            return

        origin = headers.get("origin")
        if (origin and scope.get("method") in STATE_CHANGING
                and _origin_host(origin) != host):
            await _refuse(scope, send, 403,
                          f"the Origin ({origin}) is not this server's own origin; "
                          "state-changing requests must come from the same host")
            return

        await self.app(scope, receive, send)


async def _refuse(scope, send, status: int, detail: str) -> None:
    """One JSON body with a `detail` string — the shape `docs/API.md` documents for errors."""
    body = json.dumps({"detail": detail}).encode("utf-8")
    headers = [(b"content-type", b"application/json"),
               (b"content-length", str(len(body)).encode("ascii"))]
    if status == 401:
        headers.append((b"www-authenticate", b"Bearer"))
    await send({"type": "http.response.start", "status": status, "headers": headers})
    await send({"type": "http.response.body", "body": body})


# ── bearer tokens: the read/admin split a multi-application deployment needs ──────────────
# Off by default, like the Host guard: a localhost server has nothing to authenticate. The
# split is the point — an Immich/Home-Assistant/agent client that may search must not be able
# to start an index job, a prune, or a full-tree estimate.

@dataclass(frozen=True)
class Auth:
    """The deployment's tokens. `read` guards every `/api/v1` endpoint; `admin` guards the
    mutating/heavy ones on top of it. Both None (the default) is no auth at all."""

    read: str | None = None
    admin: str | None = None

    @property
    def enabled(self) -> bool:
        return bool(self.read or self.admin)


# Not token-guarded, by design: the container's HEALTHCHECK calls /health with urllib and no
# credential (a guarded /health would mark a live container unhealthy), and the OpenAPI page
# is documentation, not data. Media ids, searches, counts and job state are all guarded.
OPEN_PATHS = frozenset({"/api/v1/health", "/api/v1/docs", "/api/v1/openapi.json"})

# POST endpoints that change the index or crawl the whole tree: administrative scope.
ADMIN_ROUTES = frozenset({("POST", "/api/v1/index"), ("POST", "/api/v1/estimate")})


def auth_from_env(env: dict[str, str]) -> Auth:
    """`DIGUP_SERVER_TOKEN` (read scope) and `DIGUP_SERVER_ADMIN_TOKEN` (admin scope)."""
    return Auth(read=(env.get("DIGUP_SERVER_TOKEN") or None),
                admin=(env.get("DIGUP_SERVER_ADMIN_TOKEN") or None))


class BearerAuth:
    """ASGI middleware for the two token scopes. Tokens are compared with
    `hmac.compare_digest`; they are configuration (compose env), never in the repo."""

    def __init__(self, app, auth: Auth | None = None) -> None:
        self.app = app
        self.auth = auth or Auth()

    async def __call__(self, scope, receive, send) -> None:
        if scope["type"] != "http" or not self.auth.enabled:
            await self.app(scope, receive, send)
            return

        path = scope.get("path", "").rstrip("/")
        if not path.startswith("/api/v1") or path in OPEN_PATHS:
            await self.app(scope, receive, send)      # the UI at /, docs, health
            return

        admin = (scope.get("method"), path) in ADMIN_ROUTES
        needed = self.auth.admin if (admin and self.auth.admin) else self.auth.read
        if needed is None:
            await self.app(scope, receive, send)      # admin-only tokens: reads stay open
            return

        supplied = _bearer(scope)
        if supplied is None:
            await _refuse(scope, send, 401, "this server asks for a bearer token")
            return
        if hmac.compare_digest(supplied, needed):
            await self.app(scope, receive, send)
            return
        if admin and self.auth.admin and hmac.compare_digest(supplied, (self.auth.read or "")):
            await _refuse(scope, send, 403,
                          "that is this server's read-scope token; indexing and estimating "
                          "need the admin token")
            return
        await _refuse(scope, send, 401, "the bearer token is not this server's token")


def _bearer(scope) -> str | None:
    for name, value in scope.get("headers", []):
        if name.decode("latin-1").lower() != "authorization":
            continue
        text = value.decode("latin-1").strip()
        scheme, _, token = text.partition(" ")
        if scheme.lower() == "bearer" and token.strip():
            return token.strip()
        return None
    return None
