"""The HTTP surface: FastAPI on `/api/v1`, sitting **on top of** the adapter, never around it.

Rules this file lives by (docs/implementation/README.md §6, §7, §10.2):

* Every answer is the engine's. Hits, `strong`, `meaning`, `ms`, `warning` pass through
  verbatim; "no good matches" stays an empty list; engine failures become 5xx bodies that
  quote the engine (with its stderr tail), never a server-invented explanation.
* `/api/v1` from day one; Pydantic models; OpenAPI comes free with FastAPI.
* The API process is the long-lived parent of every helper (ParentWatch, §15 item 8):
  the search-service is spawned as a direct child of uvicorn — never through a PID-1
  shell wrapper (`docker run --init` in dev; the runtime image carries `tini`), and
  `quit()` on shutdown. Indexing (Stage 5) arrives on the same supervision.
* Binds `127.0.0.1:8787` by default. In a container, bind `0.0.0.0` inside and publish
  `127.0.0.1:8787:8787` on the host — the port is reachable from the loopback only.

Configuration comes from the environment (see `.env.example`): index folder, media roots
(pathsep-separated), model folder, binary. No path ever arrives from a client.
"""

from __future__ import annotations

import contextlib
import hmac
import json
import os
import re
import secrets
import stat
import threading
import time
import uuid
from collections import OrderedDict
from collections.abc import AsyncIterator
from dataclasses import dataclass
from pathlib import Path
from typing import Literal
from urllib.parse import quote

import uvicorn
from fastapi import FastAPI, HTTPException, Query, Request
from fastapi.responses import FileResponse, Response, StreamingResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, ConfigDict, Field

from .engine import EngineConfig, SearchService
from .engine.cli import CLIError, estimate_lines, status as cli_status
from .engine.protocol import EngineExited, EngineRefused
from .jobs import JOB_LOG, JobBusy, JobRunner
from .security import (Auth, Cors, HostOriginGuard, PrincipalLog, TOKENS_FILE, _bearer,
                       _write_tokens_file, allowed_hosts_from_env, allowed_origins_from_env,
                       BearerAuth, env_secrets, mint_tokens, rotate_minted)
from .targets import MAIN_TARGET, Target, build_registry, _validated

# The engine's FileKind rawValues (Sources/DigUpKit FileKind): the API refuses anything
# else with a 422 — the engine would silently drop it, and silence is not honesty.
Kind = Literal["screenshot", "image", "pdf", "doc", "audio", "video", "code"]

DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8787


class UIFiles(StaticFiles):
    """The UI with `cache-control: no-cache` on every answer (etag in, 304 out — cheap).

    UI files are small and they change with every deploy; a cached panel is the difference
    between the fixed page and the broken one. Measured, not theorized: without the header,
    Chrome answered reloads from its memory cache for minutes, serving a stylesheet the
    server no longer had. Revalidation on every load is what makes an upgrade land."""

    async def get_response(self, path: str, scope):
        response = await super().get_response(path, scope)
        response.headers.setdefault("cache-control", "no-cache")
        return response


# ── the wire shape (the engine's fields, typed, not invented) ──────────────────────────


class SearchRequest(BaseModel):
    """One query, as `search-service` takes it. The UI types `q` on every keystroke and
    sends `embed_ahead` alongside; `meaning: false` is the keyword-only path while the
    encoder is cold."""

    q: str = Field(max_length=512)
    kinds: list[Kind] | None = None
    # 40 is the engine's own default (`SearchService.swift:130`): a client that names no
    # limit gets the engine's answer, not a shorter one — the server adds no cap of its own.
    # The UI's own default is 40 too (the desktop panel's row count), sent explicitly.
    limit: int = Field(default=40, ge=1, le=100)
    code: bool = False
    meaning: bool = True
    prefix_last: bool = False


class SearchReply(BaseModel):
    """The engine's reply minus the request `id` (protocol bookkeeping, not the API's).
    Each hit carries `media_id` — the server's handle for `/media/{id}/…`, documented
    here; every engine field passes through untouched — `extra="allow"` says an engine
    field this model has never seen is published, not dropped at the boundary."""

    model_config = ConfigDict(extra="allow")

    hits: list[dict]          # exactly hitFields(): path, kind, segment, segment_id, score,
                              # modified, size, info (+ z, cosine, keyword_rank, loc, loc_end…)
    strong: int
    meaning: bool
    ms: dict
    warning: str | None = None


class EstimateRequest(BaseModel):
    """Empty for now: roots come from the server's configuration, never from a client
    (README §7: no arbitrary path acceptance). Multi-root is a Stage-5/6 decision."""


class IndexRequest(BaseModel):
    """An empty body is a plain sync: the job walks the server's configured roots; a
    client never names paths, folders, or limits. `prune: true` also retires index rows
    for files no longer found under those roots — the engine's own `--prune`
    (IndexService). It is the documented procedure after remounting media: stale ghost
    rows keep counting in `files`/`vectors` and dilute the z-normalization of live hits.
    Progress is the engine's, read via `GET /jobs/{id}`."""

    prune: bool = False


class EmbedAheadRequest(BaseModel):
    """The typist's text so far: the engine embeds and caches it, so the pause's vector
    is ready when the next `search` arrives (the desktop panel's own trick)."""

    q: str = Field(max_length=512)
    code: bool = False


class TargetRegister(BaseModel):
    """An application registering its own index at a running server (stage 14, the
    user's flow: the standalone mints its API key; the application brings that key to
    `POST /api/v1/targets` and gets its OWN minted key + its OWN index folder, which
    the server crawls in the background, invisible to the main page)."""

    model_config = ConfigDict(extra="forbid")

    name: str = Field(min_length=1, max_length=64)
    roots: list[str] = Field(min_length=1, max_length=32)
    index: str | None = None


