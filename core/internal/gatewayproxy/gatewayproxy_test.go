package gatewayproxy

import (
	"context"
	"errors"
	"net/netip"
	"strings"
	"testing"
)

type fake struct {
	iface, gw string
	v6        bool
	answers   map[string][]string // server -> addrs；缺省=超时
}

func (f *fake) prober() *Prober {
	return &Prober{
		DefaultRoute: func() (string, string) { return f.iface, f.gw },
		DHCPServers:  func(string) []string { return []string{"10.0.0.53"} },
		HasPublicV6:  func(string) bool { return f.v6 },
		Resolve: func(_ context.Context, server, _ string) ([]netip.Addr, error) {
			raw, ok := f.answers[server]
			if !ok {
				return nil, errors.New("timeout")
			}
			var out []netip.Addr
			for _, s := range raw {
				out = append(out, netip.MustParseAddr(s))
			}
			return out, nil
		},
	}
}

func TestProbe(t *testing.T) {
	cases := []struct {
		name   string
		f      fake
		online bool
		want   string
	}{
		{"网关答 fake-ip", fake{iface: "en0", gw: "10.10.1.1", answers: map[string][]string{"10.10.1.1": {"198.18.0.23"}}}, true, "代理在线"},
		{"网关不答、DHCP DNS 答 fake-ip", fake{iface: "en0", gw: "10.10.1.1", answers: map[string][]string{"10.0.0.53": {"198.19.1.2"}}}, true, "10.0.0.53"},
		{"普通路由器答真实地址", fake{iface: "en0", gw: "192.168.1.1", answers: map[string][]string{"192.168.1.1": {"142.250.1.1"}, "10.0.0.53": {"142.250.1.1"}}}, false, "真实地址"},
		{"默认路由走 utun（本机代理/隧道）", fake{iface: "utun4", gw: "10.10.1.1", answers: map[string][]string{"10.10.1.1": {"198.18.0.23"}}}, false, "不是物理网卡"},
		{"有公网 IPv6", fake{iface: "en0", gw: "10.10.1.1", v6: true, answers: map[string][]string{"10.10.1.1": {"198.18.0.23"}}}, false, "IPv6"},
		{"网关是公网地址", fake{iface: "en0", gw: "8.8.8.8", answers: map[string][]string{"8.8.8.8": {"198.18.0.23"}}}, false, "不是局域网"},
		{"没网", fake{}, false, "没有默认网关"},
		{"全都超时", fake{iface: "en0", gw: "10.10.1.1"}, false, "timeout"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			r := c.f.prober().Probe()
			if r.Online != c.online || !strings.Contains(r.Detail, c.want) {
				t.Fatalf("got %+v, want online=%v detail~%q", r, c.online, c.want)
			}
		})
	}
}

// 已在线时单次失败不翻转，连续两次才掉线；从未在线时第一次失败就是不在线。
func TestHysteresis(t *testing.T) {
	f := &fake{iface: "en0", gw: "10.10.1.1", answers: map[string][]string{"10.10.1.1": {"198.18.0.23"}}}
	p := f.prober()
	if !p.Probe().Online {
		t.Fatal("首次应在线")
	}
	f.answers = nil
	if r := p.Probe(); !r.Online || !strings.Contains(r.Detail, "再观察") {
		t.Fatalf("第一次失败应维持在线: %+v", r)
	}
	if p.Probe().Online {
		t.Fatal("连续第二次失败应掉线")
	}
	if p.Probe().Online {
		t.Fatal("掉线后失败仍应不在线")
	}
	f.answers = map[string][]string{"10.10.1.1": {"198.18.0.23"}}
	if !p.Probe().Online {
		t.Fatal("恢复后一次成功即在线")
	}
}
