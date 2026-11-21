#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/wgsense-hud-check.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT

# Compiles only the read-only model and test driver. Never builds or launches WgSense.
/usr/bin/xcrun swiftc -swift-version 5 -parse-as-library \
  "$repo_root/platforms/macos/WgSense/Views/WgTokens.swift" "$repo_root/platforms/macos/WgSense/WgLocalization.swift" \
  "$repo_root/platforms/macos/WgSense/Views/WgLinkMonitor.swift" \
  "$repo_root/tests/hud/MonitorRegression.swift" \
  -o "$test_dir/check-monitor"
"$test_dir/check-monitor"
