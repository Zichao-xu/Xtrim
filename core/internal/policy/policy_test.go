package policy

import (
	"context"
	"errors"
	"path/filepath"
	"reflect"
	"testing"
	"time"

	"github.com/wgsense/core/internal/config"
	"github.com/wgsense/core/internal/location"
	"github.com/wgsense/core/internal/tunnel"
)

// mock 实现，用于隔离测试策略逻辑

type mockLocation struct{ trusted bool }

func (m mockLocation) Trusted() bool { return m.trusted }
func (m mockLocation) CurrentIPv4s() []string {
	return nil
}
func (m mockLocation) ActiveInterfaces() []location.Interface {
	return nil
}

type mockTunnel struct {
	state      tunnel.State
	connectErr error
}

func (m *mockTunnel) Connect(string) error {
	if m.connectErr != nil {
		return m.connectErr
	}
	m.state = tunnel.StateConnected
	return nil
}
func (m *mockTunnel) Disconnect(string) error                   { m.state = tunnel.StateDisconnected; return nil }
func (m *mockTunnel) Status(string) (tunnel.State, error)       { return m.state, nil }
func (m *mockTunnel) DiscoverServices() ([]string, error)       { return nil, nil }
func (m *mockTunnel) ConfigDir() string                         { return "/tmp/mock" }
func (m *mockTunnel) SaveProfile(string, string) error          { return nil }
func (m *mockTunnel) LoadProfileContent(string) (string, error) { return "", nil }
func (m *mockTunnel) DeleteProfile(string) error                { return nil }
func (m *mockTunnel) InterfaceBytes(string) (uint64, uint64)    { return 0, 0 }

type countingTunnel struct {
	mockTunnel
	connects    int
	disconnects int
}

func (m *countingTunnel) Connect(service string) error {
	m.connects++
	return m.mockTunnel.Connect(service)
}

func (m *countingTunnel) Disconnect(service string) error {
	m.disconnects++
	return m.mockTunnel.Disconnect(service)
}

type blockingTunnel struct {
	mockTunnel
	started chan struct{}
	release chan struct{}
}

func (m *blockingTunnel) Connect(string) error {
	close(m.started)
	<-m.release
	m.state = tunnel.StateConnected
	return nil
}

type blockingCleanupTunnel struct {
	countingTunnel
	started    chan struct{}
	release    chan struct{}
	cleanupErr error
}

func (m *blockingCleanupTunnel) Disconnect(service string) error {
	m.disconnects++
	if m.started != nil && m.disconnects == 1 {
		close(m.started)
	}
	if m.release != nil {
		<-m.release
	}
	if m.cleanupErr != nil {
		return m.cleanupErr
	}
	return m.mockTunnel.Disconnect(service)
}

type maintenanceStatusTunnel struct {
	countingTunnel
	started     chan struct{}
	release     chan struct{}
	statusErr   error
	statusCalls int
}

func (m *maintenanceStatusTunnel) Status(service string) (tunnel.State, error) {
	m.statusCalls++
	if m.started != nil && m.statusCalls == 1 {
		close(m.started)
		<-m.release
	}
	return m.state, m.statusErr
}

type mockHealth struct{ connected bool }

func (m mockHealth) CheckConnectivity() bool       { return m.connected }
func (m mockHealth) IsStaleConnected(tc bool) bool { return tc && !m.connected }

type mutableHealth struct{ connected bool }

func (m *mutableHealth) CheckConnectivity() bool       { return m.connected }
func (m *mutableHealth) IsStaleConnected(tc bool) bool { return tc && !m.connected }

type mockPause struct{ paused bool }

func (m *mockPause) Pause() error   { m.paused = true; return nil }
func (m *mockPause) Resume() error  { m.paused = false; return nil }
func (m *mockPause) IsPaused() bool { return m.paused }

func TestRunOnceTrustedNetworkDisconnects(t *testing.T) {
	tun := &mockTunnel{state: tunnel.StateConnected}
	cfg := config.Default()
	cfg.DesiredGuardEnabled = true
	eng := New(cfg, mockLocation{trusted: true}, tun, mockHealth{connected: true}, &mockPause{})
	if err := eng.RunOnce(); err != nil {
		t.Fatal(err)
	}
	if tun.state != tunnel.StateDisconnected {
		t.Errorf("受信任网络应断开, 实际 %s", tun.state)
	}
}

func TestRunOnceTrustedGuardOverridesManualVPNIntent(t *testing.T) {
	tun := &mockTunnel{state: tunnel.StateConnected}
	cfg := config.Default()
	cfg.DesiredVPNEnabled = true
	cfg.DesiredGuardEnabled = true
	eng := New(cfg, mockLocation{trusted: true}, tun, mockHealth{connected: true}, &mockPause{})

	if err := eng.RunOnce(); err != nil {
		t.Fatal(err)
	}
	if tun.state != tunnel.StateDisconnected {
		t.Fatalf("守护开启时回到受信任网络应断开, 实际 %s", tun.state)
	}
	if eng.Status().DesiredVPNEnabled {
		t.Fatalf("守护开启且受信任网络下，UI 不应继续显示 VPN 需要保持开启")
	}
}

