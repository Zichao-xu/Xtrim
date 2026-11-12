// Package policy 是智能管理策略引擎，整合 location/tunnel/healthcheck/pause。
// 对应 bash 守护的 run_once + daemon 循环，但跨平台、带假连接检测。
package policy

import (
	"context"
	"errors"
	"fmt"
	"log"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/wgsense/core/internal/config"
	"github.com/wgsense/core/internal/firewall"
	"github.com/wgsense/core/internal/healthcheck"
	"github.com/wgsense/core/internal/location"
	"github.com/wgsense/core/internal/logbuf"
	"github.com/wgsense/core/internal/netstate"
	"github.com/wgsense/core/internal/netwatch"
	"github.com/wgsense/core/internal/pause"
	"github.com/wgsense/core/internal/tunnel"
)

const maxHealthFailures = 5

// staleHandshakeAge 是分流隧道判定失效的握手年龄。WireGuard 会话 180 秒后作废，
// 有流量时会在此之前重新握手。
const staleHandshakeAge = 180 * time.Second

// 网络变化靠系统路由套接字通知驱动；定时检查只做兜底（通知丢失、变化时恰好有连接操作占锁）。
// 订阅失败时退回原来的高频轮询。
const (
	networkFallbackInterval = 15 * time.Second
	networkPollInterval     = 3 * time.Second
	networkSettleDelay      = time.Second
)

// ErrShuttingDown rejects new user operations after shutdown has begun.
var ErrShuttingDown = errors.New("daemon 正在退出，无法启动网络操作")

// ErrServiceMaintenance rejects new connections while the installer takes over.
var ErrServiceMaintenance = errors.New("系统服务正在维护，暂时无法启动网络操作")

// Engine 智能管理引擎。
type Engine struct {
	opMu sync.Mutex
	// These fields are protected by opMu. Shutdown is terminal; maintenance is
	// temporary and never changes the persisted connection or pause intent.
	shuttingDown       bool
	shutdownErr        error
	serviceMaintenance bool

	cfg             config.Config
	loc             location.Locator
	tun             tunnel.Manager
	hc              healthcheck.Checker
	pause           pause.Controller
	service         string
	passive         bool
	appOwned        bool
	lastAutoUp      time.Time
	lastHealthCheck time.Time
	healthFailures  int
	healthTx        uint64
	healthRx        uint64
	autoFailures    int
	nextAutoAttempt time.Time
	configPath      string
	exitPath        string
	exit            atomic.Value // string，见 exit.go：必须能在持有 opMu 时读
	mihomoExit      ExitBackend
	ipv6Path        string
	networkSnapshot func() string
	lastNetwork     string
	fw              *firewall.Controller

	// 巡检日志去重：状态不变时只按心跳间隔记一行，防止日志无限膨胀。
	lastTickKey string
	lastTickLog time.Time

	// 日志缓冲（供 /api/logs 使用）
	LogBuf *logbuf.Buffer

	// 流量统计
	trafficMu   sync.RWMutex
	lastTxBytes uint64
	lastRxBytes uint64
	lastTxTime  time.Time
	txSpeed     float64 // bytes/sec
	rxSpeed     float64 // bytes/sec
}

// New 创建引擎。
func New(cfg config.Config, loc location.Locator, tun tunnel.Manager, hc healthcheck.Checker, p pause.Controller) *Engine {
	cfg.Normalize()
	return &Engine{
		cfg:             cfg,
		loc:             loc,
		tun:             tun,
		hc:              hc,
		pause:           p,
		networkSnapshot: netstate.Fingerprint,
		LogBuf:          logbuf.New(200),
	}
}

// SetService 设置当前管理的隧道/profile 名。
func (e *Engine) SetService(s string) { e.service = s }

// SetPassive marks an API-only engine that must never create a tunnel.
func (e *Engine) SetPassive(passive bool) { e.passive = passive }

// SetAppOwned marks a daemon that was started for the current GUI app session.
func (e *Engine) SetAppOwned(appOwned bool) { e.appOwned = appOwned }

