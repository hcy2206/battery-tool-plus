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
ditto dist/BatteryTool.app "$STAGE/$NAME/BatteryTool.app"
cp README.md LICENSE THIRD_PARTY_NOTICES.md RELEASE_NOTES.md "$STAGE/$NAME/"
cp -R LICENSES "$STAGE/$NAME/"
git rev-parse HEAD > "$STAGE/$NAME/BUILD_COMMIT.txt"
# ditto may update an existing archive; replace only this version's ZIP.
rm -f "$OUT/$NAME-macos-arm64.zip"
ditto -c -k --sequesterRsrc --keepParent "$STAGE/$NAME" "$OUT/$NAME-macos-arm64.zip"
git archive --format=tar.gz --prefix="$NAME-source/" HEAD > "$OUT/$NAME-source.tar.gz"
cd "$OUT"
shasum -a 256 "$NAME-macos-arm64.zip" "$NAME-source.tar.gz" > SHA256SUMS
printf 'Release artifacts: %s\n' "$OUT"
