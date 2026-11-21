#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:?Usage: check.sh /absolute/output/directory}"
TEMP="$(mktemp -d "${TMPDIR:-/tmp}/wgsense-colors.XXXXXX")"
trap 'rm -rf "$TEMP"' EXIT
xcrun swiftc -parse-as-library \
  "$ROOT/platforms/macos/WgSense/Views/WgTokens.swift" "$ROOT/platforms/macos/WgSense/WgLocalization.swift" \
  "$ROOT/platforms/macos/WgSense/Views/WgRegionColor.swift" \
  "$ROOT/platforms/macos/WgSense/Views/WgInk.swift" \
  "$ROOT/tests/appearance/RegionColorRegression.swift" -o "$TEMP/check"
"$TEMP/check" "$OUT"
