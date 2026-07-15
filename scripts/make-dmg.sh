#!/bin/zsh
# Build a drag-to-Applications DMG from a signed Infinitty.app.
# Usage: scripts/make-dmg.sh <path-to-Infinitty.app> <version> [identity]
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${1:?path to Infinitty.app}"
VERSION="${2:?version}"
IDENTITY="${3:-}"

STAGE=$(mktemp -d)
mkdir -p "$STAGE/dmg"
cp -R "$APP" "$STAGE/dmg/Infinitty.app"
ln -s /Applications "$STAGE/dmg/Applications"

DMG="Infinitty-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Infinitty $VERSION" \
  -srcfolder "$STAGE/dmg" \
  -ov -format UDZO \
  "$DMG" >/dev/null
rm -rf "$STAGE"

if [ -n "$IDENTITY" ]; then
  codesign --force --timestamp --sign "$IDENTITY" "$DMG" 2>&1 | tail -1
fi
shasum -a 256 "$DMG" > "$DMG.sha256"
echo "$DMG built"
