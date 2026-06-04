#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT/App"
BUILD_DIR="$ROOT/build"
ARCHIVE_PATH="$BUILD_DIR/MovieBox.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
DERIVED_DATA="$BUILD_DIR/DerivedData"
SECRETS="$APP_DIR/MovieBox/Configuration/DevelopmentSecrets.swift"
SECRETS_EXAMPLE="$APP_DIR/MovieBox/Configuration/DevelopmentSecrets.swift.example"

if [[ ! -f "$SECRETS" ]]; then
  echo "→ Creating DevelopmentSecrets.swift from example"
  cp "$SECRETS_EXAMPLE" "$SECRETS"
fi

mkdir -p "$EXPORT_DIR" "$BUILD_DIR"

cd "$APP_DIR"

echo "→ Archiving MovieBox (Release, macOS arm64)…"
xcodebuild \
  -project MovieBox.xcodeproj \
  -scheme MovieBox \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE_PATH" \
  -derivedDataPath "$DERIVED_DATA" \
  archive \
  ARCHS=arm64 \
  EXCLUDED_ARCHS=x86_64 \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=YES

APP_IN_ARCHIVE="$ARCHIVE_PATH/Products/Applications/MovieBox.app"
if [[ ! -d "$APP_IN_ARCHIVE" ]]; then
  echo "error: expected app at $APP_IN_ARCHIVE" >&2
  exit 1
fi

echo "→ Copying MovieBox.app to $EXPORT_DIR"
rm -rf "$EXPORT_DIR/MovieBox.app"
ditto "$APP_IN_ARCHIVE" "$EXPORT_DIR/MovieBox.app"

echo "→ Creating MovieBox.zip"
rm -f "$EXPORT_DIR/MovieBox.zip"
ditto -c -k --sequesterRsrc --keepParent "$EXPORT_DIR/MovieBox.app" "$EXPORT_DIR/MovieBox.zip"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$EXPORT_DIR/MovieBox.app/Contents/Info.plist" 2>/dev/null || echo "?")"
BUILD_NUM="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$EXPORT_DIR/MovieBox.app/Contents/Info.plist" 2>/dev/null || echo "?")"

echo ""
echo "Done."
echo "  App:     $EXPORT_DIR/MovieBox.app"
echo "  Zip:     $EXPORT_DIR/MovieBox.zip"
echo "  Archive: $ARCHIVE_PATH"
echo "  Version: $VERSION ($BUILD_NUM)"
echo ""
echo "Open: open \"$EXPORT_DIR/MovieBox.app\""
