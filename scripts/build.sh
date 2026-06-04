#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP_NAME="OpenCall Mac"
APP="build/${APP_NAME}.app"
mkdir -p build logs
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swift scripts/make_macos_icon.swift "$APP/Contents/Resources"
iconutil -c icns "$APP/Contents/Resources/OpenCall.iconset" -o "$APP/Contents/Resources/OpenCall.icns"
rm -rf "$APP/Contents/Resources/OpenCall.iconset"

swiftc Sources/hfpctl/main.swift \
  -o "$APP/Contents/MacOS/hfpctl" \
  -framework IOBluetooth
codesign --force --sign - "$APP/Contents/MacOS/hfpctl" >/dev/null

swiftc Sources/btmeta/main.swift \
  -o "$APP/Contents/MacOS/btmeta" \
  -framework IOBluetooth -framework CoreBluetooth
codesign --force --sign - "$APP/Contents/MacOS/btmeta" >/dev/null

swiftc -parse-as-library Sources/OpenCallMac/main.swift \
  -o "$APP/Contents/MacOS/OpenCallMac" \
  -framework SwiftUI -framework AppKit -framework IOBluetooth -framework UserNotifications

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>OpenCallMac</string>
  <key>CFBundleIdentifier</key><string>local.opencall.mac</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleIconFile</key><string>OpenCall</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.4</string>
  <key>CFBundleVersion</key><string>4</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSBluetoothAlwaysUsageDescription</key><string>Use Bluetooth to control calls and discover the local OpenCall Android companion on your paired phone.</string>
  <key>NSBluetoothPeripheralUsageDescription</key><string>Use Bluetooth to control calls and discover the local OpenCall Android companion on your paired phone.</string>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsArbitraryLoads</key><true/>
    <key>NSAllowsLocalNetworking</key><true/>
  </dict>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null
codesign --verify --deep --strict "$APP"
echo "$PWD/$APP"
