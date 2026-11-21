#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:?Usage: build.sh /absolute/output/directory}"
case "$OUT" in /*) ;; *) exit 2 ;; esac
APP="$OUT/WgLayoutLab.app"
mkdir -p "$APP/Contents/MacOS"
python3 - "$APP/Contents/Info.plist" <<'PY'
import os, plistlib, sys
with open(sys.argv[1], 'wb') as f:
    plistlib.dump(dict(CFBundleExecutable='WgLayoutLab', CFBundleIdentifier='local.wgsense.layoutlab',
                      CFBundleName='WgLayoutLab', CFBundlePackageType='APPL',
                      NSHighResolutionCapable=True, LSMinimumSystemVersion='15.0',
                      LayoutLabAutostart=os.environ.get('LAYOUT_LAB_AUTOSTART') == '1'), f)
PY
xcrun swiftc -O -parse-as-library \
  "$ROOT/platforms/macos/WgSense/Views/WgTokens.swift" "$ROOT/platforms/macos/WgSense/WgLocalization.swift" \
  "$ROOT/platforms/macos/WgSense/Views/WgInk.swift" \
  "$ROOT/platforms/macos/WgSense/Views/WgRegionColor.swift" \
  "$ROOT/platforms/macos/WgSense/Views/RetainedGrid.swift" "$ROOT/tests/layout/VisibleNativePage.swift" "$ROOT/tests/layout/LayoutLab.swift" \
  -o "$APP/Contents/MacOS/WgLayoutLab"
codesign --force --sign - "$APP"
printf '%s\n' "$APP"
