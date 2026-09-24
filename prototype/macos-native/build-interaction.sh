#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
app="$PWD/.build/RecordReady Interaction Probe.app"
mkdir -p "$app/Contents/MacOS"
xcrun swiftc -swift-version 5 -O -target "$(uname -m)-apple-macos13.0" "$PWD/InteractionProbe.swift" -o "$app/Contents/MacOS/InteractionProbe"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>InteractionProbe</string>
<key>CFBundleIdentifier</key><string>dev.recordready.interaction-probe</string>
<key>CFBundleName</key><string>RecordReady Interaction Probe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - --identifier dev.recordready.interaction-probe "$app" >/dev/null
printf '%s\n' "$app"
