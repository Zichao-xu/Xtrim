//go:build !mihomo_embed

package mihomo

// 没带内核的构建（如本地 go test、拉不到内核源码时）：状态里 bundled=false。
func embedded() []byte        { return nil }
func embeddedVersion() string { return "" }
