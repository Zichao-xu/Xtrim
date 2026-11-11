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

func TestTunnelLockOnlyWhileTunnelUp(t *testing.T) {
	up := false
	c, b := newTest(t, Settings{Block: true})
	c.TunnelLocked = func() bool { return up }

	up = true
	if err := c.Sync(); err != nil {
		t.Fatal(err)
	}
	st := c.Status()
	if !st.Locked || !st.Active {
		t.Fatalf("tunnel up should lock: %+v", st)
	}
	if strings.Contains(b.pf, "wgsense_cn") {
		t.Fatalf("locked rules must not pass domestic ranges:\n%s", b.pf)
	}
	for _, want := range []string{"1.2.3.4", "192.168.0.0/16", "fe80::/10", `label "wgsense-block"`} {
		if !strings.Contains(b.pf, want) {
			t.Fatalf("missing %q in:\n%s", want, b.pf)
		}
	}

	up = false // 隧道拆除：立即回到普通规则
	if err := c.Sync(); err != nil {
		t.Fatal(err)
	}
	if st := c.Status(); st.Locked || !strings.Contains(b.pf, "wgsense_cn") {
		t.Fatalf("tunnel down must unlock: %+v\n%s", st, b.pf)
	}
}

func TestTunnelLockIndependentOfBlockSwitch(t *testing.T) {
	c, b := newTest(t, Settings{})
	c.TunnelLocked = func() bool { return true }
	_ = c.Sync()
	if !c.Status().Locked || b.pf == "" {
		t.Fatal("lock must apply even when overseas blocking is off")
	}
	if err := c.Update(Settings{AllowBypass: true}); err != nil {
		t.Fatal(err)
	}
	if c.Status().Locked || b.pf != "" {
		t.Fatalf("allow_bypass should turn the lock off: %q", b.pf)
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

func TestAllowHostsNotUsedWhenLockedOrDomestic(t *testing.T) {
	resolve := func(string) []string { return []string{"126.1.2.3"} }
	_, domestic := newHostTest(t, Settings{Block: true, ForceDomestic: true, AllowHosts: []string{"jp4.example.com"}}, resolve)
	if strings.Contains(domestic.pf, "126.1.2.3") {
		t.Fatalf("domestic mode must not allow hosts: %q", domestic.pf)
	}

	c, b := newHostTest(t, Settings{Block: true, AllowHosts: []string{"jp4.example.com"}}, resolve)
	c.TunnelLocked = func() bool { return true }
	if err := c.Sync(); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(b.pf, "126.1.2.3") {
		t.Fatalf("tunnel lock must not allow hosts: %q", b.pf)
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

func TestRenderProxyLockAllowsKernelGroupOnly(t *testing.T) {
	rules := RenderPF(RuleInput{Interfaces: []string{"en0"}, LockTunnel: true, AllowGroup: "nobody", CNFile: "/x"})
	if !strings.Contains(rules, "pass out quick on { en0 } proto { tcp udp } group nobody keep state") {
		t.Fatalf("kernel group not allowed:\n%s", rules)
	}
	if strings.Contains(rules, "wgsense_cn") {
		t.Fatalf("proxy lock must not allow the CN table:\n%s", rules)
	}
	if !strings.Contains(rules, "block return out quick on { en0 } all") {
		t.Fatalf("missing final block:\n%s", rules)
	}
}
