#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
app_dir="$PWD/.build/RecordReady Effects Probe.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 -O Main.swift -o "$app_dir/Contents/MacOS/EffectsProbe" -framework AppKit -framework AVFoundation -framework Vision -framework CoreImage -framework MetalKit
cp Info.plist "$app_dir/Contents/Info.plist"
cp Effects.metal "$app_dir/Contents/Resources/"
codesign --force --sign - "$app_dir"
"$app_dir/Contents/MacOS/EffectsProbe" --self-check
printf '%s\n' "$app_dir"