def _strip(reply: dict) -> dict:
    """Drop the protocol `id`; keep every field the engine produced, in its own words."""
    return {k: v for k, v in reply.items() if k != "id"}


# ── media/file helpers: content sniffed from the bytes, ranges honored, nothing executed ────
# The type a browser is told must match what the file *is* (magic bytes), and code/text is
# always text/plain: serving a source-named .html/.svg as markup would run script from the
# user's own files on the server's origin. Unknown types are application/octet-stream.

_MAGIC = [
    (b"\xff\xd8\xff", "image/jpeg"),
    (b"\x89PNG\r\n\x1a\n", "image/png"),
    (b"GIF87a", "image/gif"),
    (b"GIF89a", "image/gif"),
    (b"%PDF", "application/pdf"),
    (b"ID3", "audio/mpeg"),
    (b"\x00\x00\x01\xb3", "audio/mpeg"),      # MPEG audio frame sync (mp1/mp2)
    (b"\x1a\x45\xdf\xa3", "video/x-matroska"),
    (b"OggS", "audio/ogg"),
    (b"fLaC", "audio/flac"),
    (b"RIFF", "audio/wav"),                   # WAVE; AVI (RIFF AVI ) becomes octet-stream
    (b"BM", "image/bmp"),
]

# Kind rawValues that are pixels/sound/playable: served inline so the browser opens them;
# doc/code/etc. arrive as an attachment, and code's *content* is text/plain (see above).
_INLINE_KINDS = frozenset({"image", "screenshot", "video", "audio", "pdf"})

_RANGE = re.compile(r"bytes=(\d*)-(\d*)\Z")

# Hard cap on one served span: `Range: bytes=0-` is what every browser media element
# sends first, and an uncapped open range reads the WHOLE file into RAM (a 20 GB clip
# asks for a 20 GB buffer). Seeking only ever needs short spans; 8 MiB is generous.
MAX_RANGE_SPAN = 8 << 20


def sniff_type(path: Path) -> str:
    with open(path, "rb") as handle:
        head = handle.read(16)
    if head[4:8] == b"ftyp":                      # ISO-BMFF: box size 0-3, "ftyp" at 4-8 —
        brand = head[8:12]                        # the brand at 8-12 is what it IS (mp4/m4a/…)
        if brand in (b"M4A ", b"M4B ", b"M4P "):
            return "audio/mp4"
        if brand in (b"isom", b"iso2", b"iso4", b"iso6", b"avc1", b"mp41", b"mp42", b"qt  "):
            return "video/mp4"
        return "application/octet-stream"         # an ftyp we do not know: not a guess
    for magic, media_type in _MAGIC:
        if head.startswith(magic):
            if media_type.startswith(("audio/", "video/")):
                if media_type == "audio/wav" and head[8:12] != b"WAVE":
                    return "application/octet-stream"
                if media_type == "video/avi" and head[8:12] != b"AVI ":
                    return "application/octet-stream"
            return media_type
    return "application/octet-stream"


def parse_range(header: str | None, size: int) -> tuple[int, int] | None:
    """`Range: bytes=a-b` (single range) → (a, b) clamped, or 416 as ("unsatisfiable", size)
    for an out-of-range request; None when there is no range to honor. Suffix ranges
    (`bytes=-500`) mean the last 500 bytes; open ranges (`bytes=100-`) run to the end.
    `If-Range` is deliberately not honored: a 304 would teach the UI nothing about the
    file, and video seeking never sends it (the engine's previews are the pixels' source)."""
    if header is None:
        return None
    match = _RANGE.match(header.strip())
    if not match:
        return None                              # a multi-range or an unknown unit: plain 200
    start_s, end_s = match.groups()
    if not start_s and not end_s:
        return None
    if not start_s:                              # suffix range: last N bytes
        length = min(int(end_s), MAX_RANGE_SPAN)
        if length == 0:
            return ("unsatisfiable", size)
        start, end = max(0, size - length), size - 1
    else:
        start = int(start_s)
        end = int(end_s) if end_s else size - 1
        end = min(end, size - 1, start + MAX_RANGE_SPAN - 1)   # open + huge ranges capped
        if start >= size or start > end:
            return ("unsatisfiable", size)
    return (start, end)


class StatusCache:
    """The CLI's identity answers, served from a short TTL.

    `digup status` per call is real SQLite counting work. The UI polls `/status` every
    15 s and the container HEALTHCHECK hits `/health` every 30 s — each poll used to
    spawn a `digup status`, on the writer's hot index. The identity fields (fingerprints,
    build tag, per-kind table) move slowly, so the polls stop costing a subprocess each.

    `fetch` is injectable (the unit test counts calls); the app wires the real
    `cli_status`. TTL comes from `DIGUP_SERVER_STATUS_TTL_S`.
    """

    def __init__(self, fetch, ttl_s: float = 15.0):
        self._fetch = fetch
        self._ttl_s = ttl_s
        self._lock = threading.Lock()
        self._by_key: dict[str, tuple[float, dict]] = {}

    def get(self, config) -> dict:
        """Cached per index folder: with named indexes (stage-13) one cache answers
        several targets, and one target's counts must never be served for another."""
        key = str(config)
        with self._lock:
            now = time.monotonic()
            stamp = self._by_key.get(key)
            if stamp is None or now - stamp[0] > self._ttl_s:
                data = self._fetch(config)
                self._by_key[key] = (now, data)
                return data
            return stamp[1]