func TestRunOnceTrustedManualVPNWithoutGuardStaysConnected(t *testing.T) {
	tun := &mockTunnel{state: tunnel.StateConnected}
	cfg := config.Default()
	cfg.DesiredVPNEnabled = true
	eng := New(cfg, mockLocation{trusted: true}, tun, mockHealth{connected: true}, &mockPause{})

	if err := eng.RunOnce(); err != nil {
		t.Fatal(err)
	}
	if tun.state != tunnel.StateConnected {
		t.Fatalf("未开启守护时，手动 VPN 意图不应被受信任网络抢断: %s", tun.state)
	}
	if !eng.Status().DesiredVPNEnabled {
		t.Fatalf("未开启守护时应保留手动 VPN 意图")
	}
}

func TestRunOnceUntrustedConnectsWhenEnabled(t *testing.T) {
	tun := &mockTunnel{state: tunnel.StateDisconnected}
	cfg := config.Default()
	cfg.AutoConnectUntrusted = true
	eng := New(cfg, mockLocation{trusted: false}, tun, mockHealth{}, &mockPause{})
	if err := eng.RunOnce(); err != nil {
		t.Fatal(err)
	}
	if tun.state != tunnel.StateConnected {
		t.Errorf("非受信任网络应连接, 实际 %s", tun.state)
	}
}

func TestResumeImmediatelyAppliesUntrustedPolicy(t *testing.T) {
	tun := &mockTunnel{state: tunnel.StateDisconnected}
	pause := &mockPause{paused: true}
	cfg := config.Default()
	cfg.AutoConnectUntrusted = true
	eng := New(cfg, mockLocation{trusted: false}, tun, mockHealth{}, pause)

	if err := eng.Resume(); err != nil {
		t.Fatal(err)
	}
	if pause.paused {
		t.Fatal("恢复守护后仍处于暂停状态")
	}
	if tun.state != tunnel.StateConnected {
		t.Fatalf("恢复守护后应立即连接非受信任网络, 实际 %s", tun.state)
	}
}

func TestResumeImmediatelyDisconnectsTrustedNetwork(t *testing.T) {
	tun := &mockTunnel{state: tunnel.StateConnected}
	pause := &mockPause{paused: true}
	cfg := config.Default()
	cfg.AutoConnectUntrusted = true
	eng := New(cfg, mockLocation{trusted: true}, tun, mockHealth{connected: true}, pause)

	if err := eng.Resume(); err != nil {
		t.Fatal(err)
	}
	if tun.state != tunnel.StateDisconnected {
		t.Fatalf("恢复守护后应立即断开受信任网络, 实际 %s", tun.state)
	}
}

func TestRunOnceUntrustedDoesNotConnectWhenAutoDisabled(t *testing.T) {
	tun := &mockTunnel{state: tunnel.StateDisconnected}
	eng := New(config.Default(), mockLocation{trusted: false}, tun, mockHealth{}, &mockPause{})
	if err := eng.RunOnce(); err != nil {
		t.Fatal(err)
	}
	if tun.state != tunnel.StateDisconnected {
		t.Errorf("默认不应自动连接, 实际 %s", tun.state)
	}
	if !eng.Status().Auto {
		return
	}
	t.Fatal("默认配置不应启用非受信任网络自动连接")
}

func TestPassiveEngineRejectsManualConnect(t *testing.T) {
	tun := &mockTunnel{state: tunnel.StateDisconnected}
	eng := New(config.Default(), mockLocation{trusted: false}, tun, mockHealth{}, &mockPause{})
	eng.SetPassive(true)
	if err := eng.Connect(); err == nil {
		t.Fatal("passive engine must reject WireGuard connect")
	}
	if tun.state != tunnel.StateDisconnected {
		t.Fatalf("passive connect changed tunnel state to %s", tun.state)
	}
	if !eng.Status().Passive {
		t.Fatal("passive mode is missing from status")
	}
	if !eng.Status().DesiredVPNEnabled {
		t.Fatal("连接失败也应保留用户开启 VPN 的意图")
	}
}

