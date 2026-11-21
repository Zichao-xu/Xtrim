#!/bin/bash
# Build only. Launch this isolated app through the UI; never launches WgSense.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:?Usage: build-performance-lab.sh /absolute/output/directory}"
case "$OUT" in /*) ;; *) printf 'Output must be absolute\n' >&2; exit 2 ;; esac
mkdir -p "$OUT"
TEMP="$(mktemp -d "${TMPDIR:-/tmp}/wgsense-hud-performance.XXXXXX")"
trap 'rm -rf "$TEMP"' EXIT
APP="$OUT/WgHUDLab.app"
mkdir -p "$APP/Contents/MacOS"
python3 - "$ROOT" "$TEMP/Format.swift" "$APP/Contents/Info.plist" <<'PY'
import plistlib
import sys
from pathlib import Path
source = (Path(sys.argv[1]) / 'platforms/macos/WgSense/Views/WgDesign.swift').read_text()
start = source.index('enum WgFormat {')
end = source.index('\n}\n', start) + 3
Path(sys.argv[2]).write_text('import Foundation\n' + source[start:end])
Path(sys.argv[3]).write_bytes(plistlib.dumps({
    'CFBundleExecutable': 'WgHUDLab',
    'CFBundleIdentifier': 'local.wgsense.synthetic.hudlab',
    'CFBundleName': 'WgHUDLab',
    'CFBundlePackageType': 'APPL',
    'CFBundleShortVersionString': '2.0',
    'NSHighResolutionCapable': True,
    'LSMinimumSystemVersion': '14.0',
}))
PY
SOURCES=("$ROOT/platforms/macos/WgSense/Views/WgTokens.swift" "$ROOT/platforms/macos/WgSense/WgLocalization.swift" "$ROOT/platforms/macos/WgSense/Views/WgInk.swift" "$ROOT/platforms/macos/WgSense/Views/WgRegionColor.swift" "$ROOT/platforms/macos/WgSense/Views/WgLinkMonitor.swift")
for EXTRA in WgHUDMotion WgLinkMotion WgHUDClock WgHUDDisplayClock; do
  if [[ -f "$ROOT/platforms/macos/WgSense/Views/$EXTRA.swift" ]]; then
    SOURCES+=("$ROOT/platforms/macos/WgSense/Views/$EXTRA.swift")
  fi
done
xcrun swiftc -O -parse-as-library "${SOURCES[@]}" \
  "$ROOT/platforms/macos/WgSense/Views/WgLinkStage.swift" \
  "$TEMP/Format.swift" "$ROOT/tests/hud/PerformanceLab.swift" \
  -o "$TEMP/WgHUDLab"
cp "$TEMP/WgHUDLab" "$APP/Contents/MacOS/WgHUDLab"
codesign --force --sign - "$APP"
printf '%s\n' "$APP"