class HitCache:
    """Server-issued handles for the hits it published — the media endpoints accept ONLY
    these ids (README §6: "ids from the index, never paths from the client"). A bounded
    LRU: the handles live as long as a browsing session needs, and no more.

    This is the server's own bookkeeping, not an engine field: `media_id` is documented
    as the server's handle, and every path it resolves was produced by the engine.
    """

    def __init__(self, capacity: int = 1024):
        self._items: OrderedDict[str, dict] = OrderedDict()
        self._lock = threading.Lock()
        self._capacity = capacity

    def put(self, path: str, kind: str, segment_id: int, loc: float | None, code: bool) -> str:
        media_id = uuid.uuid4().hex[:12]
        with self._lock:
            self._items[media_id] = {"path": path, "kind": kind, "segment_id": segment_id,
                                     "loc": loc, "code": code}
            while len(self._items) > self._capacity:
                self._items.popitem(last=False)
        return media_id

    def get(self, media_id: str) -> dict | None:
        with self._lock:
            entry = self._items.get(media_id)
            if entry is None:
                return None
            self._items.move_to_end(media_id)   # a true LRU: get() refreshes. Without this
            return dict(entry)                  # the eviction was insertion-order, and a
                                              # browsing session (40 handles per search)
                                              # evicted its own on-screen thumbnails after
                                              # ~26 keystroke-searches — 404s with no recovery


def config_from_env() -> EngineConfig:
    """The server's engine, from the environment — the only place paths are chosen."""
    index = os.environ["DIGUP_SERVER_INDEX"]
    roots = tuple(r for r in os.environ.get("DIGUP_SERVER_ROOTS", "").split(os.pathsep) if r)
    if not roots:
        raise RuntimeError("DIGUP_SERVER_ROOTS: at least one media root is required")
    excluded = tuple(r for r in os.environ.get("DIGUP_SERVER_EXCLUDE", "").split(os.pathsep) if r)
    return EngineConfig(
        index=index,
        roots=roots,
        binary=os.environ.get("DIGUP_SERVER_BINARY", "digup"),
        excluded=excluded,
        excluded_extensions=tuple(
            e for e in os.environ.get("DIGUP_SERVER_EXCLUDE_EXT", "").split(",") if e),
        models_dir=os.environ.get("DIGUP_SERVER_MODELS"),
        encoder_idle=float(os.environ.get("DIGUP_SERVER_ENCODER_IDLE", "300")),
    )


