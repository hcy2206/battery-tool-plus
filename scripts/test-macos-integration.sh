#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="$PWD/build/macos-integration"
mkdir -p "$BUILD"
export MACOSX_DEPLOYMENT_TARGET=15.0
for source in smc smc_wrapper power_sources; do
    /usr/bin/clang -O2 -c "c/$source.c" -o "$BUILD/$source.o"
done
xcrun swiftc -module-cache-path "$PWD/build/macos/ModuleCache" -swift-version 5 -D TESTING \
    -parse-as-library -import-objc-header macos/Bridge.h macos/Sources/*.swift \
    macos/Tests/IntegrationTests.swift "$BUILD/smc.o" "$BUILD/smc_wrapper.o" "$BUILD/power_sources.o" \
    -framework SwiftUI -framework AppKit -framework Metal -framework IOKit -framework CoreFoundation \
    -framework CoreGraphics -framework Charts -lsqlite3 -o "$BUILD/integration-tests"
"$BUILD/integration-tests" "$BUILD/previews"
