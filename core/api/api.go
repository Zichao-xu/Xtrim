// Package api 提供本地 HTTP API，供 UI(原生 app)调用。
// 桌面：监听 127.0.0.1，UI 通过 HTTP 调用。
// 移动：不走 HTTP，通过 gomobile FFI 直接调用(阶段 4)。
package api

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/wgsense/core/internal/service"
	"log"
	"net"
	"net/http"
	"os"

	"github.com/wgsense/core/internal/config"
	"github.com/wgsense/core/internal/firewall"
	"github.com/wgsense/core/internal/mihomo"
	"github.com/wgsense/core/internal/policy"
	"github.com/wgsense/core/internal/proxy"
	"github.com/wgsense/core/internal/transfer"
	"github.com/wgsense/core/internal/tunnel"
)

// Server 是本地 HTTP API 服务。
type Server struct {
	eng            *policy.Engine
	addr           string
	transSvc       *transfer.Service
	proxySvc       *proxy.Service
	shutdown       func()
	serviceInfo    func() service.Info
	updateService  func(context.Context, service.Request) (service.Request, error)
	restartService func()
	mihomo         *mihomo.Manager
}

// SetMihomo 接上内置代理内核；不接时 /api/mihomo 报不可用。
func (s *Server) SetMihomo(m *mihomo.Manager) { s.mihomo = m }

func (s *Server) SetService(info func() service.Info, update func(context.Context, service.Request) (service.Request, error), restart func()) {
	s.serviceInfo, s.updateService, s.restartService = info, update, restart
}

// New 创建 API 服务。addr 如 "127.0.0.1:8765"。
func New(addr string, eng *policy.Engine, transSvc *transfer.Service, proxySvc *proxy.Service) *Server {
	return &Server{eng: eng, addr: addr, transSvc: transSvc, proxySvc: proxySvc}
}

func (s *Server) SetShutdown(fn func()) {
	s.shutdown = fn
}

// Start 启动 HTTP server（阻塞）。
func (s *Server) Start() error {
	listener, err := net.Listen("tcp", s.addr)
	if err != nil {
		return err
	}
	return s.Serve(listener)
}

