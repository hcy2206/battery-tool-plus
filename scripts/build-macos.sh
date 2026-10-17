#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="$PWD/build/macos"
APP="$PWD/dist/BatteryTool.app"
VERSION=$(awk -F '"' '/^version =/{print $2; exit}' pyproject.toml)
if [[ "$(uname -m)" != "arm64" ]]; then
    echo "BatteryTool requires Apple Silicon (arm64)." >&2
    exit 1
fi
mkdir -p "$BUILD" "$APP/Contents/MacOS" "$APP/Contents/Resources"
export MACOSX_DEPLOYMENT_TARGET=15.0
for source in smc smc_wrapper power_sources; do
    /usr/bin/clang -O2 -c "c/$source.c" -o "$BUILD/$source.o"
done
xcrun swiftc -module-cache-path "$BUILD/ModuleCache" -swift-version 5 -O -parse-as-library -import-objc-header macos/Bridge.h \
    macos/Sources/*.swift "$BUILD/smc.o" "$BUILD/smc_wrapper.o" "$BUILD/power_sources.o" \
    -framework SwiftUI -framework AppKit -framework Metal -framework IOKit -framework CoreFoundation \
    -framework CoreGraphics -framework Charts -lsqlite3 -o "$APP/Contents/MacOS/BatteryTool"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>BatteryTool</string>
<key>CFBundleIdentifier</key><string>local.batterytool.manager</string>
<key>CFBundleName</key><string>BatteryTool</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP"
printf 'Built %s\n' "$APP"