func TestManualVPNIntentRestoresAfterRestartWithPreviousPause(t *testing.T) {
	paused := &mockPause{paused: true}
	tun := &mockTunnel{state: tunnel.StateDisconnected}
	eng := New(config.Default(), mockLocation{}, tun, mockHealth{connected: true}, paused)
	path := filepath.Join(t.TempDir(), "settings.json")
	eng.SetConfigPath(path)
	if err := eng.Connect(); err != nil {
		t.Fatal(err)
	}
	if paused.IsPaused() {
		t.Fatal("explicit VPN connect left an old pause marker active")
	}
	if err := eng.ShutdownCleanup(); err != nil {
		t.Fatal(err)
	}
	cfg, err := config.LoadRuntime(path)
	if err != nil {
		t.Fatal(err)
	}
	restarted := New(cfg, mockLocation{}, tun, mockHealth{connected: true}, paused)
	if err := restarted.RunOnce(); err != nil {
		t.Fatal(err)
	}
	if tun.state != tunnel.StateConnected {
		t.Fatal("persisted manual VPN intent did not reconnect after daemon restart")
	}
	if restarted.GetConfig().DesiredGuardEnabled {
		t.Fatal("manual VPN enabled automatic guard")
	}
}

func TestManualConnectFailureKeepsDesiredVPNOn(t *testing.T) {
	tun := &mockTunnel{state: tunnel.StateDisconnected, connectErr: errors.New("network blocked")}
	eng := New(config.Default(), mockLocation{trusted: false}, tun, mockHealth{}, &mockPause{})

	if err := eng.Connect(); err == nil {
		t.Fatal("connect should fail")
	}
	status := eng.Status()
	if !status.DesiredVPNEnabled {
		t.Fatalf("连接失败后不应清空 VPN 意图: %#v", status)
	}
	if status.State != string(tunnel.StateDisconnected) {
		t.Fatalf("真实隧道状态仍应是断开: %#v", status)
	}
}

func TestGuardIntentDrivesStatusWithoutConnectedTunnel(t *testing.T) {
	tun := &mockTunnel{state: tunnel.StateDisconnected}
	cfg := config.Default()
	cfg.DesiredGuardEnabled = true
	cfg.AutoConnectUntrusted = true
	eng := New(cfg, mockLocation{trusted: false}, tun, mockHealth{}, &mockPause{})

	status := eng.Status()
	if !status.DesiredGuardEnabled || !status.DesiredVPNEnabled {
		t.Fatalf("非受信网络下守护意图应显示保持 VPN: %#v", status)
	}
	if status.State != string(tunnel.StateDisconnected) {
		t.Fatalf("意图不应伪造真实连接状态: %#v", status)
	}
}

func TestRunOnceUntrustedPaused(t *testing.T) {
	tun := &mockTunnel{state: tunnel.StateDisconnected}
	eng := New(config.Default(), mockLocation{trusted: false}, tun, mockHealth{}, &mockPause{paused: true})
	if err := eng.RunOnce(); err != nil {
		t.Fatal(err)
	}
	if tun.state != tunnel.StateDisconnected {
		t.Error("暂停时不应连接")
	}
}

func TestRunOnceStaleConnected(t *testing.T) {
	tun := &mockTunnel{state: tunnel.StateConnected}
	// 单次波动不能破坏长连接；连续多次失败才重启。
	cfg := config.Default()
	cfg.DesiredVPNEnabled = true
	eng := New(cfg, mockLocation{trusted: false}, tun, mockHealth{connected: false}, &mockPause{})
	for i := 0; i < maxHealthFailures-1; i++ {
		eng.lastHealthCheck = time.Time{}
		if err := eng.RunOnce(); err != nil {
			t.Fatal(err)
		}
		if tun.state != tunnel.StateConnected || eng.healthFailures != i+1 {
			t.Fatalf("failure %d restarted too early: state=%s failures=%d", i+1, tun.state, eng.healthFailures)
		}
	}
	eng.lastHealthCheck = time.Time{}
	if err := eng.RunOnce(); err != nil {
		t.Fatal(err)
	}
	if tun.state != tunnel.StateConnected {
		t.Errorf("假连接重启后应 Connected, 实际 %s", tun.state)
	}
	if eng.healthFailures != 0 || eng.lastAutoUp.IsZero() {
		t.Fatalf("重启后健康状态未复位: failures=%d lastAutoUp=%v", eng.healthFailures, eng.lastAutoUp)
	}
}

func TestManualConnectStartsHealthGrace(t *testing.T) {
	tun := &mockTunnel{state: tunnel.StateDisconnected}
	eng := New(config.Default(), mockLocation{trusted: false}, tun, mockHealth{connected: false}, &mockPause{})

	if err := eng.Connect(); err != nil {
		t.Fatal(err)
	}
	if eng.lastAutoUp.IsZero() || eng.healthFailures != 0 {
		t.Fatalf("手动连接后未进入宽限期: lastAutoUp=%v failures=%d", eng.lastAutoUp, eng.healthFailures)
	}
	if err := eng.RunOnce(); err != nil {
		t.Fatal(err)
	}
	if eng.healthFailures != 0 {
		t.Fatalf("宽限期内不应立刻做假连接判定: failures=%d", eng.healthFailures)
	}
}

