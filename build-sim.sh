#!/bin/bash
# Builds build-sim/Kestrel.app for the iOS Simulator (for the screenshot job, screens.yml).
set -euo pipefail
cd "$(dirname "$0")"
APP=Kestrel
OUT=build-sim
BUNDLE="$OUT/$APP.app"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
rm -rf "$OUT"
mkdir -p "$BUNDLE"
echo "==> Compiling for the simulator with $(basename "$SDK")"
xcrun --sdk iphonesimulator swiftc -swift-version 5 -target "arm64-apple-ios16.0-simulator" -sdk "$SDK" \
  -O -whole-module-optimization -module-name "$APP" \
  -Xlinker -rpath -Xlinker /usr/lib/swift -Xlinker -rpath -Xlinker @executable_path/Frameworks \
  Sources/Core/*.swift Sources/Twitch/*.swift Sources/Player/*.swift Sources/App/*.swift -o "$BUNDLE/$APP"
sed -e "s/__VERSION__/1.0.0/" -e "s/__BUILD__/1/" Resources/Info.plist > "$BUNDLE/Info.plist"
cp Resources/AppIcon60x60@2x.png Resources/AppIcon60x60@3x.png "$BUNDLE/"
printf 'APPL????' > "$BUNDLE/PkgInfo"
codesign --force --sign - --timestamp=none "$BUNDLE"
echo "Built $BUNDLE"
