#!/bin/bash
# 测速台 HUD 离线逐帧渲染。不启动 WgSense、不连守护进程、不弹窗口。
# 用法：tests/speedlab/render.sh /absolute/output/directory [帧号...]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:?Usage: render.sh /absolute/output/directory [frames...]}"
shift
TEMP="$(mktemp -d "${TMPDIR:-/tmp}/wgsense-speedlab-render.XXXXXX")"
trap 'rm -rf "$TEMP"' EXIT
SL="$ROOT/platforms/macos/WgSense/SpeedLab"
xcrun swiftc -parse-as-library \
  "$ROOT/platforms/macos/WgSense/Views/WgTokens.swift" "$ROOT/platforms/macos/WgSense/WgLocalization.swift" \
  "$ROOT/platforms/macos/WgSense/Views/WgRegionColor.swift" \
  "$SL/SpeedLabModels.swift" "$SL/SpeedLabFormat.swift" "$SL/SpeedLabHUD.swift" \
  "$ROOT/tests/speedlab/render.swift" -o "$TEMP/render"
"$TEMP/render" "$OUT" "$@"
