package api

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/wgsense/core/internal/config"
	"github.com/wgsense/core/internal/location"
	"github.com/wgsense/core/internal/policy"
	"github.com/wgsense/core/internal/service"
	"github.com/wgsense/core/internal/tunnel"
)

type serviceTestTunnel struct {
	state       atomic.Value
	connects    atomic.Int32
	disconnects atomic.Int32
}

func (m *serviceTestTunnel) Connect(string) error {
	m.connects.Add(1)
	m.state.Store(tunnel.StateConnected)
	return nil
}
func (m *serviceTestTunnel) Disconnect(string) error {
	m.disconnects.Add(1)
	m.state.Store(tunnel.StateDisconnected)
	return nil
}
func (m *serviceTestTunnel) Status(string) (tunnel.State, error) {
	return m.state.Load().(tunnel.State), nil
}
func (m *serviceTestTunnel) DiscoverServices() ([]string, error)       { return nil, nil }
func (m *serviceTestTunnel) ConfigDir() string                         { return "" }
func (m *serviceTestTunnel) SaveProfile(string, string) error          { return nil }
func (m *serviceTestTunnel) LoadProfileContent(string) (string, error) { return "", nil }
func (m *serviceTestTunnel) DeleteProfile(string) error                { return nil }
func (m *serviceTestTunnel) InterfaceBytes(string) (uint64, uint64)    { return 0, 0 }

type serviceTestLocation struct{}

func (serviceTestLocation) Trusted() bool                          { return false }
func (serviceTestLocation) CurrentIPv4s() []string                 { return nil }
func (serviceTestLocation) ActiveInterfaces() []location.Interface { return nil }

type serviceTestHealth struct{}

func (serviceTestHealth) CheckConnectivity() bool    { return true }
func (serviceTestHealth) IsStaleConnected(bool) bool { return false }

type serviceTestPause struct{ paused atomic.Bool }

func (p *serviceTestPause) Pause() error   { p.paused.Store(true); return nil }
func (p *serviceTestPause) Resume() error  { p.paused.Store(false); return nil }
func (p *serviceTestPause) IsPaused() bool { return p.paused.Load() }

func newServiceTestServer(state tunnel.State) (*Server, *serviceTestTunnel) {
	tun := &serviceTestTunnel{}
	tun.state.Store(state)
	eng := policy.New(config.Default(), serviceTestLocation{}, tun, serviceTestHealth{}, &serviceTestPause{})
	eng.SetService("test")
	eng.SetNetworkSnapshotFunc(func() string { return "virtual-test-network" })
	return New("", eng, nil, nil), tun
}

// Only API handlers run. The engine is never started, and all network-facing
// policy dependencies are stubs; the listener is an ephemeral loopback port.
func serveServiceTestAPI(t *testing.T, s *Server) (string, *http.Client) {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- s.Serve(listener) }()
	transport := &http.Transport{DisableKeepAlives: true}
	t.Cleanup(func() {
		transport.CloseIdleConnections()
		listener.Close()
		select {
		case <-done:
		case <-time.After(time.Second):
			t.Error("test API did not stop after its listener closed")
		}
	})
	return "http://" + listener.Addr().String(), &http.Client{Transport: transport, Timeout: time.Second}
}

func TestManagedServiceNotReadyBlocksNetworkCommandsButExposesIdentity(t *testing.T) {
	// A nil engine ensures that readiness is checked before any policy call.
	s := New("", nil, nil, nil)
	want := service.Info{Protocol: service.Protocol, Managed: true, OwnerUID: 501, BinarySHA256: "candidate", Ready: false, PID: 123}
	s.SetService(func() service.Info { return want }, nil, nil)
	base, client := serveServiceTestAPI(t, s)
	for _, path := range []string{"/api/connect", "/api/resume", "/api/config"} {
		t.Run(path, func(t *testing.T) {
			resp, err := client.Post(base+path, "application/json", strings.NewReader(`{}`))
			if err != nil {
				t.Fatal(err)
			}
			defer resp.Body.Close()
			if resp.StatusCode != http.StatusServiceUnavailable {
				t.Fatalf("not-ready %s = %d, want 503", path, resp.StatusCode)
			}
		})
	}
	resp, err := client.Get(base + "/api/service")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var got service.Info
	if err := json.NewDecoder(resp.Body).Decode(&got); err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != http.StatusOK || got != want {
		t.Fatalf("identity = %#v, status=%d; want %#v", got, resp.StatusCode, want)
	}
}

