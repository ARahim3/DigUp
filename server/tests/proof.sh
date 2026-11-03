#!/usr/bin/env bash
# The headless proof (Stage 2): the original DigUp engine, in Linux, with no UI — indexing the
# labeled corpus and answering natural-language searches from it, exactly as the server will.
#
#   server/tests/proof.sh                      # run inside the engine container
#
# Typical invocation on this machine (arm64, CPU only, no GPU, no desktop, no Tauri):
#
#   docker run --rm --platform linux/arm64 \
#     -v "$PWD:/src:ro" \
#     -v "$PWD/server/tests/corpus/media:/corpus:ro" \
#     -v "$HOME/Projects/digup-data/models:/models:ro" \
#     -v "$HOME/Projects/digup-data/index:/index" \
#     -e DIGUP_MODELS=/models \
#     digup-engine:local bash /src/server/tests/proof.sh
#
# Nothing here invents anything: every number and every ranking is the engine's own, and the
# logs land under server/data/proof/ (git-ignored runtime evidence) for docs/implementation/.
set -uo pipefail
DIGUP="${DIGUP:-digup}"
CORPUS="${CORPUS:-/corpus}"
INDEX="${INDEX:-/index}"
export DIGUP_MODELS="${DIGUP_MODELS:-/models}"
SRC="${SRC:-/src}"
OUT="${OUT:-$SRC/server/data/proof}"      # runtime evidence, git-ignored; docs quote it
mkdir -p "$OUT" "$INDEX"
fails=0
gate() { gate_msg="$1"; }                  # the last gate that ran (shown on failure)

run() {  # run <file> <command…>: keep the engine's own words, on screen and in a log.
  local file="$1"; shift
  echo; echo "══ $*"
  # pipefail is set, so this pipeline's status IS the command's: a proof that cannot
  # report failure is not evidence (the old version always exited 0 — a run where the
  # index died and every search answered nothing was "green", and CI cited its EXIT=0).
  if ! "$@" 2>&1 | tee "$OUT/$file.log"; then
    fails=$((fails + 1))
    echo "FAILED (gate: ${gate_msg:-command}, exit above) — $OUT/$file.log" | tee -a "$OUT/$file.log"
  fi
}

gate "speed --model"
run speed "$DIGUP" speed --model --when-quiet 5 --index "$INDEX"
gate "estimate (plain — ParentWatch rule, reconnaissance §15)"
# `estimate` plain: proof.sh runs as PID 1's script, and `estimate --json` is a ParentWatch
# helper that exits at once when its parent is PID 1 ("the app is gone") — the server, as a
# long-lived parent, uses `--json`; this script, as a script, must not (reconnaissance §15).
run estimate "$DIGUP" estimate "$CORPUS" --index "$INDEX"
gate "index"
run index "$DIGUP" index "$CORPUS" --index "$INDEX"
gate "status"
run status "$DIGUP" status --index "$INDEX"

queries=(
  "wakeboarding"
  "hiking"
  "a person riding a wakeboard behind a boat"
  "people sitting around a campfire"
  "a dog running on the beach"
  "a boat on the water at sunset"
  "someone fishing from a dock"
  "Christmas dinner"
  "cars in a parking lot"
)
n=0
for query in "${queries[@]}"; do
  n=$((n + 1))
  run "search-$n" "$DIGUP" search "$query" -n 10 --index "$INDEX"
  run "search-$n-json" "$DIGUP" search "$query" -n 10 --json --index "$INDEX"
done

run search-video-json "$DIGUP" search wakeboarding --kind video -n 10 --json --index "$INDEX"
run search-fractal-json "$DIGUP" search "a fractal" --kind video -n 10 --json --index "$INDEX"
gate "eval (exit)"
run eval env DIGUP_TESTBED="$CORPUS" "$DIGUP" eval "$SRC/server/tests/corpus/corpus.json" -n 10 --index "$INDEX"
# The gate whose numbers the docs quote (Stage 2, corpus.json pins): the ALL row must
# clear R@1 ≥ 0.60 and R@5 ≥ 0.85 — the recorded values (0.71 / 0.88) sit above it with
# margin; a corpus whose ranking collapsed fails here, not in some doc's prose later.
gate "eval ALL row (R@1 ≥ 0.60, R@5 ≥ 0.85)"
if ! awk '/^ALL/{ok = ($3 >= 0.60 && $4 >= 0.85)} END {exit ok ? 0 : 1}' "$OUT/eval.log"; then
  fails=$((fails + 1))
  echo "FAILED (gate: eval ALL row below R@1 0.60 / R@5 0.85) — see $OUT/eval.log"
fi
gate "status-after"
run status-after "$DIGUP" status --index "$INDEX"

echo; echo "proof logs: $OUT"
if [ "$fails" -ne 0 ]; then
  echo "PROOF FAILED: $fails gate(s) failed (last: ${gate_msg:-none})"
  exit 1
fi
echo "PROOF PASSED: all gates green"
