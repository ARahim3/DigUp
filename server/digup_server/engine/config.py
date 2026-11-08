"""Everything a `digup` spawn needs, in one frozen record.

Defaults follow `Sources/digup/main.swift`; the server always passes `--index` explicitly,
because the CLI default (AppPaths: `~/.local/share/digup`) is the desktop app's own folder,
not a server volume. `models_dir` sets `DIGUP_MODELS`, which ModelFiles.swift treats as the
*only* place to look for the model — the server pins it to a volume so a stray cache can't
feed the engine a different model.
"""

from __future__ import annotations

import os
from dataclasses import dataclass


# main.swift: `--encoder-idle` defaults to 300 s; after 2× that the helper exits itself and
# the supervisor starts it again on the next request.
DEFAULT_ENCODER_IDLE = 300.0


@dataclass(frozen=True)
class EngineConfig:
    """One engine + one index + the folders it serves. All paths are absolute."""

    index: str
    roots: tuple[str, ...]
    binary: str = "digup"
    excluded: tuple[str, ...] = ()            # --exclude
    excluded_extensions: tuple[str, ...] = ()  # --exclude-ext ("jpg,heic")
    models_dir: str | None = None             # DIGUP_MODELS
    encoder_idle: float = DEFAULT_ENCODER_IDLE

    def env(self) -> dict[str, str]:
        """Environment for the child: the inherited one, with the model folder pinned."""
        env = dict(os.environ)
        if self.models_dir:
            env["DIGUP_MODELS"] = self.models_dir
        return env

    def search_argv(self) -> list[str]:
        argv = [self.binary, "search-service", *self.roots,
                "--index", self.index, "--encoder-idle", f"{self.encoder_idle:g}"]
        if self.excluded:
            argv += sum([["--exclude", p] for p in self.excluded], [])
        if self.excluded_extensions:
            argv += ["--exclude-ext", ",".join(self.excluded_extensions)]
        return argv

    def index_argv(self, *, backfill: bool = False, prune: bool = False,
                   memory_limit_mb: int | None = None, time_limit_s: int | None = None,
                   new_limit: int | None = None, linger_s: float | None = None) -> list[str]:
        argv = [self.binary, "index-service", *self.roots, "--index", self.index]
        # The excludes ride along — the SAME list estimate and search get (stage-12 §11.3:
        # "the forecast must describe the tree the indexer WOULD walk"). Measured 2026-11-08
        # on the Nextcloud pilot: without them the job walked the tree's appdata folder —
        # 1,470,439 preview files — while estimate (which had them) reported 131,972.
        # The engine's shared parser accepts --exclude/--exclude-ext on index-service.
        if self.excluded:
            argv += sum([["--exclude", p] for p in self.excluded], [])
        if self.excluded_extensions:
            argv += ["--exclude-ext", ",".join(self.excluded_extensions)]
        if backfill:
            argv.append("--backfill")
        if prune:
            argv.append("--prune")
        if memory_limit_mb is not None:
            argv += ["--memory-limit", str(memory_limit_mb)]
        if time_limit_s is not None:
            argv += ["--time-limit", str(time_limit_s)]
        if new_limit is not None:
            argv += ["--new-limit", str(new_limit)]
        if linger_s is not None:
            argv += ["--linger", f"{linger_s:g}"]
        return argv

    def status_argv(self) -> list[str]:
        return [self.binary, "status", "--index", self.index]

    def estimate_argv(self) -> list[str]:
        # `estimate --json` is a ParentWatch helper: it exits at once when its parent is
        # PID 1 ("the app is gone"). The server is the app — it spawns helpers as its own
        # children, never through a PID-1 shell wrapper — so the JSON path is the right one
        # here. (The Stage-2 "silent estimate --json" report was exactly this: a script
        # running as PID 1. ParentWatch working as designed; reconnaissance §15 item 8.)
        # The excludes ride along (stage-12 §11.3, measured on the Nextcloud pilot): the
        # forecast must describe the tree the indexer WOULD walk — an estimate counting the
        # folders the job will exclude is a forecast of work nobody will do.
        argv = [self.binary, "estimate", *self.roots, "--index", self.index]
        if self.excluded:
            argv += sum([["--exclude", p] for p in self.excluded], [])
        if self.excluded_extensions:
            argv += ["--exclude-ext", ",".join(self.excluded_extensions)]
        return argv + ["--json"]

    def speed_argv(self, *, when_quiet_s: float = 5.0, tries: int = 3) -> list[str]:
        return [self.binary, "speed", "--model", "--json", "--when-quiet", f"{when_quiet_s:g}",
                "--tries", str(tries), "--index", self.index]
