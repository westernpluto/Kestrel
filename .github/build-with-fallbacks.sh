#!/bin/bash
# Builds the IPA; if the newest features don't compile with this Xcode, leaves them out (one at a
# time) instead of failing, and says so on the run.
set -uo pipefail
cd "$(dirname "$0")/.."
for flags in "" "-D KESTREL_NO_CAPTIONS" "-D KESTREL_NO_CAPTIONS -D KESTREL_NO_TRANSLATION"; do
  if SWIFT_FLAGS="$flags" ./build.sh; then
    if [[ -n "$flags" ]]; then
      echo "::warning::Built without some features ($flags): the full build failed with this Xcode (see the errors above)."
    fi
    exit 0
  fi
  echo "::group::Build failed${flags:+ with $flags}; trying without the next feature"
  echo "::endgroup::"
done
exit 1
