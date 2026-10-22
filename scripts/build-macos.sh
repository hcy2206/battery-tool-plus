#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="$PWD/build/macos"
APP="$PWD/dist/Battery Tool Plus.app"
VERSION=$(awk -F '"' '/^version =/{print $2; exit}' pyproject.toml)
# Python prerelease versions are mapped to a numeric Apple short version; the build
# number is the commit count so it increases across betas and releases alike.
APP_VERSION=$(printf '%s' "$VERSION" | sed -E 's/b[0-9]+$//')
BUILD_VERSION=$(git rev-list --count HEAD 2>/dev/null || echo 1)
if [[ "$(uname -m)" != "arm64" ]]; then
    echo "Battery Tool Plus requires Apple Silicon (arm64)." >&2
    exit 1
fi
mkdir -p "$BUILD" "$APP/Contents/MacOS" "$APP/Contents/Resources"
export MACOSX_DEPLOYMENT_TARGET=15.0
for source in smc smc_wrapper power_sources; do
    /usr/bin/clang -O2 -c "c/$source.c" -o "$BUILD/$source.o"
done
xcrun swiftc -target arm64-apple-macosx15.0 -module-cache-path "$BUILD/ModuleCache" -swift-version 5 -O -parse-as-library -import-objc-header macos/Bridge.h \
    macos/Sources/*.swift "$BUILD/smc.o" "$BUILD/smc_wrapper.o" "$BUILD/power_sources.o" \
    -framework SwiftUI -framework AppKit -framework Metal -framework IOKit -framework CoreFoundation \
    -framework CoreGraphics -framework Charts -lsqlite3 -o "$APP/Contents/MacOS/BatteryTool"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>BatteryTool</string>
<key>CFBundleIdentifier</key><string>local.batterytool.manager</string>
<key>CFBundleName</key><string>Battery Tool Plus</string>
<key>CFBundleDisplayName</key><string>Battery Tool Plus</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
<key>CFBundleVersion</key><string>$BUILD_VERSION</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
<key>NSHumanReadableCopyright</key><string>© 2026 hcy2206 and BatteryTool contributors. GPL-3.0-only.</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
cp LICENSE docs/THIRD_PARTY_NOTICES.md macos/AppIcon.icns "$APP/Contents/Resources/"
mkdir -p "$APP/Contents/Resources/LICENSES"
cp LICENSES/*.txt "$APP/Contents/Resources/LICENSES/"
codesign --force --deep --sign - "$APP"
printf 'Built %s\n' "$APP"