// Serve uses an already-bound listener so the daemon can reserve its control
// endpoint before starting anything that may change routes or DNS.
func (s *Server) Serve(listener net.Listener) error {
	mux := http.NewServeMux()
	mux.HandleFunc("/api/status", s.handleStatus)
	mux.HandleFunc("/api/connect", s.handleConnect)
	mux.HandleFunc("/api/disconnect", s.handleDisconnect)
	mux.HandleFunc("/api/pause", s.handlePause)
	mux.HandleFunc("/api/resume", s.handleResume)
	mux.HandleFunc("/api/profiles", s.handleProfiles)
	mux.HandleFunc("/api/profile/import", s.handleProfileImport)
	mux.HandleFunc("/api/profile/export", s.handleProfileExport)
	mux.HandleFunc("/api/profile/save", s.handleProfileSave)
	mux.HandleFunc("/api/profile/delete", s.handleProfileDelete)
	mux.HandleFunc("/api/config", s.handleConfig)
	mux.HandleFunc("/api/firewall", s.handleFirewall)
	mux.HandleFunc("/api/tunnel/ipv6", s.handleTunnelIPv6)
	mux.HandleFunc("/api/mihomo", s.handleMihomo)
	mux.HandleFunc("/api/exit", s.handleExit)
	mux.HandleFunc("/api/logs", s.handleLogs)
	mux.HandleFunc("/api/traffic", s.handleTraffic)
	mux.HandleFunc("/api/shutdown", s.handleShutdown)
	mux.HandleFunc("/api/service", s.handleServiceInfo)
	mux.HandleFunc("/api/service/update", s.handleServiceUpdate)
	mux.HandleFunc("/api/service/restart", s.handleServiceRestart)
	mux.HandleFunc("/api/transfer/devices", s.handleTransferDevices)
	mux.HandleFunc("/api/transfer/scan", s.handleTransferScan)
	mux.HandleFunc("/api/transfer/add-device", s.handleTransferAddDevice)
	mux.HandleFunc("/api/transfer/remove-device", s.handleTransferRemoveDevice)
	mux.HandleFunc("/api/transfer/send", s.handleTransferSend)
	mux.HandleFunc("/api/transfer/tasks", s.handleTransferTasks)
	mux.HandleFunc("/api/transfer/start", s.handleTransferStart)
	mux.HandleFunc("/api/transfer/stop", s.handleTransferStop)
	mux.HandleFunc("/api/transfer/receive", s.handleTransferReceive)
	mux.HandleFunc("/api/transfer/decision", s.handleTransferDecision)
	mux.HandleFunc("/api/transfer/cancel", s.handleTransferCancel)

	// 代理管理 (Mihomo 面板)
	mux.HandleFunc("/api/proxy/status", proxy.ProxyStatusHandler(s.proxySvc))
	mux.HandleFunc("/api/proxy/settings", proxy.SettingsHandler(s.proxySvc))
	mux.HandleFunc("/api/proxy/version", proxy.VersionHandler(s.proxySvc))
	mux.HandleFunc("/api/proxy/proxies", proxy.ProxiesHandler(s.proxySvc))
	mux.HandleFunc("/api/proxy/select", proxy.SelectProxyHandler(s.proxySvc))
	mux.HandleFunc("/api/proxy/delay", proxy.DelayTestHandler(s.proxySvc))
	mux.HandleFunc("/api/proxy/providers", proxy.ProvidersHandler(s.proxySvc))
	mux.HandleFunc("/api/proxy/provider-update", proxy.UpdateProviderHandler(s.proxySvc))
	mux.HandleFunc("/api/proxy/provider-healthcheck", proxy.ProviderHealthCheckHandler(s.proxySvc))
	mux.HandleFunc("/api/proxy/connections", proxy.ConnectionsHandler(s.proxySvc))
	mux.HandleFunc("/api/proxy/connection-close", proxy.CloseConnectionHandler(s.proxySvc))
	mux.HandleFunc("/api/proxy/connections-close-all", proxy.CloseAllConnectionsHandler(s.proxySvc))
	mux.HandleFunc("/api/proxy/rules", proxy.RulesHandler(s.proxySvc))
	mux.HandleFunc("/api/proxy/rule-providers", proxy.RuleProvidersHandler(s.proxySvc))
	mux.HandleFunc("/api/proxy/rule-provider-update", proxy.UpdateRuleProviderHandler(s.proxySvc))
	mux.HandleFunc("/api/proxy/configs", proxy.ConfigsHandler(s.proxySvc))
	mux.HandleFunc("/api/proxy/cache", proxy.CacheHandler(s.proxySvc))
	mux.HandleFunc("/api/proxy/action", proxy.ActionHandler(s.proxySvc))
	mux.HandleFunc("/api/proxy/dns-query", proxy.DNSQueryHandler(s.proxySvc))
	mux.HandleFunc("/api/proxy/logs", proxy.ProxyLogsHandler(s.proxySvc))
	srv := &http.Server{
		Addr: s.addr,
		Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			// During staging/health verification a newly installed service must
			// answer identity checks without acting on any network commands.
			if s.serviceInfo != nil && !s.serviceInfo().Ready && (r.URL.Path == "/api/connect" || r.URL.Path == "/api/resume" || r.URL.Path == "/api/config") {
				http.Error(w, "系统服务安装尚未完成，请稍后重试", http.StatusServiceUnavailable)
				return
			}
			mux.ServeHTTP(w, r)
		}),
	}
	return srv.Serve(listener)
}

