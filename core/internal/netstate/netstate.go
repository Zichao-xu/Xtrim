// Package netstate builds a lightweight fingerprint of the current network.
package netstate

import (
	"net"
	"strings"
	"syscall"

	"golang.org/x/net/route"

	"github.com/wgsense/core/internal/location"
)

// Fingerprint returns a stable summary of effective physical network addresses
// and the default route. It is best-effort; missing pieces are simply omitted.
func Fingerprint() string {
	var parts []string
	if network := location.NetworkFingerprint(); network != "" {
		parts = append(parts, "physical="+network)
	}
	if iface, gw := DefaultRoute(); iface != "" || gw != "" {
		parts = append(parts, "route="+iface+"@"+gw)
	}
	return strings.Join(parts, "|")
}

// DefaultRoute 读内核路由表（sysctl，不 fork route 命令），取未绑定网卡的 IPv4 默认路由：
// 出口网卡名与网关地址。网络变化检测和纯良心跳会频繁调用，必须足够便宜。
func DefaultRoute() (iface, gateway string) {
	rib, err := route.FetchRIB(syscall.AF_INET, route.RIBType(syscall.NET_RT_FLAGS), syscall.RTF_GATEWAY)
	if err != nil {
		return "", ""
	}
	msgs, err := route.ParseRIB(route.RIBTypeRoute, rib)
	if err != nil {
		return "", ""
	}
	for _, msg := range msgs {
		rm, ok := msg.(*route.RouteMessage)
		if !ok || rm.Flags&rtfIfScope != 0 || len(rm.Addrs) <= syscall.RTAX_NETMASK {
			continue
		}
		dst, ok := rm.Addrs[syscall.RTAX_DST].(*route.Inet4Addr)
		if !ok || dst.IP != [4]byte{} {
			continue
		}
		if mask, ok := rm.Addrs[syscall.RTAX_NETMASK].(*route.Inet4Addr); ok && mask.IP != [4]byte{} {
			continue
		}
		gateway, iface = "", ""
		if gw, ok := rm.Addrs[syscall.RTAX_GATEWAY].(*route.Inet4Addr); ok {
			gateway = net.IP(gw.IP[:]).String()
		}
		if ifi, err := net.InterfaceByIndex(rm.Index); err == nil {
			iface = ifi.Name
		}
		if gateway == "" && iface == "" {
			continue
		}
		return iface, gateway
	}
	return "", ""
}

// rtfIfScope 是 macOS 的 RTF_IFSCOPE：每张网卡各自的作用域默认路由，不是系统主默认路由。
const rtfIfScope = 0x1000000
