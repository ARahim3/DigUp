"""One `digup` helper process, read line by line, requests answered by `id`.

The protocol is DigUp's, verbatim (headers of `Sources/digup/SearchService.swift` and
`Sources/digup/IndexService.swift`): one JSON object per line on stdin, one per line on
stdout carrying the request's `id`; lines without an `id` are events. Plain-text lines
("sync", "stop") drive `index-service`, and closing stdin is EOF = stop there.

The engine's own exits are normal, not failures:

* `search-service` releases the model after `--encoder-idle` and exits itself after twice
  that (`{"event":"exit","reason":"idle"}`), expecting a shell to start it again;
* `index-service` exits after `--linger` seconds of quiet, and on EOF;
* `ParentWatch.start()` (Linux: a 1 s getppid loop) kills the helper the moment *this*
  process dies — so helpers are spawned directly (argv lists, never a shell wrapper: a
  wrapper's death would kill them), and the supervisor must be the long-lived parent.

A reader thread routes every line; requests never block on each other's stderr, and a
process that died raises `EngineExited` to whoever was waiting — with the stderr tail,
because the engine reports encoder failures there.
"""

from __future__ import annotations

import collections
import contextlib
import json
import subprocess
import threading
import time
from collections.abc import Iterator

# A query on a cold CPU encodes in a few seconds; 120 s covers a loaded model starting up.
DEFAULT_REQUEST_TIMEOUT = 120.0
# `digup --help` answers in ms; "ready" rides out with the index opening.
READY_TIMEOUT = 60.0


class EngineExited(RuntimeError):
    """The helper process ended. Normal for services that idle out — see the module docstring."""

    def __init__(self, name: str, code: int | None, stderr_tail: list[str]):
        self.name, self.code, self.stderr_tail = name, code, stderr_tail
        tail = "; ".join(stderr_tail[-3:]) if stderr_tail else "no stderr"
        super().__init__(f"{name} process ended (exit {code}): {tail}")


class EngineRefused(RuntimeError):
    """The helper ANSWERED, with its own refusal: `{"ok": false, "error": …}`
    (`SearchService.swift:106,115`). Observed live: the searcher mid-transition right
    after indexing (the Stage-10 proof battery hit this as a 500 — a reply without
    `hits` is not a search result). The engine's words ride along quoted; the API
    answers 503, and the client may retry once the searcher catches up."""

    def __init__(self, op: str, error: str):
        self.op, self.error = op, error
        super().__init__(f"engine refused {op!r}: {error}")


