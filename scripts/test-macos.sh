#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="$PWD/build/macos-tests"
mkdir -p "$BUILD"
export MACOSX_DEPLOYMENT_TARGET=15.0
xcrun swiftc -module-cache-path "$BUILD/ModuleCache" -swift-version 5 -parse-as-library \
    -import-objc-header macos/Bridge.h macos/Sources/Policy.swift macos/Sources/History.swift \
    macos/Tests/PolicyTests.swift -lsqlite3 -o "$BUILD/policy-tests"
"$BUILD/policy-tests"
