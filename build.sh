#!/bin/bash
# Builds Stagecoach.app and stagecoach-cli into ./build — Command Line Tools only.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Stagecoach"
BUNDLE_ID="local.stagecoach"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
SDK="$(xcrun --show-sdk-path)"
TARGET="$(uname -m)-apple-macos15.0"
ENGINE="Sources/Stagecoach/MenuBarIcon.swift Sources/Stagecoach/DropboxState.swift Sources/Stagecoach/Readiness.swift Sources/Stagecoach/SaveFile.swift Sources/Stagecoach/Sanitise.swift Sources/Stagecoach/Compatibility.swift Sources/Stagecoach/CampaignInfo.swift Sources/Stagecoach/SteamCache.swift Sources/Stagecoach/Paths.swift Sources/Stagecoach/Snapshot.swift Sources/Stagecoach/Ledger.swift Sources/Stagecoach/SyncEngine.swift Sources/Stagecoach/SteamCloud.swift Sources/Stagecoach/Processes.swift Sources/Stagecoach/Watcher.swift"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Compiling the app…"
swiftc -swift-version 5 -O -sdk "$SDK" -target "$TARGET" -parse-as-library \
  $ENGINE Sources/Stagecoach/Model.swift Sources/Stagecoach/App.swift \
  -o "$APP/Contents/MacOS/$APP_NAME"

echo "Compiling the command-line helper…"
swiftc -swift-version 5 -O -sdk "$SDK" -target "$TARGET" \
  $ENGINE Sources/CLI/main.swift \
  -o "$BUILD_DIR/stagecoach-cli"

mkdir -p "$APP/Contents/Helpers"
cp "$BUILD_DIR/stagecoach-cli" "$APP/Contents/Helpers/stagecoach-cli"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

echo "Drawing the icon…"
swiftc -O -sdk "$SDK" -target "$TARGET" Icon/make_icon.swift -o "$BUILD_DIR/make_icon"
rm -rf "$BUILD_DIR/AppIcon.iconset"
"$BUILD_DIR/make_icon" "$BUILD_DIR/AppIcon.iconset"
iconutil -c icns "$BUILD_DIR/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

echo "Signing…"
codesign --force --sign - "$APP/Contents/Helpers/stagecoach-cli" >/dev/null 2>&1 || true
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "  (ad-hoc signing skipped)"

echo "Built $APP and $BUILD_DIR/stagecoach-cli"
