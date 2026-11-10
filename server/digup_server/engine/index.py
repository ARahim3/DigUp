"""`digup index-service`: the single writer, flock-guarded.

Upstream runs one indexing helper at a time (`IndexService.swift`), and SQLite's WAL +
busy_timeout is the engine's inner safety, not a license for two crawlers. The server is
the outer lock: an `flock` on `<index>/.digup-server.writer.lock` held for exactly as long
as the helper lives, so a second writer asks, gets `IndexBusy`, and never races the first.

Commands are plain text lines (`sync`, `sync code`, `stop`, `backfill on/off`; EOF = stop);
events are JSON lines. The helper keeps a warm worker for `--linger` seconds after a
batch, then emits `{"event": "exit"}` and ends — normal service, not a failure; the next
index request spawns it again. Events carry real file counts (`sync: new/added/changed/…`,
`file: path/kind/state/seconds`, `summary: states`, counts as `files/searchable/pending/
vectors/unfinished`, `code_`-prefixed for the code index) — progress is counted, never a
made-up percentage.
"""

from __future__ import annotations

import fcntl
import os
from collections.abc import Iterator

from .config import EngineConfig
from .protocol import EngineExited, JsonLinesProcess

LOCK_NAME = ".digup-server.writer.lock"


class IndexBusy(RuntimeError):
    """Another writer holds this index. The server never queues blind: a job says so."""


class IndexService:
    """A supervised `digup index-service` — spawn, command lines, event stream, single writer."""

    def __init__(self, config: EngineConfig, *, backfill: bool = False, prune: bool = False,
                 memory_limit_mb: int | None = None, time_limit_s: int | None = None,
                 new_limit: int | None = None, linger_s: float | None = None):
        self._config = config
        self._argv = config.index_argv(backfill=backfill, prune=prune,
                                       memory_limit_mb=memory_limit_mb, time_limit_s=time_limit_s,
                                       new_limit=new_limit, linger_s=linger_s)
        self._proc: JsonLinesProcess | None = None
        self._lock_file = None

    # ── lifecycle (the lock rides the process) ───────────────────────────────────────────

    def start(self) -> None:
        if self._proc is not None:
            raise RuntimeError("index-service: already started")
        os.makedirs(self._config.index, exist_ok=True)
        self._lock_file = open(os.path.join(self._config.index, LOCK_NAME), "a+")
        try:
            fcntl.flock(self._lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as exc:
            self._lock_file.close()
            self._lock_file = None
            raise IndexBusy(f"{self._config.index}: another index-service is writing") from exc
        self._proc = JsonLinesProcess(self._argv, name="index-service", env=self._config.env())
        # index-service has no "ready" event: it starts working from the first `sync`.
        self._proc.start(ready_event=None)

    def finish(self) -> None:
        """EOF (the helper stops itself when it reaches a safe point) and release the lock."""
        if self._proc is not None:
            self._proc.close()
            self._proc = None
        if self._lock_file is not None:
            fcntl.flock(self._lock_file, fcntl.LOCK_UN)
            self._lock_file.close()
            self._lock_file = None

    # ── commands (plain lines, per IndexService.swift's header) ──────────────────────────

    def sync(self) -> None:
        self._command("sync")

    def stop(self) -> None:
        self._command("stop")

    def backfill(self, *, on: bool) -> None:
        self._command("backfill on" if on else "backfill off")

    def events(self, *, timeout: float = 900.0) -> Iterator[dict]:
        """Event lines until the exit event; EOF without it raises EngineExited."""
        if self._proc is None:
            raise RuntimeError("index-service: not started")
        return self._proc.events(timeout=timeout)

    def run_sync(self, *, timeout: float = 900.0) -> list[dict]:
        """Sync and drain to the helper's own exit: the events, in order, as the server logs them.

        Starts the service if it isn't running (it idles out after `--linger` seconds: the
        next job spawns it again). The helper ends on its own: `{"event": "exit"}` — normal,
        the stream's end; EOF without that event is a crash and raises.
        """
        if self._proc is None:
            self.start()
        self.sync()
        events: list[dict] = []
        try:
            for event in self.events(timeout=timeout):
                events.append(event)
        finally:
            self.finish()   # idempotent: release the writer lock even on a crash
        return events

    def _command(self, line: str) -> None:
        if self._proc is None:
            raise RuntimeError("index-service: not started")
        self._proc.send_line(line)