def create_app(config: EngineConfig) -> FastAPI:
    """The app over supervised search-services — one per named index (stage-13).

    The main media index (`media`, the deployment's own roots + index folder) behaves
    exactly as it always has. Application targets (targets.py) are additional
    (roots, index) pairs with their own search-service child, their own job runner
    (their own flock beside their own index, their own jobs log), supervised lazily:
    a target's machinery spawns on the first request that addresses it, so a server
    with registered targets and no traffic to them costs exactly one engine.
    `hit_cache` issues the media handles (§6: ids, never client paths) across all
    targets — paths are absolute; the target owning a path is resolved from the
    registry. The bearer gate binds tokens to targets (security.BearerAuth), so an
    application answers for its own index only."""

    config_dir = os.environ.get("DIGUP_SERVER_CONFIG") or os.path.join(config.index, "server-config")
    registry = build_registry(os.environ, main_roots=config.roots,
                              main_index=config.index, config_dir=config_dir)
    auth = mint_tokens(os.environ, config_dir,
                       tuple(n for n in registry if n != MAIN_TARGET),
                       mint_admin=os.environ.get("DIGUP_SERVER_MINT_KEYS", "").lower()
                       in ("1", "true", "yes"))
    # POST /api/v1/tokens (rotate) replaces the keys at runtime: the bearer gate and
    # the endpoints read the SAME live object through this holder, so one swap lands
    # everywhere. `Auth` is frozen by design — rotation swaps the reference, never the
    # fields of a live object.
    current = {"auth": auth}
    status_ttl = float(os.environ.get("DIGUP_SERVER_STATUS_TTL_S", "15"))
    # One CLI-status cache for every read (the status endpoints, health's identity,
    # the /targets counts): keyed per index folder, so targets never share counts.
    status_cache = StatusCache(lambda cfg: cli_status(cfg), status_ttl)

    hit_cache = HitCache()
    estimate_busy = threading.Lock()      # one full-tree crawl at a time (the UI retry
                                          # click and a second tab must not stack crawls)

    @dataclass
    class Scope:
        cfg: EngineConfig
        service: SearchService
        jobs: JobRunner
        status: "StatusCache"

    scopes: dict[str, Scope] = {}
    scope_build = threading.Lock()        # one spawn per target, ever

    def make_runner(cfg: EngineConfig, service: SearchService,
                    log_name: str | None = None) -> JobRunner:
        """One source for the job runner's knobs (stage-13: a runner per target; the main
        index keeps `jobs.jsonl`, an app target gets `jobs-<name>.jsonl`). After a done
        job the searcher is brought current with the sequence the contract suite proved:
        reload() → prewarm(). The job's ceiling belongs to the operator:
        DIGUP_SERVER_JOB_TIMEOUT_S (3600 s fits the corpora the suite walks; a first pass
        of a real media tree outlives an hour — the job then records *interrupted* with
        its partial counters and the next job resumes, README §5)."""
        return JobRunner(
            cfg, config_dir=config_dir,
            log_name=log_name or JOB_LOG,
            after_done=lambda: (service.reload(), service.prewarm()),
            backfill=os.environ.get("DIGUP_SERVER_BACKFILL", "1") != "0",
            sync_timeout_s=float(os.environ.get("DIGUP_SERVER_JOB_TIMEOUT_S", "3600")),
            log_rotate_bytes=int(os.environ.get("DIGUP_SERVER_JOB_LOG_SIZE", 1_048_576)))

    def scope_for(name: str) -> Scope:
        """The main scope always exists (the lifespan owns it); app targets spawn on
        first use: search-service child (prewarmed best-effort), job runner, status.

        The main target resolves `app.state.search` at call time: the lifespan sets
        it first, and it is the published seam the API tests inject a refusing
        searcher through (the 503 contract, test_api) — the scope must answer with
        the state's service, not a freshly spawned one."""
        if name in scopes:
            return scopes[name]
        target = registry.get(name)
        if target is None:
            raise HTTPException(status_code=404,
                                detail=f"no such index target {name!r} — see /api/v1/targets")
        with scope_build:
            if name in scopes:
                return scopes[name]
            if target.main:
                live = getattr(app.state, "search", None)
                if live is not None:
                    scopes[MAIN_TARGET] = Scope(cfg=config, service=live,
                                                jobs=getattr(app.state, "jobs", None),
                                                status=status_cache)
                    return scopes[MAIN_TARGET]
            cfg = EngineConfig(index=target.index, roots=target.roots, binary=config.binary,
                               excluded=config.excluded,
                               excluded_extensions=config.excluded_extensions,
                               models_dir=config.models_dir, encoder_idle=config.encoder_idle)
            os.makedirs(target.index, exist_ok=True)
            service = SearchService(cfg)
            service.start()
            try:
                service.prewarm()
            except (EngineExited, EngineRefused, TimeoutError):
                pass                      # first search respawns; a preview call must not die here
            runner = make_runner(cfg, service, f"jobs-{name}.jsonl")
            scopes[name] = Scope(cfg=cfg, service=service, jobs=runner, status=status_cache)
            return scopes[name]

    def target_for_path(path: str) -> str:
        """Which target owns a media path: the longest matching root wins (a target
        folder mounted under the media root is the more specific owner), falling back
        to the main target."""
        best, best_len = MAIN_TARGET, -1
        resolved = Path(path).resolve()
        for name, target in registry.items():
            for root in target.roots:
                r = Path(root).resolve()
                if (resolved == r or str(resolved).startswith(str(r) + os.sep)) \
                        and len(str(r)) > best_len:
                    best, best_len = name, len(str(r))
        return best

    def request_target(request: Request) -> str:
        return request.scope.get("digup.target", MAIN_TARGET)

    def _media_scope_allows(request: Request, path: str) -> str:
        """Media handles resolve to the target that owns the path. A principal with NO
        key touches the main index only — the minted-shape opening (2026-11-08 user
        brief) is for the main index's reads; an application's own index keeps needing
        its own key (or the admin's). App-keyed requests are already scoped by the
        bearer gate; this closes the media-id side for the open principal."""
        name = target_for_path(path)
        principal = request.scope.get("digup.principal", "")
        if principal in ("", "none") and name != MAIN_TARGET:
            raise HTTPException(status_code=403,
                                detail="that file belongs to an application's own index "
                                       "— its key answers it")
        return name

    # Counts for the /api/v1/targets list, all from the engine and WITHOUT spawning
    # anything for a GET: a target whose searcher is already running answers with its
    # live status (`files`/`searchable` — the searcher is the target's own engine, the
    # authority on a store it has open; a store whose writer has exited can keep its
    # fresh rows in the WAL, pinned by the searcher's reads, where the CLI's separate
    # open does not see them — measured in the suite: main db 4096 B + live -wal,
    # searcher 12 rows, CLI 0). An unspawned target reads the read-only CLI status
    # (its kinds table totals the files, `vectors` counts the searchable rows — a
    # store with no searcher open is fully checkpointed there); mid-reload refusals
    # fall back to it. An index folder with no store file has nothing to report
    # (null), and creating a store is never a GET's business.
    def target_counts(target: Target) -> dict:
        if not os.path.isdir(target.index) or not os.path.exists(os.path.join(target.index,
                                                                               "index.sqlite")):
            return {"files": None, "searchable": None}
        scope = scopes.get(target.name)
        if scope is not None:
            try:
                live = _strip(scope.service.status())
                return {"files": live.get("files"), "searchable": live.get("searchable")}
            except (EngineExited, EngineRefused, TimeoutError):
                pass                       # mid reload→prewarm: the CLI's words, below
        cfg = EngineConfig(index=target.index, roots=target.roots, binary=config.binary,
                           models_dir=config.models_dir)
        try:
            facts = status_cache.get(cfg)
        except (EngineExited, EngineRefused, TimeoutError, FileNotFoundError, OSError):
            return {"files": None, "searchable": None}
        return {"files": sum(k.get("files", 0) for k in facts.get("kinds", [])),
                "searchable": facts.get("vectors")}

    @contextlib.asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        service = SearchService(config)
        app.state.search = service
        service.start()            # spawn as a direct child of this process; index opens
        # Startup prewarm: the engine's `prewarm` op opens the vectors and warms the
        # encoder, so the first search from a first browser answers with real z-scores
        # — the model load is paid at boot (HEALTHCHECK's start-period covers it),
        # not in front of a user. DIGUP_SERVER_PREWARM=0 skips it (dev restarts).
        if os.environ.get("DIGUP_SERVER_PREWARM", "1") != "0":
            try:
                service.prewarm()
            except (EngineExited, EngineRefused, TimeoutError):
                pass               # the searcher respawns on demand; startup must not die here
        # One writer, serialized; the runner's knobs (ceiling, log rotation, the
        # reload→prewarm sequence) all come from make_runner, one source for every
        # target. Measured 2026-11-04: a first pass of a real media tree outlives the
        # default hour — the job recorded *interrupted* with its partial counters and
        # the next job resumed (README §5).
        runner = make_runner(config, service)
        app.state.jobs = runner
        scopes[MAIN_TARGET] = Scope(cfg=config, service=service, jobs=runner, status=status_cache)
        app.state.scopes = scopes
        yield                      # uvicorn owns the children; quit() ends them
        runner.shutdown()          # a running job is logged *interrupted* — the truthful state
        service.quit()
        for name, scope in list(scopes.items()):
            if name != MAIN_TARGET:
                scope.jobs.shutdown()
                scope.service.quit()

    app = FastAPI(
        title="DigUp server",
        version="0.1.0",
        docs_url="/api/v1/docs",
        openapi_url="/api/v1/openapi.json",
        lifespan=lifespan,
    )

    # §7's explicit Host/Origin validation, installed always and engaged only when the
    # operator names the hosts this deployment serves (DIGUP_SERVER_ALLOWED_HOSTS). The
    # loopback default keeps passing everything through: nothing changes for a localhost
    # server, and a Docker-network / reverse-proxy deployment opts in by naming its hosts.
    # The bearer gate (below) is installed first so the Host guard runs outside it: refuse a
    # wrong host before authenticating against it.
    #
    # Stage 12 (docs/implementation/stage-12-integrations.md) extends the same opt-in shape:
    # add_middleware wraps LAST-added = outermost, so the stack is
    #   PrincipalLog → Cors → HostOriginGuard → BearerAuth → routes:
    # the audit line sees every guarded request and its accepted principal; CORS answers the
    # widget preflights and marks allowlisted origins for the guard; the guard refuses a
    # wrong host before authentication; the bearer gate compares tokens. All three new knobs
    # (`DIGUP_SERVER_READ_TOKENS`, `DIGUP_SERVER_ALLOWED_ORIGINS`, and the named-token
    # attribution) are inert when unset, like every knob in this file.
    app.add_middleware(BearerAuth, auth=auth)
    app.add_middleware(HostOriginGuard, allowed_hosts=allowed_hosts_from_env(os.environ))
    app.add_middleware(Cors, allowed_origins=allowed_origins_from_env(os.environ))
    app.add_middleware(PrincipalLog)

    # Engine supervision facts become HTTP facts, quoted, not dressed up.
    @app.exception_handler(EngineExited)
    async def engine_exited(_request, exc: EngineExited):
        raise HTTPException(status_code=503, detail=str(exc))

    @app.exception_handler(EngineRefused)
    async def engine_refused(_request, exc: EngineRefused):
        # The engine's own refusal, quoted — a 503, not a 500: it answers "try again in a
        # moment" when the searcher is mid-transition, and says so in the engine's words.
        raise HTTPException(status_code=503, detail=str(exc))

    @app.exception_handler(TimeoutError)
    async def timed_out(_request, exc: TimeoutError):
        raise HTTPException(status_code=504, detail=str(exc))

    @app.exception_handler(CLIError)
    async def cli_failed(_request, exc: CLIError):
        raise HTTPException(status_code=502, detail=str(exc))

    @app.exception_handler(JobBusy)
    async def job_busy(_request, exc: JobBusy):
        raise HTTPException(status_code=409, detail=str(exc))

    # ── GET /api/v1/health — the engine's identity, from its own files and counts ──────
    # The container's healthcheck reads the MAIN target only: "the container is healthy"
    # is about the deployment's own index; app targets are lazily supervised.

    @app.get("/api/v1/health")
    def health() -> dict:
        main = scope_for(MAIN_TARGET)
        live = _strip(main.service.status())
        identity = main.status.get(main.cfg)
        return {
            "ok": True,
            "engine": {
                "fingerprints": identity["fingerprints"],   # google/embeddinggemma-2@… | vectors1 …
                "build_tag": identity["build_tag"],          # llama.cpp b11461
                "vectors_version": identity["vectors_version"],
                "index": identity["index"],
                "index_size": identity["index_size"],
            },
            "live": live,        # encoder state, vectors, files/searchable/pending — engine's
        }

    # ── GET /api/v1/status — counts: the searcher's live + the CLI's per-kind table ────
    # `?target=name` addresses a named index (admin answers any; an application token is
    # bound to its own — see security.BearerAuth). Default: the main media index.

    @app.get("/api/v1/status")
    def status(request: Request) -> dict:
        sc = scope_for(request_target(request))
        live = _strip(sc.service.status())
        cli = sc.status.get(sc.cfg)
        return {
            **live,
            "target": request_target(request),
            "kinds": cli["kinds"],
            "fingerprints": cli["fingerprints"],
            "build_tag": cli["build_tag"],
            "vectors_version": cli["vectors_version"],
            "index_size": cli["index_size"],
            # The server's own configuration, published for the UI's info panel: which
            # folders the index serves. These are the deployment's paths (env-configured
            # or targets-registered), never client-supplied — showing them is not path
            # acceptance (§7).
            "roots": list(sc.cfg.roots),
        }

    # ── POST /api/v1/search — ranking passes through untouched ─────────────────────────

    @app.post("/api/v1/search")
    def search(req: SearchRequest, request: Request) -> SearchReply:
        sc = scope_for(request_target(request))
        reply = sc.service.search(
            req.q, kinds=req.kinds, limit=req.limit, code=req.code,
            meaning=req.meaning, prefix_last=req.prefix_last)
        stripped = _strip(reply)
        hits = []
        for hit in stripped["hits"]:
            media_id = hit_cache.put(hit["path"], hit["kind"], hit["segment_id"],
                                      hit.get("loc"), req.code)
            hits.append({**hit, "media_id": media_id})   # the server's handle, documented
        return SearchReply(**{**stripped, "hits": hits})

    # ── POST /api/v1/estimate — the engine's own forecast, from its own JSON ───────────
    # ParentWatch rule: `estimate --json` exits when its parent is PID 1; this is a plain
    # subprocess.run child of the API process, which is exactly what the engine expects.

    @app.post("/api/v1/estimate")
    def estimate(_req: EstimateRequest, request: Request) -> dict:
        sc = scope_for(request_target(request))
        if not estimate_busy.acquire(blocking=False):
            raise HTTPException(status_code=409,
                                detail="an estimate is already running — the engine walks "
                                       "every folder once at a time")
        # The 120 s default fits corpus-sized trees. A full-tree crawl of a real media
        # tree on a spinning disk takes minutes — measured 2026-11-04: 187k files on a
        # 2 TB HDD crossed the default and the endpoint answered 502 "timed out". The
        # operator owns that ceiling: DIGUP_SERVER_ESTIMATE_TIMEOUT_S (the engine keeps
        # walking; the endpoint just stays honest about how long it will wait for it).
        timeout = float(os.environ.get("DIGUP_SERVER_ESTIMATE_TIMEOUT_S", "120"))
        try:
            return {"folders": estimate_lines(sc.cfg, timeout=timeout)}
        finally:
            estimate_busy.release()

    # ── POST /api/v1/index + GET /api/v1/jobs — one writer per index, honest states ────
    # Indexing never starts by itself (README §5): a job arrives here, runs serialized
    # under the adapter's flock, and a second request answers 409 with the live job's id.
    # Named indexes (stage-13): the flock lives beside each target's own index folder,
    # so "one at a time" is per target — a Nextcloud crawl and the media crawl never
    # queue behind each other, and each keeps its own jobs log (`jobs-<name>.jsonl`).
    # States are `queued/running/done/interrupted/busy`; a done job's counts are the
    # engine's events, and the searcher is reloaded + prewarmed after it.

    @app.post("/api/v1/index", status_code=202)
    def index(req: IndexRequest | None = None, *, request: Request) -> dict:
        sc = scope_for(request_target(request))
        prune = req.prune if req is not None else False
        return {"ok": True, "job": sc.jobs.start(prune=prune)}

    @app.get("/api/v1/jobs")
    def jobs(request: Request) -> dict:
        return {"jobs": scope_for(request_target(request)).jobs.jobs()}

    @app.get("/api/v1/jobs/{job_id}")
    def job(job_id: str, request: Request) -> dict:
        found = scope_for(request_target(request)).jobs.job(job_id)
        if found is None:
            raise HTTPException(status_code=404, detail=f"no job {job_id}")
        return {"job": found}

    # ── POST /api/v1/embed_ahead — the typist's warm-up: the engine embeds and caches
    # the text so far, so the pause's vector is ready for the next search (the desktop
    # panel's trick, same op).

    @app.post("/api/v1/embed_ahead")
    def embed_ahead(req: EmbedAheadRequest, request: Request) -> dict:
        sc = scope_for(request_target(request))
        return _strip(sc.service.embed_ahead(req.q, code=req.code))

    # ── GET /api/v1/media/{id}/preview + /text — server-issued handles, engine's files.
    # Handles come only from published search replies (HitCache): a client never sends a
    # path (§6). Previews are the JPEGs the engine's `render` wrote under
    # <index>/previews; served only when the reply's path resolves inside that folder.

    @app.get("/api/v1/media/{media_id}/preview")
    def preview(media_id: str, request: Request,
                pixels: int = Query(256, ge=32, le=2048)) -> FileResponse:
        entry = hit_cache.get(media_id)
        if entry is None:
            raise HTTPException(status_code=404, detail=f"no media handle {media_id}")
        _media_scope_allows(request, entry["path"])
        sc = scope_for(target_for_path(entry["path"]))    # the target that owns the path
        reply = sc.service.render(entry["path"], kind=entry["kind"], loc=entry["loc"],
                                  pixels=pixels)
        previews = (Path(sc.cfg.index) / "previews").resolve()
        image = Path(reply["image"]).resolve()
        if not str(image).startswith(str(previews) + os.sep):
            raise HTTPException(status_code=500, detail="render answered outside previews")
        return FileResponse(image, media_type="image/jpeg")

    @app.get("/api/v1/media/{media_id}/text")
    def media_text(media_id: str, request: Request) -> dict:
        entry = hit_cache.get(media_id)
        if entry is None:
            raise HTTPException(status_code=404, detail=f"no media handle {media_id}")
        _media_scope_allows(request, entry["path"])
        sc = scope_for(target_for_path(entry["path"]))
        return _strip(sc.service.text(entry["segment_id"], code=entry["code"]))

    # ── GET /api/v1/media/{id}/file — the file itself, the desktop's "Open" (Stage 10).
    # Same discipline as /preview: only a server-issued handle, and the path it names must
    # resolve inside the server's *configured* roots (the engine produced it; the roots are
    # the deployment's own, never a client's). The type is read from the file's magic
    # bytes; media kinds arrive inline so the browser opens them, everything else as an
    # attachment, code/text as text/plain — script is never marked script here. Ranges are
    # honored (206 + Content-Range): that is what lets <video …#t=loc> seek, and "save as"
    # download. Bytes flow only from files that exist under the roots right now.

    @app.get("/api/v1/media/{media_id}/file")
    def media_file(media_id: str, request: Request) -> Response:
        entry = hit_cache.get(media_id)
        if entry is None:
            raise HTTPException(status_code=404, detail=f"no media handle {media_id}")
        path = Path(entry["path"]).resolve()
        _media_scope_allows(request, entry["path"])
        owner = registry[target_for_path(entry["path"])]   # the target whose roots own it
        roots = [Path(r).resolve() for r in owner.roots]
        if not any(path == r or path.is_relative_to(r) for r in roots):
            raise HTTPException(status_code=404, detail="file is outside the server's media roots")
        try:                                    # the type, the size, the span — from one open
            with open(path, "rb") as handle:    # (fstat of the live handle: a replacement
                mode = os.fstat(handle.fileno()).st_mode      # mid-request cannot make the
                if not stat.S_ISREG(mode):                    # headers lie about the bytes)
                    raise HTTPException(status_code=404, detail="the file is gone (it left the folders)")
                media_type = sniff_type(path)
                size = os.fstat(handle.fileno()).st_size
        except (FileNotFoundError, IsADirectoryError, PermissionError):
            raise HTTPException(status_code=404, detail="the file is gone (it left the folders)")
        if media_type == "application/octet-stream":
            media_type = "text/plain; charset=utf-8" if entry["kind"] in ("code", "doc") \
                else "application/octet-stream"
        name = quote(path.name)              # RFC 5987: names with any characters, escaped
        disposition = "inline" if entry["kind"] in _INLINE_KINDS else "attachment"
        headers = {"content-disposition": f"{disposition}; filename*=UTF-8''{name}",
                   "accept-ranges": "bytes",
                   # Belt for the text/plain path: the magic-bytes typing above already
                   # refuses to call script script; nosniff says the browser must not guess.
                   "x-content-type-options": "nosniff"}
        span = parse_range(request.headers.get("range"), size)
        if span is not None and span[0] == "unsatisfiable":
            return Response(status_code=416, headers={
                "content-range": f"bytes */{size}", "accept-ranges": "bytes"})
        if span is not None:
            start, end = span
            headers["content-range"] = f"bytes {start}-{end}/{size}"

            def ranged():                       # chunked: a 20 GB clip streams, never buffers
                with open(path, "rb") as span_handle:
                    span_handle.seek(start)
                    remaining = end - start + 1
                    while remaining > 0:
                        chunk = span_handle.read(min(remaining, 1 << 20))
                        if not chunk:
                            break
                        remaining -= len(chunk)
                        yield chunk

            return StreamingResponse(ranged(), status_code=206, media_type=media_type,
                                     headers=headers)
        return FileResponse(path, media_type=media_type, headers=headers)

    # ── GET /api/v1/targets — the named indexes this server supervises (stage-13) ──────
    # An application token sees its own target only (the binding the bearer gate
    # enforces); read/admin tokens see the full registry. Counts come from the CLI
    # status read-only (no engine spawn for a listing), cached like every status fact.

    @app.get("/api/v1/targets")
    def targets(request: Request) -> dict:
        principal = request.scope.get("digup.principal", "")
        app_target = principal[4:] if principal.startswith("app:") else None
        out = []
        for name, target in registry.items():
            if app_target is not None and name != app_target:
                continue
            out.append({"name": name, "roots": list(target.roots), "index": target.index,
                        "main": target.main, **target_counts(target)})
        return {"targets": out}

    # ── POST /api/v1/targets — an application registers at a RUNNING server (stage 14)
    # The user's flow, made one call: the standalone box mints its API key at boot
    # (DIGUP_SERVER_MINT_KEYS) and shows it in the gear with Copy; the application
    # brings that key here with its name + folders, and the server mints its PRIVATE
    # key, registers its own index folder (default <config>/index-<name>), and persists
    # the registration (targets.json — a restart keeps it). From here on the
    # application's key answers only its target: its own status, its own search, its
    # own crawl, which runs in the background and never touches the main page.
    # Validation is the startup validator: same slug rules, same absolute-path rules,
    # same "not the main index" rule — a runtime registration cannot be sloppier than
    # an environment one.

    @app.post("/api/v1/targets")
    def register_target(body: TargetRegister, request: Request) -> dict:
        _admin_scope(request)
        index = body.index or os.path.join(config_dir, f"index-{body.name.strip().lower()}")
        try:
            target = _validated(body.name, os.pathsep.join(body.roots), index,
                                main_index=config.index)
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc))
        if target.name in registry:
            raise HTTPException(status_code=409,
                                detail=f"target {target.name!r} is already registered")
        registry[target.name] = target

        a = current["auth"]
        key = f"app:{target.name}"
        readers = dict(a.readers)
        minted = tuple(a.minted)
        token = readers.get(key)
        if token is None or key not in minted:
            token = secrets.token_urlsafe(24)          # private, minted, shown once here
            readers[key] = token
            if key not in minted:
                minted = minted + (key,)
        rotated = Auth(read=a.read, admin=a.admin, readers=readers, minted=minted)
        current["auth"] = rotated
        gate = _bearer_gate()
        if gate is not None:
            gate.auth = rotated
        _write_tokens_file(os.path.join(config_dir, TOKENS_FILE), rotated)
        persist = {n: {"roots": list(t.roots), "index": t.index}
                   for n, t in registry.items() if not t.main}
        with open(os.path.join(config_dir, "targets.json"), "w", encoding="utf-8") as handle:
            json.dump(persist, handle, indent=2)

        return {"name": target.name, "roots": list(target.roots), "index": target.index,
                "token": token, "generated": True}

    # ── /api/v1/tokens — the keys the server minted itself, admin scope only ──────────
    # Minted keys (mint_tokens) exist precisely because the operator never typed them,
    # and this is the only place they are ever shown. Environment-configured secrets are
    # reported as configured, never echoed — same rule the Nextcloud bridge lives by.
    #
    # GET shows them; POST REGENERATES them (UI: Regenerate, behind a confirm — "the
    # applications that have these keys pasted lose access"): every minted value is
    # freshly minted and persisted 0600, the old values die immediately, and the bearer
    # gate is repointed at the new ones before this answer is built. Env-configured keys
    # are never rotated (a rotation must not silently override the deployment's own
    # config) — a deployment whose keys all come from env answers 400: nothing to rotate.

    def _admin_scope(request: Request) -> None:
        principal = request.scope.get("digup.principal", "")
        # The gate records an admin token on a read route as "admin (read scope)" —
        # this IS the admin scope's surface, so both forms are accepted here. And in an
        # admin-token-only deployment the gate deliberately leaves reads OPEN (the
        # documented shape), so the principal is `none` even when the admin key is
        # presented — compare the bearer itself: admin-scope surfaces answer the
        # admin key's owner, that is the contract this endpoint exists for.
        if principal == "admin" or principal == "admin (read scope)":
            return
        a = current["auth"]
        supplied = _bearer(request.scope)
        if a.admin and supplied and hmac.compare_digest(supplied, a.admin):
            return
        raise HTTPException(status_code=403,
                            detail="the server's keys and application registrations answer "
                                   "the admin token only")

    def _tokens_payload(a: Auth) -> dict:
        apps = [{"name": name[4:],
                 "token": a.readers[name] if name in a.minted else None,
                 "generated": name in a.minted}
                for name in a.readers if name.startswith("app:")]
        return {"admin": a.admin if "admin" in a.minted else None,
                "admin_configured": a.admin is not None,
                "read_configured": a.read is not None,
                "apps": apps}

    def _bearer_gate() -> "BearerAuth | None":
        """The bearer gate instance in this app's middleware stack: rotation points
        it at the new values. The stack is built on the first HTTP request (so during
        any endpoint call it exists) as one outermost instance wrapping the next on
        `.app` — walk the chain: PrincipalLog → Cors → HostOriginGuard → BearerAuth."""
        mw = getattr(app, "middleware_stack", None)
        while mw is not None:
            if isinstance(mw, BearerAuth):
                return mw
            mw = getattr(mw, "app", None)
        return None

    @app.get("/api/v1/tokens")
    def tokens(request: Request) -> dict:
        principal = request.scope.get("digup.principal", "")
        if (principal in ("", "none") and not env_secrets(current["auth"])
                and not principal.startswith("app:")):
            # The ticket model (2026-11-08 UX brief, round 6): a server that MINTED its
            # keys shows them to its own gear — the UI reads this with no key in the
            # browser, exactly as the main page searches with no key. The minted shape
            # already answers main reads keylessly (the gate's rule); this extends it
            # to the keys row, the ticket the applications copy. A deployment that
            # TYPED its own secrets never displays them (env_secrets); an application's
            # key never lists the server's keys (_admin_scope refuses it, as before).
            return _tokens_payload(current["auth"])
        _admin_scope(request)
        return _tokens_payload(current["auth"])

    @app.post("/api/v1/tokens")
    def rotate_tokens(request: Request) -> dict:
        _admin_scope(request)
        rotated = rotate_minted(current["auth"], config_dir)
        if rotated is None:
            raise HTTPException(status_code=400,
                                detail="nothing to rotate — this server's keys are set "
                                       "in its environment, not minted")
        current["auth"] = rotated
        gate = _bearer_gate()
        if gate is not None:
            gate.auth = rotated
        payload = _tokens_payload(rotated)
        payload["rotated"] = True
        return payload

    # ── The UI, same origin (so CORS is not needed at all — Stage 6) ───────────────────
    #
    # The Lit + Vite migration (user brief 2026-11-08, server/ui/AGENTS.md): FastAPI serves
    # the BUILT frontend — `server/ui/dist` (`app.js`, `style.css`, `embed.js`, `embed.css`,
    # hashed chunks; the stable names are the pinned contract, vite.config.js maps them).
    # Node exists at BUILD time only (the Dockerfile's frontend-builder stage); the runtime
    # image ships the static dist, and the UIFiles no-cache decoration rides every byte.
    # `DIGUP_SERVER_UI` points the mount elsewhere (a dev checkout with its own build);
    # an explicit value with no index.html is a loud config error, not a silent 404 page.
    env_ui = os.environ.get("DIGUP_SERVER_UI", "").strip()
    ui = Path(env_ui) if env_ui else Path(__file__).resolve().parent.parent / "ui" / "dist"
    if (ui / "index.html").is_file():
        app.mount("/", UIFiles(directory=ui, html=True), name="ui")
    elif env_ui:
        raise FileNotFoundError(
            f"DIGUP_SERVER_UI={ui} has no index.html — serve the built UI: cd server/ui && npm run build")

    return app


def app_factory() -> FastAPI:
    """The `uv run uvicorn --factory digup_server.api:app_factory` entry: builds the app
    from the environment when uvicorn imports it. Module import stays side-effect-free —
    a module-level `app` would run `config_from_env()` at import, in every context."""
    return create_app(config_from_env())


def main() -> None:
    """`uv run python -m digup_server.api` — localhost by default (README §7)."""
    host = os.environ.get("DIGUP_SERVER_HOST", DEFAULT_HOST)
    port = int(os.environ.get("DIGUP_SERVER_PORT", DEFAULT_PORT))
    uvicorn.run(app_factory(), host=host, port=port)


if __name__ == "__main__":
    main()
