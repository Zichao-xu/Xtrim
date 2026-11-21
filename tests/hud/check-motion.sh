#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/wgsense-hud-motion.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT

# Pure time functions only. Does not build or launch the app or its services.
/usr/bin/xcrun swiftc -swift-version 5 -parse-as-library \
  "$repo_root/platforms/macos/WgSense/Views/WgTokens.swift" "$repo_root/platforms/macos/WgSense/WgLocalization.swift" \
  "$repo_root/platforms/macos/WgSense/Views/WgHUDMotion.swift" \
  "$repo_root/tests/hud/MotionRegression.swift" \
  -o "$test_dir/check-motion"
"$test_dir/check-motion"
