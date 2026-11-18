#!/bin/bash
# Signs, packages and notarises RetroTerm for distribution outside the Mac App Store (Developer ID).
#
# One-time setup:
#   1. Apple Developer Program membership; create a "Developer ID Application" certificate in Xcode or the
#      developer portal and install it in your login keychain.
#   2. Store notarisation credentials in the keychain (app-specific password from appleid.apple.com):
#        xcrun notarytool store-credentials "RetroTerm" --apple-id you@example.com --team-id TEAMID
#
# Usage:
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./Scripts/notarize.sh [keychain-profile]
#
# Produces build/RetroTerm-<version>.dmg, notarised and stapled, ready to upload.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${SIGN_IDENTITY:?set SIGN_IDENTITY to your Developer ID Application identity}"
PROFILE="${1:-RetroTerm}"
APP="build/RetroTerm.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
DMG="build/RetroTerm-$VERSION.dmg"
STAGE="build/dmg-stage"

./Scripts/build-app.sh release

echo "▶ building $DMG"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "RetroTerm" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"

echo "▶ notarising (this waits for Apple, usually a few minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait

echo "▶ stapling"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG" || true
echo "✔ $DMG"
