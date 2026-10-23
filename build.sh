#!/bin/bash
# Builds build/Kestrel.ipa (ad-hoc signed; sideload tools re-sign it).
#  - Linux: uses the Theos iOS toolchain + SDK ($THEOS, default ~/theos)
#  - macOS: uses Xcode's iOS SDK
set -euo pipefail
cd "$(dirname "$0")"

APP=Kestrel
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
MIN_IOS=16.0
OUT=build
BUNDLE="$OUT/Payload/$APP.app"
SOURCES=(Sources/Core/*.swift Sources/Twitch/*.swift Sources/App/*.swift)

rm -rf "$OUT"
mkdir -p "$BUNDLE"

if [[ "$(uname)" == "Darwin" ]] && xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
  SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
  SWIFTC=(xcrun --sdk iphoneos swiftc)
  EXTRA=()
  sign() { codesign --force --sign - --timestamp=none "$1"; }
else
  THEOS="${THEOS:-$HOME/theos}"
  TC="$THEOS/toolchain/linux/iphone/bin"
  [[ -x "$TC/swiftc" ]] || { echo "Theos iOS toolchain not found at $TC" >&2; exit 1; }
  SDK="${SDK:-$(ls -d "$THEOS"/sdks/iPhoneOS*.sdk | sort -V | tail -1)}"
  export PATH="$TC:$PATH"
  SWIFTC=("$TC/swiftc")
  EXTRA=(-resource-dir "$TC/../lib/swift" -tools-directory "$TC")
  # compiler-rt (for #available checks); Xcode's driver links this automatically
  RT="$(ls "$TC"/../lib/clang/*/lib/darwin/libclang_rt.ios.a 2>/dev/null | head -1)"
  [[ -n "$RT" ]] && EXTRA+=(-Xlinker "$RT")
  sign() { "$TC/ldid" -S "$1"; }
fi

# Optional: the Amazon IVS Player SDK enables the low-latency player (#if canImport(AmazonIVSPlayer)).
# Point IVS_XCFRAMEWORK at AmazonIVSPlayer.xcframework, or unpack it into vendor/.
IVS_XCFRAMEWORK="${IVS_XCFRAMEWORK:-vendor/AmazonIVSPlayer.xcframework}"
IVS_FRAMEWORK=""
if [[ -d "$IVS_XCFRAMEWORK" ]]; then
  for slice in "$IVS_XCFRAMEWORK"/ios-arm64*; do
    [[ "$slice" == *simulator* ]] && continue
    [[ -d "$slice/AmazonIVSPlayer.framework" ]] && IVS_FRAMEWORK="$slice/AmazonIVSPlayer.framework" && break
  done
  [[ -n "$IVS_FRAMEWORK" ]] || { echo "No iOS device slice in $IVS_XCFRAMEWORK" >&2; exit 1; }
  EXTRA+=(-F "$(dirname "$IVS_FRAMEWORK")" -framework AmazonIVSPlayer)
  echo "==> Low-latency player: linking $(basename "$IVS_FRAMEWORK") from $(dirname "$IVS_FRAMEWORK")"
else
  echo "==> Low-latency player: AmazonIVSPlayer.xcframework not found, building without it"
fi

# Extra compiler flags, e.g. SWIFT_FLAGS="-D KESTREL_NO_CAPTIONS" to leave out a feature.
read -r -a FLAGS <<< "${SWIFT_FLAGS:-}"
[[ ${#FLAGS[@]} -gt 0 ]] && echo "==> Extra flags: ${FLAGS[*]}"

echo "==> Compiling with $(basename "$SDK")"
"${SWIFTC[@]}" -swift-version 5 -target "arm64-apple-ios$MIN_IOS" -sdk "$SDK" ${EXTRA[@]+"${EXTRA[@]}"} ${FLAGS[@]+"${FLAGS[@]}"} \
  -O -whole-module-optimization -module-name "$APP" \
  -Xlinker -rpath -Xlinker /usr/lib/swift -Xlinker -rpath -Xlinker @executable_path/Frameworks \
  -Xlinker -dead_strip \
  "${SOURCES[@]}" -o "$BUNDLE/$APP"

echo "==> Bundling"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" Resources/Info.plist > "$BUNDLE/Info.plist"
cp Resources/AppIcon60x60@2x.png Resources/AppIcon60x60@3x.png "$BUNDLE/"
cp "Resources/AppIcon76x76@2x~ipad.png" "Resources/AppIcon83.5x83.5@2x~ipad.png" "$BUNDLE/"
printf 'APPL????' > "$BUNDLE/PkgInfo"
if [[ -n "$IVS_FRAMEWORK" ]]; then
  mkdir -p "$BUNDLE/Frameworks"
  cp -R "$IVS_FRAMEWORK" "$BUNDLE/Frameworks/"
  rm -rf "$BUNDLE/Frameworks/AmazonIVSPlayer.framework/Headers" "$BUNDLE/Frameworks/AmazonIVSPlayer.framework/Modules" \
    "$BUNDLE/Frameworks/AmazonIVSPlayer.framework/_CodeSignature"
fi

echo "==> Signing (ad-hoc)"
if [[ -n "$IVS_FRAMEWORK" ]]; then
  if [[ "$(uname)" == "Darwin" ]]; then sign "$BUNDLE/Frameworks/AmazonIVSPlayer.framework"
  else sign "$BUNDLE/Frameworks/AmazonIVSPlayer.framework/AmazonIVSPlayer"; fi
fi
sign "$BUNDLE/$APP"

echo "==> Packaging"
(cd "$OUT" && zip -qry "$APP.ipa" Payload)
echo "Built $OUT/$APP.ipa ($(du -h "$OUT/$APP.ipa" | cut -f1))"
