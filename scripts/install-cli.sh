#!/bin/bash
# Installs the `digup` CLI to ~/.local/bin/digup and installs the `digup` skill for Claude Code and Google Antigravity.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

scripts/build-llama.sh
swift build -c release --product digup
BIN_DIR="$(swift build -c release --show-bin-path)"

mkdir -p "$HOME/.local/bin"
cp -f "$BIN_DIR/digup" "$HOME/.local/bin/digup"
codesign --force --sign - "$HOME/.local/bin/digup" >/dev/null 2>&1 || true
echo "Installed CLI: $HOME/.local/bin/digup"

SKILL_SRC=".agents/skills/digup/SKILL.md"
if [[ -f "$SKILL_SRC" ]]; then
  for dest in \
    ".claude/skills/digup" \
    "$HOME/.claude/skills/digup" \
    "$HOME/.gemini/config/skills/digup"; do
    mkdir -p "$dest"
    cp -f "$SKILL_SRC" "$dest/SKILL.md"
    echo "Installed skill: $dest/SKILL.md"
  done
fi
