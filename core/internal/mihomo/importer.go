package mihomo

import (
	"archive/tar"
	"compress/gzip"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"gopkg.in/yaml.v3"
)

// 从 op（路由器）同步来的配置包：App 用 SSH 打包 /etc/mihomo 下的这些文件交给 daemon，
// daemon 只取白名单里的文件，把路由器专用的部分改写成 Mac 版，校验通过才替换。
//
// 白名单：配置、机场节点文件、规则源缓存、GEO 数据库。其余（ssh 密钥、cache.db、面板等）一律不收。
var importAllow = []string{
	"config.yaml", "airport.yaml",
	"GeoIP.dat", "GeoSite.dat", "Country.mmdb", "ASN.mmdb",
}

const importRuleDir = "rule_provider/"

// 单个文件上限，防止异常包把磁盘写满。
const importMaxFile = 64 << 20

// TUNDNS 是 TUN 里的 DNS 地址：系统 DNS 指向这里，查询进 TUN 被内核接管（fake-ip）。
const TUNDNS = "198.18.0.2"

// 路由器专用、在 Mac 上要去掉的顶层键。
var dropKeys = map[string]string{
	"port": "", "socks-port": "", "redir-port": "", "tproxy-port": "",
	"authentication": "", "external-controller": "", "external-controller-tls": "",
	"external-controller-cors": "", "external-controller-unix": "", "secret": "",
	"external-ui": "", "external-ui-name": "", "external-ui-url": "",
	"ntp":            "", // write-to-system 会改本机时间
	"interface-name": "", // 路由器上的出口网卡名
	"routing-mark":   "", // 路由器 nft 用的标记
	"iptables":       "",
}

