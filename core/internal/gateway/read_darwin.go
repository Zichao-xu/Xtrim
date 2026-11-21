package gateway

import (
	"context"
	"fmt"
	"net"
	"sync"
	"syscall"
	"time"

	"golang.org/x/net/route"

	"github.com/wgsense/core/internal/location"
)

// rtfIfScope 是 macOS 的 RTF_IFSCOPE：每张网卡各自的作用域默认路由。
const rtfIfScope = 0x1000000

// ipBoundIf 是 macOS 的 IP_BOUND_IF：把套接字绑到指定网卡发包。
const ipBoundIf = 25

// pokeInterval 同一网关两次「催 ARP」之间的最短间隔：ARP 缓存里一时没有时才催，
// 状态接口每秒都可能来问，不能每次都发包、每次都等。
const pokeInterval = 5 * time.Second

var pokeState struct {
	sync.Mutex
	last map[string]time.Time
}

// Read 读当前物理网卡的默认网关及其 MAC。只走 sysctl 读内核路由表与 ARP 表，不 fork 命令。
//
// 选哪张网卡：系统主默认路由走物理网卡就用它；主默认路由在 utun（WireGuard 连着）时，
// 按位置模块给出的物理网卡优先级（有线 > 无线 > 其他）取第一张带作用域默认路由的网卡。
// ARP 缓存里暂时没有网关时，往网关发一个 UDP 包催系统学一次地址再读。
func Read(ifaces []location.Interface) (Current, bool) {
	defaults := defaultGateways()
	if len(defaults) == 0 {
		return Current{}, false
	}
	physical := map[string]location.Interface{}
	for _, iface := range ifaces {
		physical[iface.Name] = iface
	}
	var chosen *defaultRoute
	for i := range defaults {
		if !defaults[i].scoped {
			if _, ok := physical[defaults[i].iface]; ok {
				chosen = &defaults[i]
			}
			break
		}
	}
	if chosen == nil {
		for _, iface := range ifaces {
			for i := range defaults {
				if defaults[i].iface == iface.Name {
					chosen = &defaults[i]
					break
				}
			}
			if chosen != nil {
				break
			}
		}
	}
	if chosen == nil {
		return Current{}, false
	}
	cur := Current{Interface: chosen.iface, IP: chosen.gateway.String()}
	if meta, ok := physical[chosen.iface]; ok {
		cur.HardwarePort = meta.HardwarePort
	}
	mac := arpLookup(chosen.gateway, chosen.index)
	if mac == "" && shouldPoke(chosen.iface+"@"+cur.IP) {
		poke(chosen.gateway, chosen.index)
		for i := 0; i < 4 && mac == ""; i++ {
			time.Sleep(50 * time.Millisecond)
			mac = arpLookup(chosen.gateway, chosen.index)
		}
	}
	cur.MAC = mac
	return cur, true
}

type defaultRoute struct {
	iface   string
	index   int
	gateway net.IP
	scoped  bool
}

// defaultGateways 返回所有 IPv4 默认路由（主路由排在前面）。
func defaultGateways() []defaultRoute {
	rib, err := route.FetchRIB(syscall.AF_INET, route.RIBType(syscall.NET_RT_FLAGS), syscall.RTF_GATEWAY)
	if err != nil {
		return nil
	}
	msgs, err := route.ParseRIB(route.RIBTypeRoute, rib)
	if err != nil {
		return nil
	}
	var primary, scoped []defaultRoute
	for _, msg := range msgs {
		rm, ok := msg.(*route.RouteMessage)
		if !ok || len(rm.Addrs) <= syscall.RTAX_NETMASK {
			continue
		}
		dst, ok := rm.Addrs[syscall.RTAX_DST].(*route.Inet4Addr)
		if !ok || dst.IP != [4]byte{} {
			continue
		}
		if mask, ok := rm.Addrs[syscall.RTAX_NETMASK].(*route.Inet4Addr); ok && mask.IP != [4]byte{} {
			continue
		}
		gw, ok := rm.Addrs[syscall.RTAX_GATEWAY].(*route.Inet4Addr)
		if !ok {
			continue
		}
		ifi, err := net.InterfaceByIndex(rm.Index)
		if err != nil {
			continue
		}
		r := defaultRoute{iface: ifi.Name, index: rm.Index, gateway: net.IP(append([]byte(nil), gw.IP[:]...)), scoped: rm.Flags&rtfIfScope != 0}
		if r.scoped {
			scoped = append(scoped, r)
		} else {
			primary = append(primary, r)
		}
	}
	return append(primary, scoped...)
}

// arpLookup 在 ARP 表里找指定网卡上该 IP 的 MAC；找不到返回空串。
func arpLookup(ip net.IP, index int) string {
	rib, err := route.FetchRIB(syscall.AF_INET, route.RIBType(syscall.NET_RT_FLAGS), syscall.RTF_LLINFO)
	if err != nil {
		return ""
	}
	msgs, err := route.ParseRIB(route.RIBTypeRoute, rib)
	if err != nil {
		return ""
	}
	want := ip.To4()
	for _, msg := range msgs {
		rm, ok := msg.(*route.RouteMessage)
		if !ok || rm.Index != index || len(rm.Addrs) <= syscall.RTAX_GATEWAY {
			continue
		}
		dst, ok := rm.Addrs[syscall.RTAX_DST].(*route.Inet4Addr)
		if !ok || !net.IP(dst.IP[:]).Equal(want) {
			continue
		}
		link, ok := rm.Addrs[syscall.RTAX_GATEWAY].(*route.LinkAddr)
		if !ok {
			continue
		}
		if mac := formatMAC(link.Addr); mac != "" {
			return mac
		}
	}
	return ""
}

func formatMAC(b []byte) string {
	if len(b) != 6 {
		return ""
	}
	zero := true
	for _, v := range b {
		if v != 0 {
			zero = false
		}
	}
	if zero {
		return ""
	}
	return fmt.Sprintf("%02x:%02x:%02x:%02x:%02x:%02x", b[0], b[1], b[2], b[3], b[4], b[5])
}

func shouldPoke(key string) bool {
	pokeState.Lock()
	defer pokeState.Unlock()
	if pokeState.last == nil {
		pokeState.last = map[string]time.Time{}
	}
	if t, ok := pokeState.last[key]; ok && time.Since(t) < pokeInterval {
		return false
	}
	pokeState.last[key] = time.Now()
	return true
}

// poke 从指定网卡向网关的 discard 端口（9）发一个空 UDP 包，让系统去解析网关的 MAC。
// 绑网卡发：WireGuard 连着时主路由在 utun，不绑就不会在物理网卡上发 ARP。
func poke(ip net.IP, index int) {
	d := net.Dialer{
		Timeout: 200 * time.Millisecond,
		Control: func(_, _ string, c syscall.RawConn) error {
			var serr error
			if err := c.Control(func(fd uintptr) {
				serr = syscall.SetsockoptInt(int(fd), syscall.IPPROTO_IP, ipBoundIf, index)
			}); err != nil {
				return err
			}
			return serr
		},
	}
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	conn, err := d.DialContext(ctx, "udp4", net.JoinHostPort(ip.String(), "9"))
	if err != nil {
		return
	}
	_, _ = conn.Write([]byte{0})
	_ = conn.Close()
}