func TestManagedServiceReadyGateReleasesConnect(t *testing.T) {
	s, tun := newServiceTestServer(tunnel.StateDisconnected)
	var ready atomic.Bool
	s.SetService(func() service.Info { return service.Info{Managed: true, Ready: ready.Load()} }, nil, nil)
	base, client := serveServiceTestAPI(t, s)
	for _, wantReady := range []bool{false, true} {
		ready.Store(wantReady)
		resp, err := client.Post(base+"/api/connect", "application/json", nil)
		if err != nil {
			t.Fatal(err)
		}
		io.Copy(io.Discard, resp.Body)
		resp.Body.Close()
		wantCode := http.StatusServiceUnavailable
		wantCalls := int32(0)
		if wantReady {
			wantCode, wantCalls = http.StatusOK, 1
		}
		if resp.StatusCode != wantCode || tun.connects.Load() != wantCalls {
			t.Fatalf("ready=%t: status=%d, connect calls=%d; want %d/%d", wantReady, resp.StatusCode, tun.connects.Load(), wantCode, wantCalls)
		}
	}
}

func TestServiceMethodsAndUnsupportedModes(t *testing.T) {
	for _, test := range []struct {
		name, method string
		handler      func(*Server) http.HandlerFunc
		want         int
	}{
		{"identity POST", http.MethodPost, func(s *Server) http.HandlerFunc { return s.handleServiceInfo }, http.StatusMethodNotAllowed},
		{"update GET", http.MethodGet, func(s *Server) http.HandlerFunc { return s.handleServiceUpdate }, http.StatusMethodNotAllowed},
		{"restart GET", http.MethodGet, func(s *Server) http.HandlerFunc { return s.handleServiceRestart }, http.StatusMethodNotAllowed},
		{"update unmanaged", http.MethodPost, func(s *Server) http.HandlerFunc { return s.handleServiceUpdate }, http.StatusConflict},
		{"restart unmanaged", http.MethodPost, func(s *Server) http.HandlerFunc { return s.handleServiceRestart }, http.StatusConflict},
	} {
		t.Run(test.name, func(t *testing.T) {
			s := New("", nil, nil, nil)
			rec := httptest.NewRecorder()
			test.handler(s)(rec, httptest.NewRequest(test.method, "/", strings.NewReader(`{}`)))
			if rec.Code != test.want {
				t.Fatalf("status=%d, want=%d", rec.Code, test.want)
			}
		})
	}
}

func TestServiceIdentityUnmanaged(t *testing.T) {
	s := New("", nil, nil, nil)
	rec := httptest.NewRecorder()
	s.handleServiceInfo(rec, httptest.NewRequest(http.MethodGet, "/api/service", nil))
	var got service.Info
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if rec.Code != http.StatusOK || got.Managed || got.Protocol != service.Protocol || got.PID <= 0 {
		t.Fatalf("invalid unmanaged identity: status=%d info=%#v", rec.Code, got)
	}
}

func TestServiceUpdateRequiresExplicitlyDisconnectedState(t *testing.T) {
	for _, state := range []tunnel.State{tunnel.StateConnected, tunnel.StateConnecting, tunnel.StateUnknown} {
		t.Run(string(state), func(t *testing.T) {
			s, tun := newServiceTestServer(state)
			var calls int
			s.SetService(nil, func(context.Context, service.Request) (service.Request, error) {
				calls++
				return service.Request{}, nil
			}, nil)
			rec := httptest.NewRecorder()
			s.handleServiceUpdate(rec, httptest.NewRequest(http.MethodPost, "/api/service/update", strings.NewReader(`{}`)))
			if rec.Code != http.StatusConflict || calls != 0 || tun.disconnects.Load() != 0 {
				t.Fatalf("%s update: status=%d installer calls=%d disconnects=%d", state, rec.Code, calls, tun.disconnects.Load())
			}
		})
	}
}

