#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
app="$PWD/.build/RecordReady Capture Reference.app"
mkdir -p "$app/Contents/MacOS"
xcrun swiftc -swift-version 5 -O -target "$(uname -m)-apple-macos13.0" "$PWD/Reference.swift" -o "$app/Contents/MacOS/Reference"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Reference</string>
<key>CFBundleIdentifier</key><string>dev.recordready.capture-reference</string>
<key>CFBundleName</key><string>RecordReady Capture Reference</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - --identifier dev.recordready.capture-reference "$app" >/dev/null
printf '%s\n' "$app"
