#!/bin/bash
# Linux binary packaging (x86_64 first): a portable tarball plus a .deb.
# .rpm and the AUR -bin package are built from the same tarball in CI
# (.github/workflows/linux-release.yml) and packaging/, so maintainers of
# other distros only need the tarball.
#
#   scripts/package-linux.sh [--version X.Y.Z] [--no-build]
#
# Output in dist/: digup-<ver>-x86_64.tar.gz, digup_<ver>_amd64.deb, SHA256SUMS.
# Needs: a release Swift build already done (or it runs build-llama.sh + swift
# build itself unless --no-build). llama.cpp is built with GGML_NATIVE=OFF so
# the binary runs on any x86_64.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=""
NO_BUILD=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    --no-build) NO_BUILD=1; shift ;;
    *) echo "usage: $0 [--version X.Y.Z] [--no-build]"; exit 2 ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  if TAG="$(git describe --tags --exact-match 2>/dev/null)"; then
    VERSION="${TAG#v}"
  else
    VERSION="$(grep -m1 CFBundleShortVersionString -A1 Resources/Info.plist | tail -1 | sed 's/.*<string>\(.*\)<\/string>.*/\1/')"
  fi
fi
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]] || { echo "bad version: $VERSION"; exit 1; }
ARCH="$(uname -m)"
[[ "$ARCH" == "x86_64" ]] || { echo "x86_64 first: refusing on $ARCH (add aarch64 as a second job)"; exit 1; }

if [[ "$NO_BUILD" == 0 ]]; then
  scripts/build-llama.sh
  swift build -c release --product digup
fi
BIN="$(swift build -c release --show-bin-path)/digup"
[[ -x "$BIN" ]] || { echo "no binary at $BIN"; exit 1; }

rm -rf dist
mkdir -p dist/stage/usr/bin dist/stage/usr/share/doc/digup
cp "$BIN" dist/stage/usr/bin/digup
cp README.md LICENSE dist/stage/usr/share/doc/digup/
chmod 0755 dist/stage/usr/bin/digup

# The -bin tarball (Arch digup-bin, manual installs): binary + docs at the root.
TARBALL="dist/digup-$VERSION-x86_64.tar.gz"
tar -czf "$TARBALL" -C dist/stage usr/bin/digup usr/share/doc/digup/README.md usr/share/doc/digup/LICENSE

# The .deb (Debian/Ubuntu): needs dpkg-deb (CI has it; on Arch: yay -S dpkg).
if command -v dpkg-deb > /dev/null; then
  mkdir -p dist/stage/DEBIAN
  cat > dist/stage/DEBIAN/control <<EOF
Package: digup
Version: $VERSION
Section: utils
Priority: optional
Architecture: amd64
Depends: libsqlite3-0, ffmpeg, poppler-utils
Maintainer: DigUp contributors <https://github.com/ARahim3/DigUp>
Description: Search your files by meaning
 DigUp indexes pictures, PDFs, documents, audio, video and code with
 Google DeepMind's EmbeddingGemma 2 and finds them from a description
 in your own words. Everything runs on your machine.
Homepage: https://github.com/ARahim3/DigUp
EOF
  dpkg-deb --build dist/stage "dist/digup_${VERSION}_amd64.deb"
  rm -rf dist/stage/DEBIAN
else
  echo "dpkg-deb missing: skipping .deb (the tarball is done)"
fi

(cd dist && sha256sum digup-*.tar.gz digup_*.deb 2>/dev/null > SHA256SUMS || true)
echo "Wrote:"
ls -la dist/ | tail -n +2