func TestServiceUpdateReturnsAcceptedOperationIdentity(t *testing.T) {
	s, _ := newServiceTestServer(tunnel.StateDisconnected)
	var calls int
	s.SetService(nil, func(_ context.Context, req service.Request) (service.Request, error) {
		calls++
		if req.SourceDaemon != "/virtual/candidate" {
			t.Errorf("candidate was not passed to installer: %#v", req)
		}
		if err := s.eng.Connect(); !errors.Is(err, policy.ErrServiceMaintenance) {
			t.Errorf("connect was not frozen during staging: %v", err)
		}
		if err := s.eng.Resume(); !errors.Is(err, policy.ErrServiceMaintenance) {
			t.Errorf("resume was not frozen during staging: %v", err)
		}
		return service.Request{OperationID: "operation-1", BinarySHA256: "hash-1"}, nil
	}, nil)
	rec := httptest.NewRecorder()
	s.handleServiceUpdate(rec, httptest.NewRequest(http.MethodPost, "/api/service/update", strings.NewReader(`{"source_daemon":"/virtual/candidate"}`)))
	var got map[string]string
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if rec.Code != http.StatusAccepted || calls != 1 || got["operation_id"] != "operation-1" || got["binary_sha256"] != "hash-1" {
		t.Fatalf("update result: status=%d calls=%d body=%v", rec.Code, calls, got)
	}
	if got := rec.Result().Header.Get("Content-Type"); got != "application/json" {
		t.Errorf("accepted update Content-Type = %q, want application/json", got)
	}
	if err := s.eng.Connect(); !errors.Is(err, policy.ErrServiceMaintenance) {
		t.Fatalf("accepted update released maintenance before installer completed: %v", err)
	}
}

func TestServiceUpdateInstallerErrorDoesNotReportAccepted(t *testing.T) {
	s, _ := newServiceTestServer(tunnel.StateDisconnected)
	s.SetService(nil, func(context.Context, service.Request) (service.Request, error) {
		return service.Request{}, errors.New("staging failed")
	}, nil)
	rec := httptest.NewRecorder()
	s.handleServiceUpdate(rec, httptest.NewRequest(http.MethodPost, "/api/service/update", strings.NewReader(`{}`)))
	if rec.Code < 400 || !strings.Contains(rec.Body.String(), "staging failed") {
		t.Fatalf("installer failure was lost: status=%d body=%s", rec.Code, rec.Body.String())
	}
	if err := s.eng.Connect(); err != nil {
		t.Fatalf("failed staging left the engine frozen: %v", err)
	}
}

func TestServiceUpdateInvalidBodyDoesNotFreezeEngine(t *testing.T) {
	s, _ := newServiceTestServer(tunnel.StateDisconnected)
	var calls int
	s.SetService(nil, func(context.Context, service.Request) (service.Request, error) {
		calls++
		return service.Request{}, nil
	}, nil)
	rec := httptest.NewRecorder()
	s.handleServiceUpdate(rec, httptest.NewRequest(http.MethodPost, "/api/service/update", strings.NewReader(`{"broken":`)))
	if rec.Code < 400 || calls != 0 {
		t.Fatalf("invalid body: status=%d installer calls=%d", rec.Code, calls)
	}
	if err := s.eng.Connect(); err != nil {
		t.Fatalf("invalid request left the engine frozen: %v", err)
	}
}

func TestServiceRestartInvokesOneCallback(t *testing.T) {
	s := New("", nil, nil, nil)
	var calls atomic.Int32
	called := make(chan struct{}, 2)
	s.SetService(nil, nil, func() { calls.Add(1); called <- struct{}{} })
	rec := httptest.NewRecorder()
	s.handleServiceRestart(rec, httptest.NewRequest(http.MethodPost, "/api/service/restart", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("restart status=%d", rec.Code)
	}
	select {
	case <-called:
	case <-time.After(time.Second):
		t.Fatal("restart callback was not invoked")
	}
	if calls.Load() != 1 {
		t.Fatalf("restart callback count=%d, want 1", calls.Load())
	}
}

func TestServiceRestartNotReadyDoesNotInvokeCallback(t *testing.T) {
	s := New("", nil, nil, nil)
	var calls atomic.Int32
	s.SetService(func() service.Info { return service.Info{Managed: true, Ready: false} }, nil, func() { calls.Add(1) })
	rec := httptest.NewRecorder()
	s.handleServiceRestart(rec, httptest.NewRequest(http.MethodPost, "/api/service/restart", nil))
	if rec.Code != http.StatusConflict || calls.Load() != 0 {
		t.Fatalf("not-ready restart: status=%d callbacks=%d", rec.Code, calls.Load())
	}
}
