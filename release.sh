#!/bin/zsh
# Build the app and wrap it in a signed disk image for a release. Nothing is installed.
# The image is signed with the same certificate as the app; without a Developer ID it is not notarized, and the
# README tells people what macOS will say about that.
set -euo pipefail
cd "$(dirname "$0")"
LIVERY_TIMESTAMP=1 ./build-app.sh
VERSION=$(grep -o 'string = "[^"]*"' Sources/LiveryCore/Commands.swift | head -1 | cut -d'"' -f2)
SIGNER=$(cat build/signer)
APP="build/Livery.app"
DMG="build/Livery-$VERSION.dmg"
STAGE="build/dmg"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Livery $VERSION" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGE"
if [ "$SIGNER" != "-" ]; then
  codesign --force --timestamp --sign "$SIGNER" "$DMG"
  codesign --verify "$DMG"
fi
shasum -a 256 "$DMG"
echo "wrote $DMG ($(du -h "$DMG" | cut -f1))"