// SetFirewall attaches the machine-wide outbound blocker. Its rules do not
// depend on network or tunnel state; ticks only refresh interfaces and the
// WireGuard endpoint address.
func (e *Engine) SetFirewall(fw *firewall.Controller) { e.fw = fw }

// Firewall returns the attached blocker, or nil.
func (e *Engine) Firewall() *firewall.Controller { return e.fw }

func (e *Engine) syncFirewallNow() {
	if e.fw != nil {
		_ = e.fw.Sync()
	}
}

// SetConfigPath enables persistence for runtime configuration changes.
func (e *Engine) SetConfigPath(path string) { e.configPath = path }

// SetIPv6SettingsPath sets where tunnel IPv6 settings are persisted.
func (e *Engine) SetIPv6SettingsPath(path string) { e.ipv6Path = path }

// ErrIPv6Unsupported is returned when the tunnel platform has no IPv6 settings.
var ErrIPv6Unsupported = errors.New("当前平台不支持隧道 IPv6 设置")

// IPv6Settings returns the tunnel's public IPv6 settings.
func (e *Engine) IPv6Settings() (tunnel.IPv6Settings, error) {
	configurable, ok := e.tun.(tunnel.IPv6Configurable)
	if !ok {
		return tunnel.IPv6Settings{}, ErrIPv6Unsupported
	}
	return configurable.IPv6Settings(), nil
}

// UpdateIPv6Settings validates, persists and applies new IPv6 settings. Mode
// and probe targets apply to the live tunnel; the prefix applies on reconnect.
func (e *Engine) UpdateIPv6Settings(s tunnel.IPv6Settings) error {
	configurable, ok := e.tun.(tunnel.IPv6Configurable)
	if !ok {
		return ErrIPv6Unsupported
	}
	s = s.Normalized()
	if err := s.Validate(); err != nil {
		return err
	}
	if e.ipv6Path != "" {
		if err := tunnel.SaveIPv6Settings(e.ipv6Path, s); err != nil {
			return err
		}
	}
	if err := configurable.SetIPv6Settings(s); err != nil {
		return err
	}
	e.Logf("隧道 IPv6 设置已更新: 模式=%s 前缀=%s 探测=%s", s.Mode, s.Prefix, strings.Join(s.ProbeTargets, ","))
	return nil
}

// SetNetworkSnapshotFunc overrides network fingerprinting for tests.
func (e *Engine) SetNetworkSnapshotFunc(fn func() string) {
	if fn == nil {
		e.networkSnapshot = netstate.Fingerprint
		return
	}
	e.networkSnapshot = fn
}

func (e *Engine) saveCurrentConfig() error {
	if e.configPath == "" {
		return nil
	}
	return config.SaveRuntime(e.configPath, e.cfg)
}

// RunOnce 执行一次巡检。
// 逻辑：
//   - 受信任网络 → 断开 WG
//   - 非受信任网络 + 已暂停 → 跳过
//   - 非受信任网络 + Disconnected + AutoConnectUntrusted → 自动连上
//   - 非受信任网络 + Connected → 假连接检测，失效则强制 stop/start
func (e *Engine) RunOnce() error {
	if !e.opMu.TryLock() {
		e.Logf("已有连接操作进行中，跳过本轮巡检")
		return nil
	}
	defer e.opMu.Unlock()
	if e.shuttingDown || e.serviceMaintenance {
		return nil
	}
	return e.runOnceLocked()
}

// RunOnNetworkChange applies policy immediately when IP, route, or DNS changes.
func (e *Engine) RunOnNetworkChange() error {
	if !e.opMu.TryLock() {
		e.Logf("已有连接操作进行中，跳过本轮网络变化检查")
		return nil
	}
	defer e.opMu.Unlock()
	if e.shuttingDown || e.serviceMaintenance {
		return nil
	}
	return e.runOnNetworkChangeLocked()
}

