#!/bin/bash

# Build script for Cluely

set -e

echo "Building Cluely..."

cd "$(dirname "$0")/Cluely"

# Build release version
swift build -c release

# Create app bundle structure
mkdir -p ../Cluely.app/Contents/MacOS
mkdir -p ../Cluely.app/Contents/Resources

# Copy binary
cp .build/release/Cluely ../Cluely.app/Contents/MacOS/Cluely
chmod +x ../Cluely.app/Contents/MacOS/Cluely

echo "Build complete!"
echo ""
echo "App bundle is at: $(dirname "$0")/Cluely.app"
echo ""
echo "To run: open $(dirname "$0")/Cluely.app"
echo "Or double-click Cluely.app in Finder"
