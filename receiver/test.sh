#!/bin/bash
# Runs the receiver's plain-JDK checks (no Android device or emulator needed).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
if [ -z "${JAVA_HOME:-}" ] && [ -d /opt/homebrew/opt/openjdk@21 ]; then
  export JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home
fi
JAVA_BIN="${JAVA_HOME:+$JAVA_HOME/bin/}"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
"${JAVA_BIN}javac" -d "$OUT" "$ROOT/src/io/firescreen/receiver/PlayoutClock.java" "$ROOT/test/PlayoutClockTest.java"
"${JAVA_BIN}java" -cp "$OUT" io.firescreen.receiver.PlayoutClockTest
