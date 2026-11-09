#!/bin/bash
# Builds build/Kestrel.ipa with Xcode's iOS SDK (ad-hoc signed; sideload tools re-sign it).
# Use Xcode 27.1 or later: built with the iOS 27.1 SDK, Kestrel fills iPhone Duo's displays.
set -euo pipefail
cd "$(dirname "$0")"

APP=Kestrel
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
MIN_IOS=16.0
OUT=build
BUNDLE="$OUT/Payload/$APP.app"
SOURCES=(Sources/Core/*.swift Sources/Twitch/*.swift Sources/Player/*.swift Sources/App/*.swift)

xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1 || { echo "Xcode with the iOS SDK is needed (macOS)" >&2; exit 1; }
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
SWIFTC=(xcrun --sdk iphoneos swiftc)
EXTRA=()
sign() { codesign --force --sign - --timestamp=none "$1"; }

rm -rf "$OUT"
mkdir -p "$BUNDLE"

# Extra compiler flags, e.g. SWIFT_FLAGS="-D KESTREL_NO_CAPTIONS" to leave out a feature.
read -r -a FLAGS <<< "${SWIFT_FLAGS:-}"
[[ ${#FLAGS[@]} -gt 0 ]] && echo "==> Extra flags: ${FLAGS[*]}"

echo "==> Compiling with $(basename "$SDK")"
"${SWIFTC[@]}" -swift-version 5 -target "arm64-apple-ios$MIN_IOS" -sdk "$SDK" ${EXTRA[@]+"${EXTRA[@]}"} ${FLAGS[@]+"${FLAGS[@]}"} \
  -O -whole-module-optimization -module-name "$APP" \
  -Xlinker -rpath -Xlinker /usr/lib/swift -Xlinker -rpath -Xlinker @executable_path/Frameworks \
  -Xlinker -dead_strip \
  "${SOURCES[@]}" -o "$BUNDLE/$APP"
# Debug and local symbols aren't needed to run (a smaller download and install).
xcrun strip -Sx "$BUNDLE/$APP"

echo "==> Bundling"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" Resources/Info.plist > "$BUNDLE/Info.plist"
cp Resources/AppIcon60x60@2x.png Resources/AppIcon60x60@3x.png "$BUNDLE/"
cp "Resources/AppIcon76x76@2x~ipad.png" "Resources/AppIcon83.5x83.5@2x~ipad.png" "$BUNDLE/"
printf 'APPL????' > "$BUNDLE/PkgInfo"

echo "==> Signing (ad-hoc)"
sign "$BUNDLE/$APP"

echo "==> Packaging"
(cd "$OUT" && zip -qry -9 "$APP.ipa" Payload)
echo "Built $OUT/$APP.ipa ($(du -h "$OUT/$APP.ipa" | cut -f1))"
