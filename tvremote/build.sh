#!/bin/sh
# Builds "TV Remote.app" with swiftc only (no Xcode project).
set -eu
cd "$(dirname "$0")"

APP="build/TV Remote.app"
rm -rf build && mkdir -p "$APP/Contents/MacOS"

swiftc -O -parse-as-library -swift-version 5 \
  -target arm64-apple-macos13.0 \
  -o "$APP/Contents/MacOS/TVRemote" TVRemote.swift

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>TV Remote</string>
  <key>CFBundleDisplayName</key><string>TV Remote</string>
  <key>CFBundleIdentifier</key><string>local.tvremote</string>
  <key>CFBundleExecutable</key><string>TVRemote</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built: $PWD/$APP"
