#!/bin/bash
# Builds RetroTerm.app into ./build using Swift Package Manager (no Xcode project needed).
#
#   ./Scripts/build-app.sh [release|debug]
#
# Signing: with SIGN_IDENTITY set (e.g. "Developer ID Application: Name (TEAMID)") the app is signed with that
# identity, hardened runtime and a secure timestamp, ready for notarisation (see Scripts/notarize.sh).
# Without it the app is ad-hoc signed, fine for local use only.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="build/RetroTerm.app"

echo "▶ swift build -c $CONFIG"
swift build -c "$CONFIG" 2>&1 | grep -vE '^\[|^$' || true
BIN="$(swift build -c "$CONFIG" --show-bin-path)/RetroTerm"
[ -x "$BIN" ] || { echo "build failed"; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/RetroTerm"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
[ -d Resources/Sounds ] && cp -R Resources/Sounds "$APP/Contents/Resources/Sounds"
echo -n "APPL????" > "$APP/Contents/PkgInfo"

if [ -n "${SIGN_IDENTITY:-}" ]; then
    echo "▶ codesign with $SIGN_IDENTITY (hardened runtime)"
    codesign --force --deep --timestamp --options runtime \
        --entitlements Resources/RetroTerm.entitlements \
        --sign "$SIGN_IDENTITY" "$APP"
    codesign --verify --strict --verbose=2 "$APP"
else
    codesign --force --sign - "$APP" >/dev/null 2>&1 || true
fi
echo "✔ $APP"
