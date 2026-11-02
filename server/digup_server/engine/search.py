"""`digup search-service`: the hot searcher — the server's primary window on the engine.

Replies pass through verbatim: `search` answers `{hits, strong, meaning, ms, warning?}`, a
hit is exactly the engine's `hitFields()` (`path, kind, segment, segment_id, score,
modified, size, info` + the optional `z, cosine, keyword_rank, loc, loc_end, focus,
excerpt`). No re-ranking, no invented similarity numbers, and "no good matches" stays an
empty `hits` — the engine refusing to guess is a fact to publish, not to paper over.

The service idles itself out (model after `--encoder-idle`, process after twice that);
`_call` treats that as a restart, not an error, and replays the last `folders` change so a
respawn keeps the server's chosen scope. Requests are serialized here: the engine is
thread-safe per line, but a single in-flight query keeps the reply routing trivial and the
encoder warm for the typist (`embed_ahead` on each keystroke).
"""

from __future__ import annotations

import threading

from .config import EngineConfig
from .protocol import DEFAULT_REQUEST_TIMEOUT, EngineExited, JsonLinesProcess


class SearchService:
    """A supervised `digup search-service` over one index and its folders."""

    def __init__(self, config: EngineConfig, *, request_timeout: float = DEFAULT_REQUEST_TIMEOUT):
        self._config = config
        self._timeout = request_timeout
        self._proc: JsonLinesProcess | None = None
        self._lock = threading.RLock()      # one query in flight; restarts are exclusive
        self._folders_fields: dict | None = None   # last `folders` change, replayed after respawn

    # ── lifecycle ────────────────────────────────────────────────────────────────────────

    def start(self) -> dict:
        """Spawn and hand-shake. Returns the engine's `{"event": "ready", "index": …}`."""
        with self._lock:
            return self._spawn_locked()

    def quit(self) -> None:
        """Ask the engine to quit (`{"op":"quit"} → {"ok":true}`), then join the process."""
        with self._lock:
            if self._proc is None:
                return
            try:
                self._proc.request({"op": "quit"}, timeout=10.0)
            except (EngineExited, TimeoutError):
                pass
            self._proc.close()
            self._proc = None

    @property
    def running(self) -> bool:
        return self._proc is not None and self._proc.alive

    # ── the protocol, one method per op ──────────────────────────────────────────────────

    def search(self, q: str, *, kinds: list[str] | None = None, limit: int = 10,
               code: bool = False, meaning: bool = True, prefix_last: bool = False) -> dict:
        fields = {"op": "search", "q": q, "code": code, "limit": limit,
                  "meaning": meaning, "prefix_last": prefix_last}
        if kinds:
            fields["kinds"] = kinds
        return self._call(fields)

    def embed_ahead(self, q: str, *, code: bool = False) -> dict:
        return self._call({"op": "embed_ahead", "q": q, "code": code})

    def text(self, segment_id: int, *, code: bool = False) -> dict:
        return self._call({"op": "text", "segment": segment_id, "code": code})

    def render(self, path: str, *, kind: str = "image", loc: float | None = None,
               pixels: int = 1024) -> dict:
        fields = {"op": "render", "path": path, "kind": kind, "pixels": pixels}
        if loc is not None:
            fields["loc"] = loc
        return self._call(fields, timeout=120.0)   # a render is engine work, not a lookup

    def reload(self) -> dict:
        """After indexing ran: reopen the index. The engine answers `{ok, vectors, code_vectors}`."""
        return self._call({"op": "reload"})

    def status(self) -> dict:
        return self._call({"op": "status"})

    def summaries(self, *, code: bool = False) -> dict:
        return self._call({"op": "summaries", "code": code})

    def prewarm(self) -> dict:
        return self._call({"op": "prewarm"}, timeout=60.0)

    def folders(self, *, roots: list[str] | None = None, skipped: list[str] | None = None,
                types: list[str] | None = None, code_roots: list[str] | None = None,
                code_skipped: list[str] | None = None) -> dict:
        fields = {"op": "folders"}
        for key, value in (("roots", roots), ("skipped", skipped), ("types", types),
                           ("code_roots", code_roots), ("code_skipped", code_skipped)):
            if value is not None:
                fields[key] = value
        reply = self._call(fields)
        self._folders_fields = {k: v for k, v in fields.items() if k != "op"}
        return reply

    def raw(self, fields: dict) -> dict:
        """An op this wrapper has no method for — passthrough, contract-tested by name."""
        return self._call(dict(fields))

    # ── the supervision ──────────────────────────────────────────────────────────────────

    def _call(self, fields: dict, *, timeout: float | None = None) -> dict:
        timeout = timeout or self._timeout
        with self._lock:
            if self._proc is None:
                self._spawn_locked()
            try:
                return self._proc.request(fields, timeout=timeout)
            except EngineExited:
                # The engine idled out (or was killed): normal. Start it again, once.
                self._spawn_locked()
                return self._proc.request(fields, timeout=timeout)

    def _spawn_locked(self) -> dict:
        proc = JsonLinesProcess(self._config.search_argv(), name="search-service",
                                env=self._config.env())
        ready = proc.start()
        if self._proc is not None and not self._proc.alive:
            self._proc.close()   # join the reaped straggler before replacing it
        self._proc = proc
        if self._folders_fields:
            proc.request({"op": "folders", **self._folders_fields}, timeout=30.0)
        return ready
