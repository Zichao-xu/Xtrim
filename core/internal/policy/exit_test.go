package policy

import (
	"errors"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/wgsense/core/internal/config"
	"github.com/wgsense/core/internal/gatewayproxy"
	"github.com/wgsense/core/internal/tunnel"
)

type fakeExit struct {
	running  bool
	notReady error
}

func (f *fakeExit) Ready() error { return f.notReady }
func (f *fakeExit) Healthy() (bool, string) {
	if f.running {
		return true, "内核运行中"
	}
	return false, "内核未运行"
}
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

func TestMihomoNotReadyKeepsWireGuard(t *testing.T) {
	e, tun, ex, _ := newExitEngine(t, false)
	ex.notReady = errors.New("还没有同步配置")
	if e.SetExit(ExitMihomo) == nil {
		t.Fatal("must refuse when mihomo is not ready")
	}
	if e.Exit() != ExitWireGuard || tun.state != tunnel.StateConnected || ex.running {
		t.Fatal("WireGuard must stay up when the switch is refused")
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

// 回归：出站拦截在策略巡检持有 opMu 时回调 Exit()，不能死锁。
func TestExitReadableWhileEngineLocked(t *testing.T) {
	e, _, _, _ := newExitEngine(t, false)
	done := make(chan string, 1)
	e.opMu.Lock()
	go func() { done <- e.Exit() }()
	select {
	case got := <-done:
		if got != ExitWireGuard {
			t.Fatalf("got %s", got)
		}
	case <-time.After(2 * time.Second):
		e.opMu.Unlock()
		t.Fatal("Exit() blocked on opMu: deadlock with firewall sync during policy ticks")
	}
	e.opMu.Unlock()
}

func TestExitHealthFollowsExit(t *testing.T) {
	e, tun, ex, _ := newExitEngine(t, false)
	if exit, online, _ := e.ExitHealth(); exit != ExitWireGuard || online {
		t.Fatalf("mock tunnel has no handshake data: want offline wireguard, got %s %v", exit, online)
	}
	_ = e.SetExit(ExitMihomo)
	if exit, online, _ := e.ExitHealth(); exit != ExitMihomo || !online {
		t.Fatalf("running kernel must count as online, got %s %v", exit, online)
	}
	ex.running = false
	if _, online, _ := e.ExitHealth(); online {
		t.Fatal("stopped kernel must count as offline")
	}
	_ = tun
}

// 回归：切换出口时引擎持锁，心跳仍要能算出口健康。
func TestExitHealthWhileEngineLocked(t *testing.T) {
	e, _, _, _ := newExitEngine(t, false)
	done := make(chan struct{})
	e.opMu.Lock()
	go func() { e.ExitHealth(); close(done) }()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		e.opMu.Unlock()
		t.Fatal("ExitHealth blocked on opMu")
	}
	e.opMu.Unlock()
}

type stubGateway struct {
	result         gatewayproxy.Result
	probes, resets int
}

func (s *stubGateway) Probe() gatewayproxy.Result { s.probes++; return s.result }
func (s *stubGateway) Reset()                     { s.resets++ }

// 所选出口不在时，网关代理在线也算出口；所选出口在线时不去探测网关。
func TestExitHealthFallsBackToGatewayProxy(t *testing.T) {
	e, _, ex, _ := newExitEngine(t, false)
	gw := &stubGateway{result: gatewayproxy.Result{Online: true, Detail: "网关 10.10.1.1 代理在线"}}
	e.SetGatewayProbe(gw)

	exit, online, detail := e.ExitHealth()
	if exit != ExitGateway || !online || !strings.Contains(detail, "WireGuard 不可用") || !strings.Contains(detail, "网关 10.10.1.1") {
		t.Fatalf("WireGuard 不在而网关代理在线应休眠: %s %v %q", exit, online, detail)
	}

	gw.result = gatewayproxy.Result{Detail: "网关 192.168.1.1 不是代理"}
	if exit, online, _ := e.ExitHealth(); exit != ExitWireGuard || online {
		t.Fatalf("网关不是代理应接管: %s %v", exit, online)
	}

	_ = e.SetExit(ExitMihomo)
	probes := gw.probes
	if exit, online, _ := e.ExitHealth(); exit != ExitMihomo || !online || gw.probes != probes || gw.resets == 0 {
		t.Fatalf("所选出口在线时应直接用它并重置探测: %s %v probes=%d resets=%d", exit, online, gw.probes-probes, gw.resets)
	}
	ex.running = false
	gw.result = gatewayproxy.Result{Online: true, Detail: "ok"}
	if exit, online, detail := e.ExitHealth(); exit != ExitGateway || !online || !strings.Contains(detail, "mihomo 不可用") {
		t.Fatalf("内置内核停了而网关代理在线应休眠: %s %v %q", exit, online, detail)
	}
}
