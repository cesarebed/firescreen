#!/bin/bash
# Builds the receiver APK with the Android SDK build-tools only (no Gradle).
# Usage: receiver/build.sh [--install]   (--install pushes it with adb and launches it)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/opt/homebrew/share/android-commandlinetools}}"
# Newest installed build-tools. 34.x's d8 crashes on classes compiled by JDK 21; use 35 or later.
TOOLS="$(ls -d "$SDK"/build-tools/* 2>/dev/null | sort -V | tail -1)"
PLATFORM="$SDK/platforms/android-34/android.jar"
[ -d "$TOOLS" ] || { echo "Android build-tools not found under $SDK (see README: Build from source)" >&2; exit 1; }
[ -f "$PLATFORM" ] || { echo "Android platform 34 not found: sdkmanager \"platforms;android-34\"" >&2; exit 1; }
if [ -z "${JAVA_HOME:-}" ] && [ -d /opt/homebrew/opt/openjdk@21 ]; then
  export JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home
fi
JAVA_BIN="${JAVA_HOME:+$JAVA_HOME/bin/}"
OUT="$ROOT/build"
KEYSTORE="$ROOT/debug.keystore"

rm -rf "$OUT" && mkdir -p "$OUT/classes" "$OUT/dex"

"$TOOLS/aapt2" compile --dir "$ROOT/res" -o "$OUT/res.zip"
"$TOOLS/aapt2" link -o "$OUT/unsigned.apk" -I "$PLATFORM" \
  --manifest "$ROOT/AndroidManifest.xml" "$OUT/res.zip" --java "$OUT/gen" --auto-add-overlay

"${JAVA_BIN}javac" --release 11 -Xlint:-options -classpath "$PLATFORM" -d "$OUT/classes" \
  $(find "$ROOT/src" "$OUT/gen" -name '*.java')
"$TOOLS/d8" --min-api 25 --lib "$PLATFORM" --output "$OUT/dex" $(find "$OUT/classes" -name '*.class')

(cd "$OUT/dex" && zip -q -j "$OUT/unsigned.apk" classes.dex)
"$TOOLS/zipalign" -f 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"

# A local debug key, created on first build and never committed. Updating an installed
# receiver requires the same key, so keep this file between builds.
if [ ! -f "$KEYSTORE" ]; then
  "${JAVA_BIN}keytool" -genkeypair -keystore "$KEYSTORE" -storepass android -keypass android \
    -alias debug -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=FireScreen Debug" >/dev/null
fi
"$TOOLS/apksigner" sign --ks "$KEYSTORE" --ks-pass pass:android --key-pass pass:android \
  --out "$OUT/firescreen-receiver.apk" "$OUT/aligned.apk"

echo "built $OUT/firescreen-receiver.apk"

if [ "${1:-}" = "--install" ]; then
  adb install -r "$OUT/firescreen-receiver.apk"
  adb shell am start -n io.firescreen.receiver/.MainActivity
fi
