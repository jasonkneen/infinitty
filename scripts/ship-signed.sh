#!/bin/zsh
# Fully sign + notarize + staple + upload the release, locally.
# Prereq: a "Developer ID Application" cert in your Keychain
#         (Xcode > Settings > Accounts > Manage Certificates > + ).
# Usage: scripts/ship-signed.sh <version>
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?usage: ship-signed.sh <version>}"

IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/')
if [ -z "$IDENTITY" ]; then
  echo "ERROR: no 'Developer ID Application' cert in Keychain."
  echo "Create one: Xcode > Settings > Accounts > (your team) > Manage Certificates > + > Developer ID Application"
  exit 1
fi
echo "Signing identity: $IDENTITY"

# One-time notarization credentials (stored in keychain as profile 'infinitty').
if ! xcrun notarytool history --keychain-profile infinitty >/dev/null 2>&1; then
  echo "Set up notarization credentials (one time):"
  read "APPLEID?  Apple ID email: "
  echo "  App-specific password: appleid.apple.com > Sign-In & Security > App-Specific Passwords"
  read -s "APPPASS?  App-specific password: "; echo
  xcrun notarytool store-credentials infinitty \
    --apple-id "$APPLEID" --team-id SW75ZJJ5R6 --password "$APPPASS"
fi

BIN=.build/apple/Products/Release
scripts/make-app.sh "$BIN" "$VERSION" dist >/dev/null
cp "$BIN/infinitty-mcp" dist/

echo "Signing…"
codesign --force --options runtime --timestamp --sign "$IDENTITY" dist/infinitty-mcp
codesign --force --options runtime --timestamp --sign "$IDENTITY" dist/Infinitty.app/Contents/MacOS/infinitty-mcp
codesign --force --options runtime --timestamp --sign "$IDENTITY" dist/Infinitty.app
codesign -vvv --strict dist/Infinitty.app

echo "Building DMG…"
scripts/make-dmg.sh dist/Infinitty.app "$VERSION" "$IDENTITY" >/dev/null

echo "Notarizing DMG (2-5 min)…"
xcrun notarytool submit "Infinitty-$VERSION.dmg" --keychain-profile infinitty --wait
xcrun stapler staple "Infinitty-$VERSION.dmg"
xcrun stapler validate "Infinitty-$VERSION.dmg"

# Also notarize the tarball's app payload for the CLI users.
echo "Notarizing app zip…"
ditto -c -k --keepParent dist/Infinitty.app notarize-app.zip
xcrun notarytool submit notarize-app.zip --keychain-profile infinitty --wait
xcrun stapler staple dist/Infinitty.app

STAGE="infinitty-$VERSION"; rm -rf pkg; mkdir -p "pkg/$STAGE"
cp -R dist/Infinitty.app "pkg/$STAGE/"; cp dist/infinitty-mcp "pkg/$STAGE/"
cp -R shell-integration "pkg/$STAGE/"; cp infinitty.conf.example README.md LICENSE "pkg/$STAGE/"
tar -czf "infinitty-$VERSION-macos.tar.gz" -C pkg "$STAGE"
shasum -a 256 "Infinitty-$VERSION.dmg" > "Infinitty-$VERSION.dmg.sha256"
shasum -a 256 "infinitty-$VERSION-macos.tar.gz" > "infinitty-$VERSION-macos.tar.gz.sha256"

echo "Uploading to release v$VERSION…"
gh release upload "v$VERSION" \
  "Infinitty-$VERSION.dmg" "Infinitty-$VERSION.dmg.sha256" \
  "infinitty-$VERSION-macos.tar.gz" "infinitty-$VERSION-macos.tar.gz.sha256" \
  --clobber
echo "DONE — signed, notarized, stapled, uploaded. No Gatekeeper errors."
