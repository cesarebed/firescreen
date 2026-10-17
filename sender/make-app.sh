#!/bin/bash
# Builds FireScreen.app (menu-bar-less accessory app) next to this script.
# Run it with:  open -n sender/FireScreen.app --args --mode extend
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/FireScreen.app"

swift build -c release --package-path "$ROOT"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$ROOT/.build/release/FireScreen" "$APP/Contents/MacOS/FireScreen"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>io.firescreen.sender</string>
    <key>CFBundleName</key><string>FireScreen</string>
    <key>CFBundleExecutable</key><string>FireScreen</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSLocalNetworkUsageDescription</key><string>FireScreen streams your screen to the Fire TV on your network.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature with an identifier-only designated requirement, so the Screen Recording
# grant (which TCC stores as that requirement) survives rebuilds.
codesign --force --sign - --identifier io.firescreen.sender \
  --requirements '=designated => identifier "io.firescreen.sender"' "$APP"
echo "built $APP"