func (e *Engine) runOnNetworkChangeLocked() error {
	current := e.currentNetworkSnapshot()
	if current == "" {
		return nil
	}
	if e.lastNetwork == "" {
		e.lastNetwork = current
		return nil
	}
	if current == e.lastNetwork {
		return nil
	}
	e.Logf("检测到网络变化，立即应用隧道策略")
	e.lastNetwork = current
	e.lastHealthCheck = time.Time{}

	trusted := e.loc.IsHome(e.cfg.TrustedNetworkPrefixes)
	state, _ := e.tun.Status(e.service)
	if e.exitLocked() == ExitWireGuard && !trusted && state == tunnel.StateConnected && e.shouldKeepVPNUp(trusted) {
		e.Logf("网络变化后验证隧道健康")
		e.lastHealthCheck = time.Now()
		if e.tunnelStale() {
			e.Logf("网络变化后隧道不可达，立即重启 WireGuard")
			_ = e.tun.Disconnect(e.service)
			if err := e.tun.Connect(e.service); err != nil {
				e.recordAutoFailure()
				return err
			}
			e.lastAutoUp = time.Now()
			e.healthFailures = 0
			e.autoFailures = 0
			e.nextAutoAttempt = time.Time{}
			return nil
		}
		e.healthFailures = 0
	}
	return e.runOnceLocked()
}

func (e *Engine) currentNetworkSnapshot() string {
	if e.networkSnapshot == nil {
		return ""
	}
	return e.networkSnapshot()
}

func (e *Engine) runOnceLocked() error {
	err := e.applyPolicyLocked()
	e.syncFirewallNow()
	return err
}

func (e *Engine) applyPolicyLocked() error {
	// 出口不是 WireGuard：保证隧道断开，WireGuard 的自动策略整体不跑。
	if handled, err := e.enforceExitLocked(); handled {
		return err
	}
	// 没有任何保持连接的用户意图，或显式暂停时，跳过自动管理。VPN/守护意图仍
	// 保留，失败只进入等待/重试，不把开关意图改回关闭。
	if (!e.cfg.DesiredGuardEnabled && !e.cfg.DesiredVPNEnabled && !e.cfg.AutoConnectUntrusted) || e.pause.IsPaused() {
		state, _ := e.tun.Status(e.service)
		reason := "未要求保持连接"
		if e.pause.IsPaused() {
			reason = "已暂停"
		}
		trusted := e.loc.IsHome(e.cfg.TrustedNetworkPrefixes)
		key := fmt.Sprintf("%v|%s|%s|%s", trusted, state, e.service, reason)
		if e.shouldLogTick(key) {
			e.Logf("巡检 trusted=%v state=%s service=%s（%s，跳过自动策略）",
				trusted, state, e.service, reason)
		}
		return nil
	}

	trusted := e.loc.IsHome(e.cfg.TrustedNetworkPrefixes)
	state, _ := e.tun.Status(e.service)
	e.logTick(trusted, state)

	// 受信任网络 → 守护策略优先断开隧道；未开启守护时，保留用户手动
	// 要求 VPN 保持开启的意图。
	if trusted {
		if state != tunnel.StateDisconnected && !e.shouldKeepVPNUp(trusted) {
			e.Logf("命中受信任网络，断开 WireGuard")
			return e.tun.Disconnect(e.service)
		}
		return nil
	}

	// 非受信任网络：根据隧道状态处理
	switch state {
	case tunnel.StateDisconnected:
		e.healthFailures = 0
		if !e.shouldKeepVPNUp(trusted) {
			e.Logf("当前网络不在受信任前缀内，自动连接未启用")
			return nil
		}
		if e.recentAutoUp() {
			e.Logf("刚自动拉起，等待连接建立")
			return nil
		}
		if !e.nextAutoAttempt.IsZero() && time.Now().Before(e.nextAutoAttempt) {
			e.Logf("自动连接退避中，等待下次尝试")
			return nil
		}
		e.Logf("当前网络不在受信任前缀内，自动连接 WireGuard")
		if err := e.tun.Connect(e.service); err != nil {
			e.recordAutoFailure()
			return err
		}
		e.autoFailures = 0
		e.nextAutoAttempt = time.Time{}
		e.lastAutoUp = time.Now()

	case tunnel.StateConnected:
		// 假连接检测（bash 守护没做的）
		// 刚连接后给 15 秒握手宽限期，不要立刻判定假连接
		if e.recentAutoUp() {
			e.Logf("刚连接，等待握手（跳过假连接检测）")
			return nil
		}
		if !e.healthCheckDue() {
			return nil
		}
		e.lastHealthCheck = time.Now()
		if e.tunnelStale() {
			e.healthFailures++
			e.Logf("隧道连通性探测失败（%d/%d）", e.healthFailures, maxHealthFailures)
		} else {
			e.healthFailures = 0
		}
		if e.healthFailures >= maxHealthFailures {
			e.Logf("连续 %d 次探测失败，重启隧道", maxHealthFailures)
			_ = e.tun.Disconnect(e.service)
			if err := e.tun.Connect(e.service); err != nil {
				e.recordAutoFailure()
				return err
			}
			e.lastAutoUp = time.Now()
			e.healthFailures = 0
			e.autoFailures = 0
			e.nextAutoAttempt = time.Time{}
		}
	}
	return nil
}

