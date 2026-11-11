#!/bin/bash
# 内置代理内核：自建 mihomo（Zichao-xu/mihomo，throughput 版，与 op 同一提交）。
#
# 二进制不进 git：按固定提交编译，缓存在 vendor/mihomo/<提交>/，再放进 core/internal/mihomo/bin/
# 供 daemon 以 mihomo_embed 标签嵌入。源码取法（按顺序）：
#   1. MIHOMO_SRC 指向的本地仓库（默认 ~/code/mihomo），含该提交就用 git archive 导出；
#   2. 否则从 MIHOMO_REPO 浅克隆该提交。
# 拿不到源码或编译失败只告警不失败：daemon 照常构建，只是不带内核（状态里 bundled=false）。
#
# 用法：build-mihomo.sh <core 目录>；成功时输出一行 "mihomo_embed"，供调用方加构建标签。
set -uo pipefail
COMMIT="${MIHOMO_COMMIT:-aa0b5220}"
VERSION="alpha-smart-tp-$COMMIT"
REPO="${MIHOMO_REPO:-https://github.com/Zichao-xu/mihomo.git}"
SRC="${MIHOMO_SRC:-$HOME/code/mihomo}"
CORE="${1:?core 目录}"
HERE="$(cd "$(dirname "$0")" && pwd)"
CACHE="$HERE/mihomo/$COMMIT"
BIN="$CACHE/mihomo-darwin-arm64"
OUT="$CORE/internal/mihomo/bin"

warn() { echo "warning: $*" >&2; }

if [ ! -x "$BIN" ]; then
	work="$(mktemp -d)"
	trap 'rm -rf "$work"' EXIT
	if git -C "$SRC" cat-file -e "$COMMIT^{commit}" 2>/dev/null; then
		git -C "$SRC" archive "$COMMIT" | tar -x -C "$work" || { warn "导出内核源码失败"; exit 0; }
	else
		git -C "$work" init -q && git -C "$work" remote add origin "$REPO" &&
			git -C "$work" fetch -q --depth 1 origin "$COMMIT" && git -C "$work" checkout -q FETCH_HEAD ||
			{ warn "拉取内核源码失败（$REPO@$COMMIT），这次构建不带内置代理内核"; exit 0; }
	fi
	mkdir -p "$CACHE"
	( cd "$work" && GOPROXY="${GOPROXY:-https://goproxy.cn,direct}" CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 \
		go build -tags with_gvisor -trimpath \
		-ldflags "-X 'github.com/metacubex/mihomo/constant.Version=$VERSION' -X 'github.com/metacubex/mihomo/constant.BuildTime=$(date -u)' -w -s -buildid=" \
		-o "$BIN.part" . ) >&2 && mv "$BIN.part" "$BIN" || { rm -f "$BIN.part"; warn "内核编译失败，这次构建不带内置代理内核"; exit 0; }
fi

mkdir -p "$OUT"
install -m 0755 "$BIN" "$OUT/mihomo-darwin-arm64"
echo "$VERSION" > "$OUT/VERSION"
echo mihomo_embed