class JsonLinesProcess:
    """Spawned `digup` helper: `request()` for answers, `events()` for the engine's own lines."""

    def __init__(self, argv: list[str], *, name: str, env: dict[str, str] | None = None):
        self._argv, self._name, self._env = argv, name, env
        self._proc: subprocess.Popen | None = None
        self._ids = iter(range(1, 1 << 30))
        self._lock = threading.Lock()
        self._cv = threading.Condition()
        self._events: collections.deque = collections.deque(maxlen=256)   # bounded: a long-lived
        self._replies: dict = {}      # searcher never drains events; timed-out replies are dropped
        self._exited: EngineExited | None = None
        self._stderr: collections.deque = collections.deque(maxlen=50)
        self._stdin_lock = threading.Lock()   # one writer at a time: lines must not interleave
        self._threads: list[threading.Thread] = []

    # ── lifecycle ────────────────────────────────────────────────────────────────────────

    def start(self, *, ready_timeout: float = READY_TIMEOUT, ready_event: str | None = "ready"):
        """Spawn and (when told) wait for the engine's opening `{"event": "ready", …}`."""
        with self._lock:
            if self._proc is not None:
                raise RuntimeError(f"{self._name}: already started")
            # No shell=True, no shell wrapper: ParentWatch kills children whose parent dies.
            self._proc = subprocess.Popen(
                self._argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                env=self._env, text=True, bufsize=1)
            self._threads = [threading.Thread(target=self._read_stdout, name=f"{self._name}-out",
                                              daemon=True),
                             threading.Thread(target=self._drain_stderr, name=f"{self._name}-err",
                                              daemon=True)]
            for thread in self._threads:
                thread.start()
        if ready_event is not None:
            event = self.next_event(timeout=ready_timeout)
            if isinstance(event, EngineExited):
                raise event
            if event.get("event") != ready_event:
                raise RuntimeError(f"{self._name}: expected the {ready_event!r} event, got {event}")
            return event
        return None

    def close(self, *, graceful_s: float = 5.0) -> None:
        """Close stdin (EOF: services stop themselves), then join, then kill if it must."""
        proc = self._proc
        if proc is None:
            return
        try:
            if proc.stdin is not None:
                proc.stdin.close()   # EOF: index-service stops; search-service's readLine ends
        except (BrokenPipeError, ValueError):
            pass
        try:
            proc.wait(timeout=graceful_s)
        except subprocess.TimeoutExpired:
            proc.terminate()
            try:
                proc.wait(timeout=graceful_s)
            except subprocess.TimeoutExpired:
                proc.kill()
                # The last wait is bookkeeping on a process we just killed: it must not
                # escape close() and fail the shutdown that called it.
                with contextlib.suppress(subprocess.TimeoutExpired):
                    proc.wait(timeout=graceful_s)

    @property
    def alive(self) -> bool:
        return self._proc is not None and self._proc.poll() is None

    @property
    def stderr_tail(self) -> list[str]:
        return list(self._stderr)

    # ── requests / replies / events ──────────────────────────────────────────────────────

    def request(self, fields: dict, *, timeout: float = DEFAULT_REQUEST_TIMEOUT) -> dict:
        """One request, one reply with the same `id`. Raises EngineExited / TimeoutError."""
        proc = self._proc
        if proc is None:
            raise RuntimeError(f"{self._name}: not started")
        rid = next(self._ids)
        line = json.dumps({**fields, "id": rid}, separators=(",", ":")) + "\n"
        try:
            with self._stdin_lock:
                assert proc.stdin is not None
                proc.stdin.write(line)
                proc.stdin.flush()
        except (BrokenPipeError, ValueError) as exc:
            raise self._death() from exc
        deadline = time.monotonic() + timeout
        with self._cv:
            while True:
                if rid in self._replies:
                    return self._replies.pop(rid)
                if self._exited is not None:
                    raise self._exited
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    self._replies.pop(rid, None)   # a late reply must not pile up
                    raise TimeoutError(f"{self._name}: no reply to {fields.get('op', fields)} "
                                       f"within {timeout:g} s")
                self._cv.wait(remaining)

    def send_line(self, line: str) -> None:
        """A plain-text command (`index-service`: "sync", "stop", "backfill on", …)."""
        proc = self._proc
        if proc is None:
            raise RuntimeError(f"{self._name}: not started")
        try:
            with self._stdin_lock:
                assert proc.stdin is not None
                proc.stdin.write(line + "\n")
                proc.stdin.flush()
        except (BrokenPipeError, ValueError) as exc:
            raise self._death() from exc

    def events(self, *, timeout: float = 300.0, stop_on: str = "exit") -> Iterator[dict]:
        """The engine's own event lines, in order, until `stop_on` (default: the exit event).

        A service that idles out ends with `{"event": "exit"}` (search-service) or the same
        (index-service); reaching EOF without it raises — a crash is not the exit event.
        """
        deadline = time.monotonic() + timeout
        while True:
            item = self.next_event(timeout=max(deadline - time.monotonic(), 0.01))
            if isinstance(item, EngineExited):
                raise item
            yield item
            if item.get("event") == stop_on:
                return

    def next_event(self, *, timeout: float) -> dict | EngineExited:
        """The next event line, in order, or EngineExited when the process has ended."""
        deadline = time.monotonic() + timeout
        with self._cv:
            while True:
                if self._events:
                    return self._events.popleft()
                if self._exited is not None:
                    return self._exited
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError(f"{self._name}: no event within {timeout:g} s")
                self._cv.wait(remaining)

    # ── the reader ───────────────────────────────────────────────────────────────────────

    def _death(self) -> EngineExited:
        """The engine's exit as we noticed it: the real exit event if one arrived, EOF if not."""
        self._proc.wait() if self._proc is not None else None
        with self._cv:
            if self._exited is None:
                code = self._proc.poll() if self._proc is not None else None
                self._exited = EngineExited(self._name, code, self.stderr_tail)
                self._cv.notify_all()
            return self._exited

    def _read_stdout(self) -> None:
        assert self._proc is not None and self._proc.stdout is not None
        for line in self._proc.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue   # the engine's non-JSON chatter (llama logs) never answers a request
            with self._cv:
                if isinstance(obj, dict) and obj.get("id") is not None:
                    self._replies[obj["id"]] = obj
                elif isinstance(obj, dict):
                    self._events.append(obj)
                self._cv.notify_all()
        # EOF: remember the end so every waiter wakes with EngineExited (via _death's path).
        with self._cv:
            code = self._proc.wait()
            self._exited = EngineExited(self._name, code, self.stderr_tail)
            self._cv.notify_all()

    def _drain_stderr(self) -> None:
        assert self._proc is not None and self._proc.stderr is not None
        for line in self._proc.stderr:
            self._stderr.append(line.rstrip())
