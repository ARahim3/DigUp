#!/bin/bash
# Builds the testbed: a deletable sandbox for trying DigUp on realistic files.
#   real/       APFS clones of a seeded random sample of your own files (no extra disk space)
#   synthetic/  generated media with known content: the ground truth for evals
#   traps/      cases the crawler must get right (TypeScript .ts, code projects, datasets, icons, bundles, odd names)
#   code/       small git repos with known functions, for code search (evals/code.json)
#
#   scripts/make-testbed.sh [dir]        default: ~/DigUpTestbed
# Delete it any time: rm -rf ~/DigUpTestbed
set -euo pipefail
TB="${1:-$HOME/DigUpTestbed}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
command -v ffmpeg >/dev/null || { echo "needs ffmpeg (brew install ffmpeg)"; exit 1; }
[[ -e "$TB" ]] && { echo "$TB already exists; delete it first (rm -rf \"$TB\")"; exit 1; }
mkdir -p "$TB"

echo "== real/: sampling your files (clones) =="
python3 -I "$REPO/scripts/testbed/sample_real.py" "$TB"

echo "== synthetic/ =="
S="$TB/synthetic"
"$REPO/scripts/testbed/make_media.sh" "$S" >/dev/null
rm -rf "$S/audio_trunc" "$S/audio/bench_60s.wav" "$S/video/bench_45s.mp4" "$S/video"/seg_*.mp4
mv "$S/shots" "$S/screenshots"
for f in "$S/screenshots"/*.png; do xattr -w com.apple.metadata:kMDItemIsScreenCapture 1 "$f"; done
swift "$REPO/scripts/testbed/make_docs.swift" "$S/docs" >/dev/null
swift "$REPO/scripts/testbed/make_long.swift" "$S/long" >/dev/null   # deep pages: read after the first pass
"$REPO/scripts/testbed/make_lang.sh" "$S/lang"   # Bengali and Arabic (evals/multilingual.json)

echo "== traps/ =="
T="$TB/traps"; mkdir -p "$T"
# TypeScript files that Spotlight types as MPEG-2 video; and one real MPEG-TS video that must still be indexed.
mkdir -p "$T/ts-code" "$T/real-mpeg-ts"
printf 'export const greet = (name: string): string => `hello ${name}`;\n' > "$T/ts-code/app.ts"
printf 'import { greet } from "./app";\nconsole.log(greet("zebra"));\n' > "$T/ts-code/main.mts"
ffmpeg -loglevel error -i "$S/video/penguin_zebra_parrot_18s.mp4" -c copy -f mpegts "$T/real-mpeg-ts/zoo clip.ts"
# A code project: only its screenshot should be indexed.
P="$T/MyProject"; mkdir -p "$P/.git" "$P/assets" "$P/node_modules/lib" "$P/screenshots"
echo '{"name": "my-project"}' > "$P/package.json"
cp -c "$S/img/Animals-Owl.jpg" "$P/assets/hero.jpg"
cp -c "$S/img/Animals-Eagle.jpg" "$P/node_modules/lib/logo.jpg"
cp -c -p "$S/screenshots/shot_weather.png" "$P/screenshots/Screenshot 2026-10-02 at 8.15.40 AM.png"
# node_modules outside a project, a hidden folder, and an app bundle: all skipped.
mkdir -p "$T/node_modules/pkg" "$T/.hidden" "$T/Fake.app/Contents/Resources"
cp -c "$S/img/Nature-Leaf.jpg" "$T/node_modules/pkg/leaf.jpg"
cp -c "$S/img/Nature-Zen.jpg" "$T/.hidden/zen.jpg"
cp -c "$S/img/Fun-Medal.jpg" "$T/Fake.app/Contents/Resources/medal.jpg"
# Icons below the 256 px minimum: skipped.
mkdir -p "$T/icons"
for px in 32 64 128; do sips -s format png -Z $px "$S/img/Sports-Target.jpg" --out "$T/icons/target-$px.png" >/dev/null; done
# A dataset: 600 machine-named clips in one folder -> the detector should flag it.
mkdir -p "$T/dataset_clips"
ffmpeg -loglevel error -f lavfi -i "sine=frequency=440:duration=1" -ac 1 -ar 16000 "$T/dataset_clips/clip_000000.wav"
for i in $(seq -f "%06g" 1 599); do cp -c "$T/dataset_clips/clip_000000.wav" "$T/dataset_clips/clip_$i.wav"; done
# Odd names: spaces, non-ASCII, and the narrow no-break space (U+202F) macOS puts before AM/PM.
N="$T/Names with spaces & ünïcödé"; mkdir -p "$N"
cp -c -p "$S/screenshots/shot_chat_meeting.png" "$N/Screenshot 2026-10-05 at 9.41.07"$' '"PM.png"
cp -c "$S/img/Flowers-Sunflower.jpg" "$N/Café menü — 日本語.jpg"
# Duplicates: the same photo under two names.
mkdir -p "$T/duplicates"
cp -c "$S/img/Animals-Penguin.jpg" "$T/duplicates/penguin.jpg"
cp -c "$S/img/Animals-Penguin.jpg" "$T/duplicates/penguin copy.jpg"

echo "== code/ =="
python3 -I "$REPO/scripts/testbed/make_code.py" "$TB/code"

cat > "$TB/README.md" <<'EOF'
# DigUp testbed

A sandbox for testing DigUp. Delete it whenever you like: `rm -rf ~/DigUpTestbed`.
Rebuild it with `scripts/make-testbed.sh` in the emgemma_app repo.

- `real/`: APFS clones of a random sample of your own files (screenshots, images, PDFs, docs, videos, audio).
  Clones share disk blocks with the originals, so they take no extra space; deleting them never touches the
  originals. `real/MANIFEST.tsv` lists where each one came from. This folder holds personal files: never commit or
  upload it.
- `synthetic/`: generated media with known content (macOS sample pictures, synthetic UI screenshots, TTS speech, a
  penguin/zebra/parrot video, PDFs and notes; `lang/` has Bengali and Arabic ones; `long/` a 120-page PDF, long
  notes and a dump of numbers). This is the ground truth for automated evals.
- `traps/`: cases the crawler must handle: TypeScript `.ts` files (not videos), a real MPEG-TS video (is a video),
  a code project (only its screenshot counts), `node_modules`, hidden folders, an app bundle, tiny icons, a
  600-clip dataset, odd file names, and duplicates.
- `code/`: four small git repos (Python, Swift, TypeScript, notebooks) and loose scripts with known functions, for
  code search (`evals/code.json`); each repo also holds what code search must leave out (vendored and built copies,
  generated and minified code, a private key, data).
EOF
echo "== done: $TB =="
du -sh "$TB" 2>/dev/null | sed 's/^/apparent size (clones share blocks with originals): /'
