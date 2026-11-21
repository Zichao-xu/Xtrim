// Package location 提供网络位置感知：当前有效的物理网卡与地址。
// 是否受信任由 gateway 包按网关 MAC 判定（以前按 IP 前缀，同网段的别人家会被误判）。
package location

import (
	"bufio"
	"bytes"
	"net"
	"os/exec"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	priorityWired = 300
	priorityWiFi  = 200
	priorityOther = 100
)

// Interface 是用于位置判断的有效物理网络接口。
type Interface struct {
	Name         string   `json:"name"`
	HardwarePort string   `json:"hardware_port,omitempty"`
	IPv4s        []string `json:"ipv4s"`
	Active       bool     `json:"active"`
	Priority     int      `json:"priority"`
	SpeedMbps    int      `json:"speed_mbps,omitempty"`
}

// Locator 检测网络位置。
type Locator interface {
	// Trusted 返回当前网络是否受信任（守护据此断开 WireGuard）。
	Trusted() bool
	// CurrentIPv4s 返回当前有效物理网络接口的 IPv4。
	CurrentIPv4s() []string
	// ActiveInterfaces 返回当前参与位置判断的有效物理网络接口。
	ActiveInterfaces() []Interface
}

type defaultLocator struct{}

// New 创建默认 Locator。
func New() Locator { return defaultLocator{} }

func (defaultLocator) CurrentIPv4s() []string {
	var ips []string
	for _, iface := range currentActiveInterfaces() {
		ips = append(ips, iface.IPv4s...)
	}
	return ips
}

func (defaultLocator) ActiveInterfaces() []Interface {
	return currentActiveInterfaces()
}

// Trusted 位置模块本身不判定信任：没接网关判定（gateway.Locator）时一律不受信任。
func (defaultLocator) Trusted() bool { return false }

// NetworkFingerprint returns the effective physical network identity used to
// detect home/away transitions. It intentionally ignores utun and local Apple
// discovery interfaces so WireGuard itself does not mask real network changes.
func NetworkFingerprint() string {
	var parts []string
	for _, iface := range currentActiveInterfaces() {
		ips := append([]string(nil), iface.IPv4s...)
		sort.Strings(ips)
		parts = append(parts, iface.Name+"="+strings.Join(ips, ","))
	}
	return strings.Join(parts, "|")
}

func currentActiveInterfaces() []Interface {
	base, key := collectIPv4s()
	meta, hardwarePorts := cachedMetadata(key)
	return selectActiveInterfaces(base, meta, hardwarePorts)
}

// 网卡元数据（ifconfig 的 status/media、networksetup 的硬件端口名）要 fork 外部命令，
// 而巡检、网络变化检测、每次 /api/status 都会查一遍。网卡地址与启停标志不变时复用上次结果，
// metaMaxAge 兜底刷新链路速率这类不改变地址的字段。
const metaMaxAge = time.Minute

var metaCache struct {
	sync.Mutex
	key   string
	at    time.Time
	meta  map[string]interfaceMeta
	ports map[string]string
}

func cachedMetadata(key string) (map[string]interfaceMeta, map[string]string) {
	metaCache.Lock()
	defer metaCache.Unlock()
	if metaCache.at.IsZero() || metaCache.key != key || time.Since(metaCache.at) >= metaMaxAge {
		metaCache.meta = collectInterfaceMetadata()
		metaCache.ports = hardwarePortMap()
		metaCache.key = key
		metaCache.at = time.Now()
	}
	return metaCache.meta, metaCache.ports
}

// Invalidate 丢弃缓存的网卡元数据，下次查询重新读取。收到系统网卡/地址变化通知时调用。
func Invalidate() {
	metaCache.Lock()
	metaCache.at = time.Time{}
	metaCache.Unlock()
}

func selectActiveInterfaces(base map[string][]string, meta map[string]interfaceMeta, hardwarePorts map[string]string) []Interface {
	var result []Interface
	for name, ips := range base {
		if isIgnoredInterface(name) {
			continue
		}
		info := meta[name]
		hardwarePort := hardwarePorts[name]
		if hardwarePort == "" {
			hardwarePort = info.hardwarePort
		}
		priority := interfacePriority(name, hardwarePort)
		if priority == 0 {
			continue
		}
		active := info.active
		if !info.sawStatus {
			active = true
		}
		if !active {
			continue
		}
		sort.Strings(ips)
		result = append(result, Interface{
			Name:         name,
			HardwarePort: hardwarePort,
			IPv4s:        ips,
			Active:       true,
			Priority:     priority,
			SpeedMbps:    info.speedMbps,
		})
	}
	sort.Slice(result, func(i, j int) bool {
		if result[i].Priority != result[j].Priority {
			return result[i].Priority > result[j].Priority
		}
		if result[i].SpeedMbps != result[j].SpeedMbps {
			return result[i].SpeedMbps > result[j].SpeedMbps
		}
		return result[i].Name < result[j].Name
	})
	return result
}

