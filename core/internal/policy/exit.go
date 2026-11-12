package policy

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/wgsense/core/internal/tunnel"
)

// 出口：WireGuard、Tailscale、mihomo 三者互斥，同一时刻只有一个能接管流量。
// 本阶段只做手动切换；Tailscale 只占位，不能选。
//
// 出口选择单独存一个文件：/api/config 是整包同步，旧版 App 不带这个字段，
// 放在 settings.json 里会被悄悄冲回 WireGuard。
const (
	ExitWireGuard = "wireguard"
	ExitTailscale = "tailscale"
	ExitMihomo    = "mihomo"
)

// ExitBackend 是 WireGuard 以外的出口（目前只有内置 mihomo）。
type ExitBackend interface {
	// Ready 能否作为出口（如配置还没同步时返回原因）。
	Ready() error
	// Healthy 正在作为出口时是否健康（纯良据此休眠或接管）。
	Healthy() (bool, string)
	Start() error
	Stop() error
}

// ErrExitNotWireGuard 当前出口不是 WireGuard 时拒绝连接 WireGuard。
var ErrExitNotWireGuard = errors.New("当前出口不是 WireGuard，先切换出口")

type exitState struct {
	Exit string `json:"exit"`
}

// SetExitStore 设置出口选择的保存位置并读入（daemon 启动时调用）。
func (e *Engine) SetExitStore(path string) {
	e.exitPath = path
	e.exit.Store(ExitWireGuard)
	if data, err := os.ReadFile(path); err == nil {
		var s exitState
		if json.Unmarshal(data, &s) == nil && s.Exit == ExitMihomo {
			e.exit.Store(s.Exit)
		}
	}
}

// SetMihomoExit 接上内置 mihomo 出口。
func (e *Engine) SetMihomoExit(b ExitBackend) { e.mihomoExit = b }

// Exit 返回当前出口。无锁读取：出站拦截在策略巡检持有 opMu 时也会来问出口，
// 这里若再拿 opMu 就是自己等自己（v42 预览版切换 mihomo 时整个引擎卡死的原因）。
func (e *Engine) Exit() string { return e.exitLocked() }

func (e *Engine) exitLocked() string {
	if v, _ := e.exit.Load().(string); v != "" {
		return v
	}
	return ExitWireGuard
}

// ExitHealth 当前出口是否健康，给纯良的心跳用（每 3 秒）。
// 不拿 opMu：切换出口时引擎正持锁，心跳也必须能算，否则就是自己等自己。
func (e *Engine) ExitHealth() (exit string, online bool, detail string) {
	exit = e.exitLocked()
	if exit == ExitMihomo {
		if e.mihomoExit == nil {
			return exit, false, "没有内置内核"
		}
		online, detail = e.mihomoExit.Healthy()
		return exit, online, detail
	}
	state, _ := e.tun.Status(e.service)
	if state != tunnel.StateConnected {
		return exit, false, "WireGuard 未连接"
	}
	if p, ok := e.tun.(tunnel.CoverageProvider); ok && !p.Coverage(e.service).FullTunnel {
		return exit, false, "分流配置：境外流量不走隧道"
	}
	if p, ok := e.tun.(tunnel.RuntimeStatsProvider); ok {
		if st, err := p.RuntimeStats(e.service); err == nil && st.LastHandshakeUnix > 0 {
			age := time.Since(time.Unix(st.LastHandshakeUnix, 0))
			if age > exitHandshakeMaxAge {
				return exit, false, fmt.Sprintf("握手已 %d 秒未更新", int(age.Seconds()))
			}
			return exit, true, fmt.Sprintf("握手 %d 秒前", int(age.Seconds()))
		}
	}
	return exit, false, "等待首次握手"
}

// WireGuard 每 2 分钟左右重新握手一次；超过 3 分钟没有更新就当它掉了。
const exitHandshakeMaxAge = 180 * time.Second

// SetExit 手动切换出口：先拆旧出口，再起新出口。
// 拆与起之间出站拦截照常生效（隧道已断，物理网卡按无出口的规则放行），不会裸奔。
func (e *Engine) SetExit(exit string) error {
	e.opMu.Lock()
	defer e.opMu.Unlock()
	if e.shuttingDown {
		return ErrShuttingDown
	}
	if e.serviceMaintenance {
		return ErrServiceMaintenance
	}
	switch exit {
	case ExitWireGuard:
	case ExitMihomo:
		if e.mihomoExit == nil {
			return errors.New("这份网络服务没有内置代理内核")
		}
		// 先确认能接管，再拆 WireGuard：不能出现两个出口都没有的切换
		if err := e.mihomoExit.Ready(); err != nil {
			return err
		}
	case ExitTailscale:
		return errors.New("Tailscale 出口尚未接入")
	default:
		return fmt.Errorf("未知出口: %s", exit)
	}
	if exit == e.exitLocked() {
		return nil
	}
	if err := e.saveExit(exit); err != nil {
		return err
	}
	prev := e.exitLocked()
	e.exit.Store(exit)
	e.Logf("切换出口: %s → %s", prev, exit)

	switch exit {
	case ExitMihomo:
		// 先拆 WireGuard。保留 VPN 意图字段不动：它只在出口是 WireGuard 时生效。
		if state, _ := e.tun.Status(e.service); state != tunnel.StateDisconnected {
			if err := e.tun.Disconnect(e.service); err != nil {
				e.Logf("切换出口时断开 WireGuard 失败: %v", err)
			}
		}
		e.syncFirewallNow()
		if err := e.mihomoExit.Start(); err != nil {
			return fmt.Errorf("启动内置代理内核失败: %w", err)
		}
	case ExitWireGuard:
		if e.mihomoExit != nil {
			if err := e.mihomoExit.Stop(); err != nil {
				e.Logf("切换出口时停止内置代理内核失败: %v", err)
			}
		}
		// 切到 WireGuard 即表示要用它；在家且守护开着时仍按设计保持断开。
		e.cfg.DesiredVPNEnabled = true
		if err := e.saveCurrentConfig(); err != nil {
			return err
		}
		if err := e.pause.Resume(); err != nil {
			return err
		}
		// 出口已经切过来了；连接失败不算切换失败，守护会继续按策略重试。
		if err := e.runOnceLocked(); err != nil {
			e.Logf("已切到 WireGuard，但连接失败（守护会继续重试）: %v", err)
		}
	}
	return nil
}

func (e *Engine) saveExit(exit string) error {
	if e.exitPath == "" {
		return nil
	}
	if err := os.MkdirAll(filepath.Dir(e.exitPath), 0755); err != nil {
		return err
	}
	data, _ := json.Marshal(exitState{Exit: exit})
	tmp := e.exitPath + ".tmp"
	if err := os.WriteFile(tmp, append(data, '\n'), 0644); err != nil {
		return err
	}
	return os.Rename(tmp, e.exitPath)
}

// enforceExitLocked 出口不是 WireGuard 时保证隧道断开，并跳过 WireGuard 的自动策略。
// 返回 true 表示已处理，调用方不再继续 WireGuard 策略。
func (e *Engine) enforceExitLocked() (bool, error) {
	if e.exitLocked() == ExitWireGuard {
		return false, nil
	}
	state, _ := e.tun.Status(e.service)
	if state != tunnel.StateDisconnected {
		e.Logf("出口是 %s，断开 WireGuard", e.exitLocked())
		return true, e.tun.Disconnect(e.service)
	}
	return true, nil
}