func (s *Server) handleServiceInfo(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if s.serviceInfo == nil {
		writeJSON(w, service.Info{Protocol: service.Protocol, Managed: false, PID: os.Getpid()})
		return
	}
	writeJSON(w, s.serviceInfo())
}
func (s *Server) handleServiceUpdate(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if s.updateService == nil {
		http.Error(w, "需要先安装持久系统服务", http.StatusConflict)
		return
	}
	var req service.Request
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64<<10)).Decode(&req); err != nil {
		writeError(w, err)
		return
	}
	if err := s.eng.BeginServiceMaintenance(); err != nil {
		http.Error(w, "请先断开当前 WgSense VPN，或等待当前安装完成: "+err.Error(), http.StatusConflict)
		return
	}
	result, err := s.updateService(r.Context(), req)
	if err != nil {
		s.eng.EndServiceMaintenance()
		writeError(w, err)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusAccepted)
	writeJSON(w, map[string]string{"operation_id": result.OperationID, "binary_sha256": result.BinarySHA256})
}
func (s *Server) handleServiceRestart(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if s.restartService == nil {
		http.Error(w, "当前不是持久系统服务", http.StatusConflict)
		return
	}
	if s.serviceInfo != nil && !s.serviceInfo().Ready {
		http.Error(w, "系统服务事务尚未完成", http.StatusConflict)
		return
	}
	writeJSON(w, map[string]bool{"ok": true})
	go s.restartService()
}

func (s *Server) handleShutdown(w http.ResponseWriter, r *http.Request) {
	if s.shutdown == nil {
		writeError(w, fmt.Errorf("当前 daemon 不是 App 临时服务，拒绝关闭"))
		return
	}
	writeJSON(w, map[string]bool{"ok": true})
	go s.shutdown()
}

func (s *Server) handleStatus(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, s.eng.Status())
}

func (s *Server) handleConnect(w http.ResponseWriter, r *http.Request) {
	log.Printf("[api] manual connect requested")
	if err := s.eng.Connect(); err != nil {
		log.Printf("[api] manual connect failed: %v", err)
		writeError(w, err)
		return
	}
	log.Printf("[api] manual connect succeeded")
	writeJSON(w, map[string]bool{"ok": true})
}

func (s *Server) handleDisconnect(w http.ResponseWriter, r *http.Request) {
	log.Printf("[api] manual disconnect requested")
	if err := s.eng.Disconnect(); err != nil {
		log.Printf("[api] manual disconnect failed: %v", err)
		writeError(w, err)
		return
	}
	log.Printf("[api] manual disconnect succeeded")
	writeJSON(w, map[string]bool{"ok": true})
}

func (s *Server) handlePause(w http.ResponseWriter, r *http.Request) {
	log.Printf("[api] manual pause requested")
	if err := s.eng.Pause(); err != nil {
		log.Printf("[api] manual pause failed: %v", err)
		writeError(w, err)
		return
	}
	log.Printf("[api] manual pause succeeded")
	writeJSON(w, map[string]bool{"ok": true})
}

func (s *Server) handleResume(w http.ResponseWriter, r *http.Request) {
	log.Printf("[api] manual resume requested")
	if err := s.eng.Resume(); err != nil {
		log.Printf("[api] manual resume failed: %v", err)
		writeError(w, err)
		return
	}
	log.Printf("[api] manual resume succeeded")
	writeJSON(w, map[string]bool{"ok": true})
}

func (s *Server) handleProfiles(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, s.eng.Profiles())
}