const tickLogHeartbeat = 10 * time.Minute

// shouldLogTick 在巡检结果变化或心跳到期时返回 true。
func (e *Engine) shouldLogTick(key string) bool {
	now := time.Now()
	if key == e.lastTickKey && now.Sub(e.lastTickLog) < tickLogHeartbeat {
		return false
	}
	e.lastTickKey = key
	e.lastTickLog = now
	return true
}

func (e *Engine) logTick(trusted bool, state tunnel.State) {
	key := fmt.Sprintf("%v|%s|%s", trusted, state, e.service)
	if !e.shouldLogTick(key) {
		return
	}
	e.Logf("巡检 trusted=%v state=%s service=%s", trusted, state, e.service)
}

func (e *Engine) shouldKeepVPNUp(trusted bool) bool {
	if trusted && e.cfg.DesiredGuardEnabled {
		return false
	}
	if e.cfg.DesiredVPNEnabled {
		return true
	}
	return !trusted && (e.cfg.DesiredGuardEnabled || e.cfg.AutoConnectUntrusted)
}

func (e *Engine) recordAutoFailure() {
	e.autoFailures++
	delay := time.Duration(10) * time.Second
	switch {
	case e.autoFailures >= 5:
		delay = time.Minute
	case e.autoFailures >= 3:
		delay = 30 * time.Second
	case e.autoFailures >= 2:
		delay = 20 * time.Second
	}
	e.nextAutoAttempt = time.Now().Add(delay)
	e.Logf("自动连接失败（%d），退避 %s", e.autoFailures, delay)
}

// tunnelStale 判断已连接的隧道是否失效。全局隧道探测外网；分流隧道不接管外网，
// 探测目标不经隧道，结果与隧道无关，所以只看隧道自身的收发和握手。
func (e *Engine) tunnelStale() bool {
	coverage, ok := e.tun.(tunnel.CoverageProvider)
	if !ok || coverage.Coverage(e.service).FullTunnel {
		return e.hc.IsStaleConnected(true)
	}
	provider, ok := e.tun.(tunnel.RuntimeStatsProvider)
	if !ok {
		return false
	}
	stats, err := provider.RuntimeStats(e.service)
	if err != nil {
		return false
	}
	prevTx, prevRx := e.healthTx, e.healthRx
	e.healthTx, e.healthRx = stats.PeerTxBytes, stats.PeerRxBytes
	return splitTunnelStale(stats, prevTx, prevRx, time.Now())
}

// splitTunnelStale 要求一直在发、完全没收到、且握手已过期。空闲隧道没有流量也
// 不会重新握手，这是正常状态，不能算失效。
func splitTunnelStale(stats tunnel.RuntimeStats, prevTx, prevRx uint64, now time.Time) bool {
	sending := stats.PeerTxBytes > prevTx
	silent := stats.PeerRxBytes == prevRx
	expired := now.Sub(time.Unix(stats.LastHandshakeUnix, 0)) > staleHandshakeAge
	return sending && silent && expired
}

