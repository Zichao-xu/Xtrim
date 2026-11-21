// Package gateway 判定当前网络是否受信任：看默认网关的 MAC 在不在受信任列表里。
//
// 以前按本机 IP 前缀判定「在家」，别人家用同一网段（比如也是 10.10.1.x）就会被当成在家，
// 守护随即断开 WireGuard、流量直连。网段是谁都能设成一样的标签；网关 MAC 是那台路由器
// 自己的地址，别人家不会意外撞上。判错时偏向「未受信任」：多开一次 WireGuard 只损失一点
// 速度，误判成受信任才会裸奔。
//
// 受信任列表、见过的网关、判定记录存一个独立文件（gateway.json）：/api/config 是整包同步，
// 放进 settings.json 会被旧版 App 冲掉。
package gateway

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/wgsense/core/internal/location"
)

const (
	maxSeen      = 20
	maxDecisions = 50
	// seenSaveInterval 只是「最后见到」时间变了时，最多多久落一次盘。
	seenSaveInterval = 10 * time.Minute
)

// Current 是当前物理网卡的默认网关。MAC 为空表示读不到（判为未受信任）。
type Current struct {
	Interface    string `json:"interface"`
	HardwarePort string `json:"hardware_port,omitempty"`
	IP           string `json:"ip"`
	MAC          string `json:"mac,omitempty"`
}

// Trusted 是一个受信任网关。
type Trusted struct {
	MAC      string    `json:"mac"`
	Name     string    `json:"name"`
	AddedAt  time.Time `json:"added_at"`
	LastSeen time.Time `json:"last_seen,omitempty"`
}

// Seen 是最近连过的网关，离开那个网络后也能一键补加信任。
type Seen struct {
	MAC          string    `json:"mac"`
	IP           string    `json:"ip"`
	Interface    string    `json:"interface"`
	HardwarePort string    `json:"hardware_port,omitempty"`
	FirstSeen    time.Time `json:"first_seen"`
	LastSeen     time.Time `json:"last_seen"`
}

// Decision 是一次网关变化后的判定，供界面回答「为什么断开 / 为什么连上」。
type Decision struct {
	At        time.Time `json:"at"`
	IP        string    `json:"ip,omitempty"`
	MAC       string    `json:"mac,omitempty"`
	Interface string    `json:"interface,omitempty"`
	Name      string    `json:"name,omitempty"`
	Trusted   bool      `json:"trusted"`
}

// Verdict 是一次判定的结果。
type Verdict struct {
	Current *Current `json:"current,omitempty"`
	Trusted bool     `json:"trusted"`
	// Name 命中的受信任网关名。
	Name string `json:"name,omitempty"`
	// LegacyMatch 旧版按网段信任、升级后还没确认任何网关，而当前 IP 落在旧网段里：
	// 界面据此提示一次「受信任规则已改为网关 MAC，信任当前网关？」。
	LegacyMatch bool `json:"legacy_match,omitempty"`
}

// State 是 /api/gateway 返回的完整内容。
type State struct {
	Verdict
	TrustedList []Trusted  `json:"trusted_list"`
	Seen        []Seen     `json:"seen"`
	Decisions   []Decision `json:"decisions"`
}

type fileData struct {
	Trusted        []Trusted  `json:"trusted"`
	Seen           []Seen     `json:"seen"`
	Decisions      []Decision `json:"decisions"`
	LegacyPrefixes []string   `json:"legacy_prefixes,omitempty"`
}

// ErrNoGateway 当前读不到网关 MAC，无法信任「当前网关」。
var ErrNoGateway = errors.New("当前读不到网关 MAC")

// ErrBadMAC MAC 格式不对。
var ErrBadMAC = errors.New("MAC 地址格式不对")