// handleProfileImport 接收 .conf 文本 + name，保存为新 profile。
// POST /api/profile/import  body: {"name":"myvpn","content":"[Interface]\n..."}
func (s *Server) handleProfileImport(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Name    string `json:"name"`
		Content string `json:"content"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, err)
		return
	}
	if req.Name == "" || req.Content == "" {
		writeError(w, fmt.Errorf("name 和 content 不能为空"))
		return
	}
	if err := s.eng.ImportProfile(req.Name, req.Content); err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, map[string]bool{"ok": true})
}

// handleProfileExport 返回指定 profile 的 .conf 文本。
// GET /api/profile/export?name=myvpn
func (s *Server) handleProfileExport(w http.ResponseWriter, r *http.Request) {
	name := r.URL.Query().Get("name")
	if name == "" {
		writeError(w, fmt.Errorf("缺少 name 参数"))
		return
	}
	content, err := s.eng.ExportProfile(name)
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, map[string]string{"name": name, "content": content})
}

// handleProfileSave 接收手动填写的字段，构造 .conf 并保存。
// POST /api/profile/save  body: Profile JSON
func (s *Server) handleProfileSave(w http.ResponseWriter, r *http.Request) {
	var p config.Profile
	if err := json.NewDecoder(r.Body).Decode(&p); err != nil {
		writeError(w, err)
		return
	}
	if p.Name == "" {
		writeError(w, fmt.Errorf("name 不能为空"))
		return
	}
	content := config.Serialize(&p)
	if err := s.eng.ImportProfile(p.Name, content); err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, map[string]bool{"ok": true})
}

// handleProfileDelete 删除指定 profile。
// POST /api/profile/delete?name=myvpn
func (s *Server) handleProfileDelete(w http.ResponseWriter, r *http.Request) {
	name := r.URL.Query().Get("name")
	if name == "" {
		writeError(w, fmt.Errorf("缺少 name 参数"))
		return
	}
	if err := s.eng.DeleteProfile(name); err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, map[string]bool{"ok": true})
}

type firewallResponse struct {
	Settings firewall.Settings `json:"settings"`
	Status   firewall.Status   `json:"status"`
}

// handleFirewall GET 返回出站拦截设置与状态，POST 更新设置并立即生效。
func (s *Server) handleFirewall(w http.ResponseWriter, r *http.Request) {
	fw := s.eng.Firewall()
	if fw == nil {
		http.Error(w, "出站拦截需要以 root 运行的正式网络服务", http.StatusConflict)
		return
	}
	switch r.Method {
	case http.MethodGet:
	case http.MethodPost:
		// 从当前设置解码：旧版 App 不带 allow_hosts 时不能把放行名单清空。
		settings := fw.Settings()
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64<<10)).Decode(&settings); err != nil {
			writeError(w, err)
			return
		}
		if err := fw.Update(settings); err != nil {
			writeError(w, err)
			return
		}
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	writeJSON(w, firewallResponse{Settings: fw.Settings(), Status: fw.Status()})
}

// handleMihomo GET 返回内置代理内核状态；POST {"action":"start"|"stop"} 启停。
func (s *Server) handleMihomo(w http.ResponseWriter, r *http.Request) {
	if s.mihomo == nil {
		http.Error(w, "这份网络服务没有接入内置代理内核", http.StatusConflict)
		return
	}
	switch r.Method {
	case http.MethodGet:
	case http.MethodPost:
		var req struct {
			Action string `json:"action"`
		}
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10)).Decode(&req); err != nil {
			writeError(w, err)
			return
		}
		var err error
		switch req.Action {
		case "start":
			// 启动内核 = 把出口切到 mihomo：与 WireGuard 互斥由引擎保证
			if s.eng.Exit() == policy.ExitMihomo {
				err = s.mihomo.Start()
			} else {
				err = s.eng.SetExit(policy.ExitMihomo)
			}
		case "stop":
			err = s.mihomo.Stop()
		default:
			http.Error(w, "action 只能是 start 或 stop", http.StatusBadRequest)
			return
		}
		if err != nil {
			writeError(w, err)
			return
		}
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	writeJSON(w, s.mihomo.Status())
}

// handleExit GET 返回当前出口；POST {"exit":"wireguard"|"mihomo"} 手动切换（三者互斥）。
func (s *Server) handleExit(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
	case http.MethodPost:
		var req struct {
			Exit string `json:"exit"`
		}
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10)).Decode(&req); err != nil {
			writeError(w, err)
			return
		}
		if err := s.eng.SetExit(req.Exit); err != nil {
			writeError(w, err)
			return
		}
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	available := []string{policy.ExitWireGuard}
	if s.mihomo != nil && s.mihomo.Bundled() {
		available = append(available, policy.ExitMihomo)
	}
	writeJSON(w, map[string]interface{}{"exit": s.eng.Exit(), "available": available})
}

// handleTunnelIPv6 GET 返回全局隧道的公网 IPv6 设置，POST 更新并立即生效
// （地址前缀下次连接生效）。当前状态见 /api/status 的 coverage.ipv6。
func (s *Server) handleTunnelIPv6(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
	case http.MethodPost:
		var settings tunnel.IPv6Settings
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64<<10)).Decode(&settings); err != nil {
			writeError(w, err)
			return
		}
		if err := s.eng.UpdateIPv6Settings(settings); err != nil {
			writeError(w, err)
			return
		}
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	settings, err := s.eng.IPv6Settings()
	if err != nil {
		http.Error(w, err.Error(), http.StatusConflict)
		return
	}
	writeJSON(w, settings)
}

// handleConfig GET 返回当前配置，POST 更新配置。
func (s *Server) handleConfig(w http.ResponseWriter, r *http.Request) {
	if r.Method == "GET" {
		writeJSON(w, s.eng.GetConfig())
		return
	}
	var cfg config.Config
	if err := json.NewDecoder(r.Body).Decode(&cfg); err != nil {
		writeError(w, err)
		return
	}
	if err := s.eng.UpdateConfig(cfg); err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, map[string]bool{"ok": true})
}

func writeJSON(w http.ResponseWriter, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, err error) {
	w.WriteHeader(http.StatusInternalServerError)
	json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
}

// handleLogs 返回最近 N 行日志。
// GET /api/logs?n=20
func (s *Server) handleLogs(w http.ResponseWriter, r *http.Request) {
	n := 20 // 默认 20 行
	if v := r.URL.Query().Get("n"); v != "" {
		fmt.Sscanf(v, "%d", &n)
	}
	if n <= 0 || n > 200 {
		n = 20
	}
	lines := s.eng.Logs(n)
	writeJSON(w, map[string]interface{}{"lines": lines, "count": len(lines)})
}

// handleTraffic 返回实时流量统计（bytes/sec）。
// GET /api/traffic
func (s *Server) handleTraffic(w http.ResponseWriter, r *http.Request) {
	// 先更新流量统计（读取接口字节数，计算速度）
	s.eng.UpdateTraffic()
	stats := s.eng.TrafficStats()
	writeJSON(w, stats)
}

// --- Transfer 文件传输 API ---

// handleTransferDevices 返回发现的设备列表（合并多播 + 手动）。
// GET /api/transfer/devices?timeout=3
func (s *Server) handleTransferDevices(w http.ResponseWriter, r *http.Request) {
	if s.transSvc == nil {
		writeError(w, fmt.Errorf("传输服务未启动"))
		return
	}
	timeout := 3
	if v := r.URL.Query().Get("timeout"); v != "" {
		fmt.Sscanf(v, "%d", &timeout)
	}
	if timeout <= 0 || timeout > 15 {
		timeout = 3
	}
	multicastDevs := s.transSvc.DiscoverDevices(timeout)
	allDevs := s.transSvc.GetAllDevices(multicastDevs)
	writeJSON(w, map[string]interface{}{"devices": allDevs})
}

// handleTransferScan 单播扫描子网发现设备。
// GET /api/transfer/scan?subnet=&timeout=10
func (s *Server) handleTransferScan(w http.ResponseWriter, r *http.Request) {
	if s.transSvc == nil {
		writeError(w, fmt.Errorf("传输服务未启动"))
		return
	}
	subnet := r.URL.Query().Get("subnet")
	timeoutSec := 10
	if v := r.URL.Query().Get("timeout"); v != "" {
		fmt.Sscanf(v, "%d", &timeoutSec)
	}
	if timeoutSec <= 0 || timeoutSec > 30 {
		timeoutSec = 10
	}
	devices := s.transSvc.ScanSubnet(subnet, timeoutSec)
	writeJSON(w, map[string]interface{}{
		"devices": devices,
		"subnet":  subnet,
	})
}

// handleTransferAddDevice 手动添加设备。
// POST /api/transfer/add-device  body: {"addr":"192.168.1.100:53317"}
func (s *Server) handleTransferAddDevice(w http.ResponseWriter, r *http.Request) {
	if s.transSvc == nil {
		writeError(w, fmt.Errorf("传输服务未启动"))
		return
	}
	var req struct {
		Addr string `json:"addr"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, err)
		return
	}
	if req.Addr == "" {
		writeError(w, fmt.Errorf("addr 不能为空"))
		return
	}
	dev, err := s.transSvc.AddManualDevice(req.Addr)
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, dev)
}

