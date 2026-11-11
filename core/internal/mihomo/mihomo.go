// Package mihomo 管理 WgSense 内置的本机 mihomo 内核（自建 throughput 版）。
//
// 内核二进制编进 daemon（构建标签 mihomo_embed），由 daemon 释放到自己的目录再运行：
// 完整性随 daemon 自身的哈希一起校验，安装事务不用多管一个文件。
// 以 root 运行时目录归 root 所有；内核以 root 用户（创建 TUN 需要）、nobody 组运行，
// 出站拦截按 nobody 组放行它自己连节点的流量，其余程序绕不开它。
//
// 两种配置：
//   - 默认配置：只监听本机端口，不开 TUN、不接管 DNS，启停不影响本机网络；不能作为出口。
//   - 从 op 同步的配置（见 importer.go）：开 TUN 接管整机流量，并把系统 DNS 指向 TUN。
package mihomo

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
)

// DefaultRootDir 是 root 服务下内核的目录（二进制、配置、数据都在这里）。
const DefaultRootDir = "/Library/Application Support/WgSense/mihomo"

// 默认端口避开常见代理客户端（Clash 系 7890 / 9090）。
const (
	DefaultMixedPort  = 7895
	DefaultController = "127.0.0.1:9095"
)

// nobody 的 uid/gid（macOS 为 -2）。
const nobodyID = 4294967294

// Status 是给 UI 的内核状态。
type Status struct {
	// Bundled 这份 daemon 带了内核。false 时其余字段无意义。
	Bundled bool   `json:"bundled"`
	Version string `json:"version,omitempty"`
	// Desired 用户希望它运行（跨 daemon 重启保持）。
	Desired bool `json:"desired"`
	Running bool `json:"running"`
	PID     int  `json:"pid,omitempty"`
	// StartedAt 本次启动时间（RFC3339）。
	StartedAt  string `json:"started_at,omitempty"`
	Controller string `json:"controller"`
	MixedPort  int    `json:"mixed_port"`
	ConfigPath string `json:"config_path"`
	// User 内核以哪个身份运行。
	User string `json:"user,omitempty"`
	// LastExit 上次退出的原因（非用户停止时）。
	LastExit string `json:"last_exit,omitempty"`
	// Source 配置来源（从 op 同步时为 root@host:/etc/mihomo），空 = 默认配置，不能作为出口。
	Source   string `json:"source,omitempty"`
	SyncedAt string `json:"synced_at,omitempty"`
	// Dropped 同步时剔除的、只能在路由器上用的节点。
	Dropped []string `json:"dropped,omitempty"`
	// DNSService 正在被接管 DNS 的网络服务（如 Wi-Fi）。
	DNSService string `json:"dns_service,omitempty"`
	Error      string `json:"error,omitempty"`
}

// state 是持久化的设置。
type state struct {
	Desired  bool   `json:"desired"`
	Secret   string `json:"secret"`
	Source   string `json:"source,omitempty"`
	SyncedAt string `json:"synced_at,omitempty"`
	// Dropped 同步时剔除的、只能在路由器上用的节点。
	Dropped []string `json:"dropped,omitempty"`
}

// Manager 管理内核进程。
type Manager struct {
	mu   sync.Mutex
	dir  string
	logf func(string, ...interface{})
	// binary 是编进 daemon 的内核；nil 表示这份 daemon 没带。
	binary []byte
	// dropPrivileges 以 root 运行时把内核的组设为 nobody（用户仍是 root，TUN 需要）。
	dropPrivileges bool
	// runCommand 执行系统命令（DNS 接管用）；nil = 不接管（非 root、测试）。
	runCommand func(name string, args ...string) (string, error)
	dnsService string
	// OnChange 内核启动或退出后调用（在锁外），用于让出站拦截立即重算。
	OnChange func()

	st        state
	version   string
	cmd       *exec.Cmd
	done      chan struct{}
	startedAt time.Time
	stopping  bool
	lastExit  string
	lastErr   string
}

// New 创建管理器。dir 为内核目录；logf 可为 nil。
func New(dir string, logf func(string, ...interface{})) *Manager {
	if logf == nil {
		logf = func(string, ...interface{}) {}
	}
	m := &Manager{dir: dir, logf: logf, binary: embedded(), dropPrivileges: os.Geteuid() == 0}
	if m.dropPrivileges {
		m.runCommand = runSystem
	}
	if data, err := os.ReadFile(m.statePath()); err == nil {
		_ = json.Unmarshal(data, &m.st)
	}
	// 上次没来得及归还的 DNS（daemon 被强杀）先恢复
	if err := m.restoreDNS(); err != nil {
		logf("恢复残留的 DNS 接管失败: %v", err)
	}
	return m
}

func (m *Manager) binPath() string    { return filepath.Join(m.dir, "bin", "mihomo") }
func (m *Manager) statePath() string  { return filepath.Join(m.dir, "state.json") }
func (m *Manager) ConfigPath() string { return filepath.Join(m.dir, "config.yaml") }
func (m *Manager) dataDir() string    { return filepath.Join(m.dir, "data") }

