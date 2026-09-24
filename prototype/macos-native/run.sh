#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
app="$PWD/.build/RecordReady Native Probe.app"
mkdir -p "$app/Contents/MacOS"
xcrun swiftc -swift-version 5 -O -target "$(uname -m)-apple-macos13.0" "$PWD/Main.swift" -o "$app/Contents/MacOS/RecordReadyProbe"
cp Info.plist "$app/Contents/Info.plist"
codesign --force --sign - --identifier dev.recordready.native-probe "$app" >/dev/null
if [[ "${1:-}" != "--build-only" ]]; then
  open "$app"
fi
printf '%s\n' "$app"
