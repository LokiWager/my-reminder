#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="StandUpReminder.app"
APP_DIR="$ROOT_DIR/dist/$APP_NAME"
PROJECT_SPEC="$ROOT_DIR/project.yml"
PROJECT_FILE="$ROOT_DIR/StandUpReminder.xcodeproj"
DERIVED_DATA_DIR="$ROOT_DIR/.build/xcode"
XCODE_APP_DIR="$DERIVED_DATA_DIR/Build/Products/Release/$APP_NAME"
RESOURCES_DIR="$APP_DIR/Contents/Resources"
XCODE_RESOURCES_DIR="$XCODE_APP_DIR/Contents/Resources"
ICON_SOURCE_SCRIPT="$ROOT_DIR/scripts/generate-icon.swift"
ICON_MASTER_PNG="$ROOT_DIR/.build/AppIcon-1024.png"
ICONSET_DIR="$ROOT_DIR/.build/AppIcon.iconset"
ICNS_PATH="$ROOT_DIR/.build/AppIcon.icns"
APP_ENTITLEMENTS="$ROOT_DIR/App/StandUpReminder.entitlements"
APP_REQUIREMENTS='=designated => identifier "com.haotingyi.standupreminder"'

set_icon_plist_key() {
  local plist_path="$1"
  if /usr/libexec/PlistBuddy -c "Print :CFBundleIconFile" "$plist_path" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$plist_path"
  else
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$plist_path"
  fi
}

echo "Generating Xcode project..."
xcodegen generate --spec "$PROJECT_SPEC"

echo "Building app (Release)..."
xcodebuild \
  -project "$PROJECT_FILE" \
  -scheme StandUpReminder \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  CODE_SIGNING_ALLOWED=NO \
  build

echo "Copying built app to dist..."
rm -rf "$APP_DIR"
cp -R "$XCODE_APP_DIR" "$APP_DIR"
mkdir -p "$RESOURCES_DIR"
mkdir -p "$XCODE_RESOURCES_DIR"

echo "Generating icon..."
swift "$ICON_SOURCE_SCRIPT" "$ICON_MASTER_PNG"
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

sips -z 16 16 "$ICON_MASTER_PNG" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
sips -z 32 32 "$ICON_MASTER_PNG" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$ICON_MASTER_PNG" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
sips -z 64 64 "$ICON_MASTER_PNG" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$ICON_MASTER_PNG" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
sips -z 256 256 "$ICON_MASTER_PNG" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$ICON_MASTER_PNG" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
sips -z 512 512 "$ICON_MASTER_PNG" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$ICON_MASTER_PNG" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
cp "$ICON_MASTER_PNG" "$ICONSET_DIR/icon_512x512@2x.png"

iconutil -c icns "$ICONSET_DIR" -o "$ICNS_PATH"
cp "$ICNS_PATH" "$RESOURCES_DIR/AppIcon.icns"
cp "$ICNS_PATH" "$XCODE_RESOURCES_DIR/AppIcon.icns"

set_icon_plist_key "$APP_DIR/Contents/Info.plist"
set_icon_plist_key "$XCODE_APP_DIR/Contents/Info.plist"

echo "Signing app bundle (ad-hoc + entitlements)..."
codesign --force --sign - --entitlements "$APP_ENTITLEMENTS" \
  --requirements "$APP_REQUIREMENTS" \
  "$APP_DIR"

echo "Unregistering derived app from LaunchServices..."
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -u "$XCODE_APP_DIR" >/dev/null 2>&1 || true

echo "Stopping running app instances..."
pkill -x "StandUpReminder" >/dev/null 2>&1 || true

echo "Registering dist app with LaunchServices..."
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f -R -trusted "$APP_DIR" >/dev/null 2>&1 || true

echo "App bundle created:"
echo "  $APP_DIR"
echo
echo "Double-click it in Finder, or run:"
echo "  open \"$APP_DIR\""
