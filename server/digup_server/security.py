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

import json
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
    await send({"type": "http.response.start", "status": status,
                "headers": [(b"content-type", b"application/json"),
                            (b"content-length", str(len(body)).encode("ascii"))]})
    await send({"type": "http.response.body", "body": body})
