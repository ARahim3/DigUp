#!/usr/bin/env bash
# Builds the server's semantic-search corpus: the pinned Commons pictures (committed, 1024 px
# renders, pinned by sha256 in manifest.tsv), the pinned videos (fetched on demand), and one
# synthetic clip whose scene boundaries are known to the second.
#
#   server/tests/corpus/build.sh [dir]      default: server/tests/corpus/media
#
# It indexes nothing: `digup index <dir>` does that. The corpus is the input the headless proof,
# the adapter's tests and the web app's acceptance run share, so the assertions in corpus.json
# name these files exactly. See README.md for provenance and licenses.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
MEDIA="${1:-$HERE/media}"
UA="DigUpServer-corpus/1.0 (dev corpus setup; contact: https://github.com/ARahim3/DigUp)"
mkdir -p "$MEDIA/photos" "$MEDIA/videos" "$MEDIA/clips"

# ffmpeg: only the synthetic clip runs it; the photos and videos need nothing. The clip needs
# an ENCODER (libx264) and the mp4 muxer, so a candidate is accepted only when it lists both.
# The engine's own Vendor ffmpeg (scripts/build-ffmpeg.sh) is a decode-only build — its encoder
# list is pcm_s16le,mjpeg,ppm,rawvideo, no mp4 muxer — and is probed out by this check.
# Measured on CI run #3 (2026-11-05): the unprobed Vendor pick (the step-4 cache restores
# Vendor/ into the workspace) died on the clip with ffmpeg's exit 8, "Unknown encoder 'libx264'"
# — a structural mismatch, not a network or ABI one: the engine never encodes x264. An explicit
# FFMPEG=… is honoured as given.
ffmpeg_makes_the_clip() {  # true when "$1" encodes libx264 and muxes mp4 (the clip's demands)
  local out
  out="$("$1" -hide_banner -encoders 2>/dev/null)" && [[ "$out" == *" libx264 "* ]] || return 1
  out="$("$1" -hide_banner -muxers 2>/dev/null)" && [[ "$out" == *" mp4 "* ]]
}
FFMPEG="${FFMPEG:-}"
if [[ -z "$FFMPEG" ]]; then
  for candidate in "$HERE/../../../Vendor/ffmpeg/bin/ffmpeg" "$(command -v ffmpeg 2>/dev/null || true)"; do
    [[ -n "$candidate" && -x "$candidate" ]] || continue
    if ffmpeg_makes_the_clip "$candidate"; then FFMPEG="$candidate"; break; fi
  done
fi

digest() {  # sha256 of a file, 64 hex digits (coreutils' tool, with the BSD one as a fallback)
  sha256sum "$1" 2>/dev/null | cut -c1-64 || shasum -a 256 "$1" | cut -c1-64
}

get() {  # get <out> <url> <sha256>: fetch once, verify against the pin, keep
  local out="$1" url="$2" sha="$3"
  if [[ -f "$out" && "$(digest "$out")" == "$sha" ]]; then
    echo "  ok   ${out##*/}"; return 0
  fi
  echo "  get  ${out##*/}"
  curl --fail --silent --show-error --location --proto '=https' -A "$UA" --retry 3 --retry-delay 2 \
       -o "$out" "$url"
  local got; got="$(digest "$out")"
  if [[ "$got" != "$sha" ]]; then echo "  sha256 mismatch for ${out##*/}: got $got, pinned $sha" >&2; exit 1; fi
  echo "  ok   ${out##*/}"
}

while IFS=$'\t' read -r name title role license artist page url bytes sha; do
  case "$role" in
    *-video) get "$MEDIA/videos/${name%.*}.webm" "$url" "$sha" ;;
    *)       get "$MEDIA/photos/$name" "$url" "$sha" ;;
  esac
done < "$HERE/manifest.tsv"

# Three 6-second scenes in one 18-second MP4: test bars, a fractal, testsrc2. The boundaries are
# known exactly, which is what the timestamp assertions in corpus.json need.
if [[ -x "$FFMPEG" ]]; then
  "$FFMPEG" -y -hide_banner -loglevel error -f lavfi -i "smptebars=size=640x360:duration=6:rate=25" \
    -f lavfi -i "mandelbrot=size=640x360:rate=25" -f lavfi -i "testsrc2=size=640x360:rate=25" \
    -filter_complex "[0][1][2]concat=n=3:v=1:a=0" -t 18 -c:v libx264 -pix_fmt yuv420p \
    -preset veryfast -crf 30 "$MEDIA/clips/scenes.mp4"
  echo "  made scenes.mp4"
else
  echo "  no ffmpeg with libx264 + mp4: scenes.mp4 not built (install ffmpeg, or set FFMPEG=…)" >&2
fi
echo "corpus in $MEDIA"
