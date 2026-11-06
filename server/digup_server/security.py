"""Explicit Host/Origin validation, bearer scopes with a named-token map, and a CORS
allowlist — all opt-in, off by default (docs/implementation/README.md §7, stage-12).

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
import logging
from dataclasses import dataclass, field
from typing import Iterable

PRINCIPAL_LOG = logging.getLogger("digup.auth")

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


def allowed_origins_from_env(env: dict[str, str]) -> frozenset[str] | None:
    """`DIGUP_SERVER_ALLOWED_ORIGINS` → the exact set, or None (= CORS off).

    Entries are exact origins — scheme, host and (non-default) port alike, since the browser's
    `Origin` header is exactly that: `http://nextcloud.lan:8081`. A deployment built on wildcards
    can express them here. Empty/unset means off: a same-origin deployment
    (the UI, server-to-server clients: PHP, curl, agents) sends no `Origin` on the requests it
    makes and needs no CORS at all.
    """
    raw = (env.get("DIGUP_SERVER_ALLOWED_ORIGINS") or "").strip()
    if not raw:
        return None
    return frozenset(o.strip().lower().rstrip("/")
                     for o in raw.split(",") if o.strip())


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
        # A cross-origin, state-changing POST is refused — unless the Cors middleware (installed
        # outside this guard) has already answered its preflight: only a browser whose exact
        # origin the operator allowlisted reaches this point with the flag set, the browser sends
        # the bearer `Authorization` header only because this server's CORS said yes, and no
        # browser attaches an Authorization header cross-site on its own. The same-origin rule
        # defends cookie-authed CSRF; this API is cookie-free (§7), so the allowlist is the
        # boundary for the in-browser widgets (docs/implementation/stage-12-integrations.md).
        if (origin and scope.get("method") in STATE_CHANGING
                and not scope.get("digup.cors_allowed")
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


# ── CORS allowlist: exact origins only, off by default (stage-12) ────────────────────────
# The server's own UI is same-origin and needs none of this; server-to-server clients send
# no Origin at all. This exists for the in-browser widgets — the embed page hosted by this
# server, embedded by a host application (Nextcloud / Immich workspaces) that runs the page
# in the user's browser. The allowlist IS the security boundary there: a cross-site page
# can read a response only when its exact origin is listed, and the bearer header rides
# along only because the browser was told this server allows it.

class Cors:
    """ASGI middleware: preflight answers + response decoration for allowlisted origins.

    `allowed_origins=None` (the default) passes everything through, header-free. On a
    preflight (`OPTIONS` with an allowlisted `Origin`) it answers 204 with the grant and
    never touches the inner app. On a request from an allowlisted origin it marks the
    scope (`digup.cors_allowed` — the guard's cross-origin POST exception) and decorates
    the response with `access-control-allow-origin`. No `Origin`, no decoration:
    server-to-server is what it always was.
    """

    def __init__(self, app, allowed_origins: Iterable[str] | None = None) -> None:
        self.app = app
        self.allowed = frozenset(allowed_origins) if allowed_origins is not None else None

    async def __call__(self, scope, receive, send) -> None:
        if scope["type"] != "http" or self.allowed is None:
            await self.app(scope, receive, send)
            return

        headers = {k.decode("latin-1").lower(): v.decode("latin-1")
                   for k, v in scope.get("headers", [])}
        origin = (headers.get("origin") or "").strip().lower().rstrip("/")
        if origin not in self.allowed:
            await self.app(scope, receive, send)
            return

        if scope.get("method") == "OPTIONS":
            body = b""
            await send({"type": "http.response.start", "status": 204, "headers": [
                (b"access-control-allow-origin", origin.encode("latin-1")),
                (b"access-control-allow-methods", b"POST, GET, OPTIONS"),
                (b"access-control-allow-headers", b"authorization, content-type"),
                (b"access-control-max-age", b"600"),
                (b"vary", b"Origin"),
                (b"content-length", b"0"),
            ]})
            return

        scope["digup.cors_allowed"] = True

        async def _decorate(message: dict) -> None:
            if message["type"] == "http.response.start":
                message = {**message, "headers": [
                    *message["headers"],
                    (b"access-control-allow-origin", origin.encode("latin-1")),
                    (b"vary", b"Origin"),
                ]}
            await send(message)

        await self.app(scope, receive, _decorate)


# ── bearer tokens: the read/admin split a multi-application deployment needs ──────────────
# Off by default, like the Host guard: a localhost server has nothing to authenticate. The
# split is the point — an Immich/Home-Assistant/agent client that may search must not be able
# to start an index job, a prune, or a full-tree estimate. On top of the split, a NAMED TOKEN
# MAP (`DIGUP_SERVER_READ_TOKENS=name:token,…`) lets one server answer several deployments —
# several Nextcloud instances, dashboard tiles — each with its own revocable secret, each
# attributable in the access log (PrincipalLog).

@dataclass(frozen=True)
class Auth:
    """The deployment's tokens. `read` guards every `/api/v1` endpoint; `admin` guards the
    mutating/heavy ones on top of it. `readers` is the named map: every entry guards the same
    read scope and is logged under its own name. All None/empty (the default) is no auth."""

    read: str | None = None
    admin: str | None = None
    readers: dict[str, str] = field(default_factory=dict)

    @property
    def enabled(self) -> bool:
        return bool(self.read or self.admin or self.readers)

    def token_names(self, supplied: str) -> tuple[str, ...]:
        """Every scope this exact token serves — () when it is nobody's. `admin` covers the
        read scope too (an admin client searches like a read client)."""
        names: list[str] = []
        if self.admin is not None and hmac.compare_digest(supplied, self.admin):
            return ("admin",)
        if self.read is not None and hmac.compare_digest(supplied, self.read):
            names.append("read")
        for name, token in self.readers.items():
            if hmac.compare_digest(supplied, token):
                names.append(name)
        return tuple(names)


# Not token-guarded, by design: the container's HEALTHCHECK calls /health with urllib and no
# credential (a guarded /health would mark a live container unhealthy), and the OpenAPI page
# is documentation, not data. Media ids, searches, counts and job state are all guarded.
OPEN_PATHS = frozenset({"/api/v1/health", "/api/v1/docs", "/api/v1/openapi.json"})

# POST endpoints that change the index or crawl the whole tree: administrative scope.
ADMIN_ROUTES = frozenset({("POST", "/api/v1/index"), ("POST", "/api/v1/estimate")})


def auth_from_env(env: dict[str, str]) -> Auth:
    """`DIGUP_SERVER_TOKEN` (read scope), `DIGUP_SERVER_ADMIN_TOKEN` (admin scope) and
    `DIGUP_SERVER_READ_TOKENS` (the named read map: `name:token` pairs, comma-separated)."""
    return Auth(read=(env.get("DIGUP_SERVER_TOKEN") or None),
                admin=(env.get("DIGUP_SERVER_ADMIN_TOKEN") or None),
                readers=read_tokens_from_env(env))


def read_tokens_from_env(env: dict[str, str]) -> dict[str, str]:
    """`DIGUP_SERVER_READ_TOKENS=nc-a:tokA,nc-b:tokB` → `{nc-a: tokA, nc-b: tokB}`.

    Names keep the FIRST entry of a duplicate, values keep the FIRST token seen for a name;
    names are lowercased (the log prints them as given to the env). An entry without a colon
    is a typo, skipped — and named in a warning, because a silently-dropped token is an outage
    nobody asked for. No wildcards, no scopes beyond read: revoking one entry revokes exactly
    that client (docs/implementation/stage-12-integrations.md §11.2).
    """
    raw = (env.get("DIGUP_SERVER_READ_TOKENS") or "").strip()
    readers: dict[str, str] = {}
    for entry in raw.split(","):
        entry = entry.strip()
        if not entry:
            continue
        name, sep, token = entry.partition(":")
        if not sep or not name.strip() or not token.strip():
            PRINCIPAL_LOG.warning("DIGUP_SERVER_READ_TOKENS: entry %r is not a 'name:token' "
                                  "pair — skipped", entry)
            continue
        readers.setdefault(name.strip().lower(), token.strip())
    return readers


class BearerAuth:
    """ASGI middleware for the token scopes. Tokens are compared with
    `hmac.compare_digest`; they are configuration (compose env), never in the repo. The
    request's accepted principal (`read`, a map name, `admin`) lands on the scope for
    PrincipalLog — an admin token answers the read scope too, so its principal is recorded
    with the admin scope it presents."""

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
        if not self.auth.read and not self.auth.readers and not (admin and self.auth.admin):
            await self.app(scope, receive, send)      # admin-only tokens: reads stay open
            return

        supplied = _bearer(scope)
        if supplied is None:
            await _refuse(scope, send, 401, "this server asks for a bearer token")
            return
        names = self.auth.token_names(supplied)
        if admin:
            if "admin" in names:
                scope["digup.principal"] = "admin"
                await self.app(scope, receive, send)
                return
            if names:
                await _refuse(scope, send, 403,
                              "that is this server's read-scope token; indexing and estimating "
                              "need the admin token")
                return
        elif names:
            scope["digup.principal"] = "admin (read scope)" if "admin" in names else names[0]
            await self.app(scope, receive, send)
            return
        await _refuse(scope, send, 401, "the bearer token is not this server's token")


class PrincipalLog:
    """Access-log attribution: one line per guarded API request, naming the principal the
    bearer gate accepted — `read`, a `DIGUP_SERVER_READ_TOKENS` name, `admin`, or `none`.

    The point is the map: when one server answers several Nextcloud instances, a log line
    says WHICH instance asked. Installed always; it answers for unguarded deployments too
    (principal=none), so the audit trail never depends on auth being on.
    """

    def __init__(self, app) -> None:
        self.app = app

    async def __call__(self, scope, receive, send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        path = scope.get("path", "").rstrip("/")
        if not path.startswith("/api/v1") or path in OPEN_PATHS:
            await self.app(scope, receive, send)      # health/docs: noise, not audits
            return

        state = {"status": None}

        async def _watch(message: dict) -> None:
            if message["type"] == "http.response.start":
                state["status"] = message["status"]
            await send(message)

        try:
            await self.app(scope, receive, _watch)
        finally:
            if state["status"] is not None:
                PRINCIPAL_LOG.info("%s %s -> %s principal=%s",
                                   scope.get("method", "?"), path, state["status"],
                                   scope.get("digup.principal", "none"))


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
