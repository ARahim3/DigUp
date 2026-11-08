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
import os
import secrets
import sys
from dataclasses import dataclass, field
from typing import Iterable
from urllib.parse import parse_qs

from .targets import MAIN_TARGET

PRINCIPAL_LOG = logging.getLogger("digup.auth")
# uvicorn's logging config configures only `uvicorn.*` loggers: an application logger's INFO
# records die with no handler attached anywhere. The audit line is the feature, so the module
# carries its own handler (stdout — the container log). Propagation stays on (the suite's
# caplog reads through the root), and setLevel opens INFO for the audit lines.
if not PRINCIPAL_LOG.handlers:
    _handler = logging.StreamHandler(sys.stdout)
    _handler.setFormatter(logging.Formatter("%(asctime)s %(message)s", datefmt="%H:%M:%S"))
    PRINCIPAL_LOG.addHandler(_handler)
PRINCIPAL_LOG.setLevel(logging.INFO)

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
    read scope and is logged under its own name. All None/empty (the default) is no auth.
    `minted` names the entries the server issued itself (stage-13 minted keys) — the ones
    `/api/v1/tokens` may show; env-configured secrets are never in it and never echoed."""

    read: str | None = None
    admin: str | None = None
    readers: dict[str, str] = field(default_factory=dict)
    minted: tuple[str, ...] = ()

    @property
    def enabled(self) -> bool:
        return bool(self.read or self.admin or self.readers)

    def token_names(self, supplied: str) -> tuple[str, ...]:
        """Every scope this exact token serves — () when it is nobody's. `admin` covers the
        read scope too (an admin client searches like a read client). An entry named
        `app:<target>` (minted for an application target) answers for THAT target's index
        only — the bearer gate enforces the binding (BearerAuth, named indexes)."""
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
    """`DIGUP_SERVER_READ_TOKENS=nc-a:tokA,app:nc:tokB` → `{nc-a: tokA, app:nc: tokB}`.

    Names keep the FIRST entry of a duplicate; names are lowercased (the log prints them
    as given to the env). The separator is the LAST colon: names may contain colons
    (the target-bound form `app:<target>` — stage-13), tokens must not (minted tokens are
    `token_urlsafe` — alphanumeric, `-`, `_`). An entry without a colon is a typo,
    skipped — and named in a warning, because a silently-dropped token is an outage nobody
    asked for. No wildcards, no scopes beyond read: revoking one entry revokes exactly
    that client (docs/implementation/stage-12-integrations.md §11.2). Plain names guard
    the main media index; `app:<name>` guards that target's index only (BearerAuth).
    """
    raw = (env.get("DIGUP_SERVER_READ_TOKENS") or "").strip()
    readers: dict[str, str] = {}
    for entry in raw.split(","):
        entry = entry.strip()
        if not entry:
            continue
        name, sep, token = entry.rpartition(":")
        if not sep or not name.strip() or not token.strip():
            PRINCIPAL_LOG.warning("DIGUP_SERVER_READ_TOKENS: entry %r is not a 'name:token' "
                                  "pair — skipped", entry)
            continue
        readers.setdefault(name.strip().lower(), token.strip())
    return readers


# ── minted application keys (stage-13, docs/API.md "Named indexes") ──────────────────────
# When the operator registers application targets, the applications need tokens — and
# hand-writing secrets into the environment is an option, not a requirement. The server
# mints what is missing (secrets.token_urlsafe(24)), stores them in <config>/tokens.json
# (the config folder is recreation-safe, the same rule as jobs.jsonl: recreation never
# silently revokes a connected application), and shows them in the admin UI
# (GET /api/v1/tokens, admin scope only). Rules that keep the surface honest:
#   * minting fires ONLY when application targets exist — a target-less, token-less
#     standalone deployment keeps running exactly as it has, unguarded and unchanged;
#   * environment-configured secrets are never copied into the file and never echoed by
#     the API: the file records only what the server generated, /api/v1/tokens shows
#     only what the server generated;
#   * an admin key is minted too when the deployment has none — the UI needs one to show
#     the keys, and `Auth.minted` marks exactly which values are displayable.

TOKENS_FILE = "tokens.json"


def mint_tokens(env: dict[str, str], config_dir: str,
                app_target_names: tuple[str, ...], mint_admin: bool = False) -> Auth:
    """The deployment's Auth, with minted keys filled in for the app targets env left
    unbound. Restart-stable: values come from <config>/tokens.json and are re-used.

    `mint_admin` (DIGUP_SERVER_MINT_KEYS, 2026-11-08 user brief): the STANDALONE box
    mints its own API key at boot with no application registered — the gear shows it
    with Copy, an application takes it as its ticket to connect (POST /api/v1/targets
    registers one and mints its private key alongside). Main reads stay open (the
    minted shape); the key guards index/estimate/keys. Without targets and without
    the knob, minting stays inert — a plain tokenless server is unchanged."""
    auth = auth_from_env(env)
    if not app_target_names and not mint_admin:
        return auth                                   # standalone: minting inert

    path = os.path.join(config_dir, TOKENS_FILE)
    stored = _read_tokens_file(path)
    readers = dict(auth.readers)
    minted: list[str] = []

    admin = auth.admin
    if admin is None:
        # A key in the file IS a minted key (server-generated), fresh-minted or from a
        # previous boot — displayable either way, so `/api/v1/tokens` shows the keys
        # the operator never typed even after a restart.
        admin = stored.get("admin")
        if admin is None:
            admin = secrets.token_urlsafe(24)
        minted.append("admin")

    for name in app_target_names:
        key = f"app:{name}"
        if key in readers:                            # env already bound this target
            continue
        token = stored.get("readers", {}).get(key)
        if token is None:
            token = secrets.token_urlsafe(24)
        readers[key] = token
        minted.append(key)                            # server-generated: displayable

    minted_auth = Auth(read=auth.read, admin=admin, readers=readers,
                       minted=tuple(minted))
    _write_tokens_file(path, minted_auth)
    return minted_auth


def env_secrets(auth: Auth) -> bool:
    """True when the DEPLOYMENT typed any key in its environment. Minted keys
    (server-generated, `auth.minted`) are not env secrets: the user's brief of
    2026-11-08 draws the line here — a minted-key deployment guards the index
    operations and each application's own index, answers the main index's READS
    openly, and shows its minted keys to the gear (the ticket model: Copy → paste
    into the application); a deployment that typed its own secrets guards every
    API call, as before."""
    if auth.read:
        return True
    if auth.admin is not None and "admin" not in auth.minted:
        return True
    return any(name not in auth.minted for name in auth.readers)


def rotate_minted(auth: Auth, config_dir: str) -> "Auth | None":
    """Regenerate the server-issued keys (UI: Regenerate — the admin scope only).

    Minted entries — the minted admin key, the minted app keys — get fresh values,
    persisted 0600 in the keys file exactly like first minting. Environment-configured
    keys are NEVER rotated: they are the deployment's own config, and a rotate must not
    silently override it (they keep working; the response flags them configured-only).

    The rotation takes effect immediately: the old minted values die with this call, so
    every application that has one pasted loses access until the operator pastes the new
    key into it — which is exactly what the UI's confirmation asks before issuing the
    POST. Returns the new Auth (rotated values live in it), or None when nothing is
    minted — an env-configured deployment has nothing the server may rotate."""
    if not auth.minted:
        return None
    readers = dict(auth.readers)
    minted: list[str] = []
    admin = auth.admin
    if "admin" in auth.minted:
        admin = secrets.token_urlsafe(24)
        minted.append("admin")
    for name in auth.minted:
        if name.startswith("app:") and name in readers:
            readers[name] = secrets.token_urlsafe(24)
            minted.append(name)
    rotated = Auth(read=auth.read, admin=admin, readers=readers, minted=tuple(minted))
    _write_tokens_file(os.path.join(config_dir, TOKENS_FILE), rotated)
    return rotated


def _read_tokens_file(path: str) -> dict:
    try:
        with open(path, encoding="utf-8") as handle:
            raw = json.load(handle)
    except FileNotFoundError:
        return {}
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"{path}: not valid JSON ({exc}) — fix it or delete it; "
                           "the server will not mint over a corrupt keys file") from exc
    return raw if isinstance(raw, dict) else {}


def _write_tokens_file(path: str, auth: Auth) -> None:
    """Persist ONLY minted values, atomically, 0600 (the keys file holds secrets).
    The config folder is the server's own to create — minting runs at startup, before
    any job has made it (the deployment bind-mounts it, a test tmp dir may not exist)."""
    payload = {}
    if "admin" in auth.minted and auth.admin:
        payload["admin"] = auth.admin
    readers = {name: auth.readers[name] for name in auth.minted
               if name.startswith("app:") and name in auth.readers}
    if readers:
        payload["readers"] = readers
    existing = _read_tokens_file(path)
    merged = {**{k: v for k, v in existing.items() if k in ("admin", "readers")}, **payload}
    union = {**(existing.get("readers") or {}), **(payload.get("readers") or {})}
    if union:
        merged["readers"] = union
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    tmp = path + ".new"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(merged, handle)
    os.replace(tmp, path)
    os.chmod(path, 0o600)


def query_target(scope) -> str | None:
    """The target a request explicitly addresses (`?target=name`); None when it does not."""
    params = parse_qs(scope.get("query_string", b"").decode("latin-1"))
    value = (params.get("target") or [""])[0].strip()
    return value or None


class BearerAuth:
    """ASGI middleware for the token scopes. Tokens are compared with
    `hmac.compare_digest`; they are configuration (compose env) or minted keys
    (`mint_tokens`), never in the repo. The request's accepted principal (`read`, a map
    name, `admin`) lands on the scope for PrincipalLog — an admin token answers the read
    scope too, so its principal is recorded with the admin scope it presents.

    Named indexes (stage-13): every request addresses a TARGET. `?target=name` names
    it explicitly; the default is the main media index — except for an app-bound
    token, whose default is its OWN target (the binding is what the token carries,
    so an application calls plain paths). The gate binds tokens to targets: `admin`
    answers every target; `read` and plain named tokens answer the main media index
    (that is what they were before this feature existed — their behavior is
    unchanged); an `app:<name>` token answers the named target's index and NOTHING
    else — on any other target it is refused. The resolved target lands on the scope
    (`digup.target`) for the endpoints, and mutating routes (index/estimate) accept
    an app token only for its own target: an application can queue work on its own
    index, never on anyone else's."""

    def __init__(self, app, auth: Auth | None = None) -> None:
        self.app = app
        self.auth = auth or Auth()

    def _env_secrets(self) -> bool:
        return env_secrets(self.auth)

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
            if not admin and not self._env_secrets() \
                    and query_target(scope) in (None, MAIN_TARGET):
                # Minted-key deployment, no key presented: the main index answers its
                # reads to the operator's own browser — the main page searches with no
                # key. Index/estimate and application targets keep needing keys.
                scope["digup.principal"] = "none"
                scope["digup.target"] = MAIN_TARGET
                await self.app(scope, receive, send)
                return
            await _refuse(scope, send, 401, "this server asks for a bearer token")
            return
        names = self.auth.token_names(supplied)
        if not names:
            await _refuse(scope, send, 401, "the bearer token is not this server's token")
            return

        requested = query_target(scope)
        app_target = next((n[4:] for n in names if n.startswith("app:")), None)
        # An app-bound token addresses ITS OWN target by default — the binding is what
        # the token carries, so the bridge calls plain paths (/search, /index). An
        # explicit `?target=` it does not match is refused below.
        target = app_target if (app_target is not None and requested is None) \
            else (requested or MAIN_TARGET)
        if target == MAIN_TARGET:
            # The main media index: admin, `read`, and plain named tokens answer it —
            # the pre-stage-13 contract, unchanged. Only an app-BOUND token is refused
            # here: it was minted for one application's own index (the `app:<name>` form).
            if app_target is not None:
                await _refuse(scope, send, 403,
                              "that token answers the application's own index; the media "
                              "index needs this server's read or admin token")
                return
        elif not ("admin" in names or app_target == target):
            await _refuse(scope, send, 403,
                          f"target {target!r} is answered by its own application token "
                          "(or the admin token) — not by this one")
            return

        if admin and "admin" not in names:
            # Mutating routes: admin always; an app token for its OWN target queues its
            # own crawl (the application's bridge indexes its own index, stage-13).
            if app_target is not None and app_target == target:
                scope["digup.principal"] = f"app:{app_target}"
                scope["digup.target"] = target
                await self.app(scope, receive, send)
                return
            await _refuse(scope, send, 403,
                          "that is this server's read-scope token; indexing and estimating "
                          "need the admin token")
            return

        if admin:
            scope["digup.principal"] = "admin"
        elif "admin" in names:
            scope["digup.principal"] = "admin (read scope)"   # an admin token on the read side
        else:
            scope["digup.principal"] = names[0]               # read, named, app:<target>
        scope["digup.target"] = target
        await self.app(scope, receive, send)


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
                # `target=` rides only when the bearer gate resolved one (named indexes,
                # stage 13): with several indexes on one server, the audit line says
                # WHICH index the principal asked.
                target = scope.get("digup.target")
                PRINCIPAL_LOG.info("%s %s -> %s principal=%s%s",
                                   scope.get("method", "?"), path, state["status"],
                                   scope.get("digup.principal", "none"),
                                   f" target={target}" if target else "")


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