// Store 保存受信任网关并做判定。并发安全。
type Store struct {
	path string
	// 依赖，测试可替换。
	Interfaces func() []location.Interface
	Read       func([]location.Interface) (Current, bool)
	Now        func() time.Time
	Logf       func(string, ...any)

	mu       sync.Mutex
	data     fileData
	lastKey  string
	dirty    bool
	lastSave time.Time
}

// Open 读入 path 处的受信任网关文件。文件不存在且 legacyPrefixes 非空，说明是从按网段信任
// 的旧版升级上来：记下旧网段，只用来触发一次确认提示，不再据此信任。
func Open(path string, legacyPrefixes []string) *Store {
	s := &Store{
		path:       path,
		Interfaces: location.New().ActiveInterfaces,
		Read:       Read,
		Now:        time.Now,
	}
	data, err := os.ReadFile(path)
	switch {
	case err == nil:
		_ = json.Unmarshal(data, &s.data)
	case errors.Is(err, os.ErrNotExist):
		for _, p := range legacyPrefixes {
			if p = strings.TrimSpace(p); p != "" {
				s.data.LegacyPrefixes = append(s.data.LegacyPrefixes, p)
			}
		}
		if len(s.data.LegacyPrefixes) > 0 {
			s.dirty = true
			s.saveLocked()
		}
	}
	return s
}

// Evaluate 读当前网关并判定，顺带更新「见过的网关」与判定记录。
func (s *Store) Evaluate() Verdict {
	ifaces := s.Interfaces()
	cur, ok := s.Read(ifaces)
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.Now()
	v := Verdict{}
	urgent := false // 新网关、判定变化：立即落盘；只有「最后见到」变了就攒着
	if ok {
		v.Current = &cur
		if t := s.findTrustedLocked(cur.MAC); t != nil {
			v.Trusted, v.Name = true, t.Name
			if now.Sub(t.LastSeen) >= seenSaveInterval {
				t.LastSeen = now
				s.dirty = true
			}
		}
		if s.noteSeenLocked(cur, now) {
			urgent = true
		}
	}
	if !v.Trusted && len(s.data.LegacyPrefixes) > 0 {
		v.LegacyMatch = matchesAnyPrefix(ifaces, s.data.LegacyPrefixes)
	}
	key := "none"
	if ok {
		key = cur.IP + "|" + cur.MAC + "|" + boolKey(v.Trusted)
	}
	if key != s.lastKey {
		s.lastKey = key
		d := Decision{At: now, Trusted: v.Trusted, Name: v.Name}
		if ok {
			d.IP, d.MAC, d.Interface = cur.IP, cur.MAC, cur.Interface
		}
		s.data.Decisions = append(s.data.Decisions, d)
		if n := len(s.data.Decisions); n > maxDecisions {
			s.data.Decisions = append([]Decision(nil), s.data.Decisions[n-maxDecisions:]...)
		}
		s.dirty, urgent = true, true
		if s.Logf != nil {
			switch {
			case !ok:
				s.Logf("网关判定：读不到默认网关，按未受信任处理")
			case cur.MAC == "":
				s.Logf("网关判定：网关 %s 读不到 MAC，按未受信任处理", cur.IP)
			case v.Trusted:
				s.Logf("网关判定：网关 %s（%s）是受信任网关「%s」", cur.IP, cur.MAC, v.Name)
			default:
				s.Logf("网关判定：网关 %s（%s）不在受信任列表，按未受信任处理", cur.IP, cur.MAC)
			}
		}
	}
	if urgent || (s.dirty && now.Sub(s.lastSave) >= seenSaveInterval) {
		s.saveLocked()
	}
	return v
}

