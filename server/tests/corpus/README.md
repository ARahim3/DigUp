# Corpus for the semantic-search proof

A tiny, labeled, real corpus for the server: 12 Commons photographs (committed, 1024 px renders),
two real videos (fetched on demand), and one synthetic clip whose scene boundaries are known to
the second. `corpus.json` is the ground truth the headless proof, the adapter's tests and the
acceptance run assert against.

This is deliberately **not** `scripts/make-testbed.sh`: that is a macOS tool (APFS clones of your
own files, screenshot xattrs, Swift generators run under Xcode). This corpus is the Linux/server
equivalent: pinned, attributed, reproducible, indexable in a container with no GUI.

## Layout

| path | in git | what it is |
|---|---|---|
| `photos/*.jpg` | yes | 12 photographs, each pinned in `manifest.tsv` by sha256 |
| `videos/*.webm` | no | the two pinned videos, fetched by `build.sh` (92 MB — not committed) |
| `clips/scenes.mp4` | no | 18 s of three 6 s scenes, made by `build.sh` with ffmpeg |
| `index/` | no | the DigUp index built from this corpus (`--index`) |
| `manifest.tsv` | yes | `name · Commons title · role · license · author · source page · URL · bytes · sha256` |
| `corpus.json` | yes | queries with their expected answers, in the `evals/` file format |

Roles are the ground truth: `wakeboarding`, `hiking`, `campfire`, `dog-beach`, `boat-sunset`,
`fishing-dock`, `christmas-dinner`, `wakeboarding-video`, `hiking-video`, and three `control`
pictures (a cat on a sofa, an office desk, a parking lot) that must stay below the real matches.

One picture is named with a space and a non-ASCII letter (`hiking trail at Námafjall.jpg`):
filename handling is part of what is being tested.

## Build it, index it, measure it

```sh
server/tests/corpus/build.sh                       # photos + videos + clips/scenes.mp4
export CORPUS="$PWD/server/tests/corpus/media"

digup index "$CORPUS" --index "$DIGUP_INDEX"       # the engine, headless
digup status --index "$DIGUP_INDEX"
DIGUP_TESTBED="$CORPUS" digup eval server/tests/corpus/corpus.json -n 10 --index "$DIGUP_INDEX"
```

`corpus.json` uses the eval file's own conventions — `"base": "~/DigUpTestbed"`, expected answers
as `path`, a moment as `path@lo-hi`, plus `tag` and `kind` — so the recall numbers it prints are
the same numbers `evals/` prints for the rest of the project, and `DIGUP_TESTBED` points the file
at this corpus.

`build.sh` needs ffmpeg only for the synthetic clip, and the clip needs an encoder: libx264 and the
mp4 muxer. The engine's own `Vendor/ffmpeg/bin/ffmpeg` is a decode-only build (`scripts/build-ffmpeg.sh`:
no lavfi sources, no libx264 — see `docs/implementation/stage-1-linux-build.md`), so `build.sh` probes
each candidate and accepts only one that lists both; the system ffmpeg (`apt install ffmpeg`, Homebrew's)
qualifies, the engine's never can, and a missing clip is a hard CI gate, not a silent skip.

## Provenance

Every picture and video is a Wikimedia Commons file, used under the license Commons records, with
author, source page, a pinned 1024 px render URL and a pinned sha256 in `manifest.tsv`. URLs use
`Special:FilePath`, Wikimedia's documented "give me this file" address. `build.sh` refuses a file
whose digest differs from its pin. The synthetic clip comes from ffmpeg's own sources
(`smptebars`, `mandelbrot`, `testsrc2`): no third-party content, reproducible.

| file | author | license |
|---|---|---|
| `wakeboarding-aarhus-04.jpg` | Ciara Ní Riain | CC BY-SA 4.0 |
| `wakeboard-logan.jpg` | Logan wake (transferred by T137) | Public domain |
| `hiking trail at Námafjall.jpg` | Jakub Hałun | CC BY 4.0 |
| `people-surrounding-campfire.jpg` | V3N0M V1V14N | CC BY-SA 4.0 |
| `a-dog-running-on-the-beach.jpg` | Bruce Emmerling | CC BY-SA 4.0 |
| `boats-at-sunset-pakse-laos.jpg` | Basile Morin | CC BY-SA 4.0 |
| `fishing-from-dock-oregon.jpg` | Gary Halvorson, Oregon State Archives | Attribution 4.0 |
| `man-on-dock-with-fish-1900.jpg` | John Fletcher Ford | Public domain |
| `christmas-eve-dinner-table.jpg` | Chris Olszewski | CC BY-SA 4.0 |
| `cat-sitting-on-a-sofa.jpg` | Smirkybec | CC BY-SA 4.0 |
| `office-desk-with-monitor.jpg` | Shixart1985 | CC BY 2.0 |
| `cars-in-a-parking-lot.jpg` | Ka23 13 | CC BY 4.0 |
| `wakeboarding-vienna.webm` | Rpoth | CC BY-SA 3.0 |
| `pct-hiking-southern-oregon.webm` | Bureau of Land Management Oregon & Washington | Public domain |
