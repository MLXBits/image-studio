#!/usr/bin/env bash
set -eo pipefail

# Usage: ./release.sh <version>
# Example: ./release.sh 0.1.0
#
# Prerequisites:
#   1. Developer ID Application certificate in Keychain
#   2. notarytool credentials stored once via:
#      xcrun notarytool store-credentials "notarytool" \
#        --apple-id "your@email.com" \
#        --team-id 39TQC8LANW \
#        --password "xxxx-xxxx-xxxx-xxxx"   # app-specific password from appleid.apple.com

VERSION="${1:?Usage: ./release.sh <version>  e.g. ./release.sh 0.1.0}"
SCHEME="MLXBits Image Studio"
APP_NAME="MLXBits Image Studio"
NOTARYTOOL_PROFILE="${NOTARYTOOL_PROFILE:-notarytool}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
ARCHIVE="$BUILD_DIR/archive.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP_PATH="$EXPORT_DIR/$APP_NAME.app"
DMG_PATH="$BUILD_DIR/${APP_NAME// /_}_${VERSION}.dmg"

echo "==> Cleaning build dir..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "==> Regenerating Xcode project..."
cd "$SCRIPT_DIR"
xcodegen generate

# Build number = total git commit count. Monotonically increases with every
# commit, so it never collides and never needs a manual bump.
BUILD_NUMBER="$(git rev-list --count HEAD)"
echo "==> Version $VERSION, build $BUILD_NUMBER (git commit count)"

echo "==> Archiving (this takes a few minutes)..."
xcodebuild archive \
  -workspace "$HOME/MLXBits.xcworkspace" \
  -scheme "$SCHEME" \
  -archivePath "$ARCHIVE" \
  -configuration Release \
  -destination "generic/platform=macOS" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  -allowProvisioningUpdates \
  -quiet \
  > "$BUILD_DIR/archive.log" 2>&1 || {
    echo "Archive failed. Last 40 lines of log:"
    tail -40 "$BUILD_DIR/archive.log"
    exit 1
  }
echo "    Archive succeeded."

echo "==> Exporting with Developer ID..."
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$SCRIPT_DIR/ExportOptions.plist" \
  > "$BUILD_DIR/export.log" 2>&1 || {
    echo "Export failed. Last 40 lines of log:"
    tail -40 "$BUILD_DIR/export.log"
    exit 1
  }
echo "    Export succeeded."

echo "==> Creating DMG..."
STAGING="$BUILD_DIR/dmg_staging"
mkdir -p "$STAGING"
cp -r "$APP_PATH" "$STAGING/"
ln -sf /Applications "$STAGING/Applications"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  -quiet \
  "$DMG_PATH"
rm -rf "$STAGING"
echo "    DMG created: $(basename "$DMG_PATH")"

echo "==> Notarizing DMG (may take a few minutes)..."
xcrun notarytool submit "$DMG_PATH" \
  --keychain-profile "$NOTARYTOOL_PROFILE" \
  --wait

echo "==> Stapling notarization ticket..."
xcrun stapler staple "$DMG_PATH"

echo ""
echo "Done. Release artifact:"
echo "  $DMG_PATH"
echo ""
echo "Upload to GitHub Releases as v${VERSION}."
