#!/bin/bash

# Build script for Better Siri

set -e

echo "Building Better Siri..."

cd "$(dirname "$0")/BetterSiri"

# Build release version
swift build -c release

# Create app bundle structure
mkdir -p ../BetterSiri.app/Contents/MacOS
mkdir -p ../BetterSiri.app/Contents/Resources

# Copy binary
cp .build/release/BetterSiri ../BetterSiri.app/Contents/MacOS/BetterSiri
chmod +x ../BetterSiri.app/Contents/MacOS/BetterSiri

echo "Build complete!"
echo ""
echo "App bundle is at: $(dirname "$0")/BetterSiri.app"
echo ""
echo "To run: open $(dirname "$0")/BetterSiri.app"
echo "Or double-click BetterSiri.app in Finder"
