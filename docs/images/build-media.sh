#!/bin/bash
# Public product media: production SwiftUI views, synthetic fixtures, no live data.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="${1:?Usage: build-media.sh /absolute/path/Xtrim.app /absolute/scratch-directory}"
SCRATCH="${2:?Provide an absolute scratch directory outside docs/images}"
OUT="$ROOT/docs/images"
case "$APP:$SCRATCH" in /*:/*) ;; *) echo "Both paths must be absolute" >&2; exit 2 ;; esac
command -v ffmpeg >/dev/null
mkdir -p "$SCRATCH"

# This renderer compiles the real HUD view with synthetic telemetry. It does not
# compile DaemonClient, launch the app, read profiles, or contact network services.
bash "$ROOT/tests/hud/render.sh" "$SCRATCH/hud" --reel
cp "$SCRATCH/hud/linked-dark-776.png" "$OUT/hud-dark.png"
cp "$SCRATCH/hud/linked-light-776.png" "$OUT/hud-light.png"
ffmpeg -hide_banner -loglevel error -y -framerate 120 \
  -i "$SCRATCH/hud/reel/%04d.png" -c:v libx264 -crf 20 -pix_fmt yuv420p \
  -movflags +faststart "$OUT/hud-motion.mp4"
ffmpeg -hide_banner -loglevel error -y -framerate 120 \
  -i "$SCRATCH/hud/reel/%04d.png" \
  -filter_complex '[0:v]fps=20,scale=960:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=256:stats_mode=full[p];[b][p]paletteuse=dither=none:diff_mode=rectangle' \
  -loop 0 "$OUT/hud-motion.gif"

xcrun swiftc -parse-as-library -O \
  "$ROOT/platforms/macos/WgSense/Views/WgBrandIcon.swift" \
  "$OUT/render-brand.swift" -o "$SCRATCH/render-brand"
"$SCRATCH/render-brand" "$APP" "$OUT/brand-appearance.png"
python3 "$OUT/check-media.py" --record-sources