func TestManualConnectDoesNotRestartExistingTunnel(t *testing.T) {
	tun := &countingTunnel{mockTunnel: mockTunnel{state: tunnel.StateConnected}}
	eng := New(config.Default(), mockLocation{trusted: false}, tun, mockHealth{connected: true}, &mockPause{})

	if err := eng.Connect(); err != nil {
		t.Fatal(err)
	}
	if tun.connects != 0 {
		t.Fatalf("already-connected tunnel should not be reconnected: %d", tun.connects)
	}
}

func TestRunOnceSkipsWhileConnectInProgress(t *testing.T) {
	tun := &blockingTunnel{
		mockTunnel: mockTunnel{state: tunnel.StateDisconnected},
		started:    make(chan struct{}),
		release:    make(chan struct{}),
	}
	cfg := config.Default()
	cfg.AutoConnectUntrusted = true
	eng := New(cfg, mockLocation{trusted: false}, tun, mockHealth{}, &mockPause{})

	done := make(chan error, 1)
	go func() { done <- eng.RunOnce() }()
	<-tun.started

	if err := eng.RunOnce(); err != nil {
		t.Fatal(err)
	}
	close(tun.release)
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	if tun.state != tunnel.StateConnected {
		t.Fatalf("first connect should finish: %s", tun.state)
	}
}

func TestShutdownCleanupPreservesDesiredVPNIntent(t *testing.T) {
	tun := &mockTunnel{state: tunnel.StateConnected}
	cfg := config.Default()
	cfg.DesiredVPNEnabled = true
	eng := New(cfg, mockLocation{trusted: false}, tun, mockHealth{connected: true}, &mockPause{})
	path := filepath.Join(t.TempDir(), "settings.json")
	eng.SetConfigPath(path)

	if err := eng.ShutdownCleanup(); err != nil {
		t.Fatal(err)
	}
	if tun.state != tunnel.StateDisconnected {
		t.Fatalf("shutdown cleanup should disconnect the tunnel: %s", tun.state)
	}
	if !eng.Status().DesiredVPNEnabled {
		t.Fatal("daemon shutdown cleanup must not clear the user's VPN intent")
	}
	if _, err := config.LoadRuntime(path); !config.IsNotExist(err) {
		t.Fatalf("shutdown cleanup should not rewrite runtime config, err=%v", err)
	}
}

func TestShutdownCleanupRejectsConcurrentReconnects(t *testing.T) {
	tun := &blockingCleanupTunnel{
		countingTunnel: countingTunnel{mockTunnel: mockTunnel{state: tunnel.StateConnected}},
		started:        make(chan struct{}),
		release:        make(chan struct{}),
	}
	t.Cleanup(func() {
		select {
		case <-tun.release:
		default:
			close(tun.release)
		}
	})
	cfg := config.Default()
	cfg.DesiredVPNEnabled = true
	p := &mockPause{}
	eng := New(cfg, mockLocation{trusted: false}, tun, mockHealth{}, p)
	before := eng.GetConfig()
	path := filepath.Join(t.TempDir(), "settings.json")
	eng.SetConfigPath(path)
	eng.lastNetwork = "before"
	networkReads := 0
	eng.SetNetworkSnapshotFunc(func() string {
		networkReads++
		return "after"
	})

	shutdownDone := make(chan error, 1)
	go func() { shutdownDone <- eng.ShutdownCleanup() }()
	select {
	case <-tun.started:
	case <-time.After(5 * time.Second):
		t.Fatal("shutdown did not enter tunnel cleanup")
	}

	// Submit manual operations while cleanup owns opMu. Both must remain
	// rejected when they eventually acquire the lock, after the tunnel is down.
	ready := make(chan struct{}, 2)
	operationDone := make(chan error, 2)
	for _, operation := range []func() error{eng.Connect, eng.Resume} {
		go func() {
			ready <- struct{}{}
			operationDone <- operation()
		}()
	}
	<-ready
	<-ready
	repeatedDone := make(chan error, 1)
	go func() { repeatedDone <- eng.ShutdownCleanup() }()

	// Polls that arrive during cleanup skip the busy lock; polls arriving after
	// it finishes must also do nothing, even though desired VPN stays enabled.
	if err := eng.RunOnce(); err != nil {
		t.Fatal(err)
	}
	if err := eng.RunOnNetworkChange(); err != nil {
		t.Fatal(err)
	}
	close(tun.release)
	for range 2 {
		if err := waitForPolicyResult(t, operationDone); !errors.Is(err, ErrShuttingDown) {
			t.Fatalf("queued operation should reject shutdown, got %v", err)
		}
	}
	if err := waitForPolicyResult(t, shutdownDone); err != nil {
		t.Fatal(err)
	}
	if err := waitForPolicyResult(t, repeatedDone); err != nil {
		t.Fatal(err)
	}
	if err := eng.RunOnce(); err != nil {
		t.Fatal(err)
	}
	if err := eng.RunOnNetworkChange(); err != nil {
		t.Fatal(err)
	}
	if tun.connects != 0 || tun.disconnects != 1 || tun.state != tunnel.StateDisconnected {
		t.Fatalf("shutdown was not final: connects=%d disconnects=%d state=%s", tun.connects, tun.disconnects, tun.state)
	}
	if networkReads != 0 || eng.lastNetwork != "before" {
		t.Fatalf("shutdown polls still inspected the network: reads=%d snapshot=%s", networkReads, eng.lastNetwork)
	}
	if got := eng.GetConfig(); !reflect.DeepEqual(got, before) {
		t.Fatalf("shutdown operations changed desired intent: got %#v, want %#v", got, before)
	}
	if _, err := config.LoadRuntime(path); !config.IsNotExist(err) {
		t.Fatalf("shutdown operations rewrote settings: %v", err)
	}
	p.paused = true
	if err := eng.Resume(); !errors.Is(err, ErrShuttingDown) || !p.paused {
		t.Fatalf("shutdown resume changed pause state: err=%v paused=%t", err, p.paused)
	}
}

