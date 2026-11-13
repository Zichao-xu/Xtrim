package netstate

import (
	"os/exec"
	"strings"
	"testing"
)

func TestDefaultRouteMatchesRouteCommand(t *testing.T) {
	out, err := exec.Command("route", "-n", "get", "default").CombinedOutput()
	if err != nil {
		t.Skipf("no default route: %v", err)
	}
	var gateway, iface string
	for _, line := range strings.Split(string(out), "\n") {
		key, value, ok := strings.Cut(strings.TrimSpace(line), ":")
		if !ok {
			continue
		}
		switch strings.TrimSpace(key) {
		case "gateway":
			gateway = strings.TrimSpace(value)
		case "interface":
			iface = strings.TrimSpace(value)
		}
	}
	if gi, gg := DefaultRoute(); gi+"@"+gg != iface+"@"+gateway {
		got, want := gi+"@"+gg, iface+"@"+gateway
		t.Fatalf("defaultRoute() = %q, route command = %q", got, want)
	}
}