// handleTransferRemoveDevice 移除手动添加的设备。
// POST /api/transfer/remove-device  body: {"id":"192.168.1.100:53318"}
func (s *Server) handleTransferRemoveDevice(w http.ResponseWriter, r *http.Request) {
	if s.transSvc == nil {
		writeError(w, fmt.Errorf("传输服务未启动"))
		return
	}
	var req struct {
		ID string `json:"id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, err)
		return
	}
	ok := s.transSvc.RemoveManualDevice(req.ID)
	writeJSON(w, map[string]bool{"ok": ok})
}

// handleTransferSend 发送文件到目标设备。
// POST /api/transfer/send  body: {"id":"IP:Port","paths":["/path/to/file"]}
func (s *Server) handleTransferSend(w http.ResponseWriter, r *http.Request) {
	if s.transSvc == nil {
		writeError(w, fmt.Errorf("传输服务未启动"))
		return
	}
	var req struct {
		ID    string   `json:"id"`
		Paths []string `json:"paths"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, err)
		return
	}
	if req.ID == "" || len(req.Paths) == 0 {
		writeError(w, fmt.Errorf("id 和 paths 不能为空"))
		return
	}

	// 发送使用发现/扫描/手动添加共享的后端缓存，避免 UI 看得到但后端找不到。
	target, found := s.transSvc.FindDevice(req.ID)
	if !found {
		writeError(w, fmt.Errorf("未找到设备: %s", req.ID))
		return
	}

	task, err := s.transSvc.StartSend(target, req.Paths)
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, map[string]interface{}{"ok": true, "task": task})
}