func TestShutdownCleanupFailureRemainsTerminal(t *testing.T) {
	cleanupErr := errors.New("cleanup failed")
	tun := &blockingCleanupTunnel{cleanupErr: cleanupErr}
	eng := New(config.Default(), mockLocation{}, tun, mockHealth{}, &mockPause{})
	for range 2 {
		if err := eng.ShutdownCleanup(); !errors.Is(err, cleanupErr) {
			t.Fatalf("cleanup should retain its result, got %v", err)
		}
	}
	if err := eng.Connect(); !errors.Is(err, ErrShuttingDown) {
		t.Fatalf("failed cleanup must still prohibit reconnect, got %v", err)
	}
	if tun.disconnects != 1 || tun.connects != 0 {
		t.Fatalf("unexpected tunnel calls: disconnects=%d connects=%d", tun.disconnects, tun.connects)
	}
}

func TestStartWithCanceledContextDoesNotRunInitialPolicy(t *testing.T) {
	cfg := config.Default()
	cfg.DesiredVPNEnabled = true
	tun := &countingTunnel{mockTunnel: mockTunnel{state: tunnel.StateDisconnected}}
	eng := New(cfg, mockLocation{trusted: false}, tun, mockHealth{}, &mockPause{})
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := eng.Start(ctx); !errors.Is(err, context.Canceled) {
		t.Fatalf("Start should report canceled context, got %v", err)
	}
	if tun.connects != 0 || tun.disconnects != 0 {
		t.Fatalf("canceled Start touched tunnel: connects=%d disconnects=%d", tun.connects, tun.disconnects)
	}
}

func TestServiceMaintenanceBlocksQueuedOperationsAndResumesIntent(t *testing.T) {
	tun := &maintenanceStatusTunnel{
		countingTunnel: countingTunnel{mockTunnel: mockTunnel{state: tunnel.StateDisconnected}},
		started:        make(chan struct{}),
		release:        make(chan struct{}),
	}
	t.Cleanup(func() {
		select {
		case <-tun.release:
		default:
			close(tun.release)
		}
	})
	cfg := config.Default()
	cfg.DesiredVPNEnabled = true
	p := &mockPause{}
	eng := New(cfg, mockLocation{}, tun, mockHealth{}, p)
	before := eng.GetConfig()
	path := filepath.Join(t.TempDir(), "settings.json")
	eng.SetConfigPath(path)
	networkReads := 0
	eng.SetNetworkSnapshotFunc(func() string {
		networkReads++
		return "must-not-read-during-maintenance"
	})
	beginDone := make(chan error, 1)
	go func() { beginDone <- eng.BeginServiceMaintenance() }()
	select {
	case <-tun.started:
	case <-time.After(5 * time.Second):
		t.Fatal("maintenance did not begin checking tunnel state")
	}

	// Begin owns opMu while verifying disconnection. Operations submitted in
	// that window must see maintenance when they eventually acquire the lock.
	ready := make(chan struct{}, 2)
	operationDone := make(chan error, 2)
	for _, operation := range []func() error{eng.Connect, eng.Resume} {
		go func() {
			ready <- struct{}{}
			operationDone <- operation()
		}()
	}
	<-ready
	<-ready
	for _, poll := range []func() error{eng.RunOnce, eng.RunOnNetworkChange} {
		if err := poll(); err != nil {
			t.Fatal(err)
		}
	}
	close(tun.release)
	if err := waitForPolicyResult(t, beginDone); err != nil {
		t.Fatal(err)
	}
	for range 2 {
		if err := waitForPolicyResult(t, operationDone); !errors.Is(err, ErrServiceMaintenance) {
			t.Fatalf("queued operation bypassed maintenance: %v", err)
		}
	}
	if err := eng.BeginServiceMaintenance(); !errors.Is(err, ErrServiceMaintenance) {
		t.Fatalf("overlapping maintenance was accepted: %v", err)
	}
	for _, poll := range []func() error{eng.RunOnce, eng.RunOnNetworkChange} {
		if err := poll(); err != nil {
			t.Fatal(err)
		}
	}
	if tun.connects != 0 || tun.disconnects != 0 || tun.statusCalls != 1 || networkReads != 0 {
		t.Fatalf("maintenance touched network: connects=%d disconnects=%d status=%d snapshots=%d", tun.connects, tun.disconnects, tun.statusCalls, networkReads)
	}
	if got := eng.GetConfig(); !reflect.DeepEqual(got, before) || p.paused {
		t.Fatalf("maintenance changed intent or pause: cfg=%#v paused=%t", got, p.paused)
	}
	if _, err := config.LoadRuntime(path); !config.IsNotExist(err) {
		t.Fatalf("maintenance rewrote settings: %v", err)
	}

	eng.EndServiceMaintenance()
	if err := eng.RunOnce(); err != nil {
		t.Fatal(err)
	}
	if tun.connects != 1 || tun.state != tunnel.StateConnected {
		t.Fatalf("ending maintenance did not restore existing VPN intent: connects=%d state=%s", tun.connects, tun.state)
	}
}

