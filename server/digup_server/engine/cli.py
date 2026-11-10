"""The read-only one-shot CLI: `status`, `estimate`, `speed --model --json`. Short-lived
processes, no protocol.

* `status` is parsed from the CLI's own lines (`main.swift: status(...)`) — the server shows
  the engine's words, and anything it can't parse stays None, never guessed.
* `estimate --json` answers one JSON line per folder as the crawl finishes (`emit()`, one
  per folder, streaming). It is a ParentWatch helper: it exits at once when its parent is
  PID 1 — the server is the long-lived parent that spawns helpers as direct children, which
  is what the engine designed for. (The Stage-2 "silent estimate" report was a PID-1
  `bash -c`; ParentWatch doing its job — see reconnaissance §15 item 8.)
* `speed --model --json` answers one JSON line (`{"event": "speed", ...}`, main.swift
  `modelSpeed`): per-kind multipliers, model load, the chosen `device`, and — when a GPU
  was compared — `agreement` (the cosine the engine demands ≥ 0.999 before trusting it).
"""

from __future__ import annotations

import json
import re
import subprocess

from .config import EngineConfig


class CLIError(RuntimeError):
    """The CLI said `error: …` and exited nonzero — the engine's own words, kept."""


def run(argv: list[str], env: dict[str, str], *, timeout: float = 300.0) -> str:
    """One `digup` process to completion; stdout returned, engine errors raised verbatim."""
    try:
        proc = subprocess.run(argv, env=env, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired as exc:
        # `TimeoutExpired` is a SubprocessError, not a TimeoutError: unmapped it is a bare
        # 500 traceback — this file's own rule (api.py:6) says quote the engine instead.
        raise CLIError(f"digup {argv[1] if len(argv) > 1 else '?'} timed out "
                       f"after {timeout:g} s") from exc
    if proc.returncode != 0:
        raise CLIError((proc.stderr or proc.stdout).strip() or f"digup exited {proc.returncode}")
    return proc.stdout


def status(config: EngineConfig, *, timeout: float = 60.0) -> dict:
    """`digup status` parsed: index path, vectors, per-kind counts, fingerprint, build tag, size."""
    out = run(config.status_argv(), config.env(), timeout=timeout)
    line = lambda pat, text: (re.search(pat, text, re.M))  # noqa: E731 — three uses, keep it local
    info: dict = {"index": None, "vectors": None, "segments": None, "fingerprints": None,
                  "build_tag": None, "vectors_version": None, "index_size": None, "kinds": []}
    if m := line(r"^index: (.+)$", out):
        info["index"] = m.group(1)
    if m := line(r"^vectors: (\d+) in (\d+) segments", out):
        info["vectors"], info["segments"] = int(m.group(1)), int(m.group(2))
    if m := line(r"^built with: (.+)$", out):
        info["fingerprints"] = m.group(1)
    if m := line(r"^this digup: llama\.cpp ([^,]+), vectors (\d+)", out):
        info["build_tag"], info["vectors_version"] = m.group(1), int(m.group(2))
    if m := line(r"^size: (.+)$", out):
        info["index_size"] = m.group(1)
    for m in re.finditer(r"^  (\S+)\s+(\d+)\s+(\d+ done(?: \(\d+ partial\))?)$", out, re.M):
        info["kinds"].append({"kind": m.group(1), "files": int(m.group(2)), "states": m.group(3)})
    return info


def estimate_json(config: EngineConfig, *, timeout: float = 120.0) -> dict:
    """`estimate --json`: the first JSON line (one per folder, as the engine streams them)."""
    return estimate_lines(config, timeout=timeout)[0]


def estimate_lines(config: EngineConfig, *, timeout: float = 120.0) -> list[dict]:
    """`estimate --json`: every JSON line — one per root folder, as the engine streams them.

    ParentWatch rule: this helper exits the moment its parent dies, and treats PID 1 as a
    dead app. The server is the long-lived parent (subprocess children, no shell wrappers),
    which is what the engine designed for; a PID-1 `bash -c` is not.
    """
    out = run(config.estimate_argv(), config.env(), timeout=timeout)
    lines = [json.loads(line) for line in out.splitlines() if line.strip().startswith("{")]
    if not lines:
        raise CLIError(f"estimate --json printed no JSON line: {out[:200]}")
    return lines


def estimate_text(config: EngineConfig, *, timeout: float = 120.0) -> str:
    """`estimate` plain — the engine's paragraph, for humans (the app's onboarding shows JSON)."""
    argv = [a for a in config.estimate_argv() if a != "--json"]
    return run(argv, config.env(), timeout=timeout).strip()


def speed_model(config: EngineConfig, *, when_quiet_s: float = 5.0, tries: int = 3,
                timeout: float = 600.0) -> dict:
    """`digup speed --model --json` → the single `{"event": "speed", …}` line, parsed."""
    out = run(config.speed_argv(when_quiet_s=when_quiet_s, tries=tries), config.env(),
              timeout=timeout)
    for line in out.splitlines():
        line = line.strip()
        if line.startswith("{"):
            return json.loads(line)
    raise CLIError(f"speed --model printed no JSON line: {out[:200]}")
