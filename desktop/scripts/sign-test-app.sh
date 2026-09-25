#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="src-tauri/target/debug/bundle/macos/RecordReady.app"
# Local tests only. An ad-hoc signature is not a persistent developer identity.
/usr/bin/codesign --force --sign - --identifier com.recordready.desktop "$app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app"
/usr/bin/codesign -d -r- "$app" 2>&1
/usr/bin/shasum -a 256 "$app/Contents/MacOS/recordready"