func TestServiceMaintenanceRequiresConfirmedDisconnection(t *testing.T) {
	for _, tc := range []struct {
		name  string
		state tunnel.State
		err   error
	}{
		{"connected", tunnel.StateConnected, nil},
		{"connecting", tunnel.StateConnecting, nil},
		{"unknown", tunnel.StateUnknown, nil},
		{"status_error", tunnel.StateDisconnected, errors.New("status unavailable")},
	} {
		t.Run(tc.name, func(t *testing.T) {
			tun := &maintenanceStatusTunnel{
				countingTunnel: countingTunnel{mockTunnel: mockTunnel{state: tc.state}},
				statusErr:      tc.err,
			}
			p := &mockPause{paused: true}
			eng := New(config.Default(), mockLocation{}, tun, mockHealth{}, p)
			before := eng.GetConfig()
			if err := eng.BeginServiceMaintenance(); err == nil {
				t.Fatal("maintenance accepted an unconfirmed disconnected state")
			}
			if tun.connects != 0 || tun.disconnects != 0 || !p.paused || !reflect.DeepEqual(eng.GetConfig(), before) {
				t.Fatal("rejected maintenance changed tunnel or user intent")
			}
			tun.state, tun.statusErr = tunnel.StateDisconnected, nil
			if err := eng.BeginServiceMaintenance(); err != nil {
				t.Fatalf("failed begin left maintenance locked: %v", err)
			}
			eng.EndServiceMaintenance()
			if !p.paused || !reflect.DeepEqual(eng.GetConfig(), before) {
				t.Fatal("maintenance cycle changed paused user intent")
			}
		})
	}
}

func TestShutdownRemainsTerminalAfterServiceMaintenanceEnds(t *testing.T) {
	tun := &countingTunnel{mockTunnel: mockTunnel{state: tunnel.StateDisconnected}}
	cfg := config.Default()
	cfg.DesiredVPNEnabled = true
	eng := New(cfg, mockLocation{}, tun, mockHealth{}, &mockPause{})
	if err := eng.BeginServiceMaintenance(); err != nil {
		t.Fatal(err)
	}
	if err := eng.ShutdownCleanup(); err != nil {
		t.Fatal(err)
	}
	eng.EndServiceMaintenance()
	for _, operation := range []func() error{eng.Connect, eng.Resume, eng.BeginServiceMaintenance} {
		if err := operation(); !errors.Is(err, ErrShuttingDown) {
			t.Fatalf("maintenance end reopened a shutting-down engine: %v", err)
		}
	}
	if err := eng.RunOnce(); err != nil {
		t.Fatal(err)
	}
	if tun.connects != 0 || tun.disconnects != 1 || !eng.GetConfig().DesiredVPNEnabled {
		t.Fatalf("shutdown after maintenance lost its boundary: connects=%d disconnects=%d", tun.connects, tun.disconnects)
	}
}

func waitForPolicyResult(t *testing.T, result <-chan error) error {
	t.Helper()
	select {
	case err := <-result:
		return err
	case <-time.After(5 * time.Second):
		t.Fatal("policy operation did not finish")
		return nil
	}
}

func TestUpdateConfigPersistsRuntimeConfig(t *testing.T) {
	tun := &mockTunnel{state: tunnel.StateDisconnected}
	eng := New(config.Default(), mockLocation{trusted: false}, tun, mockHealth{}, &mockPause{})
	path := filepath.Join(t.TempDir(), "settings.json")
	eng.SetConfigPath(path)

	cfg := config.Default()
	cfg.AutoConnectUntrusted = true
	cfg.TrustedNetworkPrefixes = []string{"10.10.1."}
	cfg.HealthCheckIntervalSeconds = 17
	if err := eng.UpdateConfig(cfg); err != nil {
		t.Fatal(err)
	}
	got, err := config.LoadRuntime(path)
	if err != nil {
		t.Fatal(err)
	}
	if !got.AutoConnectUntrusted || !reflect.DeepEqual(got.TrustedNetworkPrefixes, []string{"10.10.1."}) {
		t.Fatalf("persisted config mismatch: %#v", got)
	}
	if got.HealthCheckIntervalSeconds != 17 {
		t.Fatalf("health interval not persisted: %d", got.HealthCheckIntervalSeconds)
	}
}

