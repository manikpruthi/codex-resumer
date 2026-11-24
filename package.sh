#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
APP_NAME="CodexResumer"
BUNDLE_NAME="Codex Resumer"
BUILD_DIR="${CODEX_RESUMER_BUILD_DIR:-$HOME/Library/Caches/CodexResumerBuild}"
RELEASE_DIR="release"
APP="$BUILD_DIR/$BUNDLE_NAME.app"

./build.sh release

rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/$BUNDLE_NAME.app"
ln -s /Applications "$STAGE/Applications"

diskutil image create from --format UDZO --volumeName "$BUNDLE_NAME" \
    "$STAGE" "$RELEASE_DIR/$APP_NAME-$VERSION.dmg" >/dev/null

touch "$RELEASE_DIR/.metadata_never_index"

echo "Packaged:"
ls -lh "$RELEASE_DIR"