// wgsense-daemon 是 WgSense 的桌面守护进程。
// 后台常驻，执行智能管理策略，通过本地 HTTP API 与原生 UI 通信。
package main

import (
	"context"
	"encoding/json"
	"flag"
	"log"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/wgsense/core/api"
	"github.com/wgsense/core/internal/config"
	"github.com/wgsense/core/internal/firewall"
	"github.com/wgsense/core/internal/healthcheck"
	"github.com/wgsense/core/internal/location"
	"github.com/wgsense/core/internal/mihomo"
	"github.com/wgsense/core/internal/pause"
	"github.com/wgsense/core/internal/policy"
	"github.com/wgsense/core/internal/proxy"
	"github.com/wgsense/core/internal/service"
	"github.com/wgsense/core/internal/transfer"
	"github.com/wgsense/core/internal/tunnel"
)

func main() {
	apiAddr := flag.String("api", "127.0.0.1:8765", "API 监听地址")
	mihomoAddr := flag.String("mihomo", "127.0.0.1:9090", "Mihomo API 地址")
	mihomoSecret := flag.String("mihomo-secret", "", "Mihomo API 密钥")
	configDir := flag.String("config-dir", "", "配置目录（默认 ~/.local/share/wgsense/profiles）")
	runtimeDirOverride := flag.String("runtime-dir", "", "运行数据目录（授权启动时应指向登录用户目录）")
	downloadDir := flag.String("download-dir", "", "LocalSend 接收目录（正式 root 服务应显式指定登录用户目录）")
	passive := flag.Bool("passive", false, "被动模式：仅启动文件传输和本地 API，不运行 WireGuard 策略或 Mihomo")
	autoConnect := flag.Bool("auto-connect-untrusted", false, "当前网络不在受信任前缀内时自动连接 WireGuard（默认关闭）")
	autoConnectAway := flag.Bool("auto-connect-away", false, "兼容旧参数：非受信任网络自动连接 WireGuard")
	trustedPrefixes := flag.String("trusted-network-prefixes", "", "逗号分隔的受信任 IPv4 前缀")
	startPaused := flag.Bool("start-paused", true, "启动时暂停自动网络策略")
	appOwned := flag.Bool("app-owned", false, "由当前 GUI App 临时启动；App 退出时允许通过 API 关闭")
	managed := flag.Bool("managed-service", false, "已安装的持久系统服务")
	ownerName := flag.String("service-owner", "", "持久服务所属登录用户")
	installService := flag.Bool("install-service", false, "提交独立系统安装事务")
	uninstallService := flag.Bool("uninstall-service", false, "卸载持久系统服务并保留用户配置")
	installTask := flag.String("run-install-task", "", "执行持久安装事务请求")
	firewallClear := flag.Bool("firewall-clear", false, "应急：移除 WgSense 出站拦截(pf 锚点与 hosts 段)后退出")
	buildInfo := flag.Bool("service-build-info", false, "仅输出 helper 构建身份，不启动服务")
	sourceDaemon := flag.String("source-daemon", "", "待安装 daemon 路径")
	sourceMover := flag.String("source-mover", "", "待安装 mover 路径")
	targetUser := flag.String("target-user", "", "安装目标登录用户")
	flag.Parse()
	if *firewallClear {
		if err := firewall.ClearAll(firewall.System{}); err != nil {
			log.Fatal(err)
		}
		log.Println("已移除 WgSense 出站拦截；若 daemon 仍在运行且开关未关，下一轮巡检会重新生效")
		return
	}
	if *buildInfo {
		path, err := os.Executable()
		if err != nil {
			log.Fatal(err)
		}
		hash, err := service.Fingerprint(path)
		if err != nil {
			log.Fatal(err)
		}
		json.NewEncoder(os.Stdout).Encode(service.Info{Protocol: service.Protocol, BinarySHA256: hash})
		return
	}
	if *installService || *uninstallService || *installTask != "" {
		ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
		defer stop()
		manager := service.NewManager()
		if *installTask != "" {
			if err := manager.RunTask(ctx, *installTask); err != nil {
				log.Fatal(err)
			}
			return
		}
		owner, err := service.LookupAccount(*targetUser)
		if err != nil {
			log.Fatal(err)
		}
		if *uninstallService {
			if err := manager.Uninstall(ctx, owner); err != nil {
				log.Fatal(err)
			}
			json.NewEncoder(os.Stdout).Encode(map[string]bool{"ok": true})
			return
		}
		req, err := manager.Schedule(ctx, service.Request{SourceDaemon: *sourceDaemon, SourceMover: *sourceMover, Owner: owner})
		if err != nil {
			log.Fatal(err)
		}
		json.NewEncoder(os.Stdout).Encode(map[string]string{"operation_id": req.OperationID, "binary_sha256": req.BinarySHA256})
		return
	}
	var managedOwner service.Account
	var binaryHash string
	if *managed {
		if os.Geteuid() != 0 {
			log.Fatal("持久系统服务需要由 root launchd 启动")
		}
		var err error
		managedOwner, err = service.LookupAccount(*ownerName)
		if err != nil {
			log.Fatal(err)
		}
		path, err := os.Executable()
		if err != nil {
			log.Fatal(err)
		}
		binaryHash, err = service.Fingerprint(path)
		if err != nil {
			log.Fatal(err)
		}
	}

	// Claim the control endpoint before touching runtime state, starting LAN
	// services, or running network policy. A launchd retry must never create a
	// second tunnel when an old daemon or another application owns the port.
	apiListener, err := net.Listen("tcp", *apiAddr)
	if err != nil {
		log.Fatalf("无法监听 daemon API，未启动网络服务: %v", err)
	}
	defer apiListener.Close()

	// 运行时状态目录
	rtDir := runtimeDir(*runtimeDirOverride)
	pauseFile := filepath.Join(rtDir, "pause-marker")
	configFile := filepath.Join(rtDir, "settings.json")

	cfg := config.Default()
	if saved, err := config.LoadRuntime(configFile); err == nil {
		cfg = saved
		log.Printf("已加载运行配置: %s", configFile)
	} else if !config.IsNotExist(err) {
		log.Printf("读取运行配置失败，使用默认值: %v", err)
	}
	explicitFlags := map[string]bool{}
	flag.Visit(func(item *flag.Flag) { explicitFlags[item.Name] = true })
	if explicitFlags["auto-connect-untrusted"] || explicitFlags["auto-connect-away"] {
		cfg.AutoConnectUntrusted = *autoConnect || *autoConnectAway
	}
	if explicitFlags["trusted-network-prefixes"] {
		cfg.TrustedNetworkPrefixes = splitCommaSeparated(*trustedPrefixes)
		cfg.HomeNetworkPrefixes = nil
	}
	cfg.Normalize()

	// 配置目录(放 .conf profile)
	cDir := *configDir
	if cDir == "" {
		cDir = filepath.Join(rtDir, "profiles")
	}
	os.MkdirAll(cDir, 0755)
	if *managed {
		repairProfileOwnership(managedOwner.Home, cDir, managedOwner.UID, chownToUser)
	}

	loc := location.New()
	tun := tunnel.New(cDir)
	ipv6Path := filepath.Join(rtDir, "tunnel-ipv6.json")
	if configurable, ok := tun.(tunnel.IPv6Configurable); ok {
		if err := configurable.SetIPv6Settings(tunnel.LoadIPv6Settings(ipv6Path)); err != nil {
			log.Printf("加载隧道 IPv6 设置失败，使用默认值: %v", err)
		}
	}
	hc := healthcheck.New(cfg.HealthCheckTarget)
	p := pause.New(pauseFile)
	if explicitFlags["start-paused"] {
		if *startPaused {
			_ = p.Pause()
		} else {
			_ = p.Resume()
		}
	} else {
		log.Printf("未指定启动暂停状态，保留已有守护状态 paused=%t", p.IsPaused())
	}
	eng := policy.New(cfg, loc, tun, hc, p)
	eng.SetService("default") // 默认 profile，可从 /api/profiles 选
	eng.SetPassive(*passive)
	eng.SetAppOwned(*appOwned)
	eng.SetConfigPath(configFile)
	eng.SetIPv6SettingsPath(ipv6Path)
	if !*passive && os.Geteuid() == 0 {
		fw := firewall.New(filepath.Join(rtDir, "firewall.json"), firewall.System{}, eng.Logf)
		fw.TunnelEndpoints = liveEndpoints(tun, endpointResolver(tun, "default"))
		if provider, ok := tun.(tunnel.CoverageProvider); ok {
			fw.TunnelLocked = func() bool { return provider.Coverage("").FullTunnel }
		}
		// 隧道建立/拆除后立即同步：锁定只在隧道连着时生效，拆除后马上放开。
		if notifier, ok := tun.(tunnel.StateNotifier); ok {
			notifier.SetStateHook(func() { _ = fw.Sync() })
		}
		// 先于隧道和其他服务装上规则：开机/重启后不留无拦截的空窗。
		_ = fw.Sync()
		eng.SetFirewall(fw)
	}

	// 后台启动策略引擎守护循环
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// 传输服务（LocalSend 协议兼容）
	transSvc, err := transfer.New("WgSense-Mac", *downloadDir)
	if err != nil {
		log.Printf("传输服务初始化失败: %v", err)
		transSvc = nil
	} else {
		if err := transSvc.Start(ctx); err != nil {
			log.Printf("传输服务启动失败: %v", err)
			transSvc = nil
		} else {
			log.Println("传输服务已启动 (LocalSend 兼容)")
		}
	}

	// 代理控制器客户端只访问 Mihomo API，不修改本机路由；被动模式也可安全使用。
	proxyConfigPath := filepath.Join(rtDir, "proxy.json")
	proxyCfg, err := proxy.LoadConfig(proxyConfigPath)
	if err != nil {
		log.Printf("读取代理设置失败，使用默认值: %v", err)
		proxyCfg = proxy.DefaultConfig()
	}
	if explicitFlags["mihomo"] {
		proxyCfg.Address = *mihomoAddr
	}
	if explicitFlags["mihomo-secret"] {
		proxyCfg.Secret = *mihomoSecret
	}
	proxySvc, err := proxy.NewPersistent(proxyCfg, proxyConfigPath)
	if err != nil {
		log.Printf("代理服务初始化失败: %v", err)
		proxySvc = nil
	} else if err := proxySvc.Start(); err != nil {
		log.Printf("代理服务启动失败(非致命): %v", err)
	}

	// 内置代理内核：只管本机进程与本机端口，不改路由 / DNS，被动模式也可安全使用。
	// root 服务放在 root 专属目录（二进制会以 nobody 身份运行），其余放运行目录下。
	mihomoDir := filepath.Join(rtDir, "mihomo")
	if os.Geteuid() == 0 && !explicitFlags["runtime-dir"] {
		mihomoDir = mihomo.DefaultRootDir
	}
	mihomoMgr := mihomo.New(mihomoDir, eng.Logf)
	mihomoMgr.Restore()

	// 信号处理
	var shutdownOnce sync.Once
	stopDaemon := func(code int) {
		shutdownOnce.Do(func() {
			cancel()
			apiListener.Close()
			mihomoMgr.Shutdown()
			if err := eng.ShutdownCleanup(); err != nil {
				log.Printf("退出前清理隧道失败: %v", err)
			}
			os.Exit(code)
		})
	}
	sigCh := make(chan os.Signal, 1)
	// This is the only signal-driven cleanup owner. A second handler in the
	// tunnel manager could exit while this handler was still restoring DNS.
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP)
	go func() {
		<-sigCh
		log.Println("收到退出信号")
		stopDaemon(0)
	}()

	// Install the cleanup owner before policy can create its first tunnel.
	if !*passive {
		go func() {
			if *managed {
				for !service.RuntimeInfo(managedOwner, binaryHash).Ready {
					select {
					case <-ctx.Done():
						return
					case <-time.After(200 * time.Millisecond):
					}
				}
			}
			if err := eng.Start(ctx); err != nil {
				log.Printf("引擎退出: %v", err)
			}
		}()
	} else {
		log.Println("被动模式已启用：WireGuard 策略未启动；Mihomo 仅启用远程控制器客户端")
	}

	// 前台启动 API server
	log.Printf("WgSense daemon 启动 interval=%ds api=%s mihomo=%s passive=%t auto_connect_untrusted=%t app_owned=%t", cfg.IntervalSeconds, *apiAddr, proxyCfg.Address, *passive, cfg.AutoConnectUntrusted, *appOwned)
	apiSrv := api.New(*apiAddr, eng, transSvc, proxySvc)
	apiSrv.SetMihomo(mihomoMgr)
	if *managed {
		apiSrv.SetService(func() service.Info { return service.RuntimeInfo(managedOwner, binaryHash) }, func(_ context.Context, req service.Request) (service.Request, error) {
			req.Owner = managedOwner
			submitCtx, done := context.WithTimeout(ctx, 30*time.Second)
			defer done()
			submission, err := service.NewManager().Schedule(submitCtx, req)
			if err == nil {
				go func() {
					service.WaitForResult(ctx, submission.OperationID)
					if ctx.Err() == nil {
						eng.EndServiceMaintenance()
					}
				}()
			}
			return submission, err
		}, func() { time.Sleep(100 * time.Millisecond); stopDaemon(0) })
	}
	if *appOwned {
		apiSrv.SetShutdown(func() {
			// Close the listener and enter the engine's terminal state before
			// exiting; launchd handles managed restarts independently.
			time.Sleep(100 * time.Millisecond)
			stopDaemon(0)
		})
	}
	if err := apiSrv.Serve(apiListener); err != nil {
		log.Printf("API 已退出: %v", err)
		stopDaemon(1)
	}
}

// endpointResolver returns the WireGuard server IPs for the firewall allow
// list, cached so policy ticks do not issue DNS lookups every few seconds.
// liveEndpoints 合并隧道实际在用的服务器地址与按配置解析出的地址：DDNS 变化后
// 解析缓存可能过期，实际在用的地址必须放行，否则锁定会挡住隧道自己。
func liveEndpoints(tun tunnel.Manager, resolved func() []string) func() []string {
	return func() []string {
		ips := resolved()
		if provider, ok := tun.(tunnel.CoverageProvider); ok {
			ips = append(append([]string(nil), ips...), provider.Endpoints()...)
		}
		return ips
	}
}

func endpointResolver(tun tunnel.Manager, profile string) func() []string {
	var mu sync.Mutex
	var cached []string
	var at time.Time
	return func() []string {
		mu.Lock()
		defer mu.Unlock()
		if time.Since(at) < 5*time.Minute && cached != nil {
			return cached
		}
		at = time.Now()
		content, err := tun.LoadProfileContent(profile)
		if err != nil {
			return cached
		}
		parsed, err := config.Parse(strings.NewReader(content), profile)
		if err != nil {
			return cached
		}
		var ips []string
		for _, peer := range parsed.Peers {
			host, _, err := net.SplitHostPort(peer.Endpoint)
			if err != nil {
				continue
			}
			ctx, done := context.WithTimeout(context.Background(), 2*time.Second)
			addrs, err := net.DefaultResolver.LookupHost(ctx, host)
			done()
			if err == nil {
				ips = append(ips, addrs...)
			}
		}
		if len(ips) > 0 {
			cached = ips
		}
		return cached
	}
}

func splitCommaSeparated(value string) []string {
	var values []string
	for _, item := range strings.Split(value, ",") {
		if trimmed := strings.TrimSpace(item); trimmed != "" {
			values = append(values, trimmed)
		}
	}
	return values
}

// runtimeDir 返回运行时状态目录。
func runtimeDir(override string) string {
	if override != "" {
		dir, err := filepath.Abs(override)
		if err == nil {
			os.MkdirAll(dir, 0755)
			return dir
		}
	}
	home, _ := os.UserHomeDir()
	dir := filepath.Join(home, ".local", "share", "wgsense")
	os.MkdirAll(dir, 0755)
	return dir
}
