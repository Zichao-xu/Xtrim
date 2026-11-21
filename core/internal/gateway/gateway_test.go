package gateway

import (
	"path/filepath"
	"testing"
	"time"

	"github.com/wgsense/core/internal/location"
)

const homeMAC = "1a:95:1c:33:7a:f7"

type fakeNet struct {
	cur Current
	ok  bool
	ips []string
}

func newTestStore(t *testing.T, n *fakeNet, legacy []string) (*Store, string) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "gateway.json")
	s := Open(path, legacy)
	wire(s, n)
	return s, path
}

func wire(s *Store, n *fakeNet) {
	clock := time.Date(2026, 11, 22, 10, 0, 0, 0, time.UTC)
	s.Interfaces = func() []location.Interface {
		return []location.Interface{{Name: "en0", IPv4s: n.ips}}
	}
	s.Read = func([]location.Interface) (Current, bool) { return n.cur, n.ok }
	s.Now = func() time.Time { clock = clock.Add(time.Second); return clock }
}

func home() *fakeNet {
	return &fakeNet{cur: Current{Interface: "en0", IP: "10.10.1.1", MAC: homeMAC}, ok: true, ips: []string{"10.10.1.10"}}
}

// 朋友家同为 10.10.1.x，但网关是另一台路由器：不能被当成受信任。
func TestSameSubnetDifferentGatewayIsUntrusted(t *testing.T) {
	n := home()
	s, _ := newTestStore(t, n, nil)
	if _, err := s.Trust("", "家 · op"); err != nil {
		t.Fatal(err)
	}
	if v := s.Evaluate(); !v.Trusted || v.Name != "家 · op" {
		t.Fatalf("home gateway should be trusted: %+v", v)
	}
	n.cur.MAC = "f4:2a:7d:00:11:22"
	if v := s.Evaluate(); v.Trusted {
		t.Fatalf("friend's gateway on the same subnet must not be trusted: %+v", v)
	}
}

func TestUnreadableGatewayIsUntrusted(t *testing.T) {
	n := home()
	s, _ := newTestStore(t, n, nil)
	if _, err := s.Trust(homeMAC, "家"); err != nil {
		t.Fatal(err)
	}
	n.cur.MAC = ""
	if v := s.Evaluate(); v.Trusted {
		t.Fatalf("missing MAC must be untrusted: %+v", v)
	}
	n.ok = false
	if v := s.Evaluate(); v.Trusted || v.Current != nil {
		t.Fatalf("no gateway must be untrusted: %+v", v)
	}
	if _, err := s.Trust("", ""); err != ErrNoGateway {
		t.Fatalf("trusting the current gateway without one: err=%v", err)
	}
}

func TestTrustPersistsAndUntrustRemoves(t *testing.T) {
	n := home()
	s, path := newTestStore(t, n, nil)
	if _, err := s.Trust("1A-95-1C-33-7A-F7", ""); err != nil {
		t.Fatal(err)
	}
	reopened := Open(path, nil)
	wire(reopened, n)
	st := reopened.Snapshot()
	if !st.Trusted || len(st.TrustedList) != 1 || st.TrustedList[0].MAC != homeMAC {
		t.Fatalf("trust should survive restart: %+v", st)
	}
	if err := reopened.Untrust(homeMAC); err != nil {
		t.Fatal(err)
	}
	if reopened.Evaluate().Trusted {
		t.Fatal("untrusted gateway still trusted")
	}
}

// 从按网段信任的旧版升级：不再据网段信任，只提示一次；信任任何网关后提示消失。
func TestLegacyPrefixesOnlyPrompt(t *testing.T) {
	n := home()
	s, path := newTestStore(t, n, []string{"10.10.1."})
	v := s.Evaluate()
	if v.Trusted || !v.LegacyMatch {
		t.Fatalf("legacy prefix must prompt but not trust: %+v", v)
	}
	// 重启后（文件已存在）不会因为 settings.json 里的旧网段再次触发迁移以外的行为。
	reopened := Open(path, []string{"10.10.1."})
	wire(reopened, n)
	if v := reopened.Evaluate(); !v.LegacyMatch {
		t.Fatalf("legacy prompt should persist until answered: %+v", v)
	}
	if _, err := reopened.Trust("", ""); err != nil {
		t.Fatal(err)
	}
	if v := reopened.Evaluate(); !v.Trusted || v.LegacyMatch {
		t.Fatalf("after trusting, prompt must go away: %+v", v)
	}

	other := home()
	s2, _ := newTestStore(t, other, []string{"10.10.1."})
	s2.DismissLegacy()
	if v := s2.Evaluate(); v.LegacyMatch {
		t.Fatalf("dismissed prompt came back: %+v", v)
	}
}

func TestSeenAndDecisions(t *testing.T) {
	n := home()
	s, _ := newTestStore(t, n, nil)
	s.Evaluate()
	s.Evaluate() // 没变化不记新判定
	n.cur = Current{Interface: "en0", IP: "192.168.31.1", MAC: "aa:bb:cc:dd:ee:ff"}
	s.Evaluate()
	st := s.Snapshot()
	if len(st.Seen) != 2 || st.Seen[0].MAC != "aa:bb:cc:dd:ee:ff" {
		t.Fatalf("seen should list both gateways, newest first: %+v", st.Seen)
	}
	if len(st.Decisions) != 2 || st.Decisions[0].MAC != "aa:bb:cc:dd:ee:ff" {
		t.Fatalf("one decision per change, newest first: %+v", st.Decisions)
	}
	// 事后从「见过的网关」补加信任。
	if _, err := s.Trust(homeMAC, ""); err != nil {
		t.Fatal(err)
	}
	if got := s.Snapshot().TrustedList[0].Name; got != "10.10.1.1" {
		t.Fatalf("default name should be the gateway IP it was seen at, got %q", got)
	}
}

func TestNormalizeMAC(t *testing.T) {
	cases := map[string]string{
		"1a:95:1c:33:7a:f7": homeMAC,
		"1A-95-1C-33-7A-F7": homeMAC,
		"0:1:2:a:b:c":       "00:01:02:0a:0b:0c",
	}
	for in, want := range cases {
		if got, ok := NormalizeMAC(in); !ok || got != want {
			t.Errorf("NormalizeMAC(%q) = %q,%v want %q", in, got, ok, want)
		}
	}
	for _, bad := range []string{"", "00:00:00:00:00:00", "1a:95:1c:33:7a", "zz:95:1c:33:7a:f7"} {
		if _, ok := NormalizeMAC(bad); ok {
			t.Errorf("NormalizeMAC(%q) should fail", bad)
		}
	}
}
