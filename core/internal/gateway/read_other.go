//go:build !darwin

package gateway

import "github.com/wgsense/core/internal/location"

// Read 只在 macOS 上实现；其他平台读不到网关，一律按未受信任处理。
func Read([]location.Interface) (Current, bool) { return Current{}, false }
