"""`digup search-service`: the hot searcher — the server's primary window on the engine.

Replies pass through verbatim: `search` answers `{hits, strong, meaning, ms, warning?}`, a
hit is exactly the engine's `hitFields()` (`path, kind, segment, segment_id, score,
modified, size, info` + the optional `z, cosine, keyword_rank, loc, loc_end, focus,
excerpt`). No re-ranking, no invented similarity numbers, and "no good matches" stays an
empty `hits` — the engine refusing to guess is a fact to publish, not to paper over.

The service idles itself out (model after `--encoder-idle`, process after twice that);
`_call` treats that as a restart, not an error. The server's scope (roots, exclusions) is
argv at spawn, so a respawn re-applies it by construction. Requests are serialized here:
the engine is thread-safe per line, but a single in-flight query keeps the reply routing
trivial and the encoder warm for the typist (`embed_ahead` on each keystroke).
"""

from __future__ import annotations

import threading

from .cli import CLIError
from .config import EngineConfig
from .protocol import DEFAULT_REQUEST_TIMEOUT, EngineExited, EngineRefused, JsonLinesProcess


class SearchService:
    """A supervised `digup search-service` over one index and its folders."""

    def __init__(self, config: EngineConfig, *, request_timeout: float = DEFAULT_REQUEST_TIMEOUT):
        self._config = config
        self._timeout = request_timeout
        self._proc: JsonLinesProcess | None = None
        self._lock = threading.RLock()      # one query in flight; restarts are exclusive
        self._render_slots = threading.Semaphore(2)   # the engine's own render concurrency

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
        with self._render_slots:
            return self._render(fields)

    def _render(self, fields: dict) -> dict:
        """`render` is the engine's own concurrent work: it runs beside the read loop on two
        slots and answers out-of-order, routed by `id` (SearchService.swift:52-56, 99-113 —
        "typing never waits on one"). Taking the serialize-lock for the engine's 120 s of
        ffmpeg work would undo that design, so this path holds the lock only for the
        spawn check. The protocol routes replies by id, so out-of-order is safe here."""
        timeout = 120.0
        with self._lock:
            if self._proc is None:
                self._spawn_locked()
            proc = self._proc
        try:
            return self._checked(proc.request(fields, timeout=timeout), fields)
        except EngineExited:
            with self._lock:
                self._spawn_locked()
                proc = self._proc
            return self._checked(proc.request(fields, timeout=timeout), fields)

    def reload(self) -> dict:
        """After indexing ran: reopen the index. The engine answers `{ok, vectors, code_vectors}`."""
        return self._call({"op": "reload"})

    def status(self) -> dict:
        return self._call({"op": "status"})

    def summaries(self, *, code: bool = False) -> dict:
        return self._call({"op": "summaries", "code": code})

    def prewarm(self) -> dict:
        return self._call({"op": "prewarm"}, timeout=60.0)

    def raw(self, fields: dict) -> dict:
        """An op this wrapper has no method for — passthrough, contract-tested by name,
        refusal replies included: `ok:false` reaches the caller verbatim here (a Stage-3
        contract test pins exactly that). Typed ops raise `EngineRefused` instead."""
        return self._call(dict(fields), check=False)

    # ── the supervision ──────────────────────────────────────────────────────────────────

    def _call(self, fields: dict, *, timeout: float | None = None, check: bool = True) -> dict:
        timeout = timeout or self._timeout
        with self._lock:
            if self._proc is None:
                self._spawn_locked()
            try:
                reply = self._proc.request(fields, timeout=timeout)
            except EngineExited:
                # The engine idled out (or was killed): normal. Start it again, once.
                self._spawn_locked()
                reply = self._proc.request(fields, timeout=timeout)
            return self._checked(reply, fields) if check else reply

    @staticmethod
    def _checked(reply: dict, fields: dict) -> dict:
        """A reply with `ok:false` is the engine refusing (its words, not ours) — raised,
        never returned, so no endpoint reads `hits`/`files` out of an answer that has none.
        `ok:false` ALONE is enough: a refusal shaped without `error` reaches the API's
        `stripped["hits"]` otherwise — the KeyError this guard exists to prevent."""
        if reply.get("ok") is False:
            raise EngineRefused(str(fields.get("op", "")), str(reply.get("error", "no reason given")))
        return reply

    def _spawn_locked(self) -> dict:
        proc = JsonLinesProcess(self._config.search_argv(), name="search-service",
                                env=self._config.env())
        try:
            ready = proc.start()
        except OSError as exc:       # binary missing/not executable: the 502-shaped answer
            proc.close()
            raise CLIError(f"cannot start the engine helper: {exc}") from exc
        except BaseException:
            # A handshake failure must not leak the child: its pipes and reader threads
            # would outlive every reference to it until its own idle-exit (2×encoder-idle).
            proc.close()
            raise
        if self._proc is not None and not self._proc.alive:
            self._proc.close()   # join the reaped straggler before replacing it
        self._proc = proc
        return ready
