#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"

APP_NAME="BetterSiri.app"
VOL_NAME="Better Siri"

DIST_DIR="$ROOT_DIR/dist"
STAGING_DIR="$DIST_DIR/dmg-staging"
DMG_PATH="$DIST_DIR/BetterSiri-arm64.dmg"

cd "$ROOT_DIR"

./build.sh

rm -rf "$STAGING_DIR" "$DMG_PATH"
mkdir -p "$STAGING_DIR"

# Copy app bundle into staging
ditto "$ROOT_DIR/$APP_NAME" "$STAGING_DIR/$APP_NAME"

# Standard drag-to-install shortcut
ln -s /Applications "$STAGING_DIR/Applications"

cat > "$STAGING_DIR/INSTALL.txt" <<'EOF'
Install

1) Drag BetterSiri.app to Applications
2) First launch: Finder -> Applications -> right-click BetterSiri -> Open -> Open
   (Needed because the app is not notarized)

Browser feature

This app can call a local Python "browser-use" worker.
Install Python + browser-use and then set Settings -> Browser Use -> Browser agent Python
to your venv python path.
EOF

hdiutil create \
  -volname "$VOL_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

echo "Created: $DMG_PATH"
