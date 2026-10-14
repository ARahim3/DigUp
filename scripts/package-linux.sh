#!/usr/bin/env bash
# Make a Linux x86_64 CLI archive with its pinned native libraries.
# With --no-build, run the vendor and llama.cpp build scripts first.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=""
BUILD=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) [[ $# -ge 2 ]] || { echo "--version needs a value" >&2; exit 2; }; VERSION="$2"; shift 2 ;;
    --no-build) BUILD=0; shift ;;
    *) echo "usage: $0 --version X.Y.Z [--no-build]" >&2; exit 2 ;;
  esac
done
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+)+$ ]] || { echo "use --version X.Y.Z" >&2; exit 2; }
[[ "$(uname -s)-$(uname -m)" == "Linux-x86_64" ]] || { echo "Linux x86_64 only" >&2; exit 1; }

if [[ "$BUILD" == 1 ]]; then
  scripts/fetch-vendor.sh
  DIGUP_CPU_ONLY=1 scripts/build-llama.sh
  swift build -c release --product digup --static-swift-stdlib
fi
BIN="$(swift build -c release --show-bin-path)/digup"
[[ -x "$BIN" ]] || { echo "build the release digup binary first" >&2; exit 1; }
[[ "$(cat Vendor/llama/BUILD 2>/dev/null)" == *" cpu" ]] || {
  echo "build the CPU runtime with DIGUP_CPU_ONLY=1 scripts/build-llama.sh" >&2
  exit 1
}
if ldd "$BIN" | grep -Eq 'libswift|libFoundation|libdispatch|libBlocksRuntime'; then
  echo "the CLI still needs shared Swift libraries; rebuild with --static-swift-stdlib" >&2
  exit 1
fi

NAME="digup-$VERSION-linux-x86_64"
STAGE="dist/$NAME"
rm -rf dist
mkdir -p "$STAGE/licenses/pdfium"
cp "$BIN" "$STAGE/digup"
cp -a Vendor/llama/lib/*.so* "$STAGE/"
cp -a Vendor/pdfium/lib/libpdfium.so "$STAGE/"
cp README.md LICENSE Resources/Acknowledgements.txt "$STAGE/"
cp Vendor/pdfium/LICENSE "$STAGE/licenses/pdfium/LICENSE"
cp -a Vendor/pdfium/licenses "$STAGE/licenses/pdfium/third-party"

# The runtime and CPU backend modules live beside digup. Verify the staged
# executable's native dependencies resolve before creating a distributable archive.
for file in "$STAGE/digup" "$STAGE"/*.so*; do
  [[ -L "$file" ]] && continue
  if LD_LIBRARY_PATH="$PWD/$STAGE" ldd "$file" | grep -q 'not found'; then
    echo "a native dependency is missing from the archive: $file" >&2
    exit 1
  fi
done
tar -czf "dist/$NAME.tar.gz" -C dist "$NAME"
(cd dist && sha256sum "$NAME.tar.gz" > SHA256SUMS)
echo "Wrote dist/$NAME.tar.gz"
