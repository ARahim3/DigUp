#!/bin/bash
# Builds build.noindex/DigUp.app, signed with the hardened runtime (as releases are, so dev builds behave the same).
#   ./build.sh                       signed with the identity named in .sign-id (one line, gitignored), so macOS keeps
#                                    folder permissions across rebuilds; ad-hoc without it (macOS then asks again
#                                    after each build)
#   SIGN_ID="<identity>" ./build.sh  this identity instead
#   RELEASE=1 SIGN_ID="Developer ID Application: …" ./build.sh   plus the secure timestamp notarization needs
#                                    (scripts/release.sh does that, then notarizes and makes the DMG)
# There's no install step: run it from build.noindex (see scripts/dev-run.sh).
# For testing in-app updates with a copy of its own (never the installed DigUp's settings or updates), these replace
# Info.plist values: BUNDLE_ID, VERSION, BUILD_NUMBER, SPARKLE_FEED (the appcast URL), SPARKLE_KEY (the EdDSA public key).
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="DigUp"
# ".noindex" keeps Spotlight (and the Apps list) from showing this staging copy.
APP="build.noindex/$APP_NAME.app"

# Use full Xcode's toolchain when it's installed, even if xcode-select points at the Command Line Tools.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

# llama.cpp, the embedding runtime, linked into the helper (only rebuilt when its tag or patch changes).
scripts/build-llama.sh

# Both executables: the app, and the `digup` CLI, which the app runs as its indexing helper and query encoder.
swift build -c release --product DigUpApp
swift build -c release --product digup
BIN_DIR="$(swift build -c release --show-bin-path)"

# The app icon ("One space", moss; Resources/AppIcon/README.md): macOS 26 draws the layered AppIcon.icon (compiled into
# Assets.car), older macOS the .icns. Without the former, macOS 26 shows the icon shrunk inside a gray square.
ICON="Resources/AppIcon.icns"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
# The binary is DigUpApp in SwiftPM (it can't share a name with the `digup` CLI on a case-insensitive disk).
cp "$BIN_DIR/DigUpApp" "$APP/Contents/MacOS/$APP_NAME"
# The indexing helper lives in Helpers/: next to DigUp in MacOS/ it would collide on a case-insensitive disk.
cp "$BIN_DIR/digup" "$APP/Contents/Helpers/digup"
cp Resources/Info.plist "$APP/Contents/Info.plist"
xcrun actool --compile "$APP/Contents/Resources" --platform macosx --target-device mac --minimum-deployment-target 14.0 \
  --app-icon AppIcon --output-partial-info-plist "$(mktemp -d)/AppIcon.plist" --enable-on-demand-resources NO \
  --development-region en "$PWD/Resources/AppIcon/AppIcon.icon" > /dev/null
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"   # over actool's plainer fallback: ours has simplified 16 and 32 px
cp Resources/Acknowledgements.txt "$APP/Contents/Resources/Acknowledgements.txt"

# Sparkle (in-app updates): the framework in Frameworks/, where the app's runpath looks. Its XPC services are for
# sandboxed apps and its headers for building against it: left out.
FW="$APP/Contents/Frameworks/Sparkle.framework"
mkdir -p "$APP/Contents/Frameworks"
ditto .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework "$FW"
for part in XPCServices Headers PrivateHeaders Modules; do rm -rf "${FW:?}/$part" "${FW:?}/Versions/B/$part"; done

PLIST="$APP/Contents/Info.plist"
[[ -n "${BUNDLE_ID:-}" ]] && /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$PLIST"
[[ -n "${VERSION:-}" ]] && /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
[[ -n "${BUILD_NUMBER:-}" ]] && /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST"
[[ -n "${SPARKLE_FEED:-}" ]] && /usr/libexec/PlistBuddy -c "Set :SUFeedURL $SPARKLE_FEED" "$PLIST"
[[ -n "${SPARKLE_KEY:-}" ]] && { /usr/libexec/PlistBuddy -c "Delete :SUPublicEDKey" "$PLIST" 2>/dev/null || true
                                 /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_KEY" "$PLIST"; }

# Nested code first, then the bundle. The helper needs no entitlements: llama.cpp compiles its Metal shaders at run
# time through Metal's own compiler service, which the hardened runtime allows (checked 2026-10-08). The app's one
# entitlement lets it ask QuickTime Player to open a recording at a moment.
IDENTITY="${SIGN_ID:-$( [[ -f .sign-id ]] && head -1 .sign-id || echo - )}"
TIMESTAMP=$([[ "${RELEASE:-}" == 1 ]] && echo --timestamp || echo --timestamp=none)
codesign --force --sign "$IDENTITY" --options runtime $TIMESTAMP "$APP/Contents/Helpers/digup"
# Sparkle comes ad-hoc signed: its helpers, then the framework, with this identity (the app may only load code signed
# by its own team).
for code in "$FW/Versions/B/Autoupdate" "$FW/Versions/B/Updater.app" "$FW"; do
  codesign --force --sign "$IDENTITY" --options runtime $TIMESTAMP "$code"
done
# An ad-hoc build has no team, so the hardened runtime's library validation would refuse its (ad-hoc) Sparkle: such
# builds (from source, without a signing identity) may load it anyway. Signed builds and releases keep validation.
ENTITLEMENTS=Resources/DigUp.entitlements
if [[ "$IDENTITY" == - ]]; then
  ENTITLEMENTS="$(mktemp -d)/DigUp.entitlements"
  cp Resources/DigUp.entitlements "$ENTITLEMENTS"
  /usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.disable-library-validation bool true" "$ENTITLEMENTS"
fi
codesign --force --sign "$IDENTITY" --options runtime $TIMESTAMP --entitlements "$ENTITLEMENTS" "$APP"
echo "Signed $([[ "$IDENTITY" == - ]] && echo ad-hoc || echo "with \"$IDENTITY\"") (hardened runtime)"
echo "Built $APP"
