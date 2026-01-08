#!/bin/bash

# Build script for Better Siri

set -e

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Building Better Siri..."

cd "$SCRIPT_DIR/BetterSiri"

# Build release version
swift build -c release

# Create app bundle structure
APP_BUNDLE="$SCRIPT_DIR/BetterSiri.app"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy binary
cp .build/release/BetterSiri "$APP_BUNDLE/Contents/MacOS/BetterSiri"
chmod +x "$APP_BUNDLE/Contents/MacOS/BetterSiri"

# Copy Info.plist
cp "$SCRIPT_DIR/BetterSiri/Sources/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

echo ""
echo "Build complete!"
echo ""
echo "App bundle created at: $APP_BUNDLE"
echo ""
echo "To run:"
echo "  open \"$APP_BUNDLE\""
echo "  Or double-click BetterSiri.app in Finder"
