#!/bin/bash
# Offline SwiftUI rendering only. Never launches WgSense or contacts a daemon.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:?Usage: render.sh /absolute/output/directory}"
TEMP="$(mktemp -d "${TMPDIR:-/tmp}/wgsense-hud-render.XXXXXX")"
trap 'rm -rf "$TEMP"' EXIT
python3 - "$ROOT" "$TEMP/Format.swift" <<'PY'
import sys
from pathlib import Path
source = (Path(sys.argv[1]) / 'platforms/macos/WgSense/Views/WgDesign.swift').read_text()
start = source.index('enum WgFormat {')
end = source.index('\n}\n', start) + 3
Path(sys.argv[2]).write_text('import Foundation\n' + source[start:end])
PY
xcrun swiftc -parse-as-library \
  "$ROOT/platforms/macos/WgSense/Views/WgTokens.swift" "$ROOT/platforms/macos/WgSense/WgLocalization.swift" "$ROOT/platforms/macos/WgSense/Views/WgInk.swift" "$ROOT/platforms/macos/WgSense/Views/WgRegionColor.swift" \
  "$ROOT/platforms/macos/WgSense/Views/WgHUDMotion.swift" \
  "$ROOT/platforms/macos/WgSense/Views/WgHUDDisplayClock.swift" \
  "$ROOT/platforms/macos/WgSense/Views/WgLinkMonitor.swift" \
  "$ROOT/platforms/macos/WgSense/Views/WgLinkStage.swift" \
  "$TEMP/Format.swift" "$ROOT/tests/hud/render.swift" -o "$TEMP/render"
"$TEMP/render" "$@"
