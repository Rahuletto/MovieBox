#!/usr/bin/env bash
# Rasterize App/AppIcon.icon into Assets.xcassets/AppIcon.appiconset for CI builds.
# Xcode 26.5 actool crashes on Icon Composer .icon at compile time (Apple regression).
# Re-run after editing AppIcon.icon in Icon Composer.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ICON_SRC="$ROOT/AppIcon.icon"
ASSETS="$ROOT/MovieBox/Assets.xcassets"
ICONSET="$ASSETS/AppIcon.appiconset"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

if [[ ! -d "$ICON_SRC" ]]; then
  echo "error: missing $ICON_SRC" >&2
  exit 1
fi

mkdir -p "$ICONSET"

echo "→ Compiling Icon Composer source with actool"
actool "$ICON_SRC" "$ASSETS" \
  --compile "$STAGING" \
  --app-icon AppIcon \
  --enable-on-demand-resources NO \
  --development-region en \
  --target-device mac \
  --platform macosx \
  --minimum-deployment-target 26.5 \
  --output-partial-info-plist "$STAGING/partial.plist" >/dev/null

ICNS="$STAGING/AppIcon.icns"
if [[ ! -f "$ICNS" ]]; then
  echo "error: actool did not produce AppIcon.icns" >&2
  exit 1
fi

TMP_ICONSET="$STAGING/export.iconset"
iconutil --convert iconset "$ICNS" -o "$TMP_ICONSET"

MASTER="$TMP_ICONSET/icon_128x128@2x.png"
if [[ ! -f "$MASTER" ]]; then
  echo "error: expected 256px master icon in exported iconset" >&2
  exit 1
fi

cp "$TMP_ICONSET/icon_16x16.png" "$ICONSET/icon_16x16.png"
cp "$TMP_ICONSET/icon_16x16@2x.png" "$ICONSET/icon_16x16@2x.png"
cp "$TMP_ICONSET/icon_128x128.png" "$ICONSET/icon_128x128.png"
cp "$MASTER" "$ICONSET/icon_128x128@2x.png"
sips -z 32 32 "$MASTER" --out "$ICONSET/icon_32x32.png" >/dev/null
sips -z 64 64 "$MASTER" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 512 512 "$MASTER" --out "$ICONSET/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$MASTER" --out "$ICONSET/icon_512x512@2x.png" >/dev/null

echo "→ Updated $ICONSET"
ls -1 "$ICONSET"/*.png
