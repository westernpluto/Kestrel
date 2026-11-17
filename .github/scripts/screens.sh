#!/bin/bash
# Screenshots of Kestrel's main screens on an iPhone Duo simulator (else the newest iPhone).
set -uo pipefail
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' build-sim/Kestrel.app/Info.plist)"
mkdir -p shots
echo "==> Device types"; xcrun simctl list devicetypes | grep -i -E "duo|iphone" | tail -15
echo "==> Runtimes"; xcrun simctl list runtimes
echo "==> simctl io help"; xcrun simctl io 2>&1 | head -40
echo "==> simctl commands mentioning displays or posture"; xcrun simctl help 2>&1 | grep -i -E "fold|posture|display|hinge" || true
TYPE="$(xcrun simctl list devicetypes -j | python3 -c '
import json,sys
types=json.load(sys.stdin)["devicetypes"]
duo=[t for t in types if "duo" in t["name"].lower()]
phones=[t for t in types if t["name"].startswith("iPhone")]
pick=(duo or phones)[-1]
print(pick["identifier"])')"
RUNTIME="$(xcrun simctl list runtimes -j | python3 -c '
import json,sys
rs=[r for r in json.load(sys.stdin)["runtimes"] if r["platform"]=="iOS" and r.get("isAvailable")]
rs.sort(key=lambda r:[int(x) for x in r["version"].split(".")])
print(rs[-1]["identifier"])')"
echo "==> Using $TYPE on $RUNTIME"
UDID="$(xcrun simctl create shots "$TYPE" "$RUNTIME")"
xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b
xcrun simctl status_bar "$UDID" override --time 9:41 --batteryLevel 100 --cellularBars 4 --wifiBars 3 || true
xcrun simctl install "$UDID" build-sim/Kestrel.app
SCREENS="${SCREENS:-following browse search settings channel player emotes mini player-landscape}"
for screen in $SCREENS; do
  echo "==> $screen"
  xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE_ID" -KestrelShow "$screen" >/dev/null
  case "$screen" in player*|mini|emotes) sleep 22 ;; *) sleep 9 ;; esac
  xcrun simctl io "$UDID" screenshot --type=png "shots/$screen.png" || echo "screenshot failed"
  for display in external internal; do
    xcrun simctl io "$UDID" screenshot --type=png --display="$display" "shots/$screen-$display.png" >/dev/null 2>&1 || true
  done
done
xcrun simctl spawn "$UDID" log show --last 5m --predicate "process == \"Kestrel\"" --style compact 2>/dev/null | tail -80 > shots/log.txt || true
ls -la shots
