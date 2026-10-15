#!/bin/bash
# Checks DigUp's Windows installer the way someone first meets it: installed silently for the current user, a hidden
# first launch goes through setup by itself (the model from MODELS, downloaded there when it isn't), indexes a picture,
# a screenshot, a recording and a note with the model and finds the note from the search panel; then its helper runs
# with only Windows on PATH (everything else it needs is beside it). In Git for Windows' bash; the packages workflow
# runs it after building the installer.
#   MODELS=<folder> scripts/check-windows-package.sh <DigUp_x.y.z_x64-setup.exe>
set -euo pipefail
cd "$(dirname "$0")/.."
setup=${1:?the installer}
models=${MODELS:?set MODELS to a folder for the model files (they are downloaded there when missing)}
mkdir -p "$models"
models=$(cygpath -m "$models")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
win() { cygpath -m "$1"; }

echo "installing $setup"
MSYS_NO_PATHCONV=1 "$setup" /S
installed=$(cygpath -u "$LOCALAPPDATA")/DigUp
ls "$installed/DigUp.exe" "$installed/helper/digup.exe" > /dev/null
# The licenses of what the installer carries, beside the app.
grep -q "GNU LESSER GENERAL PUBLIC LICENSE" "$installed/THIRD-PARTY-NOTICES.txt" || { echo "no license notices"; exit 1; }

mkdir -p "$work/files"
cp Tests/LlamaRuntimeTests/Reference/photo.jpg Tests/LlamaRuntimeTests/Reference/screen.png \
  Tests/LlamaRuntimeTests/Reference/speech.wav docs/logo.png "$work/files/"
cat > "$work/files/recipe.txt" <<'TEXT'
Lemon cake

Cream the butter and sugar, beat in three eggs, then fold in the flour, the zest of two lemons and a splash of milk.
Bake for forty minutes at 180 degrees and pour the lemon syrup over it while it is still warm.
TEXT

echo "first launch"
started=$(date +%s)
"$installed/DigUp.exe" --index "$(win "$work/index")" --models "$models" --settings "$(win "$work/settings.json")" \
  --offer "$(win "$work/files")" --hotkey "Ctrl+Alt+Shift+D" --debug-setup --debug-query "how long to bake the cake" \
  --debug-quit > "$work/out.txt" 2> "$work/err.txt" &
app=$!
report=
while kill -0 "$app" 2> /dev/null && (( $(date +%s) - started < 1800 )); do
  report=$(grep '^{' "$work/out.txt" 2> /dev/null | tail -1 || true)
  [[ -n $report ]] && break
  sleep 2
done
# The report comes just before DigUp quits; a DigUp still there a minute later is ended (a session without a desktop,
# as a service has, keeps it from quitting).
for _ in $(seq 30); do kill -0 "$app" 2> /dev/null || break; sleep 2; done
if kill -0 "$app" 2> /dev/null; then
  echo "DigUp didn't quit after its report: ending it"
  taskkill //F //T //IM DigUp.exe > /dev/null || true
fi
report=$(grep '^{' "$work/out.txt" | tail -1 || true)
echo "after $(( $(date +%s) - started )) s"
if [[ -z $report ]]; then
  echo "--- stdout"; tail -20 "$work/out.txt"
  echo "--- stderr"; tail -40 "$work/err.txt"
  echo "no report from the panel"
  exit 1
fi
echo "panel: $report"
if [[ $report != *'"recipe.txt"'* ]]; then
  echo "the panel didn't find recipe.txt"
  exit 1
fi

echo "the helper with only Windows on PATH"
helper=$installed/helper/digup.exe
PATH="/c/Windows/System32:/c/Windows:/c/Windows/System32/Wbem" "$helper" status --index "$(win "$work/index")" \
  | tee "$work/status.txt"
grep -Eq '^vectors: 5 in 5 segments' "$work/status.txt" || { echo "not every file has a vector"; exit 1; }
PATH="/c/Windows/System32:/c/Windows:/c/Windows/System32/Wbem" DIGUP_MODELS="$models" \
  "$helper" search "how long to bake the cake" --index "$(win "$work/index")" -n 3
echo "ok"
