# corpus2 — 60 Commons photographs for the server's own live testing

The frozen corpus (`server/tests/corpus`) is exactly 15 files, and the suite's ranking
assertions (`corpus.json`) depend on that exact set: the engine's z-scores normalize over
the live candidate rows, so adding photos there would change every pinned ranking. **Extra
test images therefore live here, in a second corpus** — 60 photographs, 3 for each of 20
subjects, taken from Wikimedia Commons (the same source `corpus/` uses), fetched as 1400 px
renders.

* `titles.tsv` — the Commons search hits, curated by hand (name ↔ wiki title).
* `build.sh` — fetches the pins in `manifest.tsv` and verifies each sha256.
  `BAKE=1 build.sh` (re)writes the manifest from `titles.tsv` after a fresh fetch.
* The photos themselves are **not in git** (≈15 MB of bytes the manifest pins; the
  `.gitignore` entry keeps them out) — one `build.sh` run materializes them, like the
  corpus's videos.

It is *testing* material, for the running server: point Compose at it and the UI has a real
gallery to browse — 60 photos, meaning search, previews, opening files:

```bash
server/tests/corpus2/build.sh                       # fetch + verify the pinned renders
cd deploy
DIGUP_INDEX_DIR=$HOME/Projects/digup-data/index-corpus2 \
DIGUP_MODELS_DIR=$HOME/Projects/digup-data/models \
DIGUP_MEDIA_DIR=$PWD/../server/tests/corpus2/media \
docker compose up -d
# then: Index now in the UI (http://127.0.0.1:8787/) — 60 photos, ≈ 8 min on 7 CPU cores
```

The suite does **not** run against corpus2: its assertions are the frozen corpus's. This
corpus is for live proofs, UI runs, and the manual sweep of every endpoint — a bigger,
varied, licensed corpus with the same discipline (pinned bytes, honest source notes).

**Expect fewer strong hits per query than a real library.** 61 files is a small gallery,
and the engine publishes a hit only above its own z-gate of 2.0 sigma over the indexed
set (`zGate` in `Sources/DigUpKit/Searcher.swift`, identical on Mac, shell and server).
On a personal library of thousands of files the same engine answers many more matches
above 2σ; the server adds no cap of its own, and the UI shows the engine's counts
verbatim. A 1-hit answer here is the size of the corpus, not a filter, a limit, or a bug.

## Provenance and licenses

Every file is a Wikimedia Commons file, fetched through
`https://commons.wikimedia.org/wiki/Special:FilePath/<title>?width=1400` (the wiki's own
thumbnail service). Each title is a Commons search hit (`action=query&list=search`,
namespace 6), picked by hand from 20 subject queries. License and author are on each
file's Commons page — e.g. `https://commons.wikimedia.org/wiki/File:<title>` — most are
CC BY / CC BY-SA / public-domain; the `File:` names carry the attribution the uploader
chose. The pinned sha256 in `manifest.tsv` is of the 1400 px render as fetched (2026-11-02).
Fetch user-agent: `DigUpServer-corpus2/1.0`.
