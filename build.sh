#!/bin/zsh
# Builds Stash.app into ./build. Run with --install to copy it to /Applications and open it.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Stash.app
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/AppIcon.iconset

swiftc -O -swift-version 5 -target arm64-apple-macos13 Sources/*.swift -o "$APP/Contents/MacOS/Stash"

swift make-icon.swift build/icon.png
for size in 16 32 128 256 512; do
  sips -z $size $size build/icon.png --out build/AppIcon.iconset/icon_${size}x${size}.png >/dev/null
  sips -z $((size * 2)) $((size * 2)) build/icon.png --out build/AppIcon.iconset/icon_${size}x${size}@2x.png >/dev/null
done
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Stash</string>
  <key>CFBundleDisplayName</key><string>Stash</string>
  <key>CFBundleIdentifier</key><string>local.stash.app</string>
  <key>CFBundleExecutable</key><string>Stash</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>2.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDocumentTypes</key>
  <array><dict>
    <key>CFBundleTypeName</key><string>Anything</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSHandlerRank</key><string>Alternate</string>
    <key>LSItemContentTypes</key><array><string>public.item</string><string>public.folder</string></array>
  </dict></array>
  <key>NSLocalNetworkUsageDescription</key><string>Stash uses your Wi-Fi so your phone can download and send files to your shelf.</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  osascript -e 'quit app "Stash"' 2>/dev/null || true
  rm -rf /Applications/Stash.app
  cp -R "$APP" /Applications/
  open /Applications/Stash.app
  echo "Installed to /Applications/Stash.app"
fi
