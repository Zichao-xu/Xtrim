package mihomo

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// 内核开着 TUN 时接管系统 DNS：当前主网卡对应的网络服务改成 TUN 里的 DNS 地址，
// 原值存快照；内核停止（或 daemon 下次启动发现残留）时恢复。做法与 WireGuard 的 DNS 接管一致。
// 不接管时，指向局域网的 DNS 会绕开 TUN（局域网路由更具体），境外域名查询就泄露给当前网络。

type dnsSnapshot struct {
	Service string   `json:"service"`
	Servers []string `json:"servers"`
}

func (m *Manager) dnsSnapshotPath() string { return filepath.Join(m.dir, "dns-snapshot.json") }

// takeoverDNS 把主网络服务的 DNS 指向 TUN。已有快照（上次没恢复）时不覆盖原值。
func (m *Manager) takeoverDNS() error {
	if m.runCommand == nil {
		return nil
	}
	service, err := m.primaryService()
	if err != nil {
		return err
	}
	if _, err := os.Stat(m.dnsSnapshotPath()); errors.Is(err, os.ErrNotExist) {
		out, err := m.runCommand("networksetup", "-getdnsservers", service)
		if err != nil {
			return err
		}
		snap := dnsSnapshot{Service: service, Servers: parseDNSList(out)}
		data, _ := json.Marshal(snap)
		if err := os.WriteFile(m.dnsSnapshotPath(), data, 0600); err != nil {
			return err
		}
	}
	if _, err := m.runCommand("networksetup", "-setdnsservers", service, TUNDNS); err != nil {
		return err
	}
	m.dnsService = service
	m.logf("内置代理内核接管 DNS: %s → %s", service, TUNDNS)
	return nil
}

// restoreDNS 按快照恢复；没有快照什么也不做。
func (m *Manager) restoreDNS() error {
	if m.runCommand == nil {
		return nil
	}
	data, err := os.ReadFile(m.dnsSnapshotPath())
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	var snap dnsSnapshot
	if json.Unmarshal(data, &snap) != nil || snap.Service == "" {
		return os.Remove(m.dnsSnapshotPath())
	}
	args := []string{"-setdnsservers", snap.Service}
	if len(snap.Servers) == 0 {
		args = append(args, "Empty")
	} else {
		args = append(args, snap.Servers...)
	}
	if _, err := m.runCommand("networksetup", args...); err != nil {
		return err
	}
	m.dnsService = ""
	m.logf("内置代理内核已归还 DNS: %s", snap.Service)
	return os.Remove(m.dnsSnapshotPath())
}

// primaryService 找默认路由所在网卡对应的网络服务名（如 Wi-Fi）。
func (m *Manager) primaryService() (string, error) {
	out, err := m.runCommand("route", "-n", "get", "default")
	if err != nil {
		return "", err
	}
	iface := ""
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "interface:") {
			iface = strings.TrimSpace(strings.TrimPrefix(line, "interface:"))
		}
	}
	if iface == "" || strings.HasPrefix(iface, "utun") {
		return "", fmt.Errorf("找不到物理默认网卡（当前 %q）", iface)
	}
	ports, err := m.runCommand("networksetup", "-listallhardwareports")
	if err != nil {
		return "", err
	}
	return serviceForDevice(ports, iface)
}

func serviceForDevice(listing, device string) (string, error) {
	var port string
	sc := bufio.NewScanner(strings.NewReader(listing))
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		switch {
		case strings.HasPrefix(line, "Hardware Port:"):
			port = strings.TrimSpace(strings.TrimPrefix(line, "Hardware Port:"))
		case strings.HasPrefix(line, "Device:"):
			if strings.TrimSpace(strings.TrimPrefix(line, "Device:")) == device && port != "" {
				return port, nil
			}
		}
	}
	return "", fmt.Errorf("网卡 %s 没有对应的网络服务", device)
}

func parseDNSList(out string) []string {
	var servers []string
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		if strings.Contains(line, "There aren't any DNS Servers") {
			return nil
		}
		servers = append(servers, line)
	}
	return servers
}

func runSystem(name string, args ...string) (string, error) {
	out, err := exec.Command(name, args...).CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("%s %s: %s: %w", name, strings.Join(args, " "), strings.TrimSpace(string(out)), err)
	}
	return string(out), nil
}
