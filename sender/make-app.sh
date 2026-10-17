#!/bin/bash
# Builds FireScreen.app next to this script, with the receiver APK inside when it has been built.
# Open it for the menu bar app, or run its binary for the command line:
#   sender/FireScreen.app/Contents/MacOS/FireScreen --help
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/FireScreen.app"

swift build -c release --package-path "$ROOT"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/FireScreen" "$APP/Contents/MacOS/FireScreen"
APK="$ROOT/../receiver/build/firescreen-receiver.apk"
if [ -f "$APK" ]; then
  cp "$APK" "$APP/Contents/Resources/firescreen-receiver.apk"
else
  echo "note: receiver APK not built (receiver/build.sh); Install receiver will be unavailable" >&2
fi

# The calibration test pattern ships inside the app (generated, ~6 MB): writing it at
# calibration time would compete with the live encoder.
CLIPS="$(mktemp -d)"
"$APP/Contents/MacOS/FireScreen" make-test-clips "$CLIPS" >/dev/null
cp "$CLIPS/firescreen-sync.mov" "$APP/Contents/Resources/firescreen-sync.mov"
rm -rf "$CLIPS"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>io.firescreen.sender</string>
    <key>CFBundleName</key><string>FireScreen</string>
    <key>CFBundleExecutable</key><string>FireScreen</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.2.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSLocalNetworkUsageDescription</key><string>FireScreen finds your Fire TV and streams your screen to it over the local network.</string>
    <key>NSBonjourServices</key><array><string>_firescreen._tcp</string></array>
</dict>
</plist>
PLIST

# Ad-hoc signature with an identifier-only designated requirement, so the Screen Recording
# grant (which TCC stores as that requirement) survives rebuilds.
codesign --force --sign - --identifier io.firescreen.sender \
  --requirements '=designated => identifier "io.firescreen.sender"' "$APP"
echo "built $APP"
