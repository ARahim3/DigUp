#!/usr/bin/env bash
# corpus2: 60 Wikimedia Commons photographs (3 per subject, 20 subjects) for the *running*
# server to search — the frozen corpus stays exactly 15 files because the suite's ranking
# assertions normalize over that set. Photos are pinned by sha256 (manifest.tsv) and kept
# out of git; this script fetches them as 1400 px renders from Commons and verifies.
#
#   server/tests/corpus2/build.sh          fetch the pinned photos (manifest.tsv), verify
#   BAKE=1 server/tests/corpus2/build.sh   fetch from titles.tsv and (re)write the pins
#
# It indexes nothing: `digup index <dir>` does that. See README.md for provenance/licenses.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
MEDIA="${1:-$HERE/media}"
WIDTH="${WIDTH:-1400}"
UA="DigUpServer-corpus2/1.0 (dev test corpus setup; contact: https://github.com/ARahim3/DigUp)"
mkdir -p "$MEDIA/photos"

digest() {  # sha256 of a file, 64 hex digits (coreutils' tool, with the BSD one as a fallback)
  sha256sum "$1" 2>/dev/null | cut -c1-64 || shasum -a 256 "$1" | cut -c1-64
}

url_of() {  # the wiki's own thumbnail service, the title percent-encoded
  local t="${1#File:}"
  local enc; enc="$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$t")"
  echo "https://commons.wikimedia.org/wiki/Special:FilePath/${enc}?width=${WIDTH}"
}

fetch() {  # fetch <out> <url>: Commons renders are redirects; retry politely
  curl --fail --silent --show-error --location --proto '=https' -A "$UA" --retry 3 --retry-delay 2 \
       -o "$2" "$1"   # note: <out> is the second argument here ($2), the url is $1
}

if [[ "${BAKE:-0}" == 1 ]]; then
  tmp="$(mktemp)"
  printf '# corpus2 pins: name, Commons title, fetch URL (%s px render), sha256 of the render\n' "$WIDTH" > "$tmp"
  while IFS=$'\t' read -r name title; do
    case "$name" in ''|'#'*) continue ;; esac
    url="$(url_of "$title")"
    out="$MEDIA/photos/$name"
    echo "  bake ${name}"
    fetch "$url" "$out"
    printf '%s\t%s\t%s\t%s\n' "$name" "$title" "$url" "$(digest "$out")" >> "$tmp"
  done < "$HERE/titles.tsv"
  mv "$tmp" "$HERE/manifest.tsv"
  echo "baked $(grep -vc '^#' "$HERE/manifest.tsv") pins into manifest.tsv"
  exit 0
fi

[[ -s "$HERE/manifest.tsv" ]] || { echo "no manifest.tsv pins: run BAKE=1 $0" >&2; exit 1; }

get() {  # get <out> <url> <sha256>: fetch once, verify against the pin, keep
  local out="$1" url="$2" sha="$3"
  if [[ -f "$out" && "$(digest "$out")" == "$sha" ]]; then
    echo "  ok   ${out##*/}"; return 0
  fi
  echo "  get  ${out##*/}"
  fetch "$url" "$out"
  local got; got="$(digest "$out")"
  if [[ "$got" != "$sha" ]]; then echo "  sha256 mismatch for ${out##*/}: got $got, pinned $sha" >&2; exit 1; fi
  echo "  ok   ${out##*/}"
}

while IFS=$'\t' read -r name title url sha; do
  case "$name" in ''|'#'*) continue ;; esac
  get "$MEDIA/photos/$name" "$url" "$sha"
done < "$HERE/manifest.tsv"

# The synthetic clip travels with corpus2 too (its scene boundaries are known to the
# second): a copy of the corpus's built clip, so the running server has an H.264 video
# whose moments the web UI opens at #t=… (the corpus's webm files stay in corpus/).
if [[ -f "$HERE/../corpus/media/clips/scenes.mp4" ]]; then
  mkdir -p "$MEDIA/clips"
  cp -f "$HERE/../corpus/media/clips/scenes.mp4" "$MEDIA/clips/scenes.mp4"
  echo "  clip scenes.mp4 copied from corpus"
fi

echo "corpus2 in $MEDIA: $(find "$MEDIA/photos" -type f | wc -l | tr -d ' ') photos"
