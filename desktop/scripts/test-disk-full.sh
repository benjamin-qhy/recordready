#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
xcrun swiftc -swift-version 5 -parse-as-library native/CaptureEngine.swift native/DiskFullTests.swift -o .build/disk-full-tests
workspace=$(mktemp -d /tmp/recordready-diskfull.XXXXXX)
mounted=false
cleanup() {
  if [ "$mounted" = true ]; then
    hdiutil detach "$workspace/volume" -quiet || { echo "Detach failed; retained $workspace" >&2; return; }
  fi
  rm -rf "$workspace"
}
trap cleanup EXIT
hdiutil create -size 64m -fs HFS+ -volname RecordReadyDiskFullTest "$workspace/test.dmg" -quiet
mkdir "$workspace/volume"
hdiutil attach "$workspace/test.dmg" -mountpoint "$workspace/volume" -nobrowse -quiet
mounted=true
.build/disk-full-tests "$workspace/volume"
