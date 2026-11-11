// Package firewall 是整台电脑的出站拦截(pf)，与 WireGuard 链路和所在网络无关。
//
// 拦截境外直连：物理网卡上只放行国内 IP、局域网、网关 fake-ip 段和 WG 服务器，
// 其余一律拒绝。于是：
//   - WG 断开/重连空窗：直连境外(含 AI 服务)全被挡；
//   - 在家：境外流量解析成 fake-ip 交给网关代理，放行；拿真实境外 IP 直连的被挡；
//   - IPv6 同理，只放行国内段。
//
// 隧道锁定（默认开，与上面的开关独立）：WG 全局隧道连着时，物理网卡只放行
// 局域网和 WG 服务器。程序绑定物理网卡直连、或走路由表没覆盖到的路径，
// 都不能绕开隧道。隧道一拆除立即恢复，「有就用，没有就不用」。
//
// 国内模式把同一规则作用到所有接口(含隧道)，并且不放行 fake-ip。
//
// 规则是 fail-closed 的：daemon 退出不清理，只有关闭开关、卸载服务或
// 执行 `wgsense-daemon --firewall-clear` 才会解除。
package firewall

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// StateDir 存放 pf 规则、国内段表和 pf 启用令牌(root 持有，跨用户目录不变)。
var StateDir = "/Library/Application Support/WgSense/firewall"

// CNTablePath 是国内 IP 段表文件位置。
func CNTablePath() string { return filepath.Join(StateDir, "cn.txt") }

// Settings 是用户可改的拦截设置，单独持久化，避免被 /api/config 的整包同步覆盖。
type Settings struct {
	// Block 拦截物理网卡上的境外直连。沿用 v1.0.4 的字段名以保留已有开关。
	Block bool `json:"auto_block"`
	// ForceDomestic 国内模式：所有接口(含隧道)都只放行国内。
	ForceDomestic bool `json:"force_domestic"`
	// AllowBypass 关闭隧道锁定：隧道连着时仍按上面的规则放行物理网卡直连。
	// 默认 false（锁定），旧版设置文件没有这个字段，升级后即锁定。
	AllowBypass bool `json:"allow_bypass"`
	// BlockProbes 连诊断探测（出站 ICMP 回显请求，traceroute / ping）也拦。
	// 默认 false：普通拦截模式下放行探测，路由追踪能看到真实路径；国内模式与隧道锁定始终不放行。
	BlockProbes bool `json:"block_probes"`
	// AllowHosts 拦截境外直连时额外放行的域名或 IP（如本机代理软件直连的自建节点）。
	// 域名由 daemon 定时解析成 IP 写进规则；隧道锁定与国内模式下不放行。
	AllowHosts []string `json:"allow_hosts"`
}

// Status 是当前实际生效情况，供 UI 展示。
type Status struct {
	Active     bool     `json:"active"`
	Forced     bool     `json:"forced"`
	Reason     string   `json:"reason"`
	Interfaces []string `json:"interfaces,omitempty"` // 正在使用的网卡，仅供展示
	// Locked 隧道锁定或代理锁定正在生效（出口在线，物理网卡只放行局域网与出口自身）。
	Locked bool `json:"locked"`
	// LockKind 锁定的出口：tunnel（WireGuard）/ proxy（内置 mihomo）。
	LockKind string `json:"lock_kind,omitempty"`
	// BlockedPackets 自本套规则生效以来被拒绝的出站包数，非零说明有程序试图绕开。
	BlockedPackets uint64 `json:"blocked_packets"`
	// AllowedHosts 放行项当前解析到的地址，普通拦截模式下才有。
	AllowedHosts []AllowedHost `json:"allowed_hosts,omitempty"`
	Error        string        `json:"error,omitempty"`
	UpdatedAt    string        `json:"updated_at,omitempty"`
}

// Backend 执行真正的系统修改；测试里替换为假实现。
type Backend interface {
	ApplyPF(rules string) error
	ClearPF() error
	// RemoveLegacyHosts 清理 v1.0.4 写入 /etc/hosts 的域名拦截段。
	RemoveLegacyHosts() error
	// BlockedPackets 读取拒绝规则的累计命中包数。
	BlockedPackets() (uint64, error)
}