// handleTransferTasks 返回后台发送任务和历史。
// GET /api/transfer/tasks
func (s *Server) handleTransferTasks(w http.ResponseWriter, r *http.Request) {
	if s.transSvc == nil {
		writeError(w, fmt.Errorf("传输服务未启动"))
		return
	}
	if r.Method != http.MethodGet {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	writeJSON(w, s.transSvc.SendTasks())
}

// handleTransferStart 启动接收/发现服务。
// POST /api/transfer/start
func (s *Server) handleTransferStart(w http.ResponseWriter, r *http.Request) {
	if s.transSvc == nil {
		writeError(w, fmt.Errorf("传输服务未初始化"))
		return
	}
	if r.Method != http.MethodPost {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	if s.transSvc.IsRunning() {
		writeJSON(w, s.transSvc.ReceiveState())
		return
	}
	if err := s.transSvc.Start(context.Background()); err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, s.transSvc.ReceiveState())
}

// handleTransferStop 停止接收/发现服务。
// POST /api/transfer/stop
func (s *Server) handleTransferStop(w http.ResponseWriter, r *http.Request) {
	if s.transSvc == nil {
		writeError(w, fmt.Errorf("传输服务未初始化"))
		return
	}
	if r.Method != http.MethodPost {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	s.transSvc.Stop()
	writeJSON(w, s.transSvc.ReceiveState())
}

// handleTransferReceive 返回接收状态和进度。
// GET /api/transfer/receive
func (s *Server) handleTransferReceive(w http.ResponseWriter, r *http.Request) {
	if s.transSvc == nil {
		writeError(w, fmt.Errorf("传输服务未启动"))
		return
	}
	state := s.transSvc.ReceiveState()
	writeJSON(w, state)
}

// handleTransferDecision 接受或拒绝一个待处理的 LocalSend 上传请求。
// POST /api/transfer/decision body: {"request_id":"...","accepted":true}
func (s *Server) handleTransferDecision(w http.ResponseWriter, r *http.Request) {
	if s.transSvc == nil {
		writeError(w, fmt.Errorf("传输服务未启动"))
		return
	}
	if r.Method != http.MethodPost {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	var req struct {
		RequestID string `json:"request_id"`
		Accepted  bool   `json:"accepted"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, err)
		return
	}
	if err := s.transSvc.ResolvePendingTransfer(req.RequestID, req.Accepted); err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, map[string]bool{"ok": true})
}

// handleTransferCancel 取消传输任务。
// POST /api/transfer/cancel  body: {"task_id":"xxx"}
func (s *Server) handleTransferCancel(w http.ResponseWriter, r *http.Request) {
	if s.transSvc == nil {
		writeError(w, fmt.Errorf("传输服务未启动"))
		return
	}
	var req struct {
		TaskID string `json:"task_id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, err)
		return
	}
	if err := s.transSvc.CancelTask(req.TaskID); err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, map[string]bool{"ok": true})
}