func (e *Engine) healthCheckDue() bool {
	interval := e.cfg.HealthCheckIntervalSeconds
	if interval <= 0 {
		interval = 30
	}
	return e.lastHealthCheck.IsZero() || time.Since(e.lastHealthCheck) >= time.Duration(interval)*time.Second
}

// recentAutoUp 判断是否刚自动拉起（在宽限期内）。
func (e *Engine) recentAutoUp() bool {
	if e.lastAutoUp.IsZero() {
		return false
	}
	return time.Since(e.lastAutoUp) < time.Duration(e.cfg.AutoUpGraceSeconds)*time.Second
}

// Start 启动守护循环，每 IntervalSeconds 秒巡检一次。
func (e *Engine) Start(ctx context.Context) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	ticker := time.NewTicker(time.Duration(e.cfg.IntervalSeconds) * time.Second)
	defer ticker.Stop()
	networkTicker := time.NewTicker(networkFallbackInterval)
	defer networkTicker.Stop()
	changes, err := netwatch.Watch(ctx)
	if err != nil {
		e.Logf("订阅系统网络变化失败，退回 %s 轮询: %v", networkPollInterval, err)
		networkTicker.Reset(networkPollInterval)
	}
	// 一次切网会连发多条通知（地址删、加、路由改），等稳定后只检查一次。
	var settle <-chan time.Time

	// 立即执行一次
	if err := ctx.Err(); err != nil {
		return err
	}
	if err := e.RunOnce(); err != nil {
		e.Logf("巡检错误: %v", err)
	}

	checkNetwork := func() error {
		if err := ctx.Err(); err != nil {
			return err
		}
		if err := e.RunOnNetworkChange(); err != nil {
			e.Logf("网络变化处理错误: %v", err)
		}
		return nil
	}

	for {
		select {
		case <-ticker.C:
			if err := ctx.Err(); err != nil {
				return err
			}
			if err := e.RunOnce(); err != nil {
				e.Logf("巡检错误: %v", err)
			}
		case _, ok := <-changes:
			if !ok {
				changes = nil
				if ctx.Err() == nil {
					e.Logf("系统网络变化订阅中断，退回 %s 轮询", networkPollInterval)
					networkTicker.Reset(networkPollInterval)
				}
				continue
			}
			location.Invalidate()
			if settle == nil {
				settle = time.After(networkSettleDelay)
			}
		case <-settle:
			settle = nil
			if err := checkNetwork(); err != nil {
				return err
			}
		case <-networkTicker.C:
			if err := checkNetwork(); err != nil {
				return err
			}
		case <-ctx.Done():
			return ctx.Err()
		}
	}
}

// StatusSnapshot 是当前状态快照，供 UI 查询。
type StatusSnapshot struct {
	TrustedNetwork       bool   `json:"trusted_network"`
	AtHome               bool   `json:"at_home"`
	State                string `json:"state"`
	Paused               bool   `json:"paused"`
	DesiredVPNEnabled    bool   `json:"desired_vpn_enabled"`
	DesiredGuardEnabled  bool   `json:"desired_guard_enabled"`
	Service              string `json:"service"`
	Passive              bool   `json:"passive"`
	AutoConnectUntrusted bool   `json:"auto_connect_untrusted"`
	Auto                 bool   `json:"auto_connect_away"`
	AppOwned             bool   `json:"app_owned"`
	HealthFailures       int    `json:"health_failures"`
	AutoFailures         int    `json:"auto_failures"`
	NextAutoAttempt      string `json:"next_auto_attempt,omitempty"`
	LastHealthCheck      string `json:"last_health_check,omitempty"`
	LastAutoUp           string `json:"last_auto_up,omitempty"`
	TunnelInterface      string `json:"tunnel_interface,omitempty"`
	LastHandshake        string `json:"last_handshake,omitempty"`
	LastHandshakeAge     int64  `json:"last_handshake_age_seconds,omitempty"`
	PeerTxBytes          uint64 `json:"peer_tx_bytes,omitempty"`
	PeerRxBytes          uint64 `json:"peer_rx_bytes,omitempty"`
	BindRebinds          int    `json:"bind_rebinds,omitempty"`
	// Coverage 说明隧道接管了什么、哪些不走隧道以及原因。
	Coverage          *tunnel.Coverage     `json:"coverage,omitempty"`
	NetworkInterfaces []location.Interface `json:"network_interfaces,omitempty"`
	Firewall          *firewall.Status     `json:"firewall,omitempty"`
	// Exit 当前出口：wireguard / mihomo（tailscale 预留）。三者互斥。
	Exit string `json:"exit"`
}