// collectIPv4s 只走系统调用，不 fork。第二个返回值概括物理网卡的地址与启停标志，
// 用作元数据缓存的键：键不变说明网卡状态没变。
func collectIPv4s() (map[string][]string, string) {
	ifaces, err := net.Interfaces()
	if err != nil {
		return nil, ""
	}
	ips := map[string][]string{}
	var key strings.Builder
	for _, iface := range ifaces {
		if !isIgnoredInterface(iface.Name) {
			key.WriteString(iface.Name + ":" + strconv.FormatUint(uint64(iface.Flags&(net.FlagUp|net.FlagRunning)), 10) + ";")
		}
		if iface.Flags&net.FlagUp == 0 {
			continue
		}
		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, addr := range addrs {
			if ipnet, ok := addr.(*net.IPNet); ok && !ipnet.IP.IsLoopback() {
				if ip4 := ipnet.IP.To4(); ip4 != nil {
					ips[iface.Name] = append(ips[iface.Name], ip4.String())
					if !isIgnoredInterface(iface.Name) {
						key.WriteString(iface.Name + "=" + ip4.String() + ";")
					}
				}
			}
		}
	}
	return ips, key.String()
}

type interfaceMeta struct {
	active       bool
	sawStatus    bool
	speedMbps    int
	hardwarePort string
}

func collectInterfaceMetadata() map[string]interfaceMeta {
	out, err := exec.Command("ifconfig").CombinedOutput()
	if err != nil {
		return nil
	}
	meta := map[string]interfaceMeta{}
	var current string
	scanner := bufio.NewScanner(bytes.NewReader(out))
	for scanner.Scan() {
		line := scanner.Text()
		if line == "" {
			continue
		}
		if !strings.HasPrefix(line, "\t") && strings.Contains(line, ":") {
			current = strings.TrimSuffix(strings.Fields(line)[0], ":")
			continue
		}
		if current == "" {
			continue
		}
		m := meta[current]
		text := strings.TrimSpace(line)
		if strings.HasPrefix(text, "status:") {
			m.sawStatus = true
			m.active = strings.TrimSpace(strings.TrimPrefix(text, "status:")) == "active"
		}
		if strings.HasPrefix(text, "media:") {
			m.speedMbps = parseMediaSpeedMbps(text)
		}
		meta[current] = m
	}
	return meta
}

func hardwarePortMap() map[string]string {
	out, err := exec.Command("networksetup", "-listallhardwareports").CombinedOutput()
	if err != nil {
		return nil
	}
	ports := map[string]string{}
	var port string
	scanner := bufio.NewScanner(bytes.NewReader(out))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if after, ok := strings.CutPrefix(line, "Hardware Port: "); ok {
			port = after
			continue
		}
		if after, ok := strings.CutPrefix(line, "Device: "); ok {
			if port != "" {
				ports[after] = port
			}
		}
	}
	return ports
}

func interfacePriority(name, hardwarePort string) int {
	lower := strings.ToLower(hardwarePort)
	switch {
	case strings.Contains(lower, "wi-fi"), strings.Contains(lower, "wifi"), strings.Contains(lower, "airport"):
		return priorityWiFi
	case strings.Contains(lower, "ethernet"), strings.Contains(lower, "lan"), strings.Contains(lower, "usb"), strings.Contains(lower, "thunderbolt"):
		return priorityWired
	case strings.HasPrefix(name, "en"):
		if name == "en0" {
			return priorityWiFi
		}
		return priorityOther
	default:
		return 0
	}
}

func isIgnoredInterface(name string) bool {
	ignoredPrefixes := []string{"lo", "utun", "awdl", "llw", "bridge", "gif", "stf", "pktap", "anpi", "ap", "vmenet", "vmnet"}
	for _, prefix := range ignoredPrefixes {
		if strings.HasPrefix(name, prefix) {
			return true
		}
	}
	return false
}

func parseMediaSpeedMbps(media string) int {
	for _, token := range strings.Fields(media) {
		token = strings.Trim(token, "()<>")
		switch {
		case strings.HasSuffix(token, "GbaseT"):
			n := strings.TrimSuffix(token, "GbaseT")
			if speed, err := strconv.ParseFloat(n, 64); err == nil {
				return int(speed * 1000)
			}
		case strings.HasSuffix(token, "baseT"):
			n := strings.TrimSuffix(token, "baseT")
			if speed, err := strconv.Atoi(n); err == nil {
				return speed
			}
		case strings.HasSuffix(token, "baseTX"):
			n := strings.TrimSuffix(token, "baseTX")
			if speed, err := strconv.Atoi(n); err == nil {
				return speed
			}
		}
	}
	return 0
}