func TestHealthRestartFailureKeepsRetrySoon(t *testing.T) {
	tun := &mockTunnel{state: tunnel.StateConnected, connectErr: errors.New("temporary network down")}
	cfg := config.Default()
	cfg.DesiredVPNEnabled = true
	eng := New(cfg, mockLocation{trusted: false}, tun, mockHealth{connected: false}, &mockPause{})

	for i := 0; i < maxHealthFailures; i++ {
		eng.lastHealthCheck = time.Time{}
		_ = eng.RunOnce()
	}
	if eng.autoFailures != 1 {
		t.Fatalf("健康重启失败后应计入自动重试: %d", eng.autoFailures)
	}
	if eng.nextAutoAttempt.IsZero() || time.Until(eng.nextAutoAttempt) > 11*time.Second {
		t.Fatalf("首次失败退避不应太久: %v", eng.nextAutoAttempt)
	}
}

func TestRunOnceTransientHealthFailureRecovers(t *testing.T) {
	tun := &mockTunnel{state: tunnel.StateConnected}
	health := &mutableHealth{connected: false}
	cfg := config.Default()
	cfg.DesiredVPNEnabled = true
	eng := New(cfg, mockLocation{trusted: false}, tun, health, &mockPause{})
	if err := eng.RunOnce(); err != nil {
		t.Fatal(err)
	}
	health.connected = true
	eng.lastHealthCheck = time.Time{}
	if err := eng.RunOnce(); err != nil {
		t.Fatal(err)
	}
	if eng.healthFailures != 0 || !eng.lastAutoUp.IsZero() {
		t.Fatalf("transient failure should recover without reconnect: %#v", eng)
	}
}

func TestRunOnceUntrustedConnectedHealthy(t *testing.T) {
	tun := &mockTunnel{state: tunnel.StateConnected}
	// health 报告通 → 正常，不动
	cfg := config.Default()
	cfg.DesiredVPNEnabled = true
	eng := New(cfg, mockLocation{trusted: false}, tun, mockHealth{connected: true}, &mockPause{})
	if err := eng.RunOnce(); err != nil {
		t.Fatal(err)
	}
	if tun.state != tunnel.StateConnected {
		t.Error("健康连接不应被干扰")
	}
}

func TestNetworkChangeRestartsStaleUntrustedTunnelImmediately(t *testing.T) {
	tun := &countingTunnel{mockTunnel: mockTunnel{state: tunnel.StateConnected}}
	cfg := config.Default()
	cfg.DesiredVPNEnabled = true
	network := "ip=en0=192.168.2.20|route=en0@192.168.2.1|dns=192.168.2.1"
	eng := New(cfg, mockLocation{trusted: false}, tun, mockHealth{connected: false}, &mockPause{})
	eng.SetNetworkSnapshotFunc(func() string { return network })

	if err := eng.RunOnNetworkChange(); err != nil {
		t.Fatal(err)
	}
	if tun.connects != 0 || tun.disconnects != 0 {
		t.Fatalf("first network snapshot should only establish baseline: connects=%d disconnects=%d", tun.connects, tun.disconnects)
	}

	network = "ip=en0=192.168.3.20|route=en0@192.168.3.1|dns=192.168.3.1"
	if err := eng.RunOnNetworkChange(); err != nil {
		t.Fatal(err)
	}
	if tun.disconnects != 1 || tun.connects != 1 {
		t.Fatalf("stale tunnel should restart immediately after network change: connects=%d disconnects=%d", tun.connects, tun.disconnects)
	}
	if tun.state != tunnel.StateConnected || eng.healthFailures != 0 || eng.lastAutoUp.IsZero() {
		t.Fatalf("restart did not reset tunnel health state: state=%s failures=%d lastAutoUp=%v", tun.state, eng.healthFailures, eng.lastAutoUp)
	}
}

func TestNetworkChangeRunsTrustedDisconnectPolicy(t *testing.T) {
	tun := &countingTunnel{mockTunnel: mockTunnel{state: tunnel.StateConnected}}
	cfg := config.Default()
	cfg.DesiredVPNEnabled = true
	cfg.DesiredGuardEnabled = true
	network := "ip=en0=192.168.2.20|route=en0@192.168.2.1|dns=192.168.2.1"
	loc := mockLocation{trusted: false}
	eng := New(cfg, loc, tun, mockHealth{connected: true}, &mockPause{})
	eng.SetNetworkSnapshotFunc(func() string { return network })

	if err := eng.RunOnNetworkChange(); err != nil {
		t.Fatal(err)
	}
	loc.trusted = true
	network = "ip=en0=10.10.1.22|route=en0@10.10.1.1|dns=10.10.1.1"
	eng.loc = loc
	if err := eng.RunOnNetworkChange(); err != nil {
		t.Fatal(err)
	}
	if tun.disconnects != 1 || tun.state != tunnel.StateDisconnected {
		t.Fatalf("trusted network change should disconnect guard-managed tunnel: disconnects=%d state=%s", tun.disconnects, tun.state)
	}
}

