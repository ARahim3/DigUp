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
import os
import re
import threading
import uuid
from collections import OrderedDict
from collections.abc import AsyncIterator
from pathlib import Path
from typing import Literal
from urllib.parse import quote

import uvicorn
from fastapi import FastAPI, HTTPException, Query, Request
from fastapi.responses import FileResponse, Response
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

from .engine import EngineConfig, SearchService
from .engine.cli import CLIError, estimate_lines, status as cli_status
from .engine.protocol import EngineExited
from .jobs import JobBusy, JobRunner

# The engine's FileKind rawValues (Sources/DigUpKit FileKind): the API refuses anything
# else with a 422 — the engine would silently drop it, and silence is not honesty.
Kind = Literal["screenshot", "image", "pdf", "doc", "audio", "video", "code"]

DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8787


# ── the wire shape (the engine's fields, typed, not invented) ──────────────────────────


class SearchRequest(BaseModel):
    """One query, as `search-service` takes it. The UI types `q` on every keystroke and
    sends `embed_ahead` alongside; `meaning: false` is the keyword-only path while the
    encoder is cold."""

    q: str = Field(max_length=512)
    kinds: list[Kind] | None = None
    limit: int = Field(default=10, ge=1, le=100)   # the engine's own default is 40
    code: bool = False
    meaning: bool = True
    prefix_last: bool = False


class SearchReply(BaseModel):
    """The engine's reply minus the request `id` (protocol bookkeeping, not the API's).
    Each hit carries `media_id` — the server's handle for `/media/{id}/…`, documented
    here; every engine field passes through untouched."""

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
    (b"\x00\x00\x00\x1a", "video/mp4"),       # ISO-BMFF: ftyp at offset 4 (ftyp brand at 8)
    (b"\x00\x00\x00\x18", "video/mp4"),
    (b"\x00\x00\x00\x20", "video/mp4"),
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


