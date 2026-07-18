#!/bin/zsh
# Assemble Infinitty.app from built binaries.
# Usage: scripts/make-app.sh <binaries-dir> <version> [output-dir]
set -euo pipefail
cd "$(dirname "$0")/.."
BIN_DIR="${1:?binaries dir}"
VERSION="${2:?version}"
OUT="${3:-dist}"

APP="$OUT/Infinitty.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/infinitty" "$APP/Contents/MacOS/infinitty"
cp assets/AppIcon.icns "$APP/Contents/Resources/"
cp -R shell-integration "$APP/Contents/Resources/"
cp -R Sources/InfinittyKit/Resources/Pets "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>infinitty</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>com.jasonkneen.infinitty</string>
    <key>CFBundleName</key><string>Infinitty</string>
    <key>CFBundleDisplayName</key><string>Infinitty</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>© Jason Kneen</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Folder</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array><string>public.folder</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST
echo "$APP assembled"