// Snapshot 返回判定与全部列表（会先判定一次）。
func (s *Store) Snapshot() State {
	v := s.Evaluate()
	s.mu.Lock()
	defer s.mu.Unlock()
	st := State{
		Verdict:     v,
		TrustedList: append([]Trusted{}, s.data.Trusted...),
		Seen:        append([]Seen{}, s.data.Seen...),
		Decisions:   append([]Decision{}, s.data.Decisions...),
	}
	sort.Slice(st.Seen, func(i, j int) bool { return st.Seen[i].LastSeen.After(st.Seen[j].LastSeen) })
	// 判定记录新的在前。
	for i, j := 0, len(st.Decisions)-1; i < j; i, j = i+1, j-1 {
		st.Decisions[i], st.Decisions[j] = st.Decisions[j], st.Decisions[i]
	}
	return st
}

// Trust 把 mac 加入受信任列表；mac 为空表示当前网关。name 为空时用网关 IP。
// 已在列表里就只改名。信任了任何网关后，旧网段提示不再出现。
func (s *Store) Trust(mac, name string) (Trusted, error) {
	if strings.TrimSpace(mac) == "" {
		cur, ok := s.Read(s.Interfaces())
		if !ok || cur.MAC == "" {
			return Trusted{}, ErrNoGateway
		}
		mac = cur.MAC
		if strings.TrimSpace(name) == "" {
			name = cur.IP
		}
	}
	norm, ok := NormalizeMAC(mac)
	if !ok {
		return Trusted{}, ErrBadMAC
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	name = strings.TrimSpace(name)
	if name == "" {
		name = s.seenIPLocked(norm)
	}
	if name == "" {
		name = norm
	}
	now := s.Now()
	if t := s.findTrustedLocked(norm); t != nil {
		t.Name = name
	} else {
		s.data.Trusted = append(s.data.Trusted, Trusted{MAC: norm, Name: name, AddedAt: now, LastSeen: now})
	}
	s.data.LegacyPrefixes = nil
	s.lastKey = "" // 下次判定记一条新记录
	s.dirty = true
	s.saveLocked()
	if s.Logf != nil {
		s.Logf("已信任网关「%s」（%s）", name, norm)
	}
	return *s.findTrustedLocked(norm), nil
}

// Rename 改受信任网关的名字。
func (s *Store) Rename(mac, name string) error {
	norm, ok := NormalizeMAC(mac)
	if !ok {
		return ErrBadMAC
	}
	name = strings.TrimSpace(name)
	s.mu.Lock()
	defer s.mu.Unlock()
	t := s.findTrustedLocked(norm)
	if t == nil {
		return errors.New("不在受信任列表里")
	}
	if name == "" {
		name = norm
	}
	t.Name = name
	s.dirty = true
	s.saveLocked()
	return nil
}

// Untrust 把 mac 移出受信任列表。
func (s *Store) Untrust(mac string) error {
	norm, ok := NormalizeMAC(mac)
	if !ok {
		return ErrBadMAC
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	out := s.data.Trusted[:0]
	removed := false
	for _, t := range s.data.Trusted {
		if t.MAC == norm {
			removed = true
			if s.Logf != nil {
				s.Logf("已取消信任网关「%s」（%s）", t.Name, t.MAC)
			}
			continue
		}
		out = append(out, t)
	}
	s.data.Trusted = out
	if !removed {
		return errors.New("不在受信任列表里")
	}
	s.lastKey = ""
	s.dirty = true
	s.saveLocked()
	return nil
}

// ClearSeen 清空「见过的网关」与判定记录。
func (s *Store) ClearSeen() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.data.Seen = nil
	s.data.Decisions = nil
	s.lastKey = ""
	s.dirty = true
	s.saveLocked()
}

// DismissLegacy 不再提示旧网段（用户选了「不是」）。
func (s *Store) DismissLegacy() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.data.LegacyPrefixes) == 0 {
		return
	}
	s.data.LegacyPrefixes = nil
	s.dirty = true
	s.saveLocked()
}

func (s *Store) findTrustedLocked(mac string) *Trusted {
	if mac == "" {
		return nil
	}
	for i := range s.data.Trusted {
		if s.data.Trusted[i].MAC == mac {
			return &s.data.Trusted[i]
		}
	}
	return nil
}

