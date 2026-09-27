#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
xcrun swiftc -swift-version 5 -parse-as-library native/UpdatePolicy.swift native/UpdatePolicyTests.swift -o .build/update-policy-tests
.build/update-policy-tests
xcrun swiftc -swift-version 5 -parse-as-library -F vendor/sparkle -framework Sparkle -Xlinker -rpath -Xlinker "$(pwd)/vendor/sparkle" native/BeautyEffects.swift native/CaptureEngine.swift native/UpdatePolicy.swift native/Updater.swift native/Bridge.swift native/UpdaterTests.swift -o .build/updater-tests
.build/updater-tests