// Status 返回当前状态快照。
func (e *Engine) Status() StatusSnapshot {
	state, _ := e.tun.Status(e.service)
	trusted := e.loc.IsHome(e.cfg.TrustedNetworkPrefixes)
	snapshot := StatusSnapshot{
		TrustedNetwork:       trusted,
		AtHome:               trusted,
		State:                string(state),
		Paused:               e.pause.IsPaused(),
		DesiredVPNEnabled:    e.shouldKeepVPNUp(trusted),
		DesiredGuardEnabled:  e.cfg.DesiredGuardEnabled,
		Service:              e.service,
		Passive:              e.passive,
		AutoConnectUntrusted: e.cfg.AutoConnectUntrusted,
		Auto:                 e.cfg.AutoConnectUntrusted,
		AppOwned:             e.appOwned,
		HealthFailures:       e.healthFailures,
		AutoFailures:         e.autoFailures,
		NetworkInterfaces:    e.loc.ActiveInterfaces(),
		Exit:                 e.exitLocked(),
	}
	if e.fw != nil {
		status := e.fw.Status()
		snapshot.Firewall = &status
	}
	if !e.nextAutoAttempt.IsZero() {
		snapshot.NextAutoAttempt = e.nextAutoAttempt.Format(time.RFC3339)
	}
	if !e.lastHealthCheck.IsZero() {
		snapshot.LastHealthCheck = e.lastHealthCheck.Format(time.RFC3339)
	}
	if !e.lastAutoUp.IsZero() {
		snapshot.LastAutoUp = e.lastAutoUp.Format(time.RFC3339)
	}
	if provider, ok := e.tun.(tunnel.CoverageProvider); ok {
		coverage := provider.Coverage(e.service)
		snapshot.Coverage = &coverage
	}
	if provider, ok := e.tun.(tunnel.RuntimeStatsProvider); ok {
		if stats, err := provider.RuntimeStats(e.service); err == nil {
			snapshot.TunnelInterface = stats.InterfaceName
			snapshot.PeerTxBytes = stats.PeerTxBytes
			snapshot.PeerRxBytes = stats.PeerRxBytes
			snapshot.BindRebinds = stats.BindRebinds
			if stats.LastHandshakeUnix > 0 {
				handshake := time.Unix(stats.LastHandshakeUnix, 0)
				snapshot.LastHandshake = handshake.Format(time.RFC3339)
				snapshot.LastHandshakeAge = int64(time.Since(handshake).Seconds())
			}
		}
	}
	return snapshot
}

// Connect 手动连接隧道。
func (e *Engine) Connect() error {
	e.opMu.Lock()
	defer e.opMu.Unlock()
	if e.shuttingDown {
		return ErrShuttingDown
	}
	if e.serviceMaintenance {
		return ErrServiceMaintenance
	}
	if e.exitLocked() != ExitWireGuard {
		return ErrExitNotWireGuard
	}
	e.cfg.DesiredVPNEnabled = true
	if err := e.saveCurrentConfig(); err != nil {
		return err
	}
	if e.passive {
		return fmt.Errorf("daemon 处于被动模式，WireGuard 连接需要正式网络服务")
	}
	// Explicitly enabling VPN supersedes a previous automation pause. Without
	// clearing its marker, a daemon restart kept the VPN intent but skipped every
	// reconnect forever while the UI continued to show it enabled.
	if err := e.pause.Resume(); err != nil {
		return err
	}
	state, _ := e.tun.Status(e.service)
	if state == tunnel.StateConnected {
		e.lastAutoUp = time.Now()
		e.healthFailures = 0
		e.autoFailures = 0
		e.nextAutoAttempt = time.Time{}
		e.Logf("WireGuard 已连接，跳过重复连接")
		return nil
	}
	if err := e.tun.Connect(e.service); err != nil {
		return err
	}
	e.lastAutoUp = time.Now()
	e.healthFailures = 0
	e.autoFailures = 0
	e.nextAutoAttempt = time.Time{}
	return nil
}

