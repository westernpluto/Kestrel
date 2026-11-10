#!/bin/bash
# Builds Kestrel for Apple Watch (KestrelWatch.app) with Xcode's watchOS SDK, ad-hoc signed. It
# shares Sources/Core and Sources/Twitch with the iPhone app and has its own interface in
# Sources/Watch. build.sh puts it inside the iPhone app (Kestrel.app/Watch), which is how the
# Watch app on the iPhone installs it; it runs on its own once installed. Needs macOS with Xcode.
#   ./build-watch.sh [folder to put KestrelWatch.app in]   (default: build-watch)
set -euo pipefail
cd "$(dirname "$0")"

APP=KestrelWatch
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
MIN_WATCHOS=10.0
DEST="${1:-build-watch}"
BUNDLE="$DEST/$APP.app"
WORK="$(mktemp -d)"
SOURCES=(Sources/Core/*.swift Sources/Twitch/*.swift Sources/Watch/*.swift)

xcrun --sdk watchos --show-sdk-path >/dev/null 2>&1 || { echo "Xcode with the watchOS SDK is needed (macOS)" >&2; exit 1; }
SDK="$(xcrun --sdk watchos --show-sdk-path)"

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE"

# Both kinds of watch: arm64_32 (Series 4 to 8, SE, Ultra) and arm64 (Series 9 and later, Ultra 2).
echo "==> Compiling for watchOS with $(basename "$SDK")"
for arch in arm64_32 arm64; do
  xcrun --sdk watchos swiftc -swift-version 5 -target "$arch-apple-watchos$MIN_WATCHOS" -sdk "$SDK" \
    -O -whole-module-optimization -module-name "$APP" -parse-as-library \
    -Xlinker -rpath -Xlinker /usr/lib/swift -Xlinker -dead_strip \
    "${SOURCES[@]}" -o "$WORK/$APP-$arch"
done
xcrun lipo -create "$WORK/$APP-arm64_32" "$WORK/$APP-arm64" -output "$BUNDLE/$APP"
xcrun strip -Sx "$BUNDLE/$APP"

echo "==> Bundling"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" Resources/Watch-Info.plist > "$BUNDLE/Info.plist"
printf 'APPL????' > "$BUNDLE/PkgInfo"

# The icon, from the iPhone's (watchOS takes it from a compiled asset catalog). Without it the app
# still works, with a blank icon.
make_icon() {
  local set="$WORK/Assets.xcassets/AppIcon.appiconset"
  mkdir -p "$set"
  sips -s format png -z 1024 1024 Resources/AppIcon-1024.png --out "$set/icon.png" >/dev/null || return 1
  echo '{"images":[{"filename":"icon.png","idiom":"universal","platform":"watchos","size":"1024x1024"}],"info":{"author":"xcode","version":1}}' > "$set/Contents.json"
  echo '{"info":{"author":"xcode","version":1}}' > "$WORK/Assets.xcassets/Contents.json"
  xcrun actool "$WORK/Assets.xcassets" --compile "$BUNDLE" --platform watchos --minimum-deployment-target "$MIN_WATCHOS" \
    --target-device watch --app-icon AppIcon --output-partial-info-plist "$WORK/icon.plist" >/dev/null || return 1
  /usr/libexec/PlistBuddy -c "Merge $WORK/icon.plist" "$BUNDLE/Info.plist" >/dev/null || return 1
}
if make_icon; then echo "==> Icon"; else echo "::warning::Couldn't make the Apple Watch icon; built without one."; fi

echo "==> Signing (ad-hoc)"
codesign --force --sign - --timestamp=none "$BUNDLE"
rm -rf "$WORK"
echo "Built $BUNDLE ($(du -sh "$BUNDLE" | cut -f1))"
