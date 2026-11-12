#!/bin/zsh
set -euo pipefail
if [[ $# -ne 2 ]]; then
    print -u2 "Usage: $0 <built Xtrim.app> <output-directory>"
    exit 2
fi
repo_root="${0:A:h:h:h}"
build_tmp="$(mktemp -d "${TMPDIR:-/tmp}/wgsense-brand-check.XXXXXX")"
trap 'rm -rf "$build_tmp"' EXIT
xcrun swiftc -parse-as-library -O \
    "$repo_root/platforms/macos/WgSense/Views/WgBrandIcon.swift" \
    "$repo_root/tests/branding/render.swift" \
    -o "$build_tmp/brand-appearance-check"
"$build_tmp/brand-appearance-check" "$1" "$2"
