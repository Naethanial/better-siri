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

# Copy Info.plist
cp Sources/Resources/Info.plist ../BetterSiri.app/Contents/Info.plist

# Copy binary
cp .build/release/BetterSiri ../BetterSiri.app/Contents/MacOS/BetterSiri
chmod +x ../BetterSiri.app/Contents/MacOS/BetterSiri

# Copy SwiftPM resource bundles (BetterSiri + dependencies)
cp -R .build/release/*.bundle ../BetterSiri.app/Contents/Resources/ 2>/dev/null || true

# Some SwiftPM-generated bundle accessors look for resource bundles as direct
# children of the app bundle (Bundle.main.bundleURL/<Name>.bundle).
# Copy them there as well for compatibility.
cp -R .build/release/*.bundle ../BetterSiri.app/ 2>/dev/null || true

echo "Build complete!"
echo ""
echo "App bundle is at: $(dirname "$0")/BetterSiri.app"
echo ""
echo "To run: open $(dirname "$0")/BetterSiri.app"
echo "Or double-click BetterSiri.app in Finder"