// Controller 根据设置维护 pf 锚点。
type Controller struct {
	mu       sync.Mutex
	path     string
	settings Settings
	backend  Backend
	logf     func(string, ...interface{})

	// 依赖探测，测试可替换。
	PhysicalInterfaces func() []string // 规则覆盖的全部物理网卡
	ActiveInterfaces   func() []string // 有地址、正在使用的网卡
	TunnelEndpoints    func() []string
	// TunnelLocked 报告全局隧道是否连着；为 true 且未关闭锁定时启用隧道锁定。
	TunnelLocked func() bool
	// ProxyLocked 报告内置代理内核是否正作为出口接管整机；为 true 时启用代理锁定：
	// 物理网卡只放行局域网与内核（nobody 组）自己的连接。
	ProxyLocked func() bool
	// ResolveHost 把放行域名解析成地址，失败返回空。
	ResolveHost func(string) []string

	appliedPF   string
	synced      bool
	status      Status
	countedAt   time.Time
	blockedSeen uint64
	hostCache   map[string]hostEntry
}

// counterInterval 限制读取拦截计数的频率（每次要启动 pfctl）。
const counterInterval = 30 * time.Second

// New 读取 path 的设置并创建控制器。logf 可为 nil。
func New(path string, backend Backend, logf func(string, ...interface{})) *Controller {
	if logf == nil {
		logf = func(string, ...interface{}) {}
	}
	c := &Controller{
		path:               path,
		backend:            backend,
		logf:               logf,
		PhysicalInterfaces: physicalInterfaces,
		ActiveInterfaces:   activeInterfaces,
		TunnelEndpoints:    func() []string { return nil },
		TunnelLocked:       func() bool { return false },
		ProxyLocked:        func() bool { return false },
		ResolveHost:        lookupHost,
	}
	if path != "" {
		if data, err := os.ReadFile(path); err == nil {
			if json.Unmarshal(data, &c.settings) != nil {
				logf("读取拦截设置失败，使用默认值: %s", path)
			}
		}
	}
	hosts, err := NormalizeHosts(c.settings.AllowHosts)
	if err != nil {
		logf("放行名单有无效项，已忽略: %v", err)
		hosts = []string{}
	}
	c.settings.AllowHosts = hosts
	return c
}

// Settings 返回当前设置。
func (c *Controller) Settings() Settings {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.settings
}

// Status 返回当前生效状态。
func (c *Controller) Status() Status {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.status
}

// Update 保存新设置并立即生效。
func (c *Controller) Update(s Settings) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	hosts, err := NormalizeHosts(s.AllowHosts)
	if err != nil {
		return err
	}
	s.AllowHosts = hosts
	if err := c.save(s); err != nil {
		return err
	}
	c.settings = s
	c.logf("拦截设置已更新: 拦截=%t 国内模式=%t 隧道锁定=%t 放行探测=%t 放行名单=%v", s.Block, s.ForceDomestic, !s.AllowBypass, !s.BlockProbes, s.AllowHosts)
	return c.syncLocked()
}

// Sync 按当前网卡与 WG 服务器地址刷新规则；内容不变时不触碰系统。
// daemon 启动时立即调用一次，之后随巡检调用。
func (c *Controller) Sync() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.syncLocked()
}

func (c *Controller) save(s Settings) error {
	if c.path == "" {
		return nil
	}
	if err := os.MkdirAll(filepath.Dir(c.path), 0755); err != nil {
		return err
	}
	data, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	tmp := c.path + ".tmp"
	if err := os.WriteFile(tmp, append(data, '\n'), 0600); err != nil {
		return err
	}
	return os.Rename(tmp, c.path)
}

