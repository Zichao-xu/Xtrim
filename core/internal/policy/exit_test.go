package policy

import (
	"errors"
	"path/filepath"
	"testing"

	"github.com/wgsense/core/internal/config"
	"github.com/wgsense/core/internal/tunnel"
)

type fakeExit struct{ running bool }

func (f *fakeExit) Start() error { f.running = true; return nil }
func (f *fakeExit) Stop() error  { f.running = false; return nil }

func newExitEngine(t *testing.T, trusted bool) (*Engine, *mockTunnel, *fakeExit, string) {
	t.Helper()
	cfg := config.Default()
	cfg.DesiredGuardEnabled = true
	tun := &mockTunnel{state: tunnel.StateConnected}
	e := New(cfg, mockLocation{trusted: trusted}, tun, mockHealth{connected: true}, &mockPause{})
	path := filepath.Join(t.TempDir(), "exit.json")
	e.SetExitStore(path)
	ex := &fakeExit{}
	e.SetMihomoExit(ex)
	return e, tun, ex, path
}

func TestSwitchToMihomoTearsDownWireGuard(t *testing.T) {
	e, tun, ex, _ := newExitEngine(t, false)
	if err := e.SetExit(ExitMihomo); err != nil {
		t.Fatal(err)
	}
	if tun.state != tunnel.StateDisconnected || !ex.running {
		t.Fatalf("want WG down + mihomo up, got state=%s mihomo=%v", tun.state, ex.running)
	}
	if e.Status().Exit != ExitMihomo {
		t.Fatal("status should report mihomo exit")
	}
}

func TestPolicyKeepsWireGuardDownWhileMihomoIsExit(t *testing.T) {
	e, tun, _, _ := newExitEngine(t, false)
	if err := e.SetExit(ExitMihomo); err != nil {
		t.Fatal(err)
	}
	tun.state = tunnel.StateConnected // 有人绕过引擎把隧道拉起来
	if err := e.RunOnce(); err != nil {
		t.Fatal(err)
	}
	if tun.state != tunnel.StateDisconnected {
		t.Fatal("policy must tear WG down while mihomo is the exit")
	}
	if err := e.RunOnce(); err != nil || tun.state != tunnel.StateDisconnected {
		t.Fatal("guard must not auto-connect WG while mihomo is the exit")
	}
	if err := e.Connect(); !errors.Is(err, ErrExitNotWireGuard) {
		t.Fatalf("manual WG connect must be refused, got %v", err)
	}
}

func TestSwitchBackToWireGuardStopsMihomoAndConnects(t *testing.T) {
	e, tun, ex, _ := newExitEngine(t, false)
	_ = e.SetExit(ExitMihomo)
	if err := e.SetExit(ExitWireGuard); err != nil {
		t.Fatal(err)
	}
	if ex.running || tun.state != tunnel.StateConnected {
		t.Fatalf("want mihomo down + WG up, got mihomo=%v state=%s", ex.running, tun.state)
	}
}

func TestSwitchBackAtHomeRespectsGuard(t *testing.T) {
	e, tun, ex, _ := newExitEngine(t, true)
	tun.state = tunnel.StateDisconnected
	_ = e.SetExit(ExitMihomo)
	if err := e.SetExit(ExitWireGuard); err != nil {
		t.Fatal(err)
	}
	if ex.running || tun.state != tunnel.StateDisconnected {
		t.Fatal("at home with guard on, WG stays down by design")
	}
}

func TestExitPersistsAcrossRestart(t *testing.T) {
	e, _, _, path := newExitEngine(t, false)
	_ = e.SetExit(ExitMihomo)
	again := New(config.Default(), mockLocation{}, &mockTunnel{}, mockHealth{}, &mockPause{})
	again.SetExitStore(path)
	if again.Exit() != ExitMihomo {
		t.Fatal("exit choice not persisted")
	}
}

func TestTailscaleAndUnknownRejected(t *testing.T) {
	e, _, _, _ := newExitEngine(t, false)
	if e.SetExit(ExitTailscale) == nil || e.SetExit("x") == nil {
		t.Fatal("tailscale (placeholder) and unknown exits must be rejected")
	}
	if e.Exit() != ExitWireGuard {
		t.Fatal("rejected switch must not change the exit")
	}
}

func TestMihomoExitRequiresKernel(t *testing.T) {
	e := New(config.Default(), mockLocation{}, &mockTunnel{}, mockHealth{}, &mockPause{})
	e.SetExitStore(filepath.Join(t.TempDir(), "exit.json"))
	if e.SetExit(ExitMihomo) == nil {
		t.Fatal("must refuse mihomo exit without a bundled kernel")
	}
}

func TestSwitchToWireGuardSucceedsEvenIfConnectFails(t *testing.T) {
	e, tun, ex, _ := newExitEngine(t, false)
	_ = e.SetExit(ExitMihomo)
	tun.connectErr = errors.New("no profile")
	if err := e.SetExit(ExitWireGuard); err != nil {
		t.Fatalf("switch itself must succeed, got %v", err)
	}
	if e.Exit() != ExitWireGuard || ex.running {
		t.Fatal("exit should be WireGuard with mihomo stopped")
	}
}