// Bundled 报告这份 daemon 是否带了内核。
func (m *Manager) Bundled() bool { return len(m.binary) > 0 }

// TUNEnabled 当前配置会开 TUN 接管整机（从 op 同步过）。
func (m *Manager) TUNEnabled() bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.st.Source != ""
}

// Running 内核正在运行。
func (m *Manager) Running() bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.cmd != nil
}

// Ready 能否作为出口：要有内核，且配置已从 op 同步（默认配置全部直连，会绕开纯良）。
func (m *Manager) Ready() error {
	if !m.Bundled() {
		return errors.New("这份网络服务没有内置代理内核")
	}
	if !m.TUNEnabled() {
		return errors.New("还没有从 op 同步配置：默认配置全部直连，不能作为出口")
	}
	return nil
}

// Restore 在 daemon 启动时调用：用户上次让它运行，就再启动。
func (m *Manager) Restore() {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.st.Desired && m.Bundled() {
		if err := m.startLocked(); err != nil {
			m.logf("内置代理内核恢复运行失败: %v", err)
		}
	}
}

// Status 返回当前状态。
func (m *Manager) Status() Status {
	m.mu.Lock()
	defer m.mu.Unlock()
	s := Status{
		Bundled:    m.Bundled(),
		Version:    m.version,
		Desired:    m.st.Desired,
		Controller: DefaultController,
		MixedPort:  DefaultMixedPort,
		ConfigPath: m.ConfigPath(),
		LastExit:   m.lastExit,
		Error:      m.lastErr,
		Source:     m.st.Source,
		SyncedAt:   m.st.SyncedAt,
		Dropped:    m.st.Dropped,
		DNSService: m.dnsService,
	}
	if m.dropPrivileges {
		s.User = "root:nobody"
	} else {
		s.User = fmt.Sprint(os.Getuid())
	}
	if m.cmd != nil && m.cmd.Process != nil {
		s.Running, s.PID = true, m.cmd.Process.Pid
		s.StartedAt = m.startedAt.Format(time.RFC3339)
	}
	if s.Version == "" && s.Bundled {
		s.Version = embeddedVersion()
	}
	return s
}

// Start 启动内核并记住「希望运行」。
func (m *Manager) Start() error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if !m.Bundled() {
		return errors.New("这份网络服务没有内置代理内核")
	}
	m.st.Desired = true
	if err := m.saveLocked(); err != nil {
		return err
	}
	return m.startLocked()
}

// Stop 停止内核并记住「不运行」。
func (m *Manager) Stop() error {
	m.mu.Lock()
	m.st.Desired = false
	err := m.saveLocked()
	m.mu.Unlock()
	m.terminate()
	return err
}

// Shutdown 在 daemon 退出时调用：停进程，不改「希望运行」，下次启动恢复。
func (m *Manager) Shutdown() { m.terminate() }

func (m *Manager) terminate() {
	m.mu.Lock()
	cmd, done := m.cmd, m.done
	if cmd == nil || cmd.Process == nil {
		m.mu.Unlock()
		return
	}
	m.stopping = true
	m.mu.Unlock()
	// 内核自己的子进程（规则源更新等）与它同一进程组，一并结束。
	_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		<-done
	}
}

func (m *Manager) startLocked() error {
	if m.cmd != nil {
		return nil
	}
	m.lastErr = ""
	if err := m.prepareLocked(); err != nil {
		m.lastErr = err.Error()
		return err
	}
	cmd := exec.Command(m.binPath(), "-d", m.dataDir(), "-f", m.ConfigPath())
	cmd.Dir = m.dataDir()
	// 控制接口地址与密钥走环境变量：命令行参数对本机所有用户可见（ps）。
	cmd.Env = []string{"HOME=" + m.dataDir(), "PATH=/usr/bin:/bin:/usr/sbin:/sbin",
		"CLASH_OVERRIDE_EXTERNAL_CONTROLLER=" + DefaultController, "CLASH_OVERRIDE_SECRET=" + m.st.Secret}
	attr := &syscall.SysProcAttr{Setpgid: true}
	if m.dropPrivileges {
		// root 用户（TUN 需要）+ nobody 组（出站拦截按组放行它）
		attr.Credential = &syscall.Credential{Uid: 0, Gid: nobodyID, Groups: []uint32{}}
	}
	cmd.SysProcAttr = attr
	logFile, err := os.OpenFile(filepath.Join(m.dir, "mihomo.log"), os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0644)
	if err == nil {
		cmd.Stdout, cmd.Stderr = logFile, logFile
	}
	if err := cmd.Start(); err != nil {
		if logFile != nil {
			logFile.Close()
		}
		m.lastErr = err.Error()
		return fmt.Errorf("启动内核失败: %w", err)
	}
	done := make(chan struct{})
	m.cmd, m.done, m.startedAt, m.stopping, m.lastExit = cmd, done, time.Now(), false, ""
	m.logf("内置代理内核已启动: pid=%d 控制接口=%s 本机端口=%d", cmd.Process.Pid, DefaultController, DefaultMixedPort)
	if m.st.Source != "" {
		if err := m.takeoverDNS(); err != nil {
			m.logf("内置代理内核接管 DNS 失败: %v", err)
		}
	}
	m.notifyChange()
	go func() {
		err := cmd.Wait()
		if logFile != nil {
			logFile.Close()
		}
		m.mu.Lock()
		if !m.stopping {
			reason := "进程退出"
			if err != nil {
				reason = err.Error()
			}
			if tail := m.logTail(); tail != "" {
				reason += "：" + tail
			}
			m.lastExit = reason
			m.logf("内置代理内核意外退出: %s", reason)
		} else {
			m.logf("内置代理内核已停止")
		}
		m.cmd, m.done = nil, nil
		if err := m.restoreDNS(); err != nil {
			m.logf("归还 DNS 失败: %v", err)
		}
		m.mu.Unlock()
		close(done)
		m.notifyChange()
	}()
	return nil
}

