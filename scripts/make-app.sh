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
cp "$BIN_DIR/infinitty-mcp" "$APP/Contents/MacOS/infinitty-mcp"
cp "$BIN_DIR/infinitty-agent" "$APP/Contents/MacOS/infinitty-agent"
cp assets/AppIcon.icns "$APP/Contents/Resources/"
cp -R shell-integration "$APP/Contents/Resources/"
cp -R Sources/InfinittyKit/Resources/Pets "$APP/Contents/Resources/"
cp -R Sources/InfinittyKit/Resources/Logos "$APP/Contents/Resources/"
cp -R Sources/InfinittyKit/Resources/Surfaces "$APP/Contents/Resources/"
# Every directory under Resources/ must be listed here: the app has no SwiftPM
# resource bundle, so anything missed is simply absent at runtime.
cp -R Sources/InfinittyKit/Resources/NotchPets "$APP/Contents/Resources/"

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
    <!--
      TCC attributes a child process's access to the responsible process, which
      for anything started in a pane is Infinitty. These strings are what macOS
      shows in the prompt; without them the alert has no explanation and the
      user is asked to trust a terminal for no stated reason. Each one is
      phrased to make clear the request came from THEIR command.
    -->
    <key>NSAppleEventsUsageDescription</key><string>A command running in Infinitty wants to control another app.</string>
    <key>NSDesktopFolderUsageDescription</key><string>A command running in Infinitty wants to access files on your Desktop.</string>
    <key>NSDocumentsFolderUsageDescription</key><string>A command running in Infinitty wants to access files in your Documents folder.</string>
    <key>NSDownloadsFolderUsageDescription</key><string>A command running in Infinitty wants to access files in your Downloads folder.</string>
    <key>NSRemovableVolumesUsageDescription</key><string>A command running in Infinitty wants to access files on a removable volume.</string>
    <key>NSNetworkVolumesUsageDescription</key><string>A command running in Infinitty wants to access files on a network volume.</string>
    <key>NSFileProviderDomainUsageDescription</key><string>A command running in Infinitty wants to access files stored in the cloud.</string>
    <key>NSSystemAdministrationUsageDescription</key><string>A command running in Infinitty wants to administer this Mac.</string>
    <key>NSMicrophoneUsageDescription</key><string>A command running in Infinitty wants to use the microphone.</string>
    <key>NSCameraUsageDescription</key><string>A command running in Infinitty wants to use the camera.</string>
    <key>NSSpeechRecognitionUsageDescription</key><string>A command running in Infinitty wants to use speech recognition.</string>
    <key>NSContactsUsageDescription</key><string>A command running in Infinitty wants to access your contacts.</string>
    <key>NSCalendarsFullAccessUsageDescription</key><string>A command running in Infinitty wants to access your calendars.</string>
    <key>NSRemindersFullAccessUsageDescription</key><string>A command running in Infinitty wants to access your reminders.</string>
    <key>NSPhotoLibraryUsageDescription</key><string>A command running in Infinitty wants to access your photo library.</string>
    <key>NSLocationWhenInUseUsageDescription</key><string>A command running in Infinitty wants to use your location.</string>
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
