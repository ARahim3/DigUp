"""Fixtures for the engine contract tests: the real CLI, the real corpus, a real index.

These run **inside** the engine container (`server/docker/Dockerfile`'s `server-test`
stage). On a host without a Linux `digup` they skip themselves — by design: contract tests
prove the *engine's* protocol, so there is nothing to prove against a mock.

Environment (set by the container):
  DIGUP_BIN            the engine's binary (default: `digup` on PATH)
  DIGUP_SERVER_CORPUS  the corpus folder (server/tests/corpus/media: photos/ videos/ clips/)
  DIGUP_SERVER_MODELS  the model folder → DIGUP_MODELS (the engine looks *only* there)
  DIGUP_SERVER_INDEX   main index folder; `digup index` fills it once if it's empty
"""

from __future__ import annotations

import os
import shutil
from pathlib import Path

import pytest

from digup_server.engine import EngineConfig, IndexService, SearchService, cli

PHOTOS = ["wakeboard-logan.jpg", "cat-sitting-on-a-sofa.jpg", "a-dog-running-on-the-beach.jpg",
          "people-surrounding-campfire.jpg"]


def _cfg(index, roots, **kw) -> EngineConfig:
    return EngineConfig(index=str(index), roots=tuple(str(r) for r in roots),
                        binary=os.environ.get("DIGUP_BIN", "digup"),
                        models_dir=os.environ.get("DIGUP_SERVER_MODELS"), **kw)


def _cli_index(config: EngineConfig, timeout: float) -> None:
    """One-shot `digup index <roots>` — the conftest's own index, plain CLI, no service."""
    cli.run([config.binary, "index", *config.roots, "--index", config.index],
            config.env(), timeout=timeout)


@pytest.fixture(scope="session", autouse=True)
def engine_available():
    """No engine/corpus/model → the whole contract suite skips (never mocks)."""
    need = {"DIGUP_SERVER_CORPUS": "the corpus folder",
            "DIGUP_SERVER_MODELS": "the model folder"}
    missing = [f"{k} ({what})" for k, what in need.items() if not os.environ.get(k)]
    binary = os.environ.get("DIGUP_BIN", "digup")
    if not shutil.which(binary):
        missing.append(f"DIGUP_BIN={binary} not on PATH")
    if missing:
        pytest.skip("engine contract tests need: " + ", ".join(missing), allow_module_level=True)


@pytest.fixture(scope="session")
def corpus() -> Path:
    root = Path(os.environ["DIGUP_SERVER_CORPUS"])
    if not (root / "photos").is_dir():
        pytest.skip(f"{root} has no photos/ — run server/tests/corpus/build.sh",
                    allow_module_level=True)
    return root


@pytest.fixture(scope="session")
def corpus_root() -> Path:
    """The corpus *folder* (with manifest.tsv, corpus.json, build.sh…): the files the engine
    skips — which is exactly what `estimate --json` chokes on (test_cli pins it)."""
    root = Path(os.environ.get("DIGUP_SERVER_CORPUS_ROOT", "/corpus-root"))
    if not root.is_dir():
        pytest.skip("needs DIGUP_SERVER_CORPUS_ROOT mounted (server/tests/corpus)",
                    allow_module_level=True)
    return root


@pytest.fixture(scope="session")
def index(corpus) -> Path:
    """The main index the Stage-2 proof built; on a fresh run this fills it once (~4 min)."""
    folder = Path(os.environ.get("DIGUP_SERVER_INDEX") or "/tmp/digup-server-index")
    folder.mkdir(parents=True, exist_ok=True)
    if not (folder / "index.sqlite").exists():
        _cli_index(_cfg(folder, (corpus,)), timeout=3600.0)
    return folder


@pytest.fixture(scope="session")
def search(corpus, index):
    """One hot search-service for the whole session: the API's window on the engine."""
    service = SearchService(_cfg(index, (corpus,)))
    ready = service.start()
    yield {"service": service, "ready": ready, "config": _cfg(index, (corpus,))}
    service.quit()


@pytest.fixture(scope="session")
def scratch(corpus, tmp_path_factory) -> Path:
    """A tiny corpus of our own: 4 pinned photos, the 3-scene clip, and a text file whose
    words a search can quote back. Built for the index-service, job, and media tests
    (session scope: one indexing stretch shared, not one per module)."""
    if not (corpus / "clips" / "scenes.mp4").is_file():
        pytest.skip("corpus clips/scenes.mp4 missing — run server/tests/corpus/build.sh")
    root = tmp_path_factory.mktemp("scratch-corpus")
    (root / "photos").mkdir()
    (root / "clips").mkdir()
    for name in PHOTOS:
        shutil.copy(corpus / "photos" / name, root / "photos" / name)
    shutil.copy(corpus / "clips" / "scenes.mp4", root / "clips" / "scenes.mp4")
    (root / "notes.txt").write_text(
        "The campfire stories continued after midnight, long after the marshmallows.\n",
        encoding="utf-8")
    return root


@pytest.fixture(scope="session")
def scratch_index(scratch, tmp_path_factory):
    """Index the scratch corpus once, through the IndexService, and keep its event log.
    Session scope: the event log is immutable, so modules after indexing see the same
    story; files added later (jobs, media tests) only add to the index."""
    folder = tmp_path_factory.mktemp("scratch-index")
    service = IndexService(_cfg(folder, (scratch,)), backfill=True, linger_s=2.0)
    service.start()
    service.sync()
    events = list(service.events(timeout=1800.0))
    service.finish()
    return folder, events
