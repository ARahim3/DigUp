"""DigUp's own CLI as supervised processes — the only code in the server that spawns the engine.

`SearchService` and `IndexService` speak the JSON-lines protocols documented in
`Sources/digup/SearchService.swift` and `Sources/digup/IndexService.swift` — the same ones the
shipping Tauri shell uses, so upstream keeps them working. `cli` runs the read-only one-shot
commands. Nothing here re-ranks, re-scores, caches in a parallel store, or invents fields.
"""

from .config import EngineConfig
from .index import IndexBusy, IndexService
from .search import SearchService

__all__ = ["EngineConfig", "IndexBusy", "IndexService", "SearchService", "cli"]
