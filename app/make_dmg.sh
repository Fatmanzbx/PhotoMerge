#!/bin/bash
# Build a release: a universal PhotoMerge.app for macOS 14+, then a .dmg to download.
#
#   ./make_dmg.sh 1.0.0        -> dist/PhotoMerge-1.0.0.dmg
#
# The app is signed ad hoc (no Developer ID), so the first launch is right-click →
# Open; docs/GUIDE.md explains this to people who download it.
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${1:-1.0.0}"
export VERSION ARCHS=universal
./build.sh

STAGE="$(mktemp -d)"
cp -R build/PhotoMerge.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp ../docs/GUIDE.md "$STAGE/Install and use.md"
mkdir -p dist
DMG="dist/PhotoMerge-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "PhotoMerge $VERSION" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGE"
lipo -archs build/PhotoMerge.app/Contents/MacOS/PhotoMerge
echo "release: $DMG ($(du -h "$DMG" | cut -f1))"
