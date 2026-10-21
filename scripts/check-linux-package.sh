#!/bin/bash
# Checks an installed DigUp for Linux the way someone first meets it, without a desktop: the shell and its helper find
# every library they need, and a hidden first launch under a virtual screen (Xvfb) with a session bus goes through setup
# by itself (the model from MODELS, downloaded there when it isn't), indexes a picture, a screenshot, a recording and a
# note with the model, and finds the note from the search panel; launched again, the panel shows the recording, whose
# preview starts WebKit's media player. The packages workflow runs it on each distribution on the AppImage, then on the
# .deb once installed.
#   MODELS=<folder> scripts/check-linux-package.sh [/usr/bin/digup-shell | <DigUp.AppImage>]
# Needs xvfb-run (xvfb, xauth) and dbus-run-session (dbus).
set -euo pipefail
cd "$(dirname "$0")/.."
app=$(realpath "${1:-/usr/bin/digup-shell}")
models=${MODELS:?set MODELS to a folder for the model files (they are downloaded there when missing)}
mkdir -p "$models"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

if [[ $app == *.AppImage ]]; then
  # A container has no FUSE to mount it: the AppImage unpacks itself instead.
  export APPIMAGE_EXTRACT_AND_RUN=1
  helper=
else
  helper=$(dirname "$app")/../lib/DigUp/helper/digup
  missing=$(for file in "$app" "$(dirname "$helper")"/*; do
    # ffmpeg and ffprobe are static: ldd has nothing to say about them. The Vulkan backend is loaded only where
    # Vulkan is (the package recommends it).
    [[ -f $file && ! -L $file ]] && ldd "$file" 2>&1 | grep "not found" | grep -v "libvulkan.so.1" | sed "s|^|$file: |"
  done || true)
  if [[ -n $missing ]]; then
    echo "missing libraries:"
    echo "$missing"
    exit 1
  fi
  # The licenses of what the package carries: beside the app, and where Debian keeps a package's.
  for notices in "$(dirname "$app")/../lib/DigUp/THIRD-PARTY-NOTICES.txt" "$(dirname "$app")/../share/doc/dig-up/copyright"; do
    grep -q "GNU LESSER GENERAL PUBLIC LICENSE" "$notices" || { echo "no license notices in $notices"; exit 1; }
  done
fi

mkdir -p "$work/files"
cp Tests/LlamaRuntimeTests/Reference/photo.jpg Tests/LlamaRuntimeTests/Reference/screen.png \
  Tests/LlamaRuntimeTests/Reference/speech.wav docs/logo.png "$work/files/"
cat > "$work/files/recipe.txt" <<'TEXT'
Lemon cake

Cream the butter and sugar, beat in three eggs, then fold in the flour, the zest of two lemons and a splash of milk.
Bake for forty minutes at 180 degrees and pour the lemon syrup over it while it is still warm.
TEXT

# Launches the app hidden with these arguments until the panel reports what it showed ($report), for at most $2 s.
launch() {
  local name=$1 seconds=$2 started status=0
  shift 2
  started=$(date +%s)
  timeout "$seconds" xvfb-run -a -s "-screen 0 1280x800x24" dbus-run-session -- "$app" --index "$work/index" \
    --models "$models" --settings "$work/settings.json" "$@" --debug-quit > "$work/$name.out" 2> "$work/$name.err" ||
    status=$?
  echo "exit $status after $(( $(date +%s) - started )) s"
  report=$(grep '^{' "$work/$name.out" | tail -1 || true)
  if [[ $status != 0 || -z $report ]]; then
    echo "--- stdout"; tail -20 "$work/$name.out"
    echo "--- stderr"; tail -40 "$work/$name.err"
    echo "no report from the panel"
    exit 1
  fi
  echo "panel: $report"
}

echo "first launch: $app"
launch first 1800 --offer "$work/files" --hotkey "Ctrl+Alt+Shift+D" --debug-setup \
  --debug-query "how long to bake the cake"
if [[ $report != *'"recipe.txt"'* ]]; then
  echo "the panel didn't find recipe.txt"
  exit 1
fi
if [[ -n $helper ]]; then
  "$helper" status --index "$work/index" | tee "$work/status.txt"
  # Every file has its vector: the pictures (with the logo), the recording and the note.
  grep -Eq '^vectors: 5 in 5 segments' "$work/status.txt" || { echo "not every file has a vector"; exit 1; }
fi

# The recording's preview starts WebKit's media player, on GStreamer (the AppImage's own, the system's for the .deb):
# without the plugins it asks for, WebKit's page dies and the panel stops answering. (The preview itself doesn't load:
# WebKit's player turns down the files' asset:// addresses.)
echo "second launch: the recording's preview"
launch second 300 --debug-query "speech"
if [[ $report != *'"selected":"speech.wav"'* || $report != *'"tag":"audio"'* ]]; then
  echo "the panel didn't show the recording"
  exit 1
fi
if grep -h "GStreamer element .* not found\|Failed to load plugin" "$work/second.out" "$work/second.err"; then
  echo "GStreamer is missing a plugin or a library"
  exit 1
fi
echo "ok"