def sniff_type(path: Path) -> str:
    with open(path, "rb") as handle:
        head = handle.read(16)
    for magic, media_type in _MAGIC:
        if head.startswith(magic):
            if media_type.startswith(("audio/", "video/")):
                brand = head[8:12]
                if media_type == "video/mp4" and brand not in (b"ftyp",):
                    return "application/octet-stream"
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
        length = int(end_s)
        if length == 0:
            return ("unsatisfiable", size)
        start, end = max(0, size - length), size - 1
    else:
        start = int(start_s)
        end = int(end_s) if end_s else size - 1
        end = min(end, size - 1)
        if start >= size or start > end:
            return ("unsatisfiable", size)
    return (start, end)


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
            return dict(entry) if entry else None


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
    """The app over one supervised search-service. `state.search` is the adapter client,
    `state.jobs` the job runner; `hit_cache` issues the media handles (§6: ids, never
    client paths)."""

    hit_cache = HitCache()

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
            except (EngineExited, TimeoutError):
                pass               # the searcher respawns on demand; startup must not die here
        # One writer, serialized; after a done job the searcher is brought current with
        # the sequence the contract suite proved: reload() → prewarm().
        config_dir = os.environ.get("DIGUP_SERVER_CONFIG") or os.path.join(config.index, "server-config")
        runner = JobRunner(config, config_dir=config_dir,
                           after_done=lambda: (service.reload(), service.prewarm()),
                           backfill=os.environ.get("DIGUP_SERVER_BACKFILL", "1") != "0",
                           log_rotate_bytes=int(os.environ.get("DIGUP_SERVER_JOB_LOG_SIZE",
                                                               1_048_576)))
        app.state.jobs = runner
        yield                      # uvicorn owns the children; quit() ends them
        runner.shutdown()          # a running job is logged *interrupted* — the truthful state
        service.quit()

    app = FastAPI(
        title="DigUp server",
        version="0.1.0",
        docs_url="/api/v1/docs",
        openapi_url="/api/v1/openapi.json",
        lifespan=lifespan,
    )

    # Engine supervision facts become HTTP facts, quoted, not dressed up.
    @app.exception_handler(EngineExited)
    async def engine_exited(_request, exc: EngineExited):
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

    def service(app: FastAPI) -> SearchService:
        return app.state.search

    # ── GET /api/v1/health — the engine's identity, from its own files and counts ──────

    @app.get("/api/v1/health")
    def health() -> dict:
        live = _strip(service(app).status())
        identity = cli_status(config)
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

    @app.get("/api/v1/status")
    def status() -> dict:
        live = _strip(service(app).status())
        cli = cli_status(config)
        return {
            **live,
            "kinds": cli["kinds"],
            "fingerprints": cli["fingerprints"],
            "build_tag": cli["build_tag"],
            "vectors_version": cli["vectors_version"],
            "index_size": cli["index_size"],
            # The server's own configuration, published for the UI's info panel: which
            # folders the index serves. These are the deployment's paths (env-configured),
            # never client-supplied — showing them is not path acceptance (§7).
            "roots": list(config.roots),
        }

    # ── POST /api/v1/search — ranking passes through untouched ─────────────────────────

    @app.post("/api/v1/search")
    def search(req: SearchRequest) -> SearchReply:
        reply = service(app).search(
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
    def estimate(_req: EstimateRequest) -> dict:
        return {"folders": estimate_lines(config)}

    # ── POST /api/v1/index + GET /api/v1/jobs — one writer, honest states ─────────────
    # Indexing never starts by itself (README §5): a job arrives here, runs serialized
    # under the adapter's flock, and a second request answers 409 with the live job's id.
    # States are `queued/running/done/interrupted/busy`; a done job's counts are the
    # engine's events, and the searcher is reloaded + prewarmed after it.

    @app.post("/api/v1/index", status_code=202)
    def index(req: IndexRequest | None = None) -> dict:
        prune = req.prune if req is not None else False
        return {"ok": True, "job": app.state.jobs.start(prune=prune)}

    @app.get("/api/v1/jobs")
    def jobs() -> dict:
        return {"jobs": app.state.jobs.jobs()}

    @app.get("/api/v1/jobs/{job_id}")
    def job(job_id: str) -> dict:
        found = app.state.jobs.job(job_id)
        if found is None:
            raise HTTPException(status_code=404, detail=f"no job {job_id}")
        return {"job": found}

    # ── POST /api/v1/embed_ahead — the typist's warm-up: the engine embeds and caches
    # the text so far, so the pause's vector is ready for the next search (the desktop
    # panel's trick, same op).

    @app.post("/api/v1/embed_ahead")
    def embed_ahead(req: EmbedAheadRequest) -> dict:
        return _strip(service(app).embed_ahead(req.q, code=req.code))

    # ── GET /api/v1/media/{id}/preview + /text — server-issued handles, engine's files.
    # Handles come only from published search replies (HitCache): a client never sends a
    # path (§6). Previews are the JPEGs the engine's `render` wrote under
    # <index>/previews; served only when the reply's path resolves inside that folder.

    @app.get("/api/v1/media/{media_id}/preview")
    def preview(media_id: str, pixels: int = Query(256, ge=32, le=2048)) -> FileResponse:
        entry = hit_cache.get(media_id)
        if entry is None:
            raise HTTPException(status_code=404, detail=f"no media handle {media_id}")
        reply = service(app).render(entry["path"], kind=entry["kind"], loc=entry["loc"],
                                    pixels=pixels)
        previews = (Path(config.index) / "previews").resolve()
        image = Path(reply["image"]).resolve()
        if not str(image).startswith(str(previews) + os.sep):
            raise HTTPException(status_code=500, detail="render answered outside previews")
        return FileResponse(image, media_type="image/jpeg")

    @app.get("/api/v1/media/{media_id}/text")
    def media_text(media_id: str) -> dict:
        entry = hit_cache.get(media_id)
        if entry is None:
            raise HTTPException(status_code=404, detail=f"no media handle {media_id}")
        return _strip(service(app).text(entry["segment_id"], code=entry["code"]))

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
        roots = [Path(r).resolve() for r in config.roots]
        if not any(str(path) == str(r) or str(path).startswith(str(r) + os.sep) for r in roots):
            raise HTTPException(status_code=404, detail="file is outside the server's media roots")
        if not path.is_file():
            raise HTTPException(status_code=404, detail="the file is gone (it left the folders)")
        media_type = sniff_type(path)
        if media_type == "application/octet-stream":
            media_type = "text/plain; charset=utf-8" if entry["kind"] in ("code", "doc") \
                else "application/octet-stream"
        name = quote(path.name)              # RFC 5987: names with any characters, escaped
        disposition = "inline" if entry["kind"] in _INLINE_KINDS else "attachment"
        headers = {"content-disposition": f"{disposition}; filename*=UTF-8''{name}",
                   "accept-ranges": "bytes"}
        size = path.stat().st_size
        span = parse_range(request.headers.get("range"), size)
        if span is not None and span[0] == "unsatisfiable":
            return Response(status_code=416, headers={
                "content-range": f"bytes */{size}", "accept-ranges": "bytes"})
        if span is not None:
            start, end = span
            with open(path, "rb") as handle:
                handle.seek(start)
                chunk = handle.read(end - start + 1)
            headers["content-range"] = f"bytes {start}-{end}/{size}"
            return Response(content=chunk, status_code=206, media_type=media_type,
                            headers=headers)
        return FileResponse(path, media_type=media_type, headers=headers)

    # ── The UI, same origin (so CORS is not needed at all — Stage 6) ───────────────────

    ui = Path(__file__).resolve().parent.parent / "ui"      # server/ui, vanilla, no build
    if ui.is_dir():
        app.mount("/", StaticFiles(directory=ui, html=True), name="ui")

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
