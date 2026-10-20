#!/bin/zsh
# Builds Dropovr and packages it as dist/Dropovr-<version>.dmg (drag-to-Applications installer).
set -euo pipefail
cd "$(dirname "$0")"

./build.sh
VERSION=$(defaults read "$PWD/build/Dropovr.app/Contents/Info.plist" CFBundleShortVersionString)
STAGE=build/dmg
rm -rf "$STAGE" dist
mkdir -p "$STAGE" dist
cp -R build/Dropovr.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Dropovr" -srcfolder "$STAGE" -ov -format UDZO "dist/Dropovr-$VERSION.dmg" >/dev/null
echo "Made dist/Dropovr-$VERSION.dmg"