type byteTunnel struct {
	mockTunnel
	tx, rx uint64
}

func (m *byteTunnel) InterfaceBytes(string) (uint64, uint64) { return m.tx, m.rx }

func TestTrafficSpeedResetsWhenCountersDrop(t *testing.T) {
	tun := &byteTunnel{tx: 1000, rx: 5000}
	eng := New(config.Default(), mockLocation{}, tun, mockHealth{}, &mockPause{})

	eng.UpdateTraffic()
	time.Sleep(20 * time.Millisecond)
	tun.tx, tun.rx = 2000, 9000
	eng.UpdateTraffic()
	if s := eng.TrafficStats(); s.TxSpeed <= 0 || s.RxSpeed <= 0 {
		t.Fatalf("有流量时速度应大于 0: %+v", s)
	}

	time.Sleep(20 * time.Millisecond)
	tun.tx, tun.rx = 0, 0 // 隧道断开，接口计数清零
	eng.UpdateTraffic()
	if s := eng.TrafficStats(); s.TxSpeed != 0 || s.RxSpeed != 0 {
		t.Fatalf("计数回退后速度应归零，不应停留在旧值: %+v", s)
	}
}

// coveredTunnel 是能报告覆盖范围和收发统计的隧道。
type coveredTunnel struct {
	mockTunnel
	full  bool
	stats tunnel.RuntimeStats
}

func (c *coveredTunnel) Coverage(string) tunnel.Coverage {
	return tunnel.Coverage{FullTunnel: c.full}
}
func (c *coveredTunnel) Endpoints() []string { return nil }
func (c *coveredTunnel) RuntimeStats(string) (tunnel.RuntimeStats, error) {
	return c.stats, nil
}

func TestSplitTunnelIgnoresInternetProbe(t *testing.T) {
	tun := &coveredTunnel{mockTunnel: mockTunnel{state: tunnel.StateConnected}}
	tun.stats.LastHandshakeUnix = time.Now().Unix()
	cfg := config.Default()
	cfg.DesiredVPNEnabled = true
	eng := New(cfg, mockLocation{trusted: false}, tun, mockHealth{connected: false}, &mockPause{})
	for i := 0; i < maxHealthFailures+1; i++ {
		eng.lastHealthCheck = time.Time{}
		tun.stats.PeerTxBytes += 100
		tun.stats.PeerRxBytes += 100
		if err := eng.RunOnce(); err != nil {
			t.Fatal(err)
		}
		if eng.healthFailures != 0 {
			t.Fatalf("分流隧道不该因外网探测失败计数: %d", eng.healthFailures)
		}
	}
}

func TestFullTunnelStillProbesInternet(t *testing.T) {
	tun := &coveredTunnel{mockTunnel: mockTunnel{state: tunnel.StateConnected}, full: true}
	cfg := config.Default()
	cfg.DesiredVPNEnabled = true
	eng := New(cfg, mockLocation{trusted: false}, tun, mockHealth{connected: false}, &mockPause{})
	if err := eng.RunOnce(); err != nil {
		t.Fatal(err)
	}
	if eng.healthFailures != 1 {
		t.Fatalf("全局隧道探测失败应计数: %d", eng.healthFailures)
	}
}

func TestSplitTunnelStale(t *testing.T) {
	now := time.Unix(1_000_000, 0)
	old := now.Add(-staleHandshakeAge - time.Second).Unix()
	fresh := now.Add(-time.Minute).Unix()
	cases := []struct {
		name  string
		stats tunnel.RuntimeStats
		want  bool
	}{
		{"发了没收且握手过期", tunnel.RuntimeStats{PeerTxBytes: 200, PeerRxBytes: 50, LastHandshakeUnix: old}, true},
		{"空闲", tunnel.RuntimeStats{PeerTxBytes: 100, PeerRxBytes: 50, LastHandshakeUnix: old}, false},
		{"有回包", tunnel.RuntimeStats{PeerTxBytes: 200, PeerRxBytes: 60, LastHandshakeUnix: old}, false},
		{"握手还新", tunnel.RuntimeStats{PeerTxBytes: 200, PeerRxBytes: 50, LastHandshakeUnix: fresh}, false},
	}
	for _, c := range cases {
		if got := splitTunnelStale(c.stats, 100, 50, now); got != c.want {
			t.Errorf("%s: got %v, want %v", c.name, got, c.want)
		}
	}
}