// Disconnect 手动断开隧道。
func (e *Engine) Disconnect() error {
	e.opMu.Lock()
	defer e.opMu.Unlock()
	e.cfg.DesiredVPNEnabled = false
	if err := e.saveCurrentConfig(); err != nil {
		return err
	}
	e.healthFailures = 0
	return e.tun.Disconnect(e.service)
}

// BeginServiceMaintenance reserves a disconnected engine for an installer.
// Checking the tunnel and closing connection entry points under the same lock
// prevents a queued connect or policy tick from starting VPN during handoff.
func (e *Engine) BeginServiceMaintenance() error {
	e.opMu.Lock()
	defer e.opMu.Unlock()
	if e.shuttingDown {
		return ErrShuttingDown
	}
	if e.serviceMaintenance {
		return ErrServiceMaintenance
	}
	state, err := e.tun.Status(e.service)
	if err != nil {
		return fmt.Errorf("无法确认 VPN 已断开: %w", err)
	}
	if state != tunnel.StateDisconnected {
		return fmt.Errorf("请先关闭 VPN 再维护系统服务（当前状态: %s）", state)
	}
	e.serviceMaintenance = true
	return nil
}

// EndServiceMaintenance lets later policy ticks use the existing user intent.
// It does not reopen an engine that has already begun shutting down.
func (e *Engine) EndServiceMaintenance() {
	e.opMu.Lock()
	defer e.opMu.Unlock()
	e.serviceMaintenance = false
}

// ShutdownCleanup disconnects the underlying tunnel while preserving user
// intent. This engine cannot connect again after cleanup begins. Repeated calls
// wait for the first cleanup and return its result without running it again.
// Use it for daemon shutdown/restart paths, not a user-requested disconnect.
func (e *Engine) ShutdownCleanup() error {
	e.opMu.Lock()
	defer e.opMu.Unlock()
	if e.shuttingDown {
		return e.shutdownErr
	}
	e.shuttingDown = true
	e.healthFailures = 0
	e.shutdownErr = e.tun.Disconnect(e.service)
	return e.shutdownErr
}

// Pause 暂停自动管理。
func (e *Engine) Pause() error {
	e.opMu.Lock()
	defer e.opMu.Unlock()
	e.cfg.DesiredGuardEnabled = false
	e.cfg.AutoConnectUntrusted = false
	e.cfg.AutoConnectAway = false
	if err := e.saveCurrentConfig(); err != nil {
		return err
	}
	return e.pause.Pause()
}

// Resume 恢复自动管理。
func (e *Engine) Resume() error {
	e.opMu.Lock()
	if e.shuttingDown {
		e.opMu.Unlock()
		return ErrShuttingDown
	}
	if e.serviceMaintenance {
		e.opMu.Unlock()
		return ErrServiceMaintenance
	}
	e.cfg.DesiredGuardEnabled = true
	e.cfg.AutoConnectUntrusted = true
	e.cfg.AutoConnectAway = true
	if err := e.saveCurrentConfig(); err != nil {
		e.opMu.Unlock()
		return err
	}
	if err := e.pause.Resume(); err != nil {
		e.opMu.Unlock()
		return err
	}
	e.opMu.Unlock()
	// 用户重新开启守护后立即应用网络策略，避免等待下一个巡检周期。
	return e.RunOnce()
}

// Profiles 返回可用 profile 列表(扫描配置目录)。
func (e *Engine) Profiles() []string {
	services, _ := e.tun.DiscoverServices()
	return services
}

