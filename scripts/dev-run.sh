#!/bin/bash
# Launches build.noindex/DigUp.app against the testbed with a scratch index, models folder and settings under
# .dev/ and a separate defaults suite: never real folders, never the real index, model or settings. Extra launch
# arguments pass through, e.g.
#   scripts/dev-run.sh -debugQuery "zebra" -debugSnapshot /tmp/panel.png -debugQuit YES
# ROOTS=a:b:c overrides the folders (keep them inside the testbed); ROOTS= (empty) launches with none, as a fresh
# install would. INDEX, MODELS and SUITE override the rest; APP=/Applications/DigUp.app runs an installed copy the
# same way. The app's log is <index>/app.log.
set -euo pipefail
cd "$(dirname "$0")/.."
TB="${TESTBED:-$HOME/DigUpTestbed}"
INDEX="${INDEX:-$PWD/.dev/app-index}"
MODELS="${MODELS:-$PWD/.dev/models}"
SUITE="${SUITE:-com.abdurrahim.DigUp.dev}"

# The model, cloned from the Hugging Face cache (APFS clones take no extra space), unless MODELS points elsewhere.
SNAPSHOT="$HOME/.cache/huggingface/hub/models--ggml-org--embeddinggemma-2-GGUF/snapshots/bfcd298762cc34d0357ece5ebdd31791a3a374d8"
if [[ "$MODELS" == "$PWD/.dev/models" ]]; then
  mkdir -p "$MODELS"
  for file in embeddinggemma-2-Q8_0.gguf mmproj-embeddinggemma-2-Q8_0.gguf; do
    [[ -f "$MODELS/$file" || ! -e "$SNAPSHOT/$file" ]] || cp -cL "$SNAPSHOT/$file" "$MODELS/$file"
  done
fi

# Only an earlier run of this same copy is stopped: an installed DigUp in use keeps running.
APP="${APP:-build.noindex/DigUp.app}"
EXE="$(cd "$APP" && pwd -P)/Contents/MacOS/DigUp"
for pid in $(pgrep -x DigUp); do
  [[ "$(ps -o comm= -p "$pid")" == "$EXE" ]] && kill "$pid" && sleep 0.5
done
ARGS=(-indexDir "$INDEX" -modelsDir "$MODELS" -defaultsSuite "$SUITE")
if [[ -z "${ROOTS+set}" ]]; then
  ARGS+=(-roots "$TB/real:$TB/synthetic:$TB/traps")
elif [[ -n "$ROOTS" ]]; then
  ARGS+=(-roots "$ROOTS")
fi
open -n "$APP" --args "${ARGS[@]}" "$@"
