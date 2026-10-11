#!/bin/sh
# Builds release artifacts (zip for Homebrew, dmg for manual install) and updates
# the cask's version + sha256.
# Usage: VERSION=1.0 ./package.sh
set -e
cd "$(dirname "$0")"

VERSION="${VERSION:-1.0}"
export VERSION
./build.sh

mkdir -p dist
ZIP="dist/Amplify-$VERSION.zip"
DMG="dist/Amplify-$VERSION.dmg"
rm -f "$ZIP" "$DMG"

# Zip (used by the Homebrew cask).
ditto -c -k --keepParent Amplify.app "$ZIP"

# DMG with a drag-to-Applications layout.
STAGE="$(mktemp -d)/Amplify"
mkdir -p "$STAGE"
cp -R Amplify.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp Amplify.app/Contents/Resources/AppIcon.icns "$STAGE/.VolumeIcon.icns"
if command -v SetFile >/dev/null; then SetFile -a C "$STAGE"; fi
hdiutil create -quiet -volname "Amplify" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"

SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')
sed -i '' -e "s/^  version \".*\"/  version \"$VERSION\"/" -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" Casks/amplify.rb

echo "Packaged $ZIP"
echo "Packaged $DMG"
echo "zip sha256 $SHA"
