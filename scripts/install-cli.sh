#!/bin/bash
# Installs the `digup` CLI to ~/.local/bin/digup and installs the `digup` skill for Claude Code and Google Antigravity.
# macOS and Linux build it from this checkout (on Linux, the binary finds llama.cpp and PDFium in this checkout's
# Vendor/ folder, so keep the checkout where it is). On Windows, run scripts/install-cli.ps1 instead: it puts the
# installed app's digup.exe on PATH.
set -euo pipefail
cd "$(dirname "$0")/.."

case "$(uname -s)" in
  Darwin)
    if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
      export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    fi
    ;;
  Linux)
    scripts/fetch-vendor.sh   # SQLite, stb, miniz and PDFium (macOS has Apple's frameworks instead)
    ;;
  MINGW*|MSYS*|CYGWIN*)
    echo "On Windows, run: powershell -ExecutionPolicy Bypass -File scripts\\install-cli.ps1" >&2
    exit 1
    ;;
esac

scripts/build-llama.sh
swift build -c release --product digup
BIN_DIR="$(swift build -c release --show-bin-path)"

mkdir -p "$HOME/.local/bin"
cp -f "$BIN_DIR/digup" "$HOME/.local/bin/digup"
if [[ "$(uname -s)" == Darwin ]]; then
  codesign --force --sign - "$HOME/.local/bin/digup" >/dev/null 2>&1 || true
fi
echo "Installed CLI: $HOME/.local/bin/digup"
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo "Add ~/.local/bin to PATH to run it as \`digup\`." ;;
esac

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
