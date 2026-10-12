#!/bin/bash
# Builds DigUp for release: signed with a Developer ID and the hardened runtime, notarized and stapled, in a DMG.
#   SIGN_ID="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=DigUp scripts/release.sh
# NOTARY_PROFILE names notarytool credentials in your keychain, saved once with
#   xcrun notarytool store-credentials DigUp --apple-id you@example.com --team-id TEAMID
# (it asks for an app-specific password from appleid.apple.com). Output: build.noindex/release/DigUp-<version>.dmg
# With APPCAST=<path to appcast.xml> (and NOTES=<an HTML fragment> for the update window), the DMG is also signed for
# Sparkle and listed first in that update feed (scripts/appcast.py). Publishing the DMG and the feed is a separate step.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${SIGN_ID:?set SIGN_ID to a Developer ID Application identity (security find-identity -v -p codesigning)}"
: "${NOTARY_PROFILE:?set NOTARY_PROFILE to a notarytool keychain profile (see the top of this script)}"
# Checked now, not after a multi-minute build and notarization: Sparkle's key is needed to sign the DMG.
if [[ -n "${APPCAST:-}" && -z "${SPARKLE_KEY_FILE:-}" ]]; then
  security find-generic-password -s "Sparkle EdDSA key" > /dev/null 2>&1 \
    || { echo "Sparkle EdDSA key not in the login keychain (run Sparkle's generate_keys once, or set SPARKLE_KEY_FILE=<path>)." >&2; exit 1; }
fi
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
APP=build.noindex/DigUp.app
OUT=build.noindex/release
rm -rf "$OUT"
mkdir -p "$OUT"

RELEASE=1 ./build.sh
# --deep is deprecated; build.sh signs each nested item explicitly, so verify them explicitly too.
codesign --verify --strict --verbose=2 "$APP/Contents/Helpers/digup" "$APP/Contents/Frameworks/Sparkle.framework" "$APP"

# The app itself is notarized and stapled first, so a copy dragged out of the DMG passes Gatekeeper offline too.
ditto -c -k --keepParent "$APP" "$OUT/DigUp.zip"
xcrun notarytool submit "$OUT/DigUp.zip" --keychain-profile "$NOTARY_PROFILE" --wait --output "$OUT/notary-app.json"
xcrun stapler staple "$APP"
rm "$OUT/DigUp.zip"

# The DMG: the app beside a link to /Applications. Signed, notarized and stapled as well.
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/DigUp.app"
ln -s /Applications "$STAGE/Applications"
DMG="$OUT/DigUp-$VERSION.dmg"
hdiutil create -quiet -volname "DigUp" -srcfolder "$STAGE" -fs HFS+ -format ULFO -ov "$DMG"
rm -rf "$STAGE"
codesign --force --sign "$SIGN_ID" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait --output "$OUT/notary-dmg.json"
xcrun stapler staple "$DMG"

spctl --assess --type execute --verbose=2 "$APP"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
if [[ -n "${APPCAST:-}" ]]; then
  scripts/appcast.py "$DMG" "$APPCAST" ${NOTES:+--notes "$NOTES"} ${SPARKLE_KEY_FILE:+--key-file "$SPARKLE_KEY_FILE"}
elif [[ "${SKIP_APPCAST:-}" == 1 ]]; then
  echo "APPCAST skipped (SKIP_APPCAST=1): this DMG is not Sparkle-signed; in-app updates will not see it."
else
  echo "Set APPCAST=<path to appcast.xml> to Sparkle-sign the DMG, or SKIP_APPCAST=1 to build without a feed." >&2
  exit 1
fi
echo "Released $DMG ($(du -h "$DMG" | cut -f1))"
