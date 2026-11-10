# Stage 2 — headless proof: the DigUp engine indexes a corpus and answers it, no UI

Date: 2026-11-02. This is the proof the server is built on: **the original engine, in a Linux
container, with no display server, no desktop shell, no Tauri, no GPU — indexing a labeled
corpus and ranking natural-language searches from it.** Every word quoted below is the
engine's own output; nothing is mocked, nothing is adjusted.

## Command

Run inside the CPU runtime image from Stage 1 (`digup-engine:local`, 296 MB, arm64, user
`digup`), with the corpus, the verified model files and an index folder mounted:

```sh
cd ~/Projects/digup
docker run --rm --platform linux/arm64 \
  -v "$PWD:/src:ro" \
  -v "$PWD/server/tests/corpus/media:/corpus:ro" \
  -v "$HOME/Projects/digup-data/models:/models:ro" \
  -v "$HOME/Projects/digup-data/index:/index" \
  -v "$PWD/server/tests/corpus:/out" \
  -e DIGUP_MODELS=/models -e OUT=/out/proof \
  digup-engine:local bash /src/server/tests/proof.sh
```

`server/tests/proof.sh` calls, in order: `speed --model`, `estimate`, `index`, `status`,
11 searches (9 text + 2 `--kind video`, each with `--json`), `eval`, `status`. The whole run
took ~5 min on 7 emulated… **native arm64** cores, CPU only. Per-step logs land in
`server/data/proof/*.log` (git-ignored runtime evidence; lived under `corpus/proof/`
until the Stage-8 tidy); the transcript is the run's stdout.

## What the engine reported

**Device and cost calibration** (`speed --model`; `backends: CPU` — the only backend in this
image; no CUDA, no Vulkan, and none needed):

```
the model loaded in 11.91 s; the check took 79.0 s; tries 21.98 s, 21.41 s
  frame 4.140 s (M4 Pro 0.067 s, ×61.8) … text 2.357 s (M4 Pro 0.026 s, ×90.6)
kept in /index/costs.json: audioSecond ×50.3 · codeStretch ×64.0 · docChunk ×52.8 ·
  image ×61.8 · pdfPage ×26.9 · screenshot ×51.2 · videoSecond ×56.4
```

**Index run** (`index /corpus`): `sync: 15 new`, 12 images + 3 videos, **all 15 `done`,
`done in 4 min`** — including the unicode+space filename `hiking trail at Námafjall.jpg` and
the 59 MB `.webm` (`14 frames, 2 sound windows, 44 s`).

**Index after** (`status`):

```
vectors: 37 in 37 segments
  image 12 12 done · video 3 3 done
built with: google/embeddinggemma-2@bfcd298 llama.cpp-vectors1 text-q8_0+mmproj-q8_0 | photo140 shot280 page280 frame70/3.0s audio30.0/25.0s
this digup: llama.cpp b11461, vectors 1 · size: 135 KB
```

`estimate /corpus` said "first index ≈ 3 min" before the 4-minute run — the calibration is
real, and `estimate`'s plain output works.

## The searches (engine's own ranking, verbatim)

| query | engine's answer |
|---|---|
| `wakeboarding` | 1 video **wakeboarding-vienna.webm** (z 1.6) · 2 **wakeboard-logan.jpg** (z 1.6) · 3 **wakeboarding-aarhus-04.jpg** (z 0.5) — 3 hits, no controls, no unrelated files |
| `hiking` | 1 video **pct-hiking-southern-oregon.webm [at 0:09]** (z 2.8) · 2 **hiking trail at Námafjall.jpg** (z 1.4) |
| `people sitting around a campfire` | 1 **people-surrounding-campfire.jpg** (z 4.7, cosine 0.77) |
| `a dog running on the beach` | 1 **a-dog-running-on-the-beach.jpg** (z 4.0) |
| `a boat on the water at sunset` | 1 **boats-at-sunset-pakse-laos.jpg** (z 1.5) |
| `someone fishing from a dock` | 1 **fishing-from-dock-oregon.jpg** · 2 **man-on-dock-with-fish-1900.jpg** (1900 photo, matched by *content* — its filename says nothing about fishing) |
| `Christmas dinner` | 1 **christmas-eve-dinner-table.jpg** (z 4.7) |
| `cars in a parking lot` | 1 **cars-in-a-parking-lot.jpg** (z 3.5) · 2 wakeboarding-vienna.webm **[at 0:00 (sound)]** — the engine matched a *sound window*, not a picture: the clip's first 30 s audio scored z 2.0 below the photo |
| `wakeboarding --kind video` | 1 wakeboarding-vienna.webm — kind filter works |
| `a fractal --kind video` | 1 **clips/scenes.mp4 [at 0:09]** (z 2.8) — the synthetic clip's *fractal scene* (the 6–12 s scene), frame segment `loc 9.5–12.5` |
| `a person riding a wakeboard behind a boat` | **"no good matches"** + `[]` — see §Honest below |

