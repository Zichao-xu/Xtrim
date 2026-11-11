package mihomo

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// fakeKernel 模拟内核：-v 输出版本，否则常驻；收到 FAIL 环境标记时立即报错退出。
const fakeKernel = `#!/bin/sh
case "$1" in -v) echo "Mihomo Meta alpha-test darwin arm64"; exit 0;; esac
if [ -f "$2/../fail" ]; then echo 'level=fatal msg="Parse config error: bad"'; exit 1; fi
exec sleep 60
`

func newTestManager(t *testing.T) *Manager {
	t.Helper()
	m := New(t.TempDir(), t.Logf)
	m.binary = []byte(fakeKernel)
	m.dropPrivileges = false
	return m
}

func waitFor(t *testing.T, cond func() bool) {
	t.Helper()
	for i := 0; i < 100; i++ {
		if cond() {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("timeout")
}

func TestStartStop(t *testing.T) {
	m := newTestManager(t)
	if err := m.Start(); err != nil {
		t.Fatal(err)
	}
	s := m.Status()
	if !s.Running || !s.Desired || s.PID == 0 || s.Version != "alpha-test" {
		t.Fatalf("after start: %+v", s)
	}
	if _, err := os.Stat(m.ConfigPath()); err != nil {
		t.Fatalf("default config not written: %v", err)
	}
	data, _ := os.ReadFile(m.ConfigPath())
	if !strings.Contains(string(data), "bind-address: 127.0.0.1") || strings.Contains(string(data), "tun:") {
		t.Fatalf("default config must stay local-only:\n%s", data)
	}
	if err := m.Stop(); err != nil {
		t.Fatal(err)
	}
	s = m.Status()
	if s.Running || s.Desired || s.LastExit != "" {
		t.Fatalf("after stop: %+v", s)
	}
}

func TestRestoreKeepsDesired(t *testing.T) {
	m := newTestManager(t)
	if err := m.Start(); err != nil {
		t.Fatal(err)
	}
	m.Shutdown() // daemon 退出：停进程但保留「希望运行」
	again := New(m.dir, t.Logf)
	again.binary, again.dropPrivileges = m.binary, false
	if !again.Status().Desired {
		t.Fatal("desired not persisted")
	}
	again.Restore()
	waitFor(t, func() bool { return again.Status().Running })
	again.Shutdown()
}

func TestUnexpectedExitIsReported(t *testing.T) {
	m := newTestManager(t)
	if err := os.WriteFile(filepath.Join(m.dir, "fail"), nil, 0644); err != nil {
		t.Fatal(err)
	}
	if err := m.Start(); err != nil {
		t.Fatal(err)
	}
	waitFor(t, func() bool { return !m.Status().Running })
	if s := m.Status(); !strings.Contains(s.LastExit, "Parse config error") {
		t.Fatalf("exit reason not surfaced: %+v", s)
	}
}

func TestNotBundled(t *testing.T) {
	m := New(t.TempDir(), nil)
	m.binary = nil
	if m.Status().Bundled {
		t.Fatal("should not be bundled")
	}
	if err := m.Start(); err == nil {
		t.Fatal("start without kernel must fail")
	}
}

func TestKeepsUserConfig(t *testing.T) {
	m := newTestManager(t)
	if err := os.MkdirAll(m.dir, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(m.ConfigPath(), []byte("mixed-port: 1\n"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := m.Start(); err != nil {
		t.Fatal(err)
	}
	defer m.Stop()
	data, _ := os.ReadFile(m.ConfigPath())
	if string(data) != "mixed-port: 1\n" {
		t.Fatal("existing config overwritten")
	}
}

func TestApplySelectionsOnceThenClear(t *testing.T) {
	var mu sync.Mutex
	puts := map[string]string{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer s3" {
			w.WriteHeader(401)
			return
		}
		if r.Method == http.MethodPut {
			var body map[string]string
			_ = json.NewDecoder(r.Body).Decode(&body)
			mu.Lock()
			puts[strings.TrimPrefix(r.URL.Path, "/proxies/")] = body["name"]
			mu.Unlock()
			if strings.Contains(r.URL.Path, "missing") {
				w.WriteHeader(404)
				return
			}
			w.WriteHeader(204)
			return
		}
		w.WriteHeader(200)
	}))
	defer srv.Close()
	m := newTestManager(t)
	m.controller = strings.TrimPrefix(srv.URL, "http://")
	m.st.Secret = "s3"
	m.st.Selections = map[string]string{"人工智能": "日本住宅-速率", "missing": "x"}
	m.applySelections()
	mu.Lock()
	defer mu.Unlock()
	if puts["人工智能"] != "日本住宅-速率" {
		t.Fatalf("selection not applied: %v", puts)
	}
	if m.st.Selections != nil {
		t.Fatal("selections must be applied once and cleared")
	}
}
