#!/bin/bash
# Builds and runs the core tests on Linux or macOS (needs a host Swift toolchain).
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${TMPDIR:-/tmp}/kestrel-tests"
mkdir -p "$OUT"
cp Tests/CoreTests.swift "$OUT/main.swift"
swiftc -swift-version 5 -O Sources/Core/*.swift Sources/Twitch/*.swift "$OUT/main.swift" -o "$OUT/core-tests"
"$OUT/core-tests" Tests/Fixtures/usher_v2_master.m3u8
