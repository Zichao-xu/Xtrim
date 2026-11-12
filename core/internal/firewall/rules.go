package firewall

import (
	_ "embed"
	"fmt"
	"net"
	"net/netip"
	"sort"
	"strings"
)

// 国内 IP 段取自 OpenClash 的 china_ip_route / china_ip6_route。
//
//go:embed data/cn4.txt
var cn4Data string

//go:embed data/cn6.txt
var cn6Data string

// localCIDRs 永远放行：本机、局域网、CGNAT/Tailscale、链路本地、组播、广播。
var localCIDRs = []string{
	"127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
	"169.254.0.0/16", "100.64.0.0/10", "224.0.0.0/4", "255.255.255.255/32",
	"::1/128", "fe80::/10", "fc00::/7", "ff00::/8",
}

// fakeIPCIDR 是 Clash/OpenClash 的 fake-ip 段：发往这里的连接由网关代理，
// 不是真实出境地址。国内模式不放行，否则在家仍可经代理出境。
const fakeIPCIDR = "198.18.0.0/15"

// RuleInput 是渲染 pf 规则的输入。
type RuleInput struct {
	Interfaces  []string // 为空表示所有接口(国内模式)
	AllowFakeIP bool
	Endpoints   []string // WG 服务器 IP
	CNFile      string   // 国内 IP 段表文件(几千条，不适合内联)
	// AllowProbes 放行诊断探测：出站 ICMP 回显请求（traceroute -I / ping），其余协议照拦。
	AllowProbes bool
}

// RenderPF 生成加载进 WgSense 锚点的完整规则文本。
func RenderPF(in RuleInput) string {
	on := ""
	if len(in.Interfaces) > 0 {
		ifaces := append([]string(nil), in.Interfaces...)
		sort.Strings(ifaces)
		on = " on { " + strings.Join(ifaces, " ") + " }"
	}
	allow := append([]string(nil), localCIDRs...)
	if in.AllowFakeIP {
		allow = append(allow, fakeIPCIDR)
	}
	allow = append(allow, endpointAddrs(in.Endpoints)...)
	var b strings.Builder
	b.WriteString("# WgSense 出站拦截，自动生成，请勿手改\n")
	fmt.Fprintf(&b, "table <wgsense_allow> const { %s }\n", strings.Join(allow, ", "))
	// no state：生效瞬间不打断已建立的国内长连接，也不占状态表。
	fmt.Fprintf(&b, "pass out quick%s to <wgsense_allow> no state\n", on)
	fmt.Fprintf(&b, "table <wgsense_cn> const persist file %q\n", in.CNFile)
	fmt.Fprintf(&b, "pass out quick%s to <wgsense_cn> no state\n", on)
	if in.AllowProbes {
		// 只放回显请求本身；路由器回的超时 / 回显应答是入站，不经这个锚点。keep state 让应答与之关联。
		fmt.Fprintf(&b, "pass out quick%s inet proto icmp icmp-type echoreq keep state\n", on)
		fmt.Fprintf(&b, "pass out quick%s inet6 proto icmp6 icmp6-type echoreq keep state\n", on)
	}
	// block return：立即拒绝，程序马上回退(比如 IPv6 退回 IPv4)，不会卡到超时。
	// label 用于读取被拒绝的包数，展示给用户。
	fmt.Fprintf(&b, "block return out quick%s all label %q\n", on, blockLabel)
	return b.String()
}

// blockLabel 标记拒绝规则，BlockedPackets 据此统计。
const blockLabel = "wgsense-block"

// CNTable 返回国内 IP 段表文件内容，一行一段。
func CNTable() string {
	return strings.Join(cnCIDRs(), "\n") + "\n"
}

func cnCIDRs() []string {
	var out []string
	for _, data := range []string{cn4Data, cn6Data} {
		for _, line := range strings.Split(data, "\n") {
			if line = strings.TrimSpace(line); line != "" {
				if _, err := netip.ParsePrefix(line); err == nil {
					out = append(out, line)
				}
			}
		}
	}
	return out
}

func endpointAddrs(in []string) []string {
	seen := map[string]bool{}
	var out []string
	for _, ep := range in {
		addr, err := netip.ParseAddr(ep)
		if err != nil || seen[addr.String()] {
			continue
		}
		seen[addr.String()] = true
		out = append(out, addr.String())
	}
	sort.Strings(out)
	return out
}

// tunnelPrefixes 是隧道/虚拟出口，流量最终会从物理网卡出去时再被拦。
var tunnelPrefixes = []string{"lo", "utun", "ipsec", "ppp", "gif", "stf", "tun", "tap"}

func physicalInterfaces() []string {
	ifaces, err := net.Interfaces()
	if err != nil {
		return nil
	}
	var out []string
	for _, iface := range ifaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		if isTunnelInterface(iface.Name) {
			continue
		}
		out = append(out, iface.Name)
	}
	sort.Strings(out)
	return out
}

// activeInterfaces 是有非链路本地地址的物理网卡，只用于界面展示。
func activeInterfaces() []string {
	var out []string
	for _, name := range physicalInterfaces() {
		iface, err := net.InterfaceByName(name)
		if err != nil {
			continue
		}
		addrs, _ := iface.Addrs()
		for _, addr := range addrs {
			if ipnet, ok := addr.(*net.IPNet); ok && !ipnet.IP.IsLinkLocalUnicast() && !ipnet.IP.IsLoopback() {
				out = append(out, name)
				break
			}
		}
	}
	return out
}

func isTunnelInterface(name string) bool {
	for _, prefix := range tunnelPrefixes {
		if strings.HasPrefix(name, prefix) {
			return true
		}
	}
	return false
}