// ConfigDir 返回配置目录路径。
func (e *Engine) ConfigDir() string {
	return e.tun.ConfigDir()
}

// ImportProfile 将 .conf 文本内容保存为新 profile。
func (e *Engine) ImportProfile(name, content string) error {
	return e.tun.SaveProfile(name, content)
}

// ExportProfile 读取指定 profile 的 .conf 文本内容。
func (e *Engine) ExportProfile(name string) (string, error) {
	return e.tun.LoadProfileContent(name)
}

// DeleteProfile 删除指定 profile。
func (e *Engine) DeleteProfile(name string) error {
	return e.tun.DeleteProfile(name)
}

// GetConfig 返回当前运行配置。
func (e *Engine) GetConfig() config.Config {
	e.opMu.Lock()
	defer e.opMu.Unlock()
	return e.cfg
}

// UpdateConfig 更新运行配置（热更新，不需要重启 daemon）。
func (e *Engine) UpdateConfig(cfg config.Config) error {
	e.opMu.Lock()
	defer e.opMu.Unlock()
	cfg.Normalize()
	if e.configPath != "" {
		if err := config.SaveRuntime(e.configPath, cfg); err != nil {
			return err
		}
	}
	e.cfg = cfg
	e.hc = healthcheck.New(cfg.HealthCheckTarget)
	e.lastHealthCheck = time.Time{}
	e.healthFailures = 0
	e.autoFailures = 0
	e.nextAutoAttempt = time.Time{}
	e.Logf("配置已更新: 间隔=%ds 宽限=%ds 探测=%s 受信任网络前缀=%v 自动连接非受信任网络=%t",
		cfg.IntervalSeconds, cfg.AutoUpGraceSeconds, cfg.HealthCheckTarget, cfg.TrustedNetworkPrefixes, cfg.AutoConnectUntrusted)
	return nil
}

// Logf 写日志到标准输出 + 缓冲区。
func (e *Engine) Logf(format string, args ...interface{}) {
	line := fmt.Sprintf(format, args...)
	log.Println(line)
	e.LogBuf.WriteLine(line)
}

// Logs 返回最近 n 行日志。
func (e *Engine) Logs(n int) []string {
	return e.LogBuf.LastN(n)
}

// TrafficSnapshot 是流量统计快照。
type TrafficSnapshot struct {
	TxSpeed float64 `json:"tx_speed"` // 上行 bytes/sec
	RxSpeed float64 `json:"rx_speed"` // 下行 bytes/sec
	TxBytes uint64  `json:"tx_bytes"` // 累计上行
	RxBytes uint64  `json:"rx_bytes"` // 累计下行
}

// TrafficStats 返回当前流量统计（通过 utun 接口读取）。
func (e *Engine) TrafficStats() TrafficSnapshot {
	e.trafficMu.RLock()
	defer e.trafficMu.RUnlock()
	return TrafficSnapshot{
		TxSpeed: e.txSpeed,
		RxSpeed: e.rxSpeed,
		TxBytes: e.lastTxBytes,
		RxBytes: e.lastRxBytes,
	}
}

// UpdateTraffic 从 tun 接口读取最新字节数并计算速度。
func (e *Engine) UpdateTraffic() {
	tx, rx := e.tun.InterfaceBytes(e.service)
	now := time.Now()

	e.trafficMu.Lock()
	defer e.trafficMu.Unlock()

	if !e.lastTxTime.IsZero() {
		dt := now.Sub(e.lastTxTime).Seconds()
		if dt > 0 {
			// 计数回退说明隧道断开或重建（接口字节数清零），此时速度归零，
			// 否则会一直停留在断开前最后一次的速度。
			if tx >= e.lastTxBytes {
				e.txSpeed = float64(tx-e.lastTxBytes) / dt
			} else {
				e.txSpeed = 0
			}
			if rx >= e.lastRxBytes {
				e.rxSpeed = float64(rx-e.lastRxBytes) / dt
			} else {
				e.rxSpeed = 0
			}
		}
	}
	e.lastTxBytes = tx
	e.lastRxBytes = rx
	e.lastTxTime = now
}
