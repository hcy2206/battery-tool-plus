#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -n "$(git status --porcelain)" ]]; then
    echo 'Commit all source changes before packaging a release.' >&2
    exit 1
fi
VERSION=$(awk -F '"' '/^version =/{print $2; exit}' pyproject.toml)
RELEASE_VERSION=$(printf '%s' "$VERSION" | sed -E 's/b([0-9]+)$/-beta.\1/')
NAME="BatteryToolPlus-$RELEASE_VERSION"
OUT="$PWD/dist/release"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$OUT" "$STAGE/$NAME"
./scripts/build-macos.sh
codesign --verify --deep --strict dist/BatteryTool.app
plutil -lint dist/BatteryTool.app/Contents/Info.plist
MIN_OS=$(xcrun vtool -show-build dist/BatteryTool.app/Contents/MacOS/BatteryTool | awk '/minos/{print $2}')
if [[ "$MIN_OS" != "15.0" ]]; then
    echo "Unexpected binary deployment target: $MIN_OS (expected 15.0)" >&2
    exit 1
fi
# Disk image root: the app next to an Applications link for drag-and-drop install; documents in a folder.
DMG="$OUT/$NAME-macos-arm64.dmg"
ditto dist/BatteryTool.app "$STAGE/$NAME/BatteryTool.app"
ln -s /Applications "$STAGE/$NAME/Applications"
mkdir -p "$STAGE/$NAME/Documents"
cp README.md LICENSE THIRD_PARTY_NOTICES.md RELEASE_NOTES.md "$STAGE/$NAME/Documents/"
cp -R LICENSES "$STAGE/$NAME/Documents/"
git rev-parse HEAD > "$STAGE/$NAME/Documents/BUILD_COMMIT.txt"
rm -f "$DMG"
hdiutil create -quiet -volname "Battery Tool Plus $RELEASE_VERSION" -srcfolder "$STAGE/$NAME" -fs HFS+ -format UDZO "$DMG"
codesign --force --sign - "$DMG"
# Mount the image and verify the app inside it is the signed bundle that was built.
MOUNT=$(hdiutil attach -nobrowse -readonly -noautoopen "$DMG" | awk -F '\t' '/\/Volumes\//{print $NF}')
trap 'hdiutil detach -quiet "$MOUNT" || true; rm -rf "$STAGE"' EXIT
codesign --verify --deep --strict "$MOUNT/BatteryTool.app"
test -L "$MOUNT/Applications"
hdiutil detach -quiet "$MOUNT"
trap 'rm -rf "$STAGE"' EXIT
git archive --format=tar.gz --prefix="$NAME-source/" HEAD > "$OUT/$NAME-source.tar.gz"
cd "$OUT"
shasum -a 256 "$NAME-macos-arm64.dmg" "$NAME-source.tar.gz" > SHA256SUMS
printf 'Release artifacts: %s\n' "$OUT"
