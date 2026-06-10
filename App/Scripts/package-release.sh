#!/usr/bin/env bash
# Package MovieBox.app into zip (Sparkle) and dmg (manual install) under build/export/.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EXPORT_DIR="$ROOT/build/export"
APP_PATH="$EXPORT_DIR/MovieBox.app"
ZIP_PATH="$EXPORT_DIR/MovieBox.zip"
DMG_PATH="$EXPORT_DIR/MovieBox.dmg"
DMG_STAGING="$EXPORT_DIR/dmg-staging"

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: expected app at $APP_PATH" >&2
  exit 1
fi

mkdir -p "$EXPORT_DIR"

echo "→ Creating MovieBox.zip"
rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

echo "→ Creating MovieBox.dmg"
rm -rf "$DMG_STAGING" "$DMG_PATH"
mkdir -p "$DMG_STAGING"
ditto "$APP_PATH" "$DMG_STAGING/MovieBox.app"
ln -s /Applications "$DMG_STAGING/Applications"
hdiutil create -volname "MovieBox" -srcfolder "$DMG_STAGING" -ov -format UDZO "$DMG_PATH" >/dev/null
rm -rf "$DMG_STAGING"

echo "  Zip: $ZIP_PATH"
echo "  Dmg: $DMG_PATH"
