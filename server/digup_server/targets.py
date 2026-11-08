"""Named indexes (stage-13): the standalone media target plus per-application targets.

The server's own media index stays exactly as it has always been — one set of roots,
one index folder, the UI on top of it. An application target is a NAMED pair of
(roots, index folder) the same server supervises independently: its own writer lock
(the flock lives beside the index folder, so per-target locking is the existing
design), its own jobs log, its own search-service child, its own token. A Nextcloud
bridge pointing at the server with its own token therefore indexes and searches its
OWN index, and never touches the media index — and a second application gets its own
target, its own lock, its own log, its own token. The engine changes nothing: it
already answers for any (roots, --index) pair.

Registry sources, merged with env winning per name:

  DIGUP_SERVER_APP_TARGETS=nc=/media/nc:/media/nc2:/idx/nc;dc=/media/dc:/idx/dc
      entries split on ';'; each entry is `name=roots:index`, the roots colon-separated
      (the same os.pathsep split the main roots use), the index the LAST folder.

  <config>/targets.json — {"name": {"roots": [...], "index": "..."}} — for registrations
      the operator made at runtime (a future API surface); persisted so recreation never
      loses them, like every other config-folder fact (README §5).

Validation is strict on purpose: names are lowercase slugs (letters/digits/dashes,
starting alphanumeric, ≤32 chars — they ride in log lines, jobs files, and URLs), roots
and index must be absolute, the index may not be the main index
(the whole point is that they are DIFFERENT indexes), and the reserved name `media` is
the main target's — an app target may not take it. Malformed entries are refused at
startup with the entry quoted: a silently-dropped target is an outage nobody asked for
(the same rule as DIGUP_SERVER_READ_TOKENS).
"""
from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass

MAIN_TARGET = "media"                      # the standalone media index; reserved

_NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,31}$")


@dataclass(frozen=True)
class Target:
    name: str
    roots: tuple[str, ...]
    index: str
    main: bool = False


def parse_app_targets(value: str, main_index: str | None = None) -> dict[str, Target]:
    """`DIGUP_SERVER_APP_TARGETS` → {name: Target}. Raises ValueError quoting the entry.

    Each entry is `name=roots:index`: the roots are the colon-separated list (the same
    os.pathsep shape `DIGUP_SERVER_ROOTS` uses) and the index is the LAST folder. Two
    colons minimum (root list + index) keep every entry unambiguous; validation below
    refuses relative paths, so a misplaced folder names itself.
    """
    targets: dict[str, Target] = {}
    for entry in (value or "").split(";"):
        entry = entry.strip()
        if not entry:
            continue
        name, sep, rest = entry.partition("=")
        parts = [p for p in rest.split(":") if p.strip()]
        if not sep or len(parts) < 2:
            raise ValueError(f"DIGUP_SERVER_APP_TARGETS: {entry!r} is not 'name=roots:index' "
                             "(the index is the last colon-separated folder)")
        name = name.strip().lower()
        targets[name] = _validated(name, os.pathsep.join(parts[:-1]), parts[-1].strip(),
                                   main_index=main_index)
    return targets


def load_targets_file(path: str, main_index: str) -> dict[str, Target]:
    """<config>/targets.json → {name: Target}. A missing file is the empty registry; a
    corrupt one is refused loudly (config files are operator facts, not suggestions)."""
    try:
        with open(path, encoding="utf-8") as handle:
            raw = json.load(handle)
    except FileNotFoundError:
        return {}
    except json.JSONDecodeError as exc:
        raise ValueError(f"{path}: not valid JSON ({exc})") from exc
    targets: dict[str, Target] = {}
    for name, spec in raw.items():
        name = str(name).strip().lower()
        roots = (spec.get("roots") or []) if isinstance(spec, dict) else []
        index = str((spec.get("index") or "") if isinstance(spec, dict) else "")
        targets[name] = _validated(name, os.pathsep.join(roots), index, main_index=main_index)
    return targets


def _validated(name: str, roots_blob: str, index: str,
               main_index: str | None = None) -> Target:
    if not _NAME_RE.match(name):
        raise ValueError(f"application target name {name!r} is not a lowercase slug "
                         f"(letters, digits, dashes, starting with a letter)")
    if name == MAIN_TARGET:
        raise ValueError("the target name 'media' is the main media index's own — reserved")
    roots = tuple(r for r in roots_blob.split(os.pathsep) if r.strip())
    if not roots:
        raise ValueError(f"application target {name!r} has no roots")
    for r in roots:
        if not os.path.isabs(r):
            raise ValueError(f"application target {name!r} root {r!r} is not an absolute path")
    if not os.path.isabs(index):
        raise ValueError(f"application target {name!r} index {index!r} is not an absolute path")
    if main_index is not None and os.path.realpath(index) == os.path.realpath(main_index):
        raise ValueError(f"application target {name!r} index is the main index — targets are "
                         "separate indexes by definition (docs/API.md, named indexes)")
    return Target(name=name, roots=tuple(roots), index=index)


def build_registry(env: dict[str, str], main_roots: tuple[str, ...],
                   main_index: str, config_dir: str) -> dict[str, Target]:
    """The deployment's targets: main first, app targets from env then the persisted
    file (env wins on a name clash: the operator's env is the authority)."""
    registry: dict[str, Target] = {
        MAIN_TARGET: Target(name=MAIN_TARGET, roots=main_roots, index=main_index, main=True),
    }
    file_targets = load_targets_file(os.path.join(config_dir, "targets.json"), main_index)
    env_targets = parse_app_targets(env.get("DIGUP_SERVER_APP_TARGETS", ""), main_index)
    for name, target in file_targets.items():
        registry[name] = target
    for name, target in env_targets.items():          # env wins, per name
        registry[name] = target
    return registry