// Import 导入配置包（tar.gz）。origin 记录来源（如 root@10.10.1.1:/etc/mihomo）。
// 内核正在运行时，导入成功后重启内核生效。
func (m *Manager) Import(bundle, origin string) error {
	if !m.Bundled() {
		return errors.New("这份网络服务没有内置代理内核")
	}
	m.mu.Lock()
	if err := m.prepareLocked(); err != nil {
		m.mu.Unlock()
		return err
	}
	m.mu.Unlock()

	stage, err := os.MkdirTemp(m.dir, "import-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(stage)
	stageData := filepath.Join(stage, "data")
	if err := extractBundle(bundle, stageData); err != nil {
		return fmt.Errorf("解包失败: %w", err)
	}
	raw, err := os.ReadFile(filepath.Join(stageData, "config.yaml"))
	if err != nil {
		return errors.New("配置包里没有 config.yaml")
	}
	out, dropped, err := TransformForMac(raw)
	if err != nil {
		return fmt.Errorf("改写配置失败: %w", err)
	}
	stageConfig := filepath.Join(stage, "config.yaml")
	if err := os.WriteFile(stageConfig, out, 0644); err != nil {
		return err
	}
	// 原件留在数据目录里，便于对照
	if err := os.Rename(filepath.Join(stageData, "config.yaml"), filepath.Join(stageData, "source.yaml")); err != nil {
		return err
	}
	if err := m.testConfig(stageData, stageConfig); err != nil {
		return err
	}

	// 校验通过：替换数据文件与配置
	m.mu.Lock()
	running := m.cmd != nil
	m.mu.Unlock()
	if running {
		m.terminate()
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := mergeInto(stageData, m.dataDir()); err != nil {
		return err
	}
	if err := os.Rename(stageConfig, m.ConfigPath()); err != nil {
		return err
	}
	if m.dropPrivileges {
		_ = chownTree(m.dataDir(), 0, nobodyID)
	}
	m.st.Source = origin
	m.st.SyncedAt = time.Now().Format(time.RFC3339)
	m.st.Dropped = dropped
	if err := m.saveLocked(); err != nil {
		return err
	}
	m.logf("内置代理内核配置已从 %s 同步", origin)
	if running {
		return m.startLocked()
	}
	return nil
}

// testConfig 用内核自带的 -t 校验配置。
func (m *Manager) testConfig(dataDir, config string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, m.binPath(), "-t", "-d", dataDir, "-f", config).CombinedOutput()
	if err != nil {
		msg := strings.TrimSpace(string(out))
		if i := strings.LastIndex(msg, "msg="); i >= 0 {
			msg = strings.Trim(msg[i+4:], `"`)
		}
		return fmt.Errorf("配置校验未通过: %s", msg)
	}
	return nil
}

// TransformForMac 把路由器上的配置改写成 Mac 版：
// 去掉透明代理端口、局域网监听、面板与改系统时间的项；只在本机监听；
// TUN 改为自动接管路由与 DNS；DNS 只在本机监听。策略组、规则原样保留。
// 依赖路由器本机文件的节点（如引用 /etc/mihomo/ssh 私钥的 SSH 节点）在 Mac 上用不了，
// 连同经它中转的节点一起剔除并从策略组里摘掉，返回剔除的节点名。私钥不随配置同步。
func TransformForMac(raw []byte) ([]byte, []string, error) {
	var doc yaml.Node
	if err := yaml.Unmarshal(raw, &doc); err != nil {
		return nil, nil, err
	}
	if len(doc.Content) == 0 || doc.Content[0].Kind != yaml.MappingNode {
		return nil, nil, errors.New("顶层不是映射")
	}
	root := doc.Content[0]
	var kept []*yaml.Node
	for i := 0; i+1 < len(root.Content); i += 2 {
		key := root.Content[i].Value
		if _, drop := dropKeys[key]; drop {
			continue
		}
		kept = append(kept, root.Content[i], root.Content[i+1])
	}
	root.Content = kept

	setScalar(root, "mixed-port", fmt.Sprint(DefaultMixedPort), "!!int")
	setScalar(root, "allow-lan", "false", "!!bool")
	setScalar(root, "bind-address", "127.0.0.1", "")
	setScalar(root, "find-process-mode", "off", "")

	// TUN：整机接管
	var tun yaml.Node
	if err := yaml.Unmarshal([]byte(`
enable: true
stack: mixed
auto-route: true
auto-detect-interface: true
strict-route: false
dns-hijack: ["any:53", "tcp://any:53"]
`), &tun); err != nil {
		return nil, nil, err
	}
	setNode(root, "tun", tun.Content[0])

	// DNS：只在本机监听（查询经 TUN 劫持进来，不需要对外端口）
	if dns := getNode(root, "dns"); dns != nil && dns.Kind == yaml.MappingNode {
		setScalar(dns, "listen", "127.0.0.1:1053", "")
	}
	dropped := dropRouterOnlyProxies(root)
	out, err := yaml.Marshal(&doc)
	return out, dropped, err
}

// 指向路由器本机文件的字段：这些节点在 Mac 上读不到文件。
var routerFileKeys = map[string]bool{"private-key": true, "private-key-path": true, "certificate": true, "ca": true}

func deref(n *yaml.Node) *yaml.Node {
	for n != nil && n.Kind == yaml.AliasNode {
		n = n.Alias
	}
	return n
}

func dropRouterOnlyProxies(root *yaml.Node) []string {
	proxies := deref(getNode(root, "proxies"))
	if proxies == nil || proxies.Kind != yaml.SequenceNode {
		return nil
	}
	removed := map[string]bool{}
	nameOf := func(p *yaml.Node) string {
		if v := getNode(p, "name"); v != nil {
			return v.Value
		}
		return ""
	}
	for _, p := range proxies.Content {
		p = deref(p)
		if p.Kind != yaml.MappingNode {
			continue
		}
		for i := 0; i+1 < len(p.Content); i += 2 {
			if routerFileKeys[p.Content[i].Value] && strings.HasPrefix(deref(p.Content[i+1]).Value, "/") {
				removed[nameOf(p)] = true
			}
		}
	}
	// 经被剔除节点中转的节点（dialer-proxy）一并剔除，直到不再变化
	for changed := true; changed; {
		changed = false
		for _, p := range proxies.Content {
			p = deref(p)
			if p.Kind != yaml.MappingNode || removed[nameOf(p)] {
				continue
			}
			if d := getNode(p, "dialer-proxy"); d != nil && removed[deref(d).Value] {
				removed[nameOf(p)] = true
				changed = true
			}
		}
	}
	if len(removed) == 0 {
		return nil
	}
	var keep []*yaml.Node
	for _, p := range proxies.Content {
		if !removed[nameOf(deref(p))] {
			keep = append(keep, p)
		}
	}
	proxies.Content = keep

	// 从策略组的 proxies 列表里摘掉（列表可能是锚点，改一处所有引用都生效）
	seen := map[*yaml.Node]bool{}
	if groups := deref(getNode(root, "proxy-groups")); groups != nil {
		for _, g := range groups.Content {
			g = deref(g)
			if g.Kind != yaml.MappingNode {
				continue
			}
			list := deref(getNode(g, "proxies"))
			if list == nil || list.Kind != yaml.SequenceNode || seen[list] {
				continue
			}
			seen[list] = true
			var items []*yaml.Node
			for _, it := range list.Content {
				if !removed[deref(it).Value] {
					items = append(items, it)
				}
			}
			list.Content = items
		}
		// 摘空了又没有 use / include-all 的组补一个 REJECT：宁可不通，也不直连
		for _, g := range groups.Content {
			g = deref(g)
			if g.Kind != yaml.MappingNode {
				continue
			}
			list := deref(getNode(g, "proxies"))
			if list != nil && list.Kind == yaml.SequenceNode && len(list.Content) == 0 &&
				getNode(g, "use") == nil && getNode(g, "include-all") == nil && getNode(g, "include-all-proxies") == nil {
				list.Content = []*yaml.Node{{Kind: yaml.ScalarNode, Value: "REJECT"}}
			}
		}
	}
	names := make([]string, 0, len(removed))
	for n := range removed {
		names = append(names, n)
	}
	sort.Strings(names)
	return names
}

func getNode(m *yaml.Node, key string) *yaml.Node {
	for i := 0; i+1 < len(m.Content); i += 2 {
		if m.Content[i].Value == key {
			return m.Content[i+1]
		}
	}
	return nil
}

func setNode(m *yaml.Node, key string, value *yaml.Node) {
	for i := 0; i+1 < len(m.Content); i += 2 {
		if m.Content[i].Value == key {
			m.Content[i+1] = value
			return
		}
	}
	m.Content = append(m.Content, &yaml.Node{Kind: yaml.ScalarNode, Value: key}, value)
}

func setScalar(m *yaml.Node, key, value, tag string) {
	setNode(m, key, &yaml.Node{Kind: yaml.ScalarNode, Value: value, Tag: tag})
}

// extractBundle 只解出白名单里的普通文件，拒绝绝对路径与 ..。
func extractBundle(bundle, dest string) error {
	f, err := os.Open(bundle)
	if err != nil {
		return err
	}
	defer f.Close()
	gz, err := gzip.NewReader(f)
	if err != nil {
		return err
	}
	tr := tar.NewReader(gz)
	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
		if hdr.Typeflag != tar.TypeReg {
			continue
		}
		name := path.Clean(strings.TrimPrefix(hdr.Name, "./"))
		if !allowedEntry(name) || hdr.Size > importMaxFile {
			continue
		}
		target := filepath.Join(dest, filepath.FromSlash(name))
		if err := os.MkdirAll(filepath.Dir(target), 0755); err != nil {
			return err
		}
		out, err := os.OpenFile(target, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0644)
		if err != nil {
			return err
		}
		_, err = io.Copy(out, io.LimitReader(tr, importMaxFile))
		out.Close()
		if err != nil {
			return err
		}
	}
}

func allowedEntry(name string) bool {
	if name == "" || strings.HasPrefix(name, "/") || strings.HasPrefix(name, "..") || strings.Contains(name, "/../") {
		return false
	}
	for _, a := range importAllow {
		if name == a {
			return true
		}
	}
	// 规则源路径本身带斜杠（如 "rule_provider/Google / IP"），子目录照收
	rest := strings.TrimPrefix(name, importRuleDir)
	return rest != name && rest != ""
}

// mergeInto 把 src 下的文件覆盖进 dst（保留 dst 里其他文件，如 cache.db）。
func mergeInto(src, dst string) error {
	return filepath.Walk(src, func(p string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(src, p)
		target := filepath.Join(dst, rel)
		if info.IsDir() {
			return os.MkdirAll(target, 0755)
		}
		return os.Rename(p, target)
	})
}

func chownTree(dir string, uid, gid int) error {
	return filepath.Walk(dir, func(p string, _ os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		return os.Lchown(p, uid, gid)
	})
}
