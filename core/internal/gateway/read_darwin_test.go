package gateway

import (
	"testing"

	"github.com/wgsense/core/internal/location"
)

// 在真实网络上读一次网关：有默认网关时必须读到 IP 与 MAC。没联网的机器上跳过。
func TestReadLiveGateway(t *testing.T) {
	ifaces := location.New().ActiveInterfaces()
	cur, ok := Read(ifaces)
	if !ok {
		t.Skip("no physical default gateway on this machine")
	}
	if cur.IP == "" || cur.Interface == "" {
		t.Fatalf("incomplete gateway: %+v", cur)
	}
	if cur.MAC == "" {
		t.Fatalf("gateway %s on %s has no MAC even after poking ARP", cur.IP, cur.Interface)
	}
	t.Logf("gateway %s on %s (%s) mac %s", cur.IP, cur.Interface, cur.HardwarePort, cur.MAC)
}
