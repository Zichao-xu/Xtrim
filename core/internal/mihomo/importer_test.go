package mihomo

import (
	"archive/tar"
	"compress/gzip"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
)

const routerConfig = `
rules:
  - MATCH,其他
proxy-groups:
  - {name: 其他, type: select, proxies: [DIRECT]}
proxies: []
mode: rule
allow-lan: true
bind-address: "*"
port: 7890
socks-port: 7891
redir-port: 7892
tproxy-port: 7895
mixed-port: 7893
authentication: ["Clash:x"]
external-controller: 0.0.0.0:9090
secret: "x"
external-ui: /etc/mihomo/ui
ntp: {enable: true, server: time.apple.com, write-to-system: true}
routing-mark: 6666
dns:
  enable: true
  listen: 0.0.0.0:7874
  enhanced-mode: fake-ip
tun:
  enable: true
  auto-route: false
  dns-hijack: ["127.0.0.1:53"]
`

func TestTransformForMac(t *testing.T) {
	out, _, err := TransformForMac([]byte(routerConfig))
	if err != nil {
		t.Fatal(err)
	}
	var cfg map[string]interface{}
	if err := yaml.Unmarshal(out, &cfg); err != nil {
		t.Fatal(err)
	}
	for _, k := range []string{"port", "socks-port", "redir-port", "tproxy-port", "authentication", "external-controller", "secret", "external-ui", "ntp", "routing-mark"} {
		if _, ok := cfg[k]; ok {
			t.Errorf("router-only key %q kept", k)
		}
	}
	if cfg["allow-lan"] != false || cfg["bind-address"] != "127.0.0.1" || cfg["mixed-port"] != DefaultMixedPort {
		t.Errorf("listen settings not localised: %v %v %v", cfg["allow-lan"], cfg["bind-address"], cfg["mixed-port"])
	}
	tun := cfg["tun"].(map[string]interface{})
	if tun["auto-route"] != true || tun["enable"] != true {
		t.Errorf("tun must take over routes: %v", tun)
	}
	if dns := cfg["dns"].(map[string]interface{}); dns["listen"] != "127.0.0.1:1053" || dns["enhanced-mode"] != "fake-ip" {
		t.Errorf("dns: %v", dns)
	}
	if !strings.Contains(string(out), "MATCH,其他") {
		t.Error("rules must be kept verbatim")
	}
}

func TestExtractBundleWhitelist(t *testing.T) {
	dir := t.TempDir()
	bundle := filepath.Join(dir, "b.tgz")
	f, _ := os.Create(bundle)
	gz := gzip.NewWriter(f)
	tw := tar.NewWriter(gz)
	for name, body := range map[string]string{
		"config.yaml":               "a: 1\n",
		"rule_provider/Google / IP": "1.1.1.0/24\n",
		"ssh/id_rsa":                "secret",
		"../escape":                 "x",
		"cache.db":                  "x",
	} {
		_ = tw.WriteHeader(&tar.Header{Name: name, Mode: 0644, Size: int64(len(body)), Typeflag: tar.TypeReg})
		_, _ = tw.Write([]byte(body))
	}
	tw.Close()
	gz.Close()
	f.Close()

	dest := filepath.Join(dir, "out")
	if err := extractBundle(bundle, dest); err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"config.yaml", "rule_provider/Google / IP"} {
		if _, err := os.Stat(filepath.Join(dest, want)); err != nil {
			t.Errorf("missing %s", want)
		}
	}
	for _, bad := range []string{"ssh/id_rsa", "cache.db"} {
		if _, err := os.Stat(filepath.Join(dest, bad)); err == nil {
			t.Errorf("%s must not be extracted", bad)
		}
	}
	if _, err := os.Stat(filepath.Join(dir, "escape")); err == nil {
		t.Error("path traversal")
	}
}

func TestReadyRequiresSyncedConfig(t *testing.T) {
	m := newTestManager(t)
	if m.Ready() == nil {
		t.Fatal("default config must not be usable as an exit")
	}
	m.st.Source = "root@op:/etc/mihomo"
	if err := m.Ready(); err != nil {
		t.Fatal(err)
	}
}

func TestServiceForDevice(t *testing.T) {
	listing := "Hardware Port: Ethernet\nDevice: en7\n\nHardware Port: Wi-Fi\nDevice: en0\nEthernet Address: x\n"
	if s, err := serviceForDevice(listing, "en0"); err != nil || s != "Wi-Fi" {
		t.Fatalf("got %q %v", s, err)
	}
}

func TestDropRouterOnlyProxies(t *testing.T) {
	src := `
x-anchors:
  all: &all [SSH通道, 经SSH, 日本, DIRECT]
proxies:
  - {name: SSH通道, type: ssh, server: 1.2.3.4, private-key: /etc/mihomo/ssh/key}
  - {name: 经SSH, type: socks5, server: 127.0.0.1, port: 1080, dialer-proxy: SSH通道}
  - {name: 日本, type: hysteria2, server: 5.6.7.8, port: 443}
proxy-groups:
  - {name: 甲, type: select, proxies: *all}
  - {name: 乙, type: select, proxies: [经SSH]}
rules:
  - MATCH,甲
`
	out, dropped, err := TransformForMac([]byte(src))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(dropped, ",") != "SSH通道,经SSH" {
		t.Fatalf("dropped %v", dropped)
	}
	if strings.Contains(string(out), "/etc/mihomo/ssh") {
		t.Fatal("router key path must not survive")
	}
	var cfg struct {
		Proxies []map[string]interface{} `yaml:"proxies"`
		Groups  []struct {
			Name    string   `yaml:"name"`
			Proxies []string `yaml:"proxies"`
		} `yaml:"proxy-groups"`
	}
	if err := yaml.Unmarshal(out, &cfg); err != nil {
		t.Fatal(err)
	}
	if len(cfg.Proxies) != 1 || cfg.Proxies[0]["name"] != "日本" {
		t.Fatalf("proxies: %v", cfg.Proxies)
	}
	if strings.Join(cfg.Groups[0].Proxies, ",") != "日本,DIRECT" {
		t.Fatalf("anchored list: %v", cfg.Groups[0].Proxies)
	}
	if strings.Join(cfg.Groups[1].Proxies, ",") != "REJECT" {
		t.Fatalf("emptied group must reject, got %v", cfg.Groups[1].Proxies)
	}
}