func (c *Controller) syncLocked() error {
	s := c.settings
	status := Status{Forced: s.ForceDomestic, UpdatedAt: time.Now().Format(time.RFC3339)}
	var rules string
	switch {
	case s.ForceDomestic:
		status.Active, status.Reason = true, "国内模式：所有出口只放行国内"
		rules = RenderPF(RuleInput{Endpoints: c.TunnelEndpoints(), CNFile: CNTablePath()})
	case !s.AllowBypass && c.ProxyLocked():
		ifaces := c.PhysicalInterfaces()
		status.Active, status.Locked, status.LockKind = true, true, "proxy"
		status.Reason = "代理锁定：物理网卡只放行局域网与内置代理内核，其余必须走代理"
		if len(ifaces) == 0 {
			status.Reason += "（当前无物理网卡）"
		} else {
			rules = RenderPF(RuleInput{Interfaces: ifaces, LockTunnel: true, AllowGroup: "nobody", CNFile: CNTablePath()})
		}
	case !s.AllowBypass && c.TunnelLocked():
		ifaces := c.PhysicalInterfaces()
		status.Active, status.Locked, status.LockKind = true, true, "tunnel"
		status.Reason = "隧道锁定：物理网卡只放行局域网与 WG 服务器，其余必须走隧道"
		if len(ifaces) == 0 {
			status.Reason += "（当前无物理网卡）"
		} else {
			rules = RenderPF(RuleInput{Interfaces: ifaces, LockTunnel: true, Endpoints: c.TunnelEndpoints(), CNFile: CNTablePath()})
		}
	case s.Block:
		ifaces := c.PhysicalInterfaces()
		status.Active, status.Reason = true, "物理网卡只放行国内、局域网与 WG 服务器"
		if !s.BlockProbes {
			status.Reason += "；诊断探测（ICMP 回显）放行"
		}
		status.AllowedHosts = c.resolveAllowHosts(s.AllowHosts)
		endpoints := append([]string(nil), c.TunnelEndpoints()...)
		for _, host := range status.AllowedHosts {
			endpoints = append(endpoints, host.IPs...)
		}
		if len(status.AllowedHosts) > 0 {
			status.Reason += fmt.Sprintf("；另放行 %d 个自定义地址", len(status.AllowedHosts))
		}
		if len(ifaces) == 0 {
			status.Reason += "（当前无物理网卡）"
		} else {
			rules = RenderPF(RuleInput{Interfaces: ifaces, AllowFakeIP: true, Endpoints: endpoints, CNFile: CNTablePath(), AllowProbes: !s.BlockProbes})
		}
	default:
		status.Reason = "未开启拦截"
	}
	if status.Active {
		status.Interfaces = c.ActiveInterfaces()
	}

	reload := !c.synced || rules != c.appliedPF
	var errs []error
	if !c.synced {
		if err := c.backend.RemoveLegacyHosts(); err != nil {
			errs = append(errs, fmt.Errorf("hosts: %w", err))
		}
	}
	if !c.synced || rules != c.appliedPF {
		var err error
		if rules == "" {
			err = c.backend.ClearPF()
		} else {
			err = c.backend.ApplyPF(rules)
		}
		if err != nil {
			errs = append(errs, fmt.Errorf("pf: %w", err))
		} else {
			c.appliedPF = rules
		}
	}
	switch {
	case reload || rules == "":
		// 新加载的规则计数从零开始
		c.countedAt, c.blockedSeen = time.Now(), 0
	case time.Since(c.countedAt) >= counterInterval:
		if n, err := c.backend.BlockedPackets(); err == nil {
			c.countedAt, c.blockedSeen = time.Now(), n
		}
	}
	status.BlockedPackets = c.blockedSeen
	changed := !c.synced || c.status.Active != status.Active || c.status.Reason != status.Reason
	err := errors.Join(errs...)
	if err == nil {
		c.synced = true
	} else {
		status.Error = err.Error()
		c.logf("拦截规则应用失败: %v", err)
	}
	if err == nil && changed {
		if status.Active {
			c.logf("拦截已生效: %s", status.Reason)
		} else {
			c.logf("拦截已解除")
		}
	}
	c.status = status
	return err
}

// ClearAll 无条件移除所有拦截(卸载/应急)。
func ClearAll(b Backend) error {
	return errors.Join(b.ClearPF(), b.RemoveLegacyHosts())
}
