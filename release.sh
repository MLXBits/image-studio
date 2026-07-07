#!/usr/bin/env bash
set -eo pipefail

# Usage: ./release.sh [version]
#
# The VERSION file is the single source of truth. Bump it, run this, done:
# the script syncs project.yml, builds/signs/notarizes the DMG, tags the
# commit, pushes, and publishes the GitHub release. Pass a version argument
# only to override the VERSION file for a one-off.
#
# Prerequisites:
#   1. Developer ID Application certificate in Keychain.
#   2. notarytool credentials stored once via:
#      xcrun notarytool store-credentials "notarytool" \
#        --apple-id "your@email.com" --team-id XXXXXXXXXX \
#        --password "xxxx-xxxx-xxxx-xxxx"   # app-specific password
#   3. A local .env (gitignored) exporting DEVELOPMENT_TEAM (and optionally
#      NOTARYTOOL_PROFILE). Sourced automatically.
#   4. gh CLI authenticated with push access to the GitHub repo.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Local secrets (Team ID, notarytool profile).
# shellcheck disable=SC1091
[ -f "$SCRIPT_DIR/.env" ] && source "$SCRIPT_DIR/.env"

# Version: VERSION file is the source of truth; a CLI arg overrides it.
VERSION="${1:-$(tr -d '[:space:]' < "$SCRIPT_DIR/VERSION")}"
[ -n "$VERSION" ] || { echo "No version found (set VERSION file or pass an arg)."; exit 1; }

SCHEME="MLXBits Image Studio"
APP_NAME="MLXBits Image Studio"
NOTARYTOOL_PROFILE="${NOTARYTOOL_PROFILE:-notarytool}"
GH_REPO="MLXBits/image-studio"
PUSH_REMOTE="all"
TAG="v${VERSION}"

# Your 10-character Apple Developer Team ID, from .env (gitignored).
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM in .env to your Apple Developer Team ID}"

BUILD_DIR="$SCRIPT_DIR/build"
ARCHIVE="$BUILD_DIR/archive.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP_PATH="$EXPORT_DIR/$APP_NAME.app"
DMG_PATH="$BUILD_DIR/${APP_NAME// /_}_${VERSION}.dmg"

echo "==> Releasing $TAG"

# Keep project.yml's MARKETING_VERSION in sync with VERSION so plain builds and
# the committed source always match the release — no separate manual bump.
sed -i '' "s/^\( *MARKETING_VERSION:\).*/\1 \"$VERSION\"/" project.yml

echo "==> Cleaning build dir..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "==> Regenerating Xcode project..."
xcodegen generate

# Commit the version bump (VERSION + project.yml + regenerated pbxproj) if
# anything changed, so the tag points at source that matches the release.
if ! git diff --quiet -- VERSION project.yml "MLXBits Image Studio.xcodeproj/project.pbxproj"; then
  git add VERSION project.yml "MLXBits Image Studio.xcodeproj/project.pbxproj"
  git commit -q -m "chore: release $TAG"
  echo "    Committed version bump."
fi

# Build number = total git commit count. Monotonically increases with every
# commit, so it never collides and never needs a manual bump.
BUILD_NUMBER="$(git rev-list --count HEAD)"
echo "==> Version $VERSION, build $BUILD_NUMBER (git commit count)"

echo "==> Archiving (this takes a few minutes)..."
xcodebuild archive \
  -project "$SCRIPT_DIR/MLXBits Image Studio.xcodeproj" \
  -scheme "$SCHEME" \
  -archivePath "$ARCHIVE" \
  -configuration Release \
  -destination "generic/platform=macOS" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  -allowProvisioningUpdates \
  -quiet \
  > "$BUILD_DIR/archive.log" 2>&1 || {
    echo "Archive failed. Last 40 lines of log:"
    tail -40 "$BUILD_DIR/archive.log"
    exit 1
  }
echo "    Archive succeeded."

EXPORT_PLIST="$BUILD_DIR/ExportOptions.plist"
cat > "$EXPORT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>${DEVELOPMENT_TEAM}</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
PLIST

echo "==> Exporting with Developer ID..."
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_PLIST" \
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

# Everything below runs only after a signed, notarized, stapled DMG exists.

echo "==> Tagging $TAG and pushing to $PUSH_REMOTE..."
if ! git rev-parse "$TAG" >/dev/null 2>&1; then
  git tag -a "$TAG" -m "$TAG"
fi
git push "$PUSH_REMOTE" HEAD:main
git push "$PUSH_REMOTE" "$TAG"

# Build release notes from the commits since the previous tag. Each line is a
# clickable short hash, so the notes work even without PRs (--generate-notes
# only lists merged PRs and otherwise degrades to a bare compare link).
NOTES_FILE="$BUILD_DIR/notes.md"
PREV_TAG="$(git describe --tags --abbrev=0 "${TAG}^" 2>/dev/null || true)"
{
  echo "## What's Changed"
  echo
  git log --no-merges --invert-grep --grep="^chore: release " \
    --pretty=format:"- %s ([\`%h\`](https://github.com/${GH_REPO}/commit/%H))" \
    "${PREV_TAG:+$PREV_TAG..}HEAD"
  echo
  if [ -n "$PREV_TAG" ]; then
    echo
    echo "**Full Changelog**: https://github.com/${GH_REPO}/compare/${PREV_TAG}...${TAG}"
  fi
} > "$NOTES_FILE"

echo "==> Publishing GitHub release..."
if gh release view "$TAG" -R "$GH_REPO" >/dev/null 2>&1; then
  gh release upload "$TAG" "$DMG_PATH" -R "$GH_REPO" --clobber
  echo "    Release already existed; DMG uploaded."
else
  gh release create "$TAG" "$DMG_PATH" \
    -R "$GH_REPO" \
    --title "$TAG" \
    --verify-tag \
    --notes-file "$NOTES_FILE"
fi

echo ""
echo "Done. Released $TAG:"
echo "  https://github.com/${GH_REPO}/releases/tag/${TAG}"
echo "  $DMG_PATH"
