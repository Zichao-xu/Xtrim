#!/bin/zsh
set -euo pipefail

app_path="${1:?usage: create-dmg.sh /path/to/Xtrim.app [/path/to/Xtrim.dmg]}"
output_path="${2:-$PWD/Xtrim.dmg}"

if [[ ! -d "$app_path" ]]; then
  echo "App bundle not found: $app_path" >&2
  exit 1
fi

staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/wgsense-dmg.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT

/usr/bin/ditto "$app_path" "$staging_dir/Xtrim.app"
/bin/ln -s /Applications "$staging_dir/Applications"
/bin/rm -f "$output_path"

if command -v create-dmg >/dev/null 2>&1; then
  if create-dmg \
    --volname "Xtrim" \
    --window-pos 200 120 \
    --window-size 600 400 \
    --icon-size 112 \
    --icon "Xtrim.app" 155 190 \
    --hide-extension "Xtrim.app" \
    --app-drop-link 445 190 \
    --no-internet-enable \
    "$output_path" \
    "$staging_dir"; then
    exit 0
  fi
  /bin/rm -f "$output_path"
fi

/usr/bin/hdiutil create \
  -volname "Xtrim" \
  -srcfolder "$staging_dir" \
  -ov \
  -format UDZO \
  "$output_path"
