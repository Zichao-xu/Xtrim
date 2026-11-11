//go:build mihomo_embed

package mihomo

import (
	_ "embed"
	"strings"
)

// 构建脚本（platforms/macos/vendor/build-mihomo.sh）把内核放到 bin/ 下，再以 mihomo_embed 标签编译 daemon。
//
//go:embed bin/mihomo-darwin-arm64
var kernel []byte

//go:embed bin/VERSION
var kernelVersion string

func embedded() []byte        { return kernel }
func embeddedVersion() string { return strings.TrimSpace(kernelVersion) }
