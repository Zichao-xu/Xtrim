package firewall

import (
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type fakeBackend struct {
	pf          string
	pfCalls     int
	hostsClears int
	blocked     uint64
	counts      int
}

func (f *fakeBackend) ApplyPF(rules string) error { f.pf = rules; f.pfCalls++; return nil }
func (f *fakeBackend) ClearPF() error             { f.pf = ""; f.pfCalls++; return nil }
func (f *fakeBackend) RemoveLegacyHosts() error   { f.hostsClears++; return nil }
func (f *fakeBackend) BlockedPackets() (uint64, error) {
	f.counts++
	return f.blocked, nil
}

func newTest(t *testing.T, s Settings) (*Controller, *fakeBackend) {
	t.Helper()
	b := &fakeBackend{}
	c := New(filepath.Join(t.TempDir(), "firewall.json"), b, nil)
	c.PhysicalInterfaces = func() []string { return []string{"en7", "en0"} }
	c.ActiveInterfaces = func() []string { return []string{"en0"} }
	c.TunnelEndpoints = func() []string { return []string{"1.2.3.4", "bad"} }
	if err := c.Update(s); err != nil {
		t.Fatal(err)
	}
	return c, b
}

func TestDisabledClearsEverything(t *testing.T) {
	c, b := newTest(t, Settings{})
	if b.pf != "" || c.Status().Active {
		t.Fatalf("disabled should not block: %q", b.pf)
	}
	if b.hostsClears != 1 {
		t.Fatal("first sync must remove the v1.0.4 hosts section")
	}
}

func TestBlockScopesPhysicalInterfaces(t *testing.T) {
	c, b := newTest(t, Settings{Block: true})
	st := c.Status()
	if !st.Active || st.Forced || strings.Join(st.Interfaces, ",") != "en0" {
		t.Fatalf("unexpected status: %+v", st)
	}
	for _, want := range []string{
		"198.18.0.0/15", "1.2.3.4", "fe80::/10",
		"pass out quick on { en0 en7 } to <wgsense_allow> no state",
		"pass out quick on { en0 en7 } to <wgsense_cn> no state",
		"block return out quick on { en0 en7 } all",
	} {
		if !strings.Contains(b.pf, want) {
			t.Fatalf("missing %q in:\n%s", want, b.pf)
		}
	}
}

func TestProbesAllowedOnlyInBlockMode(t *testing.T) {
	const echo = "pass out quick on { en0 en7 } inet proto icmp icmp-type echoreq keep state"
	_, b := newTest(t, Settings{Block: true})
	if !strings.Contains(b.pf, echo) || !strings.Contains(b.pf, "icmp6-type echoreq") {
		t.Fatalf("block mode should let traceroute probes out by default:\n%s", b.pf)
	}
	if strings.Index(b.pf, echo) > strings.Index(b.pf, "block return") {
		t.Fatal("probe pass must come before the block rule")
	}
	_, b = newTest(t, Settings{Block: true, BlockProbes: true})
	if strings.Contains(b.pf, "echoreq") {
		t.Fatal("BlockProbes must close the probe hole")
	}
	_, b = newTest(t, Settings{Block: true, ForceDomestic: true})
	if strings.Contains(b.pf, "echoreq") {
		t.Fatal("domestic mode never lets probes out")
	}
}

func TestForceDomesticCoversTunnelAndProxy(t *testing.T) {
	c, b := newTest(t, Settings{Block: true, ForceDomestic: true})
	if !c.Status().Forced {
		t.Fatal("expected forced")
	}
	if strings.Contains(b.pf, " on {") {
		t.Fatal("domestic mode must cover every interface including the tunnel")
	}
	if strings.Contains(b.pf, "198.18.0.0/15") {
		t.Fatal("domestic mode must not let fake-ip traffic reach the gateway proxy")
	}
	if !strings.Contains(b.pf, "block return out quick all") {
		t.Fatalf("missing global block:\n%s", b.pf)
	}
}

func TestSyncIsIdempotent(t *testing.T) {
	c, b := newTest(t, Settings{Block: true})
	calls := b.pfCalls
	for i := 0; i < 3; i++ {
		_ = c.Sync()
	}
	if b.pfCalls != calls || b.hostsClears != 1 {
		t.Fatal("unchanged state must not touch the system again")
	}
	c.PhysicalInterfaces = func() []string { return []string{"en0"} }
	_ = c.Sync()
	if b.pfCalls != calls+1 {
		t.Fatal("interface change must reload pf")
	}
}

func TestSettingsPersistAndKeepV104Switch(t *testing.T) {
	path := filepath.Join(t.TempDir(), "firewall.json")
	c := New(path, &fakeBackend{}, nil)
	if err := c.Update(Settings{Block: true}); err != nil {
		t.Fatal(err)
	}
	if got := New(path, &fakeBackend{}, nil).Settings(); !got.Block {
		t.Fatalf("setting lost: %+v", got)
	}
}

func TestStripLegacyHosts(t *testing.T) {
	base := "127.0.0.1 localhost\n::1 localhost\n"
	if stripLegacyHosts(base) != base {
		t.Fatal("hosts without our section must stay byte-identical")
	}
	legacy := base + hostsBegin + "\n0.0.0.0 claude.ai\n:: claude.ai\n" + hostsEnd + "\n"
	if got := stripLegacyHosts(legacy); got != base {
		t.Fatalf("legacy section not removed:\n%q", got)
	}
}

func TestCNTableParses(t *testing.T) {
	v6 := 0
	for _, cidr := range cnCIDRs() {
		if strings.Contains(cidr, ":") {
			v6++
		}
	}
	if n := len(cnCIDRs()); n < 5000 || v6 < 1000 {
		t.Fatalf("CN table looks truncated: total=%d v6=%d", n, v6)
	}
}

func TestDormantWhileExitOnline(t *testing.T) {
	c, b := newTest(t, Settings{Block: true})
	if b.pf == "" || !c.Status().Active {
		t.Fatal("without an exit purity must take over")
	}
	if err := c.SetExitHealth(ExitHealth{Exit: "wireguard", Online: true, Detail: "握手 5 秒前"}); err != nil {
		t.Fatal(err)
	}
	st := c.Status()
	if b.pf != "" || st.Active || !st.Dormant || !st.ExitOnline || st.Exit != "wireguard" {
		t.Fatalf("online exit must put purity to sleep: %+v %q", st, b.pf)
	}
	// 出口掉线：立即接管
	if err := c.SetExitHealth(ExitHealth{Exit: "mihomo", Online: false, Detail: "内核未运行"}); err != nil {
		t.Fatal(err)
	}
	if st := c.Status(); !st.Active || st.Dormant || !strings.Contains(b.pf, "block return") {
		t.Fatalf("offline exit must wake purity: %+v %q", st, b.pf)
	}
}

func TestDomesticModeIgnoresExitHealth(t *testing.T) {
	c, b := newTest(t, Settings{Block: true, ForceDomestic: true})
	_ = c.SetExitHealth(ExitHealth{Exit: "wireguard", Online: true})
	if st := c.Status(); !st.Active || st.Dormant || b.pf == "" {
		t.Fatalf("domestic mode must stay on even with an exit: %+v", st)
	}
}

func TestDisabledStaysOffWithoutExit(t *testing.T) {
	c, b := newTest(t, Settings{})
	_ = c.SetExitHealth(ExitHealth{Exit: "wireguard", Online: false})
	if st := c.Status(); st.Active || b.pf != "" {
		t.Fatalf("purity switched off must not block: %+v", st)
	}
}

func TestExitHealthUnchangedDoesNotTouchPF(t *testing.T) {
	c, b := newTest(t, Settings{Block: true})
	h := ExitHealth{Exit: "wireguard", Online: true}
	_ = c.SetExitHealth(h)
	calls := b.pfCalls
	_ = c.SetExitHealth(h)
	if b.pfCalls != calls {
		t.Fatal("unchanged health must not reload pf (heartbeat runs every 3 s)")
	}
}

func TestBlockedPacketsCountedWithoutReloadingRules(t *testing.T) {
	c, b := newTest(t, Settings{Block: true})
	b.blocked = 7
	calls := b.pfCalls
	c.countedAt = time.Time{} // 模拟已过 30 秒
	_ = c.Sync()
	if got := c.Status().BlockedPackets; got != 7 {
		t.Fatalf("blocked = %d", got)
	}
	if b.pfCalls != calls {
		t.Fatal("reading counters must not reload rules")
	}
	b.blocked = 9
	_ = c.Sync() // 30 秒内不重复启动 pfctl
	if got := c.Status().BlockedPackets; got != 7 || b.counts != 1 {
		t.Fatalf("counter should be throttled: blocked=%d counts=%d", got, b.counts)
	}
}

func TestParseLabelPackets(t *testing.T) {
	out := "wgsense-block 120 5 300 0 0 0 0\nother 1 9 9\nwgsense-block 10 2 100 0 0 0 0\n"
	if got := parseLabelPackets(out, blockLabel); got != 7 {
		t.Fatalf("got %d", got)
	}
}

func newHostTest(t *testing.T, s Settings, resolve func(string) []string) (*Controller, *fakeBackend) {
	t.Helper()
	b := &fakeBackend{}
	c := New(filepath.Join(t.TempDir(), "firewall.json"), b, nil)
	c.PhysicalInterfaces = func() []string { return []string{"en0"} }
	c.ActiveInterfaces = func() []string { return []string{"en0"} }
	c.ResolveHost = resolve
	if err := c.Update(s); err != nil {
		t.Fatal(err)
	}
	return c, b
}

func TestAllowHostsAddedToBlockRules(t *testing.T) {
	c, b := newHostTest(t, Settings{Block: true, AllowHosts: []string{" JP4.Example.com. ", "jp4.example.com", "9.9.9.9"}},
		func(host string) []string {
			if host == "jp4.example.com" {
				return []string{"126.1.2.3"}
			}
			return []string{host}
		})
	for _, want := range []string{"126.1.2.3", "9.9.9.9"} {
		if !strings.Contains(b.pf, want) {
			t.Fatalf("missing %s in %q", want, b.pf)
		}
	}
	if got := c.Settings().AllowHosts; len(got) != 2 || got[0] != "jp4.example.com" {
		t.Fatalf("hosts not normalized: %v", got)
	}
	if st := c.Status(); len(st.AllowedHosts) != 2 || st.AllowedHosts[0].IPs[0] != "126.1.2.3" {
		t.Fatalf("status must show resolved hosts: %+v", st)
	}
}

func TestAllowHostsFollowDNSAndSurviveFailure(t *testing.T) {
	answer := []string{"126.1.2.3"}
	c, b := newHostTest(t, Settings{Block: true, AllowHosts: []string{"jp4.example.com"}},
		func(string) []string { return answer })
	expire := func() {
		e := c.hostCache["jp4.example.com"]
		e.at = time.Now().Add(-2 * hostTTL)
		c.hostCache["jp4.example.com"] = e
	}

	for _, bad := range [][]string{nil, {"198.18.0.9"}} {
		answer = bad
		expire()
		if err := c.Sync(); err != nil {
			t.Fatal(err)
		}
		if !strings.Contains(b.pf, "126.1.2.3") {
			t.Fatalf("answer %v must keep the last real IP: %q", bad, b.pf)
		}
	}

	answer = []string{"126.4.5.6"}
	expire()
	if err := c.Sync(); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(b.pf, "126.4.5.6") || strings.Contains(b.pf, "126.1.2.3") {
		t.Fatalf("rules must follow the new IP: %q", b.pf)
	}
}

func TestAllowHostsNotUsedInDomesticMode(t *testing.T) {
	resolve := func(string) []string { return []string{"126.1.2.3"} }
	_, domestic := newHostTest(t, Settings{Block: true, ForceDomestic: true, AllowHosts: []string{"jp4.example.com"}}, resolve)
	if strings.Contains(domestic.pf, "126.1.2.3") {
		t.Fatalf("domestic mode must not allow hosts: %q", domestic.pf)
	}
}

func TestAllowHostsRejectInvalidAndPersist(t *testing.T) {
	c, _ := newHostTest(t, Settings{Block: true, AllowHosts: []string{"jp4.example.com"}},
		func(string) []string { return nil })
	if err := c.Update(Settings{Block: true, AllowHosts: []string{"a b; pass out all"}}); err == nil {
		t.Fatal("invalid host must be rejected")
	}
	if got := c.Settings().AllowHosts; len(got) != 1 {
		t.Fatalf("rejected update must not change settings: %v", got)
	}
	reloaded := New(c.path, &fakeBackend{}, nil)
	if got := reloaded.Settings().AllowHosts; len(got) != 1 || got[0] != "jp4.example.com" {
		t.Fatalf("hosts must persist: %v", got)
	}
	if empty := New("", &fakeBackend{}, nil).Settings().AllowHosts; empty == nil {
		t.Fatal("allow_hosts must be non-nil so the UI can detect support")
	}
}
