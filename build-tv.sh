#!/bin/bash
# Builds build-tv/Kestrel-tv.ipa, Kestrel for Apple TV, with Xcode's tvOS SDK (ad-hoc signed;
# sideload tools re-sign it). It shares Sources/Core and Sources/Twitch with the iPhone app and has
# its own interface in Sources/TV. Needs macOS with Xcode 27.1 or later.
set -euo pipefail
cd "$(dirname "$0")"

APP=Kestrel
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
MIN_TVOS=17.0
OUT=build-tv
BUNDLE="$OUT/Payload/$APP.app"
SOURCES=(Sources/Core/*.swift Sources/Twitch/*.swift Sources/TV/*.swift)

xcrun --sdk appletvos --show-sdk-path >/dev/null 2>&1 || { echo "Xcode with the tvOS SDK is needed (macOS)" >&2; exit 1; }
SDK="$(xcrun --sdk appletvos --show-sdk-path)"

rm -rf "$OUT"
mkdir -p "$BUNDLE"

echo "==> Compiling with $(basename "$SDK")"
xcrun --sdk appletvos swiftc -swift-version 5 -target "arm64-apple-tvos$MIN_TVOS" -sdk "$SDK" \
  -O -whole-module-optimization -module-name "$APP" -parse-as-library \
  -Xlinker -rpath -Xlinker /usr/lib/swift -Xlinker -rpath -Xlinker @executable_path/Frameworks \
  -Xlinker -dead_strip \
  "${SOURCES[@]}" -o "$BUNDLE/$APP"
xcrun strip -Sx "$BUNDLE/$APP"

echo "==> Bundling"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" Resources/TV-Info.plist > "$BUNDLE/Info.plist"
printf 'APPL????' > "$BUNDLE/PkgInfo"

# The Home screen icon and Top Shelf image: tvOS takes them from a compiled asset catalog, as a
# layered image (it tilts with the remote). Made here from the iPhone icon on Kestrel's dark
# background. If anything about it fails, the app is still built, with a plain icon.
make_icons() {
  local work="$OUT/icons"
  local cat="$work/Assets.xcassets"
  local brand="$cat/App Icon & Top Shelf Image.brandassets"
  mkdir -p "$brand"
  local bg=0E1116
  # A picture of the icon centred on the background, at width x height.
  picture() {  # $1 out, $2 width, $3 height
    local side=$(( $3 * 7 / 10 ))
    sips -s format png -z "$side" "$side" Resources/AppIcon-1024.png --out "$1" >/dev/null
    sips -p "$3" "$2" --padColor "$bg" "$1" --out "$1" >/dev/null
  }
  # A solid background layer.
  backdrop() {  # $1 out, $2 width, $3 height
    sips -s format png -z 2 2 Resources/AppIcon-1024.png --out "$1" >/dev/null
    sips -p "$3" "$2" --padColor "$bg" "$1" --out "$1" >/dev/null
  }
  imagestack() {  # $1 name, $2 width, $3 height, $4 scales ("1x 2x" or "1x")
    local stack="$brand/$1.imagestack"
    for layer in Front Back; do
      local set="$stack/$layer.imagestacklayer/Content.imageset"
      mkdir -p "$set"
      local entries=""
      for scale in $4; do
        local f=${scale%x}
        local file="$layer-$scale.png"
        if [[ $layer == Front ]]; then picture "$set/$file" $(( $2 * f )) $(( $3 * f )); else backdrop "$set/$file" $(( $2 * f )) $(( $3 * f )); fi
        entries="$entries${entries:+,}{\"idiom\":\"tv\",\"filename\":\"$file\",\"scale\":\"$scale\"}"
      done
      echo "{\"images\":[$entries],\"info\":{\"author\":\"xcode\",\"version\":1}}" > "$set/Contents.json"
      echo '{"info":{"author":"xcode","version":1}}' > "$stack/$layer.imagestacklayer/Contents.json"
    done
    echo '{"info":{"author":"xcode","version":1},"layers":[{"filename":"Front.imagestacklayer"},{"filename":"Back.imagestacklayer"}]}' > "$stack/Contents.json"
  }
  imageset() {  # $1 name, $2 width, $3 height
    local set="$brand/$1.imageset"
    mkdir -p "$set"
    picture "$set/1x.png" "$2" "$3"
    picture "$set/2x.png" $(( $2 * 2 )) $(( $3 * 2 ))
    echo '{"images":[{"idiom":"tv","filename":"1x.png","scale":"1x"},{"idiom":"tv","filename":"2x.png","scale":"2x"}],"info":{"author":"xcode","version":1}}' > "$set/Contents.json"
  }
  imagestack "App Icon" 400 240 "1x 2x" || return 1
  imagestack "App Icon - App Store" 1280 768 "1x" || return 1
  imageset "Top Shelf Image" 1920 720 || return 1
  imageset "Top Shelf Image Wide" 2320 720 || return 1
  cat > "$brand/Contents.json" <<'JSON'
{
  "assets" : [
    { "filename" : "App Icon - App Store.imagestack", "idiom" : "tv", "role" : "primary-app-icon", "size" : "1280x768" },
    { "filename" : "App Icon.imagestack", "idiom" : "tv", "role" : "primary-app-icon", "size" : "400x240" },
    { "filename" : "Top Shelf Image Wide.imageset", "idiom" : "tv", "role" : "top-shelf-image-wide", "size" : "2320x720" },
    { "filename" : "Top Shelf Image.imageset", "idiom" : "tv", "role" : "top-shelf-image", "size" : "1920x720" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON
  echo '{"info":{"author":"xcode","version":1}}' > "$cat/Contents.json"
  xcrun actool "$cat" --compile "$BUNDLE" --platform appletvos --minimum-deployment-target "$MIN_TVOS" \
    --target-device tv --app-icon "App Icon & Top Shelf Image" \
    --output-partial-info-plist "$work/icons.plist" >/dev/null || return 1
  # The icon's names go in the app's Info.plist.
  /usr/libexec/PlistBuddy -c "Merge $work/icons.plist" "$BUNDLE/Info.plist" >/dev/null || return 1
}
if make_icons; then
  echo "==> Icons: layered Home screen icon and Top Shelf image"
else
  echo "::warning::Couldn't make the Apple TV icons; built with a plain icon."
fi
rm -rf "$OUT/icons"

echo "==> Signing (ad-hoc)"
codesign --force --sign - --timestamp=none "$BUNDLE/$APP"

echo "==> Packaging"
(cd "$OUT" && zip -qry -9 "$APP-tv.ipa" Payload)
echo "Built $OUT/$APP-tv.ipa ($(du -h "$OUT/$APP-tv.ipa" | cut -f1))"