func (s *Store) seenIPLocked(mac string) string {
	for _, seen := range s.data.Seen {
		if seen.MAC == mac {
			return seen.IP
		}
	}
	return ""
}

// noteSeenLocked 记下见到的网关；返回是否是新网关。
func (s *Store) noteSeenLocked(cur Current, now time.Time) bool {
	if cur.MAC == "" {
		return false
	}
	for i := range s.data.Seen {
		seen := &s.data.Seen[i]
		if seen.MAC != cur.MAC {
			continue
		}
		if seen.IP != cur.IP || seen.Interface != cur.Interface || seen.HardwarePort != cur.HardwarePort {
			seen.IP, seen.Interface, seen.HardwarePort = cur.IP, cur.Interface, cur.HardwarePort
			s.dirty = true
		}
		if now.Sub(seen.LastSeen) >= seenSaveInterval {
			s.dirty = true
		}
		seen.LastSeen = now
		return false
	}
	s.data.Seen = append(s.data.Seen, Seen{MAC: cur.MAC, IP: cur.IP, Interface: cur.Interface, HardwarePort: cur.HardwarePort, FirstSeen: now, LastSeen: now})
	if len(s.data.Seen) > maxSeen {
		sort.Slice(s.data.Seen, func(i, j int) bool { return s.data.Seen[i].LastSeen.After(s.data.Seen[j].LastSeen) })
		s.data.Seen = s.data.Seen[:maxSeen]
	}
	s.dirty = true
	return true
}

func (s *Store) saveLocked() {
	if !s.dirty || s.path == "" {
		return
	}
	data, err := json.MarshalIndent(s.data, "", "  ")
	if err != nil {
		return
	}
	if err := os.MkdirAll(filepath.Dir(s.path), 0755); err != nil {
		return
	}
	tmp, err := os.CreateTemp(filepath.Dir(s.path), ".gateway-*.json")
	if err != nil {
		return
	}
	name := tmp.Name()
	_, werr := tmp.Write(append(data, '\n'))
	cerr := tmp.Close()
	if werr != nil || cerr != nil || os.Rename(name, s.path) != nil {
		_ = os.Remove(name)
		return
	}
	s.dirty = false
	s.lastSave = s.Now()
}

// NormalizeMAC 统一成小写冒号分隔；接受 - 分隔与省略前导零（macOS arp 的写法）。
func NormalizeMAC(mac string) (string, bool) {
	mac = strings.ToLower(strings.TrimSpace(mac))
	mac = strings.ReplaceAll(mac, "-", ":")
	parts := strings.Split(mac, ":")
	if len(parts) != 6 {
		return "", false
	}
	for i, p := range parts {
		if len(p) == 1 {
			p = "0" + p
		}
		if len(p) != 2 || strings.Trim(p, "0123456789abcdef") != "" {
			return "", false
		}
		parts[i] = p
	}
	out := strings.Join(parts, ":")
	if out == "00:00:00:00:00:00" {
		return "", false
	}
	return out, true
}

func matchesAnyPrefix(ifaces []location.Interface, prefixes []string) bool {
	for _, iface := range ifaces {
		for _, ip := range iface.IPv4s {
			for _, p := range prefixes {
				if p != "" && strings.HasPrefix(ip, p) {
					return true
				}
			}
		}
	}
	return false
}

func boolKey(b bool) string {
	if b {
		return "1"
	}
	return "0"
}

// Locator 在位置模块之上加网关信任判定，交给策略引擎用。
type Locator struct {
	location.Locator
	Store *Store
}

// Trusted 当前网关是否受信任。
func (l Locator) Trusted() bool { return l.Store.Evaluate().Trusted }

// GatewayVerdict 当前判定（给状态接口）。
func (l Locator) GatewayVerdict() Verdict { return l.Store.Evaluate() }