func (m *Manager) notifyChange() {
	if fn := m.OnChange; fn != nil {
		go fn()
	}
}

// prepareLocked 释放二进制、补齐默认配置与目录权限。
func (m *Manager) prepareLocked() error {
	for _, d := range []string{m.dir, filepath.Dir(m.binPath())} {
		if err := os.MkdirAll(d, 0755); err != nil {
			return err
		}
	}
	if err := m.installBinary(); err != nil {
		return fmt.Errorf("释放内核失败: %w", err)
	}
	if m.st.Secret == "" {
		var b [16]byte
		if _, err := rand.Read(b[:]); err != nil {
			return err
		}
		m.st.Secret = hex.EncodeToString(b[:])
		if err := m.saveLocked(); err != nil {
			return err
		}
	}
	if _, err := os.Stat(m.ConfigPath()); errors.Is(err, os.ErrNotExist) {
		if err := os.WriteFile(m.ConfigPath(), []byte(defaultConfig), 0644); err != nil {
			return err
		}
	}
	// 数据目录要让降权后的内核可写（缓存、规则源）。
	if err := os.MkdirAll(m.dataDir(), 0755); err != nil {
		return err
	}
	if m.dropPrivileges {
		if err := os.Chown(m.dataDir(), nobodyID, nobodyID); err != nil {
			return err
		}
	}
	if m.version == "" {
		if out, err := exec.Command(m.binPath(), "-v").Output(); err == nil {
			m.version = parseVersion(string(out))
		}
	}
	return nil
}

// installBinary 只在内容不同时重写，避免每次启动都写 30MB。
func (m *Manager) installBinary() error {
	want := sha256.Sum256(m.binary)
	if f, err := os.Open(m.binPath()); err == nil {
		h := sha256.New()
		buf := make([]byte, 1<<20)
		for {
			n, err := f.Read(buf)
			h.Write(buf[:n])
			if err != nil {
				break
			}
		}
		f.Close()
		if bytes.Equal(h.Sum(nil), want[:]) {
			return nil
		}
	}
	tmp := m.binPath() + ".tmp"
	if err := os.WriteFile(tmp, m.binary, 0755); err != nil {
		return err
	}
	if err := os.Rename(tmp, m.binPath()); err != nil {
		return err
	}
	m.version = ""
	return nil
}

func (m *Manager) saveLocked() error {
	if err := os.MkdirAll(m.dir, 0755); err != nil {
		return err
	}
	data, err := json.MarshalIndent(m.st, "", "  ")
	if err != nil {
		return err
	}
	tmp := m.statePath() + ".tmp"
	if err := os.WriteFile(tmp, append(data, '\n'), 0600); err != nil {
		return err
	}
	return os.Rename(tmp, m.statePath())
}

// logTail 取日志最后一条错误，用于说明意外退出的原因。
func (m *Manager) logTail() string {
	data, err := os.ReadFile(filepath.Join(m.dir, "mihomo.log"))
	if err != nil {
		return ""
	}
	lines := strings.Split(strings.TrimSpace(string(data)), "\n")
	for i := len(lines) - 1; i >= 0 && i >= len(lines)-20; i-- {
		if strings.Contains(lines[i], "level=fatal") || strings.Contains(lines[i], "level=error") {
			if at := strings.Index(lines[i], "msg="); at >= 0 {
				return strings.Trim(lines[i][at+4:], `"`)
			}
			return lines[i]
		}
	}
	return ""
}

// parseVersion 从 `mihomo -v` 的输出里取版本号。
func parseVersion(out string) string {
	fields := strings.Fields(out)
	for i, f := range fields {
		if f == "Meta" && i+1 < len(fields) {
			return fields[i+1]
		}
	}
	return ""
}

// defaultConfig 只监听本机端口、全部直连：内核跑起来但不影响本机网络。
const defaultConfig = `# WgSense 内置代理内核的默认配置（首次启动自动生成，可替换为自己的配置）
# 只监听本机端口，不开 TUN、不接管 DNS、不改系统代理。
mixed-port: 7895
bind-address: 127.0.0.1
allow-lan: false
mode: rule
log-level: warning
geo-auto-update: false
profile:
  store-selected: true
proxies: []
rules:
  - MATCH,DIRECT
`
