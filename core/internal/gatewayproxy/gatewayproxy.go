// Package gatewayproxy 判断当前网络的网关是否在做透明代理（Clash/mihomo 的 fake-ip 网关）。
//
// 纯良把它当作一种出口：WireGuard 不在时（比如在家守护按设计断开隧道），只要网关代理
// 确实在线，境外流量本来就会被网关接走，本机不必再拦。判断全靠运行时探测，不看 SSID、
// 不看「是否在家」：
//   - 系统默认路由走物理网卡且有网关（走 utun 说明本机另有代理接管，不算网关代理）；
//   - 直接问网关（再退到 DHCP 下发的 DNS）解析一个境外域名，答案落在 fake-ip 段，
//     说明网关上的代理内核活着并在接管 DNS；
//   - 出口网卡没有公网 IPv6：网关代理不一定管 v6，有 v6 就不算，避免本机休眠后 v6 裸连。
//
// 网关代理挂了时网关自己的纯良会兜底；本机这里探测失败就立即回到接管。
package gatewayproxy

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"os/exec"
	"strings"
	"sync"
	"time"

	"github.com/wgsense/core/internal/netstate"
)

// FakeIPCIDR 是 Clash/mihomo 的 fake-ip 段：发往这里的连接由网关代理。
const FakeIPCIDR = "198.18.0.0/15"

var fakeIPPrefix = netip.MustParsePrefix(FakeIPCIDR)

// probeDomain 用来探测的境外域名。只看答案是否落在 fake-ip 段，不真的连它。
const probeDomain = "www.google.com"

// queryTimeout 单个 DNS 服务器的探测超时。心跳每 3 秒一次，整轮探测必须远小于它。
const queryTimeout = 800 * time.Millisecond

// failuresToDrop 已在线时连续失败几次才判掉线：单次丢包不让纯良来回翻转。
// 掉线到接管最多多出一个心跳（3 秒），这段时间网关自己的纯良仍在。
const failuresToDrop = 2

// Result 是一次探测的结论。
type Result struct {
	Online bool
	Detail string
}

// Prober 带迟滞地探测网关代理。并发安全。
type Prober struct {
	// 依赖，测试可替换。
	DefaultRoute func() (iface, gateway string)
	DHCPServers  func(iface string) []string
	HasPublicV6  func(iface string) bool
	Resolve      func(ctx context.Context, server, host string) ([]netip.Addr, error)

	mu       sync.Mutex
	online   bool
	failures int
	last     Result
}

// New 返回使用真实系统探测的 Prober。
func New() *Prober {
	return &Prober{
		DefaultRoute: netstate.DefaultRoute,
		DHCPServers:  dhcpServers,
		HasPublicV6:  hasPublicV6,
		Resolve:      resolveVia,
	}
}

// Probe 探测一次并返回（带迟滞的）结论。
func (p *Prober) Probe() Result {
	r := p.probeOnce()
	p.mu.Lock()
	defer p.mu.Unlock()
	switch {
	case r.Online:
		p.online, p.failures, p.last = true, 0, r
	case p.online && p.failures+1 < failuresToDrop:
		p.failures++
		return Result{Online: true, Detail: p.last.Detail + "（本次探测失败，再观察一次）"}
	default:
		p.online, p.failures, p.last = false, 0, r
	}
	return r
}

// Reset 清掉迟滞状态。主出口在线、不需要网关代理时调用：
// 否则隔了很久换了网络，旧的「在线」会让第一次失败仍被当成在线。
func (p *Prober) Reset() {
	p.mu.Lock()
	p.online, p.failures, p.last = false, 0, Result{}
	p.mu.Unlock()
}

func (p *Prober) probeOnce() Result {
	iface, gateway := p.DefaultRoute()
	switch {
	case iface == "" || gateway == "":
		return Result{Detail: "没有默认网关"}
	case !isPhysical(iface):
		return Result{Detail: fmt.Sprintf("默认路由走 %s，不是物理网卡", iface)}
	}
	gw, err := netip.ParseAddr(gateway)
	if err != nil || !gw.IsPrivate() {
		return Result{Detail: fmt.Sprintf("网关 %s 不是局域网地址", gateway)}
	}
	if p.HasPublicV6(iface) {
		return Result{Detail: fmt.Sprintf("%s 有公网 IPv6，网关代理不一定覆盖", iface)}
	}

	servers := []string{gateway}
	for _, s := range p.DHCPServers(iface) {
		if s != gateway {
			servers = append(servers, s)
		}
	}
	var lastErr error
	for _, server := range servers {
		ctx, cancel := context.WithTimeout(context.Background(), queryTimeout)
		addrs, err := p.Resolve(ctx, server, probeDomain)
		cancel()
		if err != nil {
			lastErr = err
			continue
		}
		for _, a := range addrs {
			if fakeIPPrefix.Contains(a.Unmap()) {
				return Result{Online: true, Detail: fmt.Sprintf("网关 %s 代理在线（DNS %s 答 fake-ip）", gateway, server)}
			}
		}
		lastErr = fmt.Errorf("DNS %s 答真实地址", server)
	}
	if lastErr == nil {
		lastErr = errors.New("没有可问的 DNS")
	}
	return Result{Detail: fmt.Sprintf("网关 %s 不是代理（%v）", gateway, lastErr)}
}

// isPhysical 排除 utun/ipsec/bridge 等虚拟接口：默认路由走它们说明本机有别的隧道或代理接管。
func isPhysical(iface string) bool {
	return strings.HasPrefix(iface, "en")
}

func resolveVia(ctx context.Context, server, host string) ([]netip.Addr, error) {
	r := &net.Resolver{
		PreferGo: true,
		Dial: func(ctx context.Context, network, _ string) (net.Conn, error) {
			var d net.Dialer
			return d.DialContext(ctx, "udp", net.JoinHostPort(server, "53"))
		},
	}
	return r.LookupNetIP(ctx, "ip4", host)
}

// dhcpServers 读出口网卡 DHCP 下发的 DNS（只做补充：多数网关自己就答 DNS）。
func dhcpServers(iface string) []string {
	out, err := exec.Command("/usr/sbin/ipconfig", "getoption", iface, "domain_name_server").Output()
	if err != nil {
		return nil
	}
	var servers []string
	for _, f := range strings.Fields(string(out)) {
		if a, err := netip.ParseAddr(f); err == nil && a.Is4() {
			servers = append(servers, a.String())
		}
	}
	return servers
}

// hasPublicV6 出口网卡上有没有全局单播、非 ULA 的 IPv6 地址。
func hasPublicV6(iface string) bool {
	ifi, err := net.InterfaceByName(iface)
	if err != nil {
		return false
	}
	addrs, err := ifi.Addrs()
	if err != nil {
		return false
	}
	for _, a := range addrs {
		ipnet, ok := a.(*net.IPNet)
		if !ok {
			continue
		}
		ip, ok := netip.AddrFromSlice(ipnet.IP)
		if !ok || ip.Is4() || ip.Is4In6() {
			continue
		}
		if ip.IsGlobalUnicast() && !ip.IsPrivate() {
			return true
		}
	}
	return false
}
