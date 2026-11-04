"""The media-handle semantics `docs/API.md` promises clients (step: media identifiers).

These are the properties a multi-application client designs against, pinned at the unit level
(no engine, no lifespan): handles are per-reply (two replies never share one), the cache is
bounded and a real LRU (a browsing session refreshes its own on-screen handles), and handles
die with the process. `tests/test_media_ui.py` pins the HTTP side (`404` for an unissued id,
previews, text, `/file`); this file pins the rules the doc states.
"""

from __future__ import annotations

from digup_server.api import HitCache


def put(cache: HitCache, path: str = "/media/photos/a.jpg") -> str:
    return cache.put(path, "image", 1, None, False)


def test_handles_are_per_reply_never_global():
    """The same file in two replies gets two handles: a client may not cache a `media_id`
    across searches, and may not share one between clients."""
    cache = HitCache(capacity=8)
    first, second = put(cache), put(cache)
    assert first != second
    assert cache.get(first)["path"] == cache.get(second)["path"]


def test_the_cache_is_bounded_and_a_true_lru():
    """A bounded cache: oldest-unused goes. `get()` refreshes, which is what keeps the handles
    a session is looking at alive while it keeps searching (the Stage-11 fix)."""
    cache = HitCache(capacity=2)
    a, b = put(cache), put(cache)
    assert cache.get(a) is not None              # refresh: a is now the most recently used
    c = put(cache)
    assert cache.get(c) is not None
    assert cache.get(b) is None                  # b is the least recently used: gone
    assert cache.get(a) is not None


def test_handles_are_the_process_lifespan_not_a_durable_identifier():
    """A new cache is what a restart is: every handle from before it answers as unknown. A
    client keys its own records on the engine's identity fields (path + kind + segment_id,
    plus loc for a moment), never on a media_id."""
    cache = HitCache(capacity=4)
    issued = put(cache)
    assert cache.get(issued) is not None
    after_restart = HitCache(capacity=4)
    assert after_restart.get(issued) is None
