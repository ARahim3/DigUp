#!/bin/bash
# Builds DigUp for Linux as a .deb and an AppImage: the Tauri shell (shell/), with DigUp's helper, llama.cpp, PDFium and
# ffmpeg inside. Run it on the CPU architecture the packages are for, after scripts/fetch-vendor.sh and
# scripts/build-llama.sh. Needs Swift, Rust, Tauri's CLI (`cargo install tauri-cli --version "^2"`, else Node runs it from
# npm), patchelf, and what scripts/build-ffmpeg.sh needs (it builds the small ffmpeg the packages carry):
#   scripts/package-linux.sh       → shell/src-tauri/target/release/bundle/{deb,appimage}/
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build-ffmpeg.sh

# The helper with the Swift runtime linked in, so no Swift libraries ship. The runtime's archives are named again at the
# end of the link: Swift 6.4's static link otherwise misses symbols in archives it has already passed.
late=()
for library in _CFURLSessionInterface curl CoreFoundation _FoundationICU FoundationEssentials \
    FoundationInternationalization _FoundationCShims _FoundationCollections swiftSynchronization swift_Concurrency \
    swift_StringProcessing swift_RegexParser swiftDispatch dispatch BlocksRuntime swiftCore; do
  late+=(-Xlinker "-l$library")
done
swift build -c release --product digup --static-swift-stdlib --scratch-path .build/static "${late[@]}"

# What the packages carry beside the shell (shell/src-tauri/helper): the helper finds llama.cpp's backends and ffmpeg
# in its own folder, and each library finds the others there ($ORIGIN, not the build's folders).
helper=shell/src-tauri/helper
rm -rf "$helper"
mkdir -p "$helper"
cp .build/static/release/digup Vendor/pdfium/lib/libpdfium.so Vendor/ffmpeg/bin/ffmpeg Vendor/ffmpeg/bin/ffprobe "$helper/"
for file in Vendor/llama/lib/*.so*; do
  name=${file##*/}
  if [[ -L $file && $name =~ \.so\.[0-9]+$ ]]; then
    cp -L "$file" "$helper/"   # once, under the name the helper asks for (libllama.so.0)
  elif [[ ! -L $file && $name == *.so ]]; then
    cp "$file" "$helper/"      # llama.cpp's backends (libggml-cpu-*.so), loaded by path
  fi
done
for file in "$helper"/digup "$helper"/*.so*; do
  patchelf --set-rpath '$ORIGIN' "$file"
done

tauri=(npx --yes @tauri-apps/cli@2.12.2)
if cargo tauri --version > /dev/null 2>&1; then tauri=(cargo tauri); fi
# With the release's signing key (TAURI_SIGNING_PRIVATE_KEY, and its password) the packages that update themselves are
# signed for in-app updates (a .sig beside each). Installed copies check those signatures with the public key in
# tauri.conf.json (plugins.updater.pubkey): a release built without it could never update.
signing=
if [[ -n "${TAURI_SIGNING_PRIVATE_KEY:-}" ]]; then
  if grep -q '"pubkey": ""' shell/src-tauri/tauri.conf.json; then
    echo "the signing key is set, but plugins.updater.pubkey in shell/src-tauri/tauri.conf.json is empty" >&2
    exit 1
  fi
  signing=',"createUpdaterArtifacts":true'
fi
# The license of everything the packages carry, beside the app (and the .deb's copyright file, below).
python3 scripts/notices.py linux shell/src-tauri/THIRD-PARTY-NOTICES.txt
# Packages of an earlier build (another version) would be taken for this one's.
rm -rf shell/src-tauri/target/release/bundle/deb shell/src-tauri/target/release/bundle/appimage
# The helper folder goes in as the packages' resources here only: Tauri checks resources on every build.
resources='{"helper/":"helper/","THIRD-PARTY-NOTICES.txt":"THIRD-PARTY-NOTICES.txt"}'
(cd shell/src-tauri && "${tauri[@]}" build --bundles deb,appimage \
  --config "{\"bundle\":{\"resources\":$resources$signing}}")

# Packed again with xz (Tauri's gzip makes it 51 MB, xz 32). Its name stays "dig-up" (Tauri's spelling of the product's
# name): Debian and Ubuntu already have a "digup" (a digest updating tool), which would replace DigUp at the next update.
deb=$(ls shell/src-tauri/target/release/bundle/deb/*.deb)
repack=$(mktemp -d)
chmod 755 "$repack"   # the package's root: mktemp's 700 would ship as /'s mode
dpkg-deb -R "$deb" "$repack"
mkdir -p "$repack/usr/share/doc/dig-up"
cp shell/src-tauri/THIRD-PARTY-NOTICES.txt "$repack/usr/share/doc/dig-up/copyright"   # where Debian looks for it
# A beta's version as Debian sorts it before the release: 0.7.0~beta.1 (Debian reads 0.7.0-beta.1 as 0.7.0's revision
# beta.1, newer than 0.7.0 itself).
sed -i -E 's/^(Version: [0-9]+\.[0-9]+\.[0-9]+)-/\1~/' "$repack/DEBIAN/control"
dpkg-deb --root-owner-group -Zxz -b "$repack" "$deb" > /dev/null
rm -rf "$repack"
rm -f "$deb.sig"   # signed before the repacking, so no longer its signature (a .deb doesn't update itself anyway)
ls -la shell/src-tauri/target/release/bundle/deb/*.deb shell/src-tauri/target/release/bundle/appimage/*.AppImage
