#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
xcrun swiftc -swift-version 5 -parse-as-library native/BeautyEffects.swift native/CaptureEngine.swift native/UpdatePolicy.swift native/Updater.swift native/Bridge.swift native/NativeTests.swift -o .build/native-tests
.build/native-tests
