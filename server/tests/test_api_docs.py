"""The API reference stays true to the app (docs/API.md is the compatibility promise).

`create_app()` builds the routes without spawning anything — the engine only starts inside the
lifespan — so this is a cheap tripwire that needs no engine, no corpus and no container: add an
endpoint and forget the docs, and this fails. The parameter *names* in the doc may differ from
the code's (`{id}` vs `{job_id}`), so each `{parameter}` segment matches any non-slash token.
"""

from __future__ import annotations

import re
from pathlib import Path

from digup_server.api import SearchRequest, create_app
from digup_server.engine import EngineConfig

DOC = Path(__file__).resolve().parent.parent / "docs" / "API.md"


def app_paths() -> list[str]:
    app = create_app(EngineConfig(index="/nonexistent-index", roots=("/nonexistent-root",)))
    return sorted({r.path for r in app.routes if r.path.startswith("/api/v1")})


def test_every_api_endpoint_is_documented():
    text = DOC.read_text(encoding="utf-8")
    missing = []
    for path in app_paths():
        pattern = "/".join("[^/`]+" if seg.startswith("{") else re.escape(seg)
                           for seg in path.split("/"))
        if not re.search(pattern, text):
            missing.append(path)
    assert not missing, f"endpoints missing from server/docs/API.md: {missing}"


def test_the_documented_default_limit_is_the_models_default():
    """The doc's `limit` row and the model's default cannot drift apart (step 1's decision:
    the API default equals the engine's own default, 40)."""
    default = SearchRequest.model_fields["limit"].default
    rows = [line for line in DOC.read_text(encoding="utf-8").splitlines()
            if line.startswith("| `limit` |")]
    assert rows, "API.md documents no `limit` parameter row"
    assert all(f"**{default}**" in line for line in rows), \
        f"API.md's limit row(s) do not carry the model's default ({default}): {rows}"


def test_the_api_version_and_the_openapi_surface_are_named_in_the_docs():
    text = DOC.read_text(encoding="utf-8")
    app = create_app(EngineConfig(index="/nonexistent-index", roots=("/nonexistent-root",)))
    assert app.openapi_url and app.docs_url
    for url in (app.openapi_url, app.docs_url):
        assert url in text, f"API.md does not name {url}"