The `--json` shape the adapter will consume is exactly `hitFields()`: `path, kind, segment,
segment_id, score, modified, size, info` + `z, cosine, keyword_rank, loc, loc_end` — e.g. the
hiking video hit carries `"loc": 9.5, "loc_end": 12.5, "segment": "frame", "keyword_rank": 1`
and `info {duration, frames, sound_windows}`; the images carry `info {width, height, taken}`.

## Eval (`digup eval corpus.json`, the project's own metric)

```
ALL  17 queries   R@1 0.71 · R@5 0.88 · R@10 0.88 · MRR 0.79
image 12           R@1 0.67 · R@5 0.92 · MRR 0.79
video  5           R@1 0.80 · MRR 0.80
weaker-matches fold (below 0.5× the top score): 0 expected answers folded
```

15 of 17 queries answer **at rank 1, three of them with exact timestamps**
(`scenes.mp4 [at 0:00]` for "television test bars", `[at 0:09]` for "a fractal",
`pct-hiking [at 0:09]` for hiking). The two misses, verbatim:

```
miss  image  “a person riding a wakeboard behind a boat”  top: -
miss  video  “a test pattern with a moving ramp and numbers”  top: scenes.mp4 [at 0:00]
```

First one: the engine answered **"no good matches" and an empty array**. It had the wakeboard
photos in the index (they ranked 1–3 for `wakeboarding`), but for that long phrasing no vector
cleared its bar, and it refused to invent a ranking. That is the behaviour the server must
expose honestly — an empty honest result, not a fake "best guess".
Second: for the testsrc2 scene (ramp + numbers, 12–18 s) the model pointed at the *test-bar*
scene (0:00) — a semantic near-miss on synthetic content, inside the right file.

## Honest — what this does and does not prove

- **Proves**: the Linux build (Stage 1) does the whole pipeline headlessly — crawl, decode
  (stb images, ffmpeg video + audio windows), embed (EmbeddingGemma 2 Q8_0 via llama.cpp CPU),
  store (SQLite 37 vectors/segments), rank, timestamp, filter by kind, and evaluate. The
  rankings are content-based (the 1900 dock photo found by picture, the campfire/dog/boat/
  Christmas hits at z 4+ with cosine ~0.75), the controls (cat/sofa, office desk) stayed out of
  every target query's hits, and the synthetic clip's scene boundaries were found to ~3 s
  (frames are sampled every 3.0 s — `frame70/3.0s` — so `[at 0:09]` is the 9.5 s frame inside
  the 6–12 s scene: as exact as the engine's own sampling grid).
- **Does not prove**: GPU paths (this image has no Vulkan/CUDA, by design), the
  `search-service`/`index-service` protocols under load (Stage 3), scale (15 files).
- **Costs measured, not assumed**: each one-shot `search` pays encoder start-up (~2–4 s,
  "query encoder 3.29 s incl. start-up"); the persistent `search-service` exists exactly to
  avoid that, and the adapter will use it.
- One **finding of Stage 2, corrected in Stage 3 — kept visible on purpose**: `digup
  estimate --json` printed nothing during the proof (exit 0, every folder), and Stage 2
  attributed it to a swallowed serialization failure. That was a misdiagnosis:
  `estimate --json` calls `ParentWatch.start()` (`main.swift:699`), which exits the helper
  when its parent is PID 1 — "the app is gone" — and the proof's script *is* PID 1's
  `bash`. With a live parent the same binary streams its JSON lines fine (skipped files
  counted, tested in `server/tests/test_cli.py`). The engine behaved exactly as designed;
  the server must spawn helpers as direct children of the long-lived API process — which
  `protocol.py` enforces — and the API can use `estimate --json`. What this documents for
  the PR: a PID-1 invocation of any ParentWatch helper (`index-service`, `worker`,
  `search-service`, `estimate --json`) exits in ≤ 1 s — the supervision rule of the house.

## Evidence

- Run transcript: 428 lines, `EXIT=0`, per-step logs in `server/data/proof/` (speed,
  estimate, index, status, `search-1…9` + `-json`, `search-video-json`, `search-fractal-json`,
  eval, status-after).
- Corpus and pins: `server/tests/corpus/` (manifest pins verified against fetched files,
  including the two videos `9422c8d1…`, `79db23e6…`, and the clip `528db370…`).
- Model files verified against `Sources/DigUpKit/ModelFiles.swift` (Stage 1 doc).

## What the adapter must respect (contract, from this run's own words)

1. Use `search-service` (hot encoder), not repeated one-shot `search` — start-up is seconds.
2. Keep the engine's fields verbatim (`score, z, cosine, keyword_rank, loc, loc_end, segment,
   info`) and its "no good matches" state — the API returns hits + `strong`/`warning`, never a
   manufactured percentage.
3. Timestamps are seconds (`loc`/`loc_end`), tied to the 3 s frame grid and 30 s audio windows
   — expose them as-is.
4. Kind filters (`--kind video`) are engine-side.
5. `costs.json`/`speed.json` live beside the index and are the engine's, read-only for the
   server.
6. Index writes happen under a single writer (one `index-service`), the adapter owns that lock.
