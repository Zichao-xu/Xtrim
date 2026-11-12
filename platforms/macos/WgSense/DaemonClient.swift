import SwiftUI
import UserNotifications
import CryptoKit
import Darwin

@MainActor
class DaemonClient: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    struct LogLine: Identifiable, Equatable {
        let id: UUID
        let text: String

        init(id: UUID = UUID(), text: String) {
            self.id = id
            self.text = text
        }
    }

    struct ActionToast: Identifiable, Equatable {
        let id: UUID
        let title: String
        let detail: String
        let symbol: String
        let tint: Color
    }

    @Published var status: DaemonStatus?
    @Published var profiles: [String] = []
    @Published var errorMsg: String?
    @Published var alertMsg: String?
    @Published var actionToast: ActionToast?
    @Published var logLines: [LogLine] = []
    @Published var traffic: TrafficStats?
    /// 链路事件（握手、重绑、能收不能发），只读状态字段推导。
    let linkMonitor = WgLinkMonitor()
    @Published private(set) var isAuthorizingDaemon = false
    @Published private(set) var serviceLifecycleError: String?
    /// 安装失败后停止自动提权，界面显示“重试安装”。
    @Published private(set) var serviceNeedsRetry = false
    @Published private(set) var pendingConnected: Bool?
    @Published private(set) var pendingGuardRunning: Bool?
    @Published private(set) var pendingPaused: Bool?

    /// 暂停时长（分钟），可在设置页修改，默认 5
    @AppStorage("pauseMinutes") var pauseMinutes: Int = 5

    // 运行配置（AppStorage 本地缓存 + 同步到 daemon）
    @AppStorage("healthCheckTarget") var healthCheckTarget: String = "https://www.gstatic.com/generate_204"
    @AppStorage("intervalSeconds") var intervalSeconds: Int = 10
    @AppStorage("autoUpGraceSeconds") var autoUpGraceSeconds: Int = 20
    @AppStorage("trustedNetworkPrefixes") var trustedNetworkPrefixes: String = ""
    @AppStorage("autoConnectUntrusted") var autoConnectUntrusted: Bool = true
    @AppStorage("guardAutomationEnabled") private var guardAutomationEnabled: Bool = false
    @AppStorage("desiredVPNEnabled") private var desiredVPNEnabled: Bool = false

    private let api = DaemonAPIClient()
    private let controlAPI = DaemonControlAPIClient()
    private let profileStore = ProfileFileStore()
    private let transferAPI = TransferAPIClient()
    private let proxyAPI = ProxyAPIClient()
    private var baseURL: URL { api.baseURL }
    private var pollTimer: Timer?

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        requestNotificationAuthorization()
        migrateTrustedNetworkPolicyIfNeeded()
        startPolling()
        Task { [weak self] in
            self?.isAuthorizingDaemon = true
            let result = await DaemonServiceCoordinator.shared.ensure(.firstLaunch)
            self?.isAuthorizingDaemon = false
            self?.serviceNeedsRetry = result.needsExplicitRetry
            if !result.ok {
                self?.serviceLifecycleError = result.message
                self?.errorMsg = result.message
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    private func requestNotificationAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func migrateTrustedNetworkPolicyIfNeeded() {
        let defaults = UserDefaults.standard
        let migrationKey = "trustedNetworkPolicyV2Migrated"
        guard !defaults.bool(forKey: migrationKey) else { return }

        // Earlier builds persisted `false` as a product default even though the
        // guard tile implied full trusted/untrusted automation.
        autoConnectUntrusted = true
        defaults.set(true, forKey: migrationKey)
    }

    /// 用户意图（开关位置）。daemon 离线时不再沿用旧意图，避免开关亮着而实际无人维持隧道。
    var isVPNOn: Bool {
        pendingConnected ?? status?.desired_vpn_enabled ?? false
    }

    /// 隧道实际已建立。“已连接/已建立隧道”等文字只看这个，不看意图。
    var isTunnelUp: Bool {
        status?.state == "Connected"
    }

    /// 设计规则：受信任网络（在家）且守护开启时，VPN 由守护保持断开，不允许手动打开。
    var isGuardBlockingVPN: Bool {
        (status?.isTrustedNetwork ?? false) && isGuardOn && !isTunnelUp
    }

    var isGuardOn: Bool {
        pendingGuardRunning ?? status?.desired_guard_enabled ?? guardAutomationEnabled
    }

    var isPauseOn: Bool {
        pendingPaused ?? (status?.paused ?? false)
    }

    // MARK: - 连通性检测（1s 超时，极速判定）

    /// 检测 daemon 是否在线，1 秒超时
    func isDaemonReachable() -> Bool {
        let sem = DispatchSemaphore(value: 0)
        var reachable = false
        var req = URLRequest(url: baseURL.appendingPathComponent("api/status"))
        req.timeoutInterval = 1.0
        req.httpMethod = "GET"
        Task {
            do {
                let (_, resp) = try await URLSession.shared.data(for: req)
                if let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                    reachable = true
                }
            } catch { /* 超时/拒绝 = 不可达 */ }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 1.5)
        return reachable
    }

    /// Verify the persistent helper before any network control. Installation
    /// and updates are coalesced by one app-wide coordinator.
    func ensureDaemon(requireActive: Bool = false, authorizeIfNeeded: Bool = false, allowOldForStop: Bool = false) async -> Bool {
        let mode: DaemonServiceCoordinator.Mode = allowOldForStop ? .stopOnly : (authorizeIfNeeded ? .userAction : .readOnly)
        isAuthorizingDaemon = authorizeIfNeeded
        defer { isAuthorizingDaemon = false }
        let result = await DaemonServiceCoordinator.shared.ensure(mode)
        serviceNeedsRetry = result.needsExplicitRetry
        if result.ok {
            serviceLifecycleError = nil
            markDaemonUp()
        } else {
            serviceLifecycleError = result.message
            errorMsg = result.message
        }
        return result.ok
    }

    /// 用户显式重试安装后台服务（唯一会在失败后再次弹密码的入口）。
    func retryServiceInstall() async {
        isAuthorizingDaemon = true
        let result = await DaemonServiceCoordinator.shared.ensure(.maintenance)
        isAuthorizingDaemon = false
        serviceNeedsRetry = result.needsExplicitRetry
        if result.ok {
            serviceLifecycleError = nil
            markDaemonUp()
            await fetchStatus()
        } else {
            serviceLifecycleError = result.message
            errorMsg = result.message
        }
    }

    private func log(_ msg: String) {
        print("[DaemonClient] \(msg)")
    }

    /// 重置可达状态（供轮询成功后调用）
    func markDaemonUp() {
        if serviceLifecycleError == nil && errorMsg != nil { errorMsg = nil }
    }

    deinit {
        pollTimer?.invalidate()
    }

    /// 全 App 唯一的状态轮询。窗口可见时 2 秒一轮；只剩菜单栏图标时 10 秒一轮，
    /// 流量只在隧道连通且窗口可见时拉取。各页面不再各自起定时器重复请求。
    func startPolling(interval: TimeInterval = 2.0) {
        pollTimer?.invalidate()
        var tick = 0
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in
                tick += 1
                let visible = Self.hasVisibleWindow()
                guard visible || tick % 5 == 0 else { return }
                await self.fetchStatus()
                guard visible else { return }
                if self.status != nil { await self.fetchTransferState() }
                // 内置代理内核状态只给磁贴用，10 秒一轮足够；代理页打开时自己 2 秒一轮
                if self.status != nil, tick % 5 == 0 { await self.fetchMihomo() }
                if self.isTunnelUp {
                    await self.fetchTraffic()
                } else if self.traffic != nil {
                    self.traffic = nil
                }
            }
        }
        pollTimer?.tolerance = interval * 0.25
        // 立即拉一次
        Task {
            await fetchStatus()
            if status != nil { await fetchTransferState() }
            if status != nil { await fetchMihomo() }
            await fetchTraffic()
        }
    }

    /// 主窗口或菜单栏面板是否真的在屏幕上（被遮挡、最小化、隐藏都不算）。
    private static func hasVisibleWindow() -> Bool {
        NSApp.windows.contains { $0.isVisible && $0.occlusionState.contains(.visible) && $0.frame.height > 60 }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func refresh() async {
        await fetchStatus()
        await fetchProfiles()
        await fetchTraffic()
    }

    private var followedExit: String?

    /// 面板跟随出口：出口变化时把「面板」切到本机内核或路由器。
    private func followPanelBackend() async {
        let exit = status?.exit ?? "wireguard"
        guard exit != followedExit else { return }
        if exit == "mihomo" {
            guard let ctl = try? await api.decode(MihomoController.self, path: "api/mihomo/controller", timeout: 5) else { return }
            MihomoBackendStore.shared.ensureLocal(address: ctl.address, secret: ctl.secret)
        }
        followedExit = exit
        MihomoBackendStore.shared.follow(exitIsMihomo: exit == "mihomo")
        if exit == "mihomo", proxyError != nil { proxyError = nil }
    }

    private struct MihomoController: Decodable {
        var address: String
        var secret: String
    }

    // 只有数据真的变了才赋值：@Published 每次赋值都会让所有订阅视图重算，
    // 轮询拿回同样的数据时不应触发重绘；@AppStorage 同理还会写磁盘。
    func fetchStatus() async {
        do {
            let next = try await controlAPI.status()
            if status != next { status = next }
            await followPanelBackend()
            linkMonitor.ingest(handshake: next.last_handshake, handshakeAge: next.last_handshake_age_seconds,
                               tx: next.peer_tx_bytes, rx: next.peer_rx_bytes, rebinds: next.bind_rebinds, tunnelUp: isTunnelUp)
            let wantVPN = next.desired_vpn_enabled ?? (next.state == "Connected")
            if desiredVPNEnabled != wantVPN { desiredVPNEnabled = wantVPN }
            let wantGuard = next.desired_guard_enabled ?? !next.paused
            if guardAutomationEnabled != wantGuard { guardAutomationEnabled = wantGuard }
            markDaemonUp()
        } catch {
            linkMonitor.markUnavailable()
            if status != nil { status = nil }
            if transferState != nil { transferState = nil }
            let message = serviceLifecycleError ?? "daemon 未连接"
            if errorMsg != message { errorMsg = message }
        }
    }

    func fetchProfiles() async {
        do {
            profiles = try await controlAPI.profiles()
        } catch {
            // daemon 离线时从文件系统直读
            profiles = profileStore.listProfiles()
        }
    }

    /// 拉取最近 N 行日志（供小磁贴日志滚动用）
    func fetchLogs(n: Int = 15) async {
        do {
            let incoming = try await controlAPI.logs(limit: n).lines
            mergeLogLines(incoming, limit: max(n, 500))
        } catch { /* daemon 可能还没启动 */ }
    }

    private func mergeLogLines(_ incoming: [String], limit: Int) {
        guard !incoming.isEmpty else { return }
        let current = logLines.map(\.text)
        if current.suffix(incoming.count).elementsEqual(incoming) { return }

        let maxOverlap = min(current.count, incoming.count)
        var overlap = 0
        if maxOverlap > 0 {
            for count in stride(from: maxOverlap, through: 1, by: -1) {
                if current.suffix(count).elementsEqual(incoming.prefix(count)) {
                    overlap = count
                    break
                }
            }
        }

        if overlap == 0 && !current.isEmpty {
            logLines = incoming.map { LogLine(text: $0) }
        } else {
            logLines.append(contentsOf: incoming.dropFirst(overlap).map { LogLine(text: $0) })
        }
        if logLines.count > limit {
            logLines.removeFirst(logLines.count - limit)
        }
    }

    /// 拉取实时流量统计
    func fetchTraffic() async {
        do {
            let next = try await controlAPI.traffic()
            if traffic != next { traffic = next }
        } catch {
            if traffic != nil { traffic = nil }
        }
    }

    func post(_ endpoint: String) async {
        await dispatchDaemonCommand(endpoint)
    }

    /// 守护开关代表完整网络策略：受信任网络断开，非受信任网络自动连接。
    func setGuardEnabled(_ enabled: Bool) async {
        guardAutomationEnabled = enabled
        setPending(connect: nil, guardRunning: enabled, paused: !enabled)
        if enabled {
            autoConnectUntrusted = true
            guard await ensureDaemon(requireActive: true, authorizeIfNeeded: true) else {
                clearPendingState()
                return
            }
            await syncConfigSilently()
            await runDaemonCommand("resume")
        } else {
            await runDaemonCommand("pause")
        }
    }

    nonisolated static func shutdownAppOwnedDaemonSync() {
        guard shouldShutdownAppOwnedDaemonSync() else { return }
        guard let url = URL(string: "http://127.0.0.1:8765/api/shutdown") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 1.0
        let sem = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: req) { _, _, _ in sem.signal() }
        task.resume()
        _ = sem.wait(timeout: .now() + 1.2)
    }

    private nonisolated static func shouldShutdownAppOwnedDaemonSync() -> Bool {
        guard let url = URL(string: "http://127.0.0.1:8765/api/status") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 0.8

        let sem = DispatchSemaphore(value: 0)
        var shouldShutdown = false
        let task = URLSession.shared.dataTask(with: req) { data, _, _ in
            defer { sem.signal() }
            guard
                let data,
                let status = try? JSONDecoder().decode(DaemonStatus.self, from: data),
                status.app_owned == true
            else { return }

            shouldShutdown = shouldShutdownAppOwnedDaemon(status)
        }
        task.resume()
        _ = sem.wait(timeout: .now() + 1.0)
        return shouldShutdown
    }

    private nonisolated static func shouldShutdownAppOwnedDaemon(_ status: DaemonStatus) -> Bool {
        guard status.app_owned == true else { return false }
        // If the user has an active tunnel or active guard policy, leaving the
        // app must not silently tear down the network session. Idle temporary
        // daemons are still cleaned up on quit.
        return status.state != "Connected" && status.paused
    }

    func shutdownAppOwnedDaemon() async -> Bool {
        do {
            try await controlAPI.shutdownAppOwnedDaemon()
            status = nil
            errorMsg = "daemon 已关闭"
            return true
        } catch {
            alertMsg = "关闭 daemon 失败: \(error.localizedDescription)"
            return false
        }
    }

    /// 发送 POST 并等待完成（用于需要严格顺序的操作）
    func postAndWait(_ endpoint: String) async {
        await dispatchDaemonCommand(endpoint)
    }

    func restartGuardFlow() async {
        setPending(connect: false, guardRunning: false, paused: true)
        await runDaemonCommand("pause", showToast: false)
        await runDaemonCommand("disconnect", showToast: false)
        try? await Task.sleep(for: .seconds(1))
        guardAutomationEnabled = true
        autoConnectUntrusted = true
        setPending(connect: nil, guardRunning: true, paused: false)
        await syncConfigSilently()
        await runDaemonCommand("resume", showToast: false)
        await fetchStatus()
        showActionNotification(
            title: "守护已重启",
            detail: "\(networkSummary)。已交给守护按当前网络判断 VPN。",
            category: "restart",
            symbol: "arrow.triangle.2.circlepath",
            tint: .purple
        )
        clearPendingState()
    }

    private func dispatchDaemonCommand(_ endpoint: String) async {
        if endpoint == "connect" {
            // 所有连接入口统一拦截，避免连上后被守护立即断开。
            if isGuardBlockingVPN {
                showActionNotification(
                    title: "在家由守护保持断开",
                    detail: "受信任网络下守护不允许连接 VPN；需要时先关闭守护。",
                    category: "guard-block",
                    symbol: "shield.checkered",
                    tint: .orange
                )
                return
            }
            await connectVPN()
            return
        }
        if endpoint == "disconnect" {
            desiredVPNEnabled = false
        } else if endpoint == "resume" {
            guardAutomationEnabled = true
            autoConnectUntrusted = true
        } else if endpoint == "pause" {
            guardAutomationEnabled = false
            autoConnectUntrusted = false
        }
        await runDaemonCommand(endpoint)
    }

    private func connectVPN() async {
        desiredVPNEnabled = true
        setPending(connect: true, guardRunning: nil, paused: nil)
        guard await ensureDaemon(requireActive: true, authorizeIfNeeded: true) else {
            clearPendingState()
            return
        }

        let oldStatus = status
        do {
            let current = try await controlAPI.status(timeout: 2)
            status = current

            optimisticUpdate("connect")
            // Connect waits for endpoint resolution and WireGuard handshake. Keep this
            // longer than the daemon's handshake window so the UI receives the real error.
            try await controlAPI.command("connect", timeout: 30)
            markDaemonUp()
            await fetchStatus()
            showToast(for: "connect")
            clearPendingState()
        } catch {
            let message = DaemonAPIClient.connectionMessage(error) == "daemon 未连接"
                ? "无法连接 daemon"
                : "连接失败：\(error.localizedDescription)"
            revertAndAlert(oldStatus, message)
            await fetchStatus()
            clearPendingState()
        }
    }

    private func runDaemonCommand(_ endpoint: String, showToast: Bool = true) async {
        let shouldStartDaemon = endpoint == "connect" || endpoint == "resume"
        setPending(for: endpoint)
        guard await ensureDaemon(
            requireActive: endpoint == "connect",
            authorizeIfNeeded: shouldStartDaemon,
            allowOldForStop: endpoint == "disconnect" || endpoint == "pause"
        ) else {
            clearPendingState()
            return
        }

        let oldStatus = status
        optimisticUpdate(endpoint)
        do {
            try await controlAPI.command(endpoint)
            markDaemonUp()
            await fetchStatus()
            if showToast {
                self.showToast(for: endpoint)
            }
            clearPendingState()
        } catch {
            let message = DaemonAPIClient.connectionMessage(error) == "daemon 未连接"
                ? "无法连接 daemon"
                : "操作失败：\(error.localizedDescription)"
            revertAndAlert(oldStatus, message)
            clearPendingState()
        }
    }

    /// 回退状态：连接失败只设置 inline errorMsg，不再弹模态框
    @MainActor
    private func revertAndAlert(_ oldStatus: DaemonStatus?, _ msg: String) {
        status = oldStatus
        // 只对非连接类错误弹窗（连接失败用 errorMsg 内联显示即可）
        if !msg.contains("Could not connect") && !msg.contains("无法连接") {
            alertMsg = msg
        } else {
            errorMsg = "daemon 未运行"
        }
    }

    private func setPending(for endpoint: String) {
        switch endpoint {
        case "connect":
            setPending(connect: true, guardRunning: nil, paused: nil)
        case "disconnect":
            setPending(connect: false, guardRunning: nil, paused: nil)
        case "pause":
            setPending(connect: nil, guardRunning: false, paused: true)
        case "resume":
            setPending(connect: nil, guardRunning: true, paused: false)
        default:
            break
        }
    }

    private func setPending(connect: Bool?, guardRunning: Bool?, paused: Bool?) {
        withAnimation(.smooth(duration: 0.22, extraBounce: 0.08)) {
            if let connect { pendingConnected = connect }
            if let guardRunning { pendingGuardRunning = guardRunning }
            if let paused { pendingPaused = paused }
        }
    }

    private func clearPendingState() {
        withAnimation(.smooth(duration: 0.22, extraBounce: 0.05)) {
            pendingConnected = nil
            pendingGuardRunning = nil
            pendingPaused = nil
        }
    }

    private var currentIPText: String {
        status?.primaryIPv4 ?? "未知"
    }

    private var networkSummary: String {
        let network = status?.isTrustedNetwork == true ? "受信任网络" : "非受信任网络"
        return "\(network) · IP \(currentIPText)"
    }

    private var guardSummary: String {
        if status?.paused == true { return "守护已暂停" }
        if status?.desired_guard_enabled == true { return "守护运行中" }
        return "守护未开启"
    }

    private func showToast(for endpoint: String) {
        switch endpoint {
        case "connect":
            showActionNotification(
                title: "VPN 已开启",
                detail: networkSummary,
                category: "vpn-connect",
                symbol: "network",
                tint: .green
            )
        case "disconnect":
            showActionNotification(
                title: "VPN 已关闭",
                detail: "\(guardSummary)。非信任网络下守护可能自动接管。",
                category: "vpn-disconnect",
                symbol: "shield.slash",
                tint: .red
            )
        case "pause":
            showActionNotification(
                title: "守护已暂停",
                detail: "自动开关已停止，VPN 不会被自动拉起。",
                category: "guard-pause",
                symbol: "pause.circle.fill",
                tint: .orange
            )
        case "resume":
            showActionNotification(
                title: "守护已恢复",
                detail: "\(networkSummary)。将按规则自动处理 VPN。",
                category: "guard-resume",
                symbol: "shield.checkered",
                tint: .blue
            )
        default:
            break
        }
    }

    /// 只在 App 内弹一条轻提示（不发系统通知），3 秒后收起。
    func showInAppToast(title: String, detail: String, symbol: String) {
        let toast = ActionToast(id: UUID(), title: title, detail: detail, symbol: symbol, tint: .gray)
        withAnimation(.snappy(duration: 0.32, extraBounce: 0.16)) { actionToast = toast }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard self?.actionToast?.id == toast.id else { return }
            withAnimation(.snappy(duration: 0.24, extraBounce: 0.05)) { self?.actionToast = nil }
        }
    }

    private func showActionNotification(title: String, detail: String, category: String, symbol: String, tint: Color) {
        let toast = ActionToast(id: UUID(), title: title, detail: detail, symbol: symbol, tint: tint)
        withAnimation(.snappy(duration: 0.32, extraBounce: 0.16)) {
            actionToast = toast
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard self?.actionToast?.id == toast.id else { return }
            withAnimation(.snappy(duration: 0.24, extraBounce: 0.05)) {
                self?.actionToast = nil
            }
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = detail
        content.sound = .default
        content.categoryIdentifier = "wgsense.\(category)"

        let request = UNNotificationRequest(
            identifier: "wgsense.action.\(category).\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// 乐观更新：点击按钮后立即更新 UI 显示的状态
    private func optimisticUpdate(_ endpoint: String) {
        guard var s = status else { return }
        switch endpoint {
        case "connect":
            s.state = "Connected"
        case "disconnect":
            s.state = "Disconnected"
        case "pause":
            s.paused = true
        case "resume":
            s.paused = false
        default:
            break
        }
        status = s
    }

    // MARK: - Profile 管理

    func importProfile(name: String, content: String) async {
        do {
            try await storeProfile(name, content: content)
            try await adoptIfNoActiveProfile(content)
        } catch {
            alertMsg = "导入配置失败：\(error.localizedDescription)"
        }
    }

    /// 先直接写文件（daemon 离线也能成功），写不进去时交给 daemon，两边都失败才算失败。
    private func storeProfile(_ name: String, content: String) async throws {
        do {
            try profileStore.saveProfile(name, content: content)
        } catch {
            try await controlAPI.importProfile(name: name, content: content)
            return
        }
        try? await controlAPI.importProfile(name: name, content: content)
    }

    /// daemon 只读 default.conf。还没有可用的当前配置时，这份配置直接启用；
    /// 已有当前配置时不动它，换配置走「切换」。
    private func adoptIfNoActiveProfile(_ content: String) async throws {
        if await exportProfile(name: "default").isEmpty {
            try await storeProfile("default", content: content)
        }
    }

    /// 导出 profile 内容（先读磁盘，daemon 作为备选）
    func exportProfile(name: String) async -> String {
        // 优先从本地文件读取
        if let content = profileStore.readProfile(name) {
            return content
        }
        // daemon 备选
        do {
            return try await controlAPI.exportProfile(name: name).content
        } catch { return "" }
    }

    /// 加载 profile 内容供编辑（直接读磁盘）
    func loadProfileContent(name: String) async -> String {
        await exportProfile(name: name)
    }

    /// 切换当前使用的 profile（复制为 default.conf → 重连）
    func switchProfile(_ name: String) async {
        // 1. 读取目标 profile 内容
        let content = await exportProfile(name: name)
        guard !content.isEmpty else {
            alertMsg = "无法读取配置「\(name)」"
            return
        }

        // 2. 写到 default.conf（ daemon 的默认配置路径）
        do {
            try await storeProfile("default", content: content)
        } catch {
            alertMsg = "切换配置失败：\(error.localizedDescription)"
            return
        }

        // 3. 断开再连接（让 daemon 用新配置）
        await postAndWait("disconnect")
        try? await Task.sleep(for: .milliseconds(300))
        await postAndWait("connect")
        await fetchStatus()
    }

    func saveProfile(_ profile: WGProfile) async {
        // 1. 先直接写 .conf 文件
        do {
            try await storeProfile(profile.name, content: profile.wireGuardConfig)
            try await adoptIfNoActiveProfile(profile.wireGuardConfig)
        } catch {
            alertMsg = "保存配置失败：\(error.localizedDescription)"
            return
        }
        // 2. 再通知 daemon
        do {
            try await controlAPI.saveProfile(profile)
            await fetchProfiles()
        } catch {
            alertMsg = "配置已保存到本机，但同步 daemon 失败：\(error.localizedDescription)"
        }
    }

    func deleteProfile(name: String) async {
        // 1. 先直接删文件
        do {
            try profileStore.deleteProfile(name)
        } catch {
            alertMsg = "删除配置失败：\(error.localizedDescription)"
            return
        }
        // 2. 再通知 daemon
        do {
            try await controlAPI.deleteProfile(name: name)
            await fetchProfiles()
        } catch {
            alertMsg = "配置已从本机删除，但同步 daemon 失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 配置同步

    func syncConfig() async -> Bool {
        let prefixes = trustedNetworkPrefixes
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        do {
            try await controlAPI.syncConfig(
                trustedNetworkPrefixes: prefixes,
                autoConnectUntrusted: autoConnectUntrusted,
                desiredVPNEnabled: desiredVPNEnabled,
                desiredGuardEnabled: guardAutomationEnabled,
                intervalSeconds: intervalSeconds,
                autoUpGraceSeconds: autoUpGraceSeconds,
                healthCheckTarget: healthCheckTarget
            )
            alertMsg = "配置已应用到 daemon"
            return true
        } catch {
            alertMsg = "配置应用失败: \(error.localizedDescription)"
            return false
        }
    }

    private func syncConfigSilently() async {
        let prefixes = trustedNetworkPrefixes
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        try? await controlAPI.syncConfig(
            trustedNetworkPrefixes: prefixes,
            autoConnectUntrusted: autoConnectUntrusted,
            desiredVPNEnabled: desiredVPNEnabled,
            desiredGuardEnabled: guardAutomationEnabled,
            intervalSeconds: intervalSeconds,
            autoUpGraceSeconds: autoUpGraceSeconds,
            healthCheckTarget: healthCheckTarget
        )
    }

    // MARK: - Profile 切换

    /// 更新 profile 内容（写磁盘 + 同步 default）
    func updateProfile(name: String, content: String) async {
        // 直接覆盖写入磁盘
        do {
            try await storeProfile(name, content: content)
        } catch {
            alertMsg = "更新配置失败：\(error.localizedDescription)"
            return
        }
        // 如果是当前使用的 profile，同步到 default 并重连
        if status?.service == name {
            do {
                try await storeProfile("default", content: content)
            } catch {
                alertMsg = "配置已更新，但应用到当前连接失败：\(error.localizedDescription)"
            }
        }
    }
    // MARK: - Transfer 文件传输

    typealias TransferDevice = WgSense.TransferDevice
    typealias TransferReceiveState = WgSense.TransferReceiveState
    typealias TransferFileProgress = WgSense.TransferFileProgress
    typealias TransferSendFileProgress = WgSense.TransferSendFileProgress
    typealias TransferSendTask = WgSense.TransferSendTask
    typealias TransferSendTasksState = WgSense.TransferSendTasksState
    typealias TransferPendingFile = WgSense.TransferPendingFile
    typealias TransferPendingRequest = WgSense.TransferPendingRequest

    @Published var transferDevices: [TransferDevice] = []
    @Published var transferState: TransferReceiveState?
    @Published var firewall: FirewallResponse?
    /// 内置代理内核状态；nil 且 mihomoError 有值 = 运行中的网络服务还不支持。
    @Published var mihomo: MihomoStatus?
    @Published var mihomoError: String?
    @Published var firewallError: String?
    @Published var tunnelIPv6: TunnelIPv6Settings?
    @Published var tunnelIPv6Error: String?
	@Published var transferSendTasks: TransferSendTasksState?
	@Published var transferError: String?

    /// 发现局域网内设备（多播 + 手动合并）
    func fetchTransferDevices(timeoutSec: Int = 3) async {
        do {
            transferDevices = try await transferAPI.devices(timeoutSec: timeoutSec)
            transferError = nil
        } catch {
            transferError = daemonConnectionMessage(error)
        }
    }

    /// 单播扫描子网发现设备（用于 WG 隧道等无多播环境）
    func scanSubnet(timeoutSec: Int = 10, subnet: String? = nil) async -> [TransferDevice] {
        do {
            let devices = try await transferAPI.scan(timeoutSec: timeoutSec, subnet: subnet)
            let existingIDs = Set(transferDevices.map { $0.id })
            transferDevices += devices.filter { !existingIDs.contains($0.id) }
            return devices
        } catch {
            alertMsg = "扫描失败: \(error.localizedDescription)"
            return []
        }
    }

    /// 手动添加设备（IP 或 IP:Port）
    func addManualDevice(addr: String) async -> TransferDevice? {
        do {
            let device = try await transferAPI.addManualDevice(addr: addr)
            if !transferDevices.contains(where: { $0.id == device.id }) {
                transferDevices.append(device)
            }
            return device
        } catch {
            alertMsg = "添加设备失败: \(error.localizedDescription)"
            return nil
        }
    }

    /// 移除手动添加的设备
    func removeManualDevice(deviceID: String) async -> Bool {
        do {
            let result = try await transferAPI.removeManualDevice(deviceID: deviceID)
            if result {
                transferDevices.removeAll { $0.id == deviceID }
            }
            return result
        } catch { /* 忽略 */ }
        return false
    }

    /// 获取传输接收状态
    func fetchTransferState() async {
        do {
            let next = try await transferAPI.receiveState()
            if transferState != next { transferState = next }
            if transferError != nil { transferError = nil }
        } catch {
            if transferState != nil { transferState = nil }
            let message = daemonConnectionMessage(error)
            if transferError != message { transferError = message }
        }
    }

    func fetchFirewall() async {
        do {
            let next = try await controlAPI.firewall()
            if firewall != next { firewall = next }
            if firewallError != nil { firewallError = nil }
        } catch {
            if firewall != nil { firewall = nil }
            let message = daemonConnectionMessage(error)
            if firewallError != message { firewallError = message }
        }
    }

    func fetchMihomo() async {
        do {
            let next = try await controlAPI.mihomo()
            if mihomo != next { mihomo = next }
            if mihomoError != nil { mihomoError = nil }
        } catch {
            if mihomo != nil { mihomo = nil }
            let message = daemonConnectionMessage(error)
            if mihomoError != message { mihomoError = message }
        }
    }

    /// 启停内置代理内核（只影响本机端口，不动路由与 DNS）。
    func setMihomo(running: Bool) async -> Bool {
        do {
            mihomo = try await controlAPI.mihomo(action: running ? "start" : "stop")
            mihomoError = nil
            return true
        } catch {
            alertMsg = (running ? "启动" : "停止") + "内置代理内核失败: \(error.localizedDescription)"
            await fetchMihomo()
            return false
        }
    }

    /// 交给网络服务导入配置包。
    func importMihomo(bundle: String, origin: String, selections: [String: String] = [:]) async throws -> MihomoStatus {
        let next = try await controlAPI.importMihomo(bundle: bundle, origin: origin, selections: selections)
        mihomo = next
        return next
    }

    @Published var syncingMihomo = false

    /// 从 op 同步配置（代理页按钮与切换前调用）。返回是否成功；失败时 alert 由 showError 决定。
    @discardableResult
    func syncMihomoFromOp(showError: Bool = true) async -> Bool {
        guard !syncingMihomo else { return false }
        syncingMihomo = true
        defer { syncingMihomo = false }
        do {
            _ = try await MihomoSync.run(client: self, includeGeo: mihomo?.geo_ready != true)
            return true
        } catch {
            if showError { alertMsg = error.localizedDescription }
            return false
        }
    }

    /// 当前出口；旧版网络服务不报 = WireGuard。
    var currentExit: WgExit { WgExit(rawValue: status?.exit ?? "") ?? .wireguard }

    /// 网络服务是否支持切换出口（新版才报 exit 字段，且带了内核才能选 mihomo）。
    func exitAvailable(_ exit: WgExit) -> Bool {
        switch exit {
        case .wireguard: return true
        // Tailscale 开发中：按钮可点，点了只提示，不灰显
        case .tailscale: return true
        // 运行中的服务还不认识出口时也可以点：点了就是要切，切换流程会先把服务升级到 App 自带的版本
        case .mihomo: return status?.exit == nil || mihomo?.bundled == true
        }
    }

    @Published var switchingExit: WgExit?

    /// 界面显示的出口：点击即切到目标（乐观更新），切换失败再退回实际出口。
    var displayedExit: WgExit { switchingExit ?? currentExit }
    /// 切换进行到哪一步，给界面显示。
    @Published var exitProgress: String?

    /// 手动切换出口（三者互斥）：网络服务先拆旧出口再起新出口。
    /// 运行中的网络服务太旧、不认识出口时，先断开隧道并升级服务，再切换——用户点了就是要切。
    func setExit(_ exit: WgExit) async {
        guard exit != currentExit, switchingExit == nil else { return }
        switchingExit = exit
        defer { switchingExit = nil; exitProgress = nil }
        if exit == .mihomo {
            // 先判断要不要升级服务：升级后内核目录可能换了、GEO 库可能不在，这时一律带上 GEO 库
            let outdated = await serviceLacksMihomoImport()
            // ① 趁 WireGuard 还连着（在外也能到路由器）先把 op 的配置拉到本机
            exitProgress = outdated || mihomo?.geo_ready != true
                ? "正在从 op 拉取配置（含 GEO 库，约 13 MB）" : "正在从 op 拉取配置"
            var fetched: (bundle: URL, origin: String, selections: [String: String])?
            var fetchError: String?
            do {
                fetched = try await MihomoSync.fetch(includeGeo: outdated || mihomo?.geo_ready != true)
            } catch {
                fetchError = error.localizedDescription
            }
            defer { if let fetched { try? FileManager.default.removeItem(at: fetched.bundle) } }
            // ② 运行中的网络服务和 App 自带的不是同一份就先升级：升级要求先断开 WireGuard
            if outdated {
                guard await upgradeServiceForExit() else { return }
            }
            // ③ 导入刚拉到的配置；拉不到但已有上次同步的配置就沿用
            if let fetched {
                exitProgress = "正在导入 op 的配置"
                do {
                    _ = try await importMihomo(bundle: fetched.bundle.path, origin: fetched.origin,
                                               selections: fetched.selections)
                } catch {
                    fetchError = error.localizedDescription
                }
            }
            await fetchMihomo()
            if mihomo?.source == nil {
                alertMsg = "切换到 mihomo 需要 op 的配置：\(fetchError ?? "还没有同步过")"
                await restoreWireGuardIfNeeded()
                return
            }
        }
        exitProgress = "正在切换到 \(exit.title)"
        do {
            try await controlAPI.setExit(exit.rawValue)
        } catch {
            alertMsg = "切换到 \(exit.title) 失败: \(error.localizedDescription)"
        }
        await fetchStatus()
        await fetchMihomo()
    }

    /// 运行中的网络服务和 App 自带的不是同一份（哈希不同）：切到 mihomo 前要先升级，
    /// 否则新加的接口（配置导入、控制接口等）在旧服务上不存在。
    private func serviceLacksMihomoImport() async -> Bool {
        guard let path = Bundle.main.path(forResource: "wgsense-daemon", ofType: nil, inDirectory: "libexec"),
              let bytes = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return false }
        let bundled = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        struct Identity: Decodable { var binary_sha256: String }
        guard let running = try? await api.decode(Identity.self, path: "api/service", timeout: 5) else { return true }
        return running.binary_sha256.lowercased() != bundled
    }

    /// 切换中途失败、WireGuard 已被断开时把它连回去。
    private func restoreWireGuardIfNeeded() async {
        await fetchStatus()
        if currentExit == .wireguard && !isTunnelUp {
            _ = try? await api.request("api/connect", method: "POST", timeout: 60)
            await fetchStatus()
        }
    }

    /// 升级网络服务以支持出口切换。升级要求隧道先断开（保护规则：不在隧道连着时换服务）；
    /// 切到别的出口本来就要断开 WireGuard，所以这里直接断开。失败则把隧道恢复原状。
    private func upgradeServiceForExit() async -> Bool {
        let wasConnected = isTunnelUp
        if wasConnected {
            exitProgress = "正在断开 WireGuard"
            _ = try? await api.request("api/disconnect", method: "POST", timeout: 30)
            for _ in 0..<20 {
                await fetchStatus()
                if !isTunnelUp { break }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        exitProgress = "正在更新网络服务"
        let ok = await ensureDaemon(requireActive: true, authorizeIfNeeded: true)
        if ok {
            // 新服务起来后才会报 exit 字段
            for _ in 0..<60 {
                await fetchStatus()
                if status?.exit != nil { break }
                try? await Task.sleep(for: .milliseconds(500))
            }
            await fetchMihomo()
        }
        guard ok, status?.exit != nil else {
            alertMsg = "更新网络服务失败，未切换出口: \(serviceLifecycleError ?? "新服务未就绪")"
            if wasConnected { _ = try? await api.request("api/connect", method: "POST", timeout: 60) }
            await fetchStatus()
            return false
        }
        return true
    }

    func fetchTunnelIPv6() async {
        do {
            let next = try await controlAPI.tunnelIPv6()
            if tunnelIPv6 != next { tunnelIPv6 = next }
            if tunnelIPv6Error != nil { tunnelIPv6Error = nil }
        } catch {
            if tunnelIPv6 != nil { tunnelIPv6 = nil }
            let message = daemonConnectionMessage(error)
            if tunnelIPv6Error != message { tunnelIPv6Error = message }
        }
    }

    /// 保存隧道 IPv6 设置：模式与探测地址立即生效，地址前缀下次连接生效。
    func updateTunnelIPv6(_ settings: TunnelIPv6Settings) async -> Bool {
        do {
            tunnelIPv6 = try await controlAPI.updateTunnelIPv6(settings)
            tunnelIPv6Error = nil
            await fetchStatus()
            return true
        } catch {
            alertMsg = "保存隧道 IPv6 设置失败: \(error.localizedDescription)"
            return false
        }
    }

    /// 保存出站拦截设置，daemon 立即按当前网络重新落规则。
    func updateFirewall(_ settings: FirewallSettings) async -> Bool {
        do {
            firewall = try await controlAPI.updateFirewall(settings)
            firewallError = nil
            await fetchStatus()
            return true
        } catch {
            alertMsg = "保存出站拦截设置失败: \(error.localizedDescription)"
            return false
        }
    }

    /// 启停传输接收服务
    func setTransferReceiveEnabled(_ enabled: Bool) async -> Bool {
        do {
            transferState = try await transferAPI.setReceiveEnabled(enabled)
            return true
        } catch {
            alertMsg = "\(enabled ? "启动" : "停止")接收服务失败: \(error.localizedDescription)"
            return false
        }
    }

    /// 接受或拒绝一个等待中的官方 LocalSend 上传请求。
    func resolveTransferRequest(_ requestID: String, accepted: Bool) async -> Bool {
        do {
            try await transferAPI.resolveRequest(requestID, accepted: accepted)
            await fetchTransferState()
            return true
        } catch {
            alertMsg = "处理接收请求失败: \(error.localizedDescription)"
            return false
        }
    }

    /// 创建后台发送任务，后续进度从 /api/transfer/tasks 获取。
    func startFileSend(to deviceID: String, paths: [String]) async -> TransferSendTask? {
        do {
            let task = try await transferAPI.startSend(to: deviceID, paths: paths)
            await fetchTransferTasks()
            return task
        } catch {
            alertMsg = "发送失败: \(error.localizedDescription)"
            return nil
        }
    }

    func fetchTransferTasks() async {
        do {
            transferSendTasks = try await transferAPI.tasks()
            transferError = nil
        } catch {
            transferError = daemonConnectionMessage(error)
        }
    }

	private func daemonConnectionMessage(_ error: Error) -> String {
		DaemonAPIClient.connectionMessage(error)
	}

    /// 取消传输任务
    func cancelTransfer(taskID: String) async -> Bool {
        do {
            try await transferAPI.cancel(taskID: taskID)
            await fetchTransferTasks()
            return true
        } catch {
            alertMsg = "取消发送失败: \(error.localizedDescription)"
            return false
        }
    }

    /// 启动文件传输所需的应用自有后台服务，不连接 WireGuard。
    func startDaemonForTransfer() async -> Bool {
        let ok = await ensureDaemon(requireActive: false, authorizeIfNeeded: true)
        guard ok else {
            transferError = errorMsg ?? "后台服务启动失败"
            return false
        }
        await fetchTransferState()
        await fetchTransferDevices(timeoutSec: 2)
        await fetchTransferTasks()
        return true
    }

    // MARK: - 代理管理 (Mihomo)

    typealias ProxyStatus = WgSense.ProxyStatus
    typealias ProxySettings = WgSense.ProxySettings
    typealias ProxySettingsResponse = WgSense.ProxySettingsResponse
    typealias MihomoVersion = WgSense.MihomoVersion
    typealias DelayHistory = WgSense.DelayHistory
    typealias ProxyInfo = WgSense.ProxyInfo
    typealias ProxiesResponse = WgSense.ProxiesResponse
    typealias DelayResult = WgSense.DelayResult
    typealias GroupDelayResult = WgSense.GroupDelayResult
    typealias ConnectionInfo = WgSense.ConnectionInfo
    typealias ConnectionMetadata = WgSense.ConnectionMetadata
    typealias ConnectionsResponse = WgSense.ConnectionsResponse
    typealias RuleInfo = WgSense.RuleInfo
    typealias RulesResponse = WgSense.RulesResponse
    typealias ProxyProviderInfo = WgSense.ProxyProviderInfo
    typealias SubscriptionInfo = WgSense.SubscriptionInfo
    typealias ProxyProvidersResponse = WgSense.ProxyProvidersResponse
    typealias RuleProviderInfo = WgSense.RuleProviderInfo
    typealias RuleProvidersResponse = WgSense.RuleProvidersResponse
    typealias MihomoConfig = WgSense.MihomoConfig
    typealias DNSQueryResponse = WgSense.DNSQueryResponse
    typealias ProxyLogEntry = WgSense.ProxyLogEntry
    typealias ProxyLogsResponse = WgSense.ProxyLogsResponse

    @Published var proxyRunning: Bool = false
    @Published var proxyServiceRunning: Bool = false
    @Published var proxyAddress: String = ""
    @Published var proxyStatus: ProxyStatus?
    @Published var proxySettings: ProxySettings?
    @Published var proxyError: String?
    @Published var proxyNotice: String?
    @Published var mihomoVersion: MihomoVersion?
    @Published var proxies: [String: ProxyInfo] = [:]
    /// 连接列表每秒刷新，单独放在 ProxyLiveStore：挂在这里当 @Published 的话，每次刷新
    /// 都会让侧栏等所有订阅 DaemonClient 的视图一起重算。只有代理页订阅 ProxyLiveStore。
    var connections: ConnectionsResponse? {
        get { ProxyLiveStore.shared.connections }
        set { ProxyLiveStore.shared.connections = newValue }
    }
    @Published var rules: [RuleInfo] = []
    @Published var proxyProviders: [String: ProxyProviderInfo] = [:]
    @Published var ruleProviders: [String: RuleProviderInfo] = [:]
    @Published var mihomoConfig: MihomoConfig?
    @Published var dnsQueryResult: DNSQueryResponse?
    @Published var proxyLogs: [ProxyLogEntry] = []

    private func proxyFailure(_ error: Error, prefix: String? = nil) {
        let message = error.localizedDescription
        proxyError = prefix.map { "\($0): \(message)" } ?? message
        proxyNotice = nil
    }

    private func runProxyCommand(
        _ command: () async throws -> Void,
        success: String? = nil
    ) async -> Bool {
        do {
            try await command()
            proxyError = nil
            proxyNotice = success
            return true
        } catch {
            proxyFailure(error)
            return false
        }
    }

    func fetchProxyStatus() async {
        // 面板接的是本机内核时，网络服务里那个指向路由器的控制器客户端与面板无关：
        // 不去问它，也不把它连不上路由器的错误显示在面板上
        if MihomoBackendStore.shared.active?.isLocal == true {
            if proxyError != nil { proxyError = nil }
            return
        }
        do {
            let result = try await proxyAPI.status()
            proxyStatus = result
            proxyServiceRunning = result.running
            proxyRunning = result.connected
            proxyAddress = result.address
            proxyError = result.connected ? nil : result.lastError
        } catch {
            proxyStatus = nil
            proxyServiceRunning = false
            proxyRunning = false
            proxyFailure(error, prefix: "读取代理状态失败")
        }
    }

    func startDaemonForProxy() async -> Bool {
        let ok = await ensureDaemon(requireActive: false, authorizeIfNeeded: true)
        await fetchProxySettings()
        await fetchProxyStatus()
        if ok {
            proxyNotice = proxyRunning ? "后台服务已启动，控制器连接成功" : "后台服务已启动，请检查控制器地址与密钥"
        } else {
            proxyError = errorMsg ?? "后台服务启动失败"
        }
        return ok
    }

    func fetchProxySettings() async {
        do {
            let result = try await proxyAPI.settings()
            proxySettings = result.settings
            proxyStatus = result.status
            proxyAddress = result.settings.address
            proxyServiceRunning = result.status.running
            proxyRunning = result.status.connected
            proxyError = result.status.connected ? nil : result.status.lastError
        } catch {
            proxyFailure(error, prefix: "读取控制器设置失败")
        }
    }

    func saveProxySettings(
        address: String,
        secret: String?,
        latencyTestURL: String,
        latencyTimeout: Int,
        latencyLow: Int,
        latencyMedium: Int
    ) async -> Bool {
        do {
            let result = try await proxyAPI.saveSettings(
                address: address,
                secret: secret,
                latencyTestURL: latencyTestURL,
                latencyTimeout: latencyTimeout,
                latencyLow: latencyLow,
                latencyMedium: latencyMedium
            )
            proxySettings = result.settings
            proxyStatus = result.status
            proxyAddress = result.settings.address
            proxyServiceRunning = result.status.running
            proxyRunning = result.status.connected
            proxyError = result.status.connected ? nil : result.status.lastError
            proxyNotice = result.status.connected ? "控制器连接成功" : "设置已保存，连接测试失败"
            return result.status.connected
        } catch {
            proxyFailure(error, prefix: "保存控制器设置失败")
            return false
        }
    }

    func fetchProxyVersion() async {
        do {
            mihomoVersion = try await proxyAPI.version()
        } catch {
            mihomoVersion = nil
            proxyFailure(error, prefix: "读取核心版本失败")
        }
    }

    func fetchProxies() async {
        do {
            let result = try await proxyAPI.proxies()
            proxies = result.proxies
            proxyError = nil
        } catch {
            proxyFailure(error, prefix: "读取代理节点失败")
        }
    }

    func selectProxy(group: String, name: String) async -> Bool {
        let ok = await runProxyCommand(
            { try await proxyAPI.selectProxy(group: group, name: name) },
            success: "已切换到 \(name)"
        )
        if ok { await fetchProxies() }
        return ok
    }

    func testDelay(name: String) async -> DelayResult? {
        do {
            return try await proxyAPI.delay(name: name)
        } catch {
            proxyFailure(error, prefix: "延迟测试失败")
            return nil
        }
    }

    func testGroupDelay(group: String) async -> GroupDelayResult? {
        do {
            return try await proxyAPI.groupDelay(group: group)
        } catch {
            proxyFailure(error, prefix: "策略组延迟测试失败")
            return nil
        }
    }

    func fetchConnections() async {
        do {
            connections = try await proxyAPI.connections()
        } catch {
            proxyFailure(error, prefix: "读取连接失败")
        }
    }

    func closeConnection(id: String) async -> Bool {
        let ok = await runProxyCommand { try await proxyAPI.closeConnection(id: id) }
        if ok { await fetchConnections() }
        return ok
    }

    func closeAllConnections() async -> Bool {
        let ok = await runProxyCommand(
            { try await proxyAPI.closeAllConnections() },
            success: "已关闭全部连接"
        )
        if ok { await fetchConnections() }
        return ok
    }

    func fetchRules() async {
        do {
            let result = try await proxyAPI.rules()
            rules = result.rules
        } catch {
            proxyFailure(error, prefix: "读取规则失败")
        }
    }

    func fetchProxyProviders() async {
        do {
            let result = try await proxyAPI.proxyProviders()
            proxyProviders = result.providers
        } catch {
            proxyFailure(error, prefix: "读取订阅失败")
        }
    }

    func fetchRuleProviders() async {
        do {
            let result = try await proxyAPI.ruleProviders()
            ruleProviders = result.providers
        } catch {
            proxyFailure(error, prefix: "读取规则集失败")
        }
    }

    func fetchProxyConfig() async {
        do {
            mihomoConfig = try await proxyAPI.config()
        } catch {
            proxyFailure(error, prefix: "读取运行配置失败")
        }
    }

    func updateProvider(name: String) async -> Bool {
        let ok = await runProxyCommand(
            { try await proxyAPI.updateProvider(name: name) },
            success: "订阅 \(name) 已更新"
        )
        if ok { await fetchProxyProviders(); await fetchProxies() }
        return ok
    }

    func healthCheckProvider(name: String) async -> Bool {
        await runProxyCommand(
            { try await proxyAPI.healthCheckProvider(name: name) },
            success: "订阅 \(name) 延迟测试完成"
        )
    }

    func updateRuleProvider(name: String) async -> Bool {
        let ok = await runProxyCommand(
            { try await proxyAPI.updateRuleProvider(name: name) },
            success: "规则集 \(name) 已更新"
        )
        if ok { await fetchRuleProviders(); await fetchRules() }
        return ok
    }

    func patchProxyConfig(_ values: [String: Any], success: String? = nil) async -> Bool {
        let ok = await runProxyCommand(
            { try await proxyAPI.patchConfig(values) },
            success: success
        )
        if ok { await fetchProxyConfig() }
        return ok
    }

    func updateProxyMode(_ mode: String) async -> Bool {
        await patchProxyConfig(["mode": mode], success: "运行模式已切换为 \(mode.uppercased())")
    }

    func updateProxyTUN(_ enabled: Bool) async -> Bool {
        await patchProxyConfig(["tun": ["enable": enabled]], success: enabled ? "TUN 已启用" : "TUN 已停用")
    }

    func updateProxyAllowLAN(_ enabled: Bool) async -> Bool {
        await patchProxyConfig(["allow-lan": enabled], success: enabled ? "局域网访问已允许" : "局域网访问已关闭")
    }

    func performProxyAction(_ action: String, success: String) async -> Bool {
        await runProxyCommand(
            { try await proxyAPI.performAction(action) },
            success: success
        )
    }

    func flushFakeIP() async -> Bool {
        await performProxyAction("flush-fakeip", success: "FakeIP 缓存已清除")
    }

    func queryProxyDNS(name: String, type: String) async -> Bool {
        do {
            dnsQueryResult = try await proxyAPI.dnsQuery(name: name, type: type)
            proxyError = nil
            return true
        } catch {
            dnsQueryResult = nil
            proxyFailure(error, prefix: "DNS 查询失败")
            return false
        }
    }

    func fetchProxyLogs(limit: Int = 200) async {
        do {
            let result = try await proxyAPI.logs(limit: limit)
            if proxyLogs.map(\.id) != result.logs.map(\.id) {
                proxyLogs = result.logs
            }
        } catch {
            proxyFailure(error, prefix: "读取 Mihomo 日志失败")
        }
    }
}

// Coordinates the single privileged installation attempt for this App process.
// User-triggered retries remain possible after cancellation or a failed install.
@MainActor
final class DaemonServiceCoordinator {
    static let shared = DaemonServiceCoordinator()

    enum Mode { case firstLaunch, userAction, maintenance, readOnly, stopOnly, restart }

    struct Outcome {
        let ok: Bool
        let message: String
        /// 安装已失败过且安装包未变：不再自动弹密码，等用户显式点“重试安装”。
        var needsExplicitRetry = false
        static let ready = Outcome(ok: true, message: "系统服务已就绪")
        static func failure(_ message: String) -> Outcome { Outcome(ok: false, message: message) }
    }

    private struct ServiceIdentity: Decodable {
        let `protocol`: Int
        let managed: Bool
        let owner_uid: Int
        let binary_sha256: String
        let ready: Bool
        let pid: Int?
    }

    private struct Submission: Decodable {
        let operation_id: String
        let binary_sha256: String
    }

    private struct InstallResult: Decodable {
        let operation_id: String
        let status: String
        let message: String?
        let binary_sha256: String?
    }

    private let api = DaemonAPIClient()
    private let controlAPI = DaemonControlAPIClient()
    private let plistPath = "/Library/LaunchDaemons/com.wgsense.daemon.plist"
    private let resultPath = "/Library/Application Support/WgSense/install-result.json"
    private var operation: Task<Outcome, Never>?
    private var operationMode: Mode?
    private var operationGeneration = 0
    private var firstLaunchStarted = false
    private var firstLaunchOutcome: Outcome?

    func ensure(_ mode: Mode) async -> Outcome {
        if case .firstLaunch = mode {
            if firstLaunchStarted {
                if let operation, operationMode == .firstLaunch { return await operation.value }
                return firstLaunchOutcome ?? .failure("首次安装正在检查")
            }
            firstLaunchStarted = true
        }
        let outcome = await performCoalesced(mode)
        if case .firstLaunch = mode { firstLaunchOutcome = outcome }
        return outcome
    }

    private func performCoalesced(_ mode: Mode) async -> Outcome {
        if let operation {
            let joinedMode = operationMode
            let generation = operationGeneration
            let outcome = await operation.value
            clearOperation(ifGeneration: generation)
            if joinedMode == mode || !outcome.ok { return outcome }
            // A successful stop-only or read-only result never authorizes a
            // different action; run that action's own identity/version check.
            return await performCoalesced(mode)
        }
        operationGeneration += 1
        let generation = operationGeneration
        operationMode = mode
        let task = Task { mode == .restart ? await performRestart() : await perform(mode) }
        operation = task
        let outcome = await task.value
        clearOperation(ifGeneration: generation)
        return outcome
    }

    private func clearOperation(ifGeneration generation: Int) {
        guard operationGeneration == generation else { return }
        operation = nil
        operationMode = nil
    }

    func restart() async -> Outcome {
        await performCoalesced(.restart)
    }

    private func performRestart() async -> Outcome {
        let checked = await perform(.readOnly)
        guard checked.ok else { return checked }
        guard let before = await serviceIdentity() else { return .failure("无法读取重启前的系统服务状态") }
        var requestError: Error?
        do {
            _ = try await api.request("api/service/restart", method: "POST", timeout: 5)
        } catch {
            // The daemon may exit after accepting the request but before the
            // HTTP response reaches us. Judge completion by the new process.
            requestError = error
        }
        for _ in 0..<20 {
            try? await Task.sleep(for: .seconds(1))
            if let after = await serviceIdentity(), identityProblem(after) == nil,
               after.ready && after.binary_sha256 == before.binary_sha256,
               after.pid != before.pid { return .ready }
        }
        if let requestError {
            return .failure("无法确认系统服务已重启：\(requestError.localizedDescription)")
        }
        return .failure("系统服务重启后未按时就绪；请查看维护诊断")
    }

    private func perform(_ mode: Mode) async -> Outcome {
        guard let daemon = Bundle.main.path(forResource: "wgsense-daemon", ofType: nil, inDirectory: "libexec"),
              let mover = Bundle.main.path(forResource: "wgsense-receive-mover", ofType: "sh", inDirectory: "packaging"),
              FileManager.default.isExecutableFile(atPath: daemon) else {
            return .failure("安装包缺少后台服务文件，请重新安装完整的 Xtrim App")
        }
        let expectedHash: String
        do {
            let bytes = try Data(contentsOf: URL(fileURLWithPath: daemon))
            expectedHash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        } catch {
            return .failure("无法校验后台服务文件：\(error.localizedDescription)")
        }

        if let identity = await serviceIdentity() {
            if let mismatch = identityProblem(identity) { return .failure(mismatch) }
            if mode == .stopOnly {
                return identity.ready ? .ready : .failure("Xtrim 服务尚未就绪，无法安全断开")
            }
            if identity.binary_sha256.lowercased() == expectedHash && identity.ready { return .ready }
            if identity.binary_sha256.lowercased() != expectedHash {
                if mode == .readOnly { return .failure("系统服务版本与 App 不一致；请先完成升级") }
                if let running = try? await controlAPI.status(timeout: 1.5), running.state == "Connected" {
                    return .failure("旧版 Xtrim 隧道仍在运行；请先断开，再升级后台服务")
                }
                return await submitUpdate(daemon: daemon, mover: mover, expectedHash: expectedHash)
            }
            if await waitForIdentity(expectedHash: expectedHash, seconds: 10) { return .ready }
            return .failure("系统服务未就绪；请在维护面板查看诊断")
        }

        let hasPlist = FileManager.default.fileExists(atPath: plistPath)
        if mode == .stopOnly, let old = try? await controlAPI.status(timeout: 1.5),
           old.app_owned == true || (hasPlist && old.app_owned == false) {
            return .ready
        }
        if hasPlist {
            if await waitForIdentity(expectedHash: expectedHash, seconds: 10) { return .ready }
            // An old daemon can be migrated by the installer; an offline
            // registered job should be diagnosed rather than repeatedly prompting.
            if (try? await controlAPI.status(timeout: 1.5)) == nil && mode != .maintenance {
                return .failure("系统服务已安装但未运行；请在维护面板检查或明确选择修复")
            }
        }
        if let legacy = try? await controlAPI.status(timeout: 1.5),
           legacy.app_owned == true && legacy.state == "Connected" {
            return .failure("旧版临时 VPN 正在运行；请先在旧版中断开，再安装常驻服务")
        }

        guard mode != .readOnly && mode != .stopOnly else { return .failure("系统服务尚未安装或无法识别") }
        // 同一安装包上次已由安装程序判定失败：再弹密码也只会同样失败。自动路径（启动、
        // 点连接/守护）到此为止，只有维护/重试入口才再次提权。取消密码框不写失败记录，不受影响。
        if mode != .maintenance, let last = readInstallResult(), last.status == "error",
           last.binary_sha256?.lowercased() == expectedHash {
            var outcome = Outcome.failure("后台服务安装失败：\(last.message ?? "未知原因")")
            outcome.needsExplicitRetry = true
            return outcome
        }
        return await submitInstall(daemon: daemon, mover: mover, expectedHash: expectedHash)
    }

    private func identityProblem(_ identity: ServiceIdentity) -> String? {
        if identity.`protocol` != 1 || !identity.managed || identity.owner_uid != Int(getuid()) {
            return "当前端口不是本用户可用的 Xtrim 系统服务；请检查是否有旧进程占用"
        }
        return nil
    }

    private func serviceIdentity() async -> ServiceIdentity? {
        try? await api.decode(ServiceIdentity.self, path: "api/service", timeout: 1.5)
    }

    private func submitUpdate(daemon: String, mover: String, expectedHash: String) async -> Outcome {
        let previousOperationID = readInstallResult()?.operation_id
        do {
            let submission = try await api.decode(
                Submission.self,
                path: "api/service/update",
                method: "POST",
                body: ["source_daemon": daemon, "source_mover": mover, "binary_sha256": expectedHash],
                timeout: 10
            )
            guard submission.binary_sha256.lowercased() == expectedHash else {
                return .failure("后台服务升级任务的版本校验不匹配")
            }
            return await waitForOperation(submission, expectedHash: expectedHash)
        } catch {
            // The old daemon can exit after accepting the upgrade but before
            // its HTTP response reaches the App. Verify the new service or the
            // newly written operation receipt before reporting failure.
            if let identity = await serviceIdentity(), identityProblem(identity) == nil,
               identity.ready && identity.binary_sha256.lowercased() == expectedHash {
                return .ready
            }
            if let receipt = readInstallResult(), !receipt.operation_id.isEmpty,
               receipt.operation_id != previousOperationID,
               receipt.binary_sha256?.lowercased() == expectedHash {
                if receipt.status == "running" || receipt.status == "success" {
                    return await waitForOperation(
                        Submission(operation_id: receipt.operation_id, binary_sha256: expectedHash),
                        expectedHash: expectedHash
                    )
                }
                if receipt.status == "error" {
                    return .failure(receipt.message ?? "后台服务升级失败，旧服务已保留")
                }
            }
            return .failure("后台服务升级未提交：\(error.localizedDescription)")
        }
    }

    private func submitInstall(daemon: String, mover: String, expectedHash: String) async -> Outcome {
        guard let script = Bundle.main.path(forResource: "wgsense-install-services", ofType: "sh", inDirectory: "packaging") else {
            return .failure("安装包缺少系统服务安装脚本")
        }
        let username = NSUserName()
        guard !username.isEmpty && username != "root" else { return .failure("无法确定登录用户") }
        let command = [script, daemon, mover, username].map(ShellCommand.quote).joined(separator: " ")
        let result = await ShellCommand.administrator(command, timeout: 120)
        guard result.succeeded else {
            return .failure("系统服务安装被取消或失败：\(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        guard let submission = try? JSONDecoder().decode(Submission.self, from: Data(result.output.utf8)),
              submission.binary_sha256.lowercased() == expectedHash else {
            return .failure("安装程序未返回可验证的任务编号；请查看维护诊断")
        }
        return await waitForOperation(submission, expectedHash: expectedHash)
    }

    private func waitForIdentity(expectedHash: String, seconds: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        while Date() < deadline {
            if let identity = await serviceIdentity(), identityProblem(identity) == nil,
               identity.ready && identity.binary_sha256.lowercased() == expectedHash { return true }
            try? await Task.sleep(for: .seconds(1))
        }
        return false
    }

    private func waitForOperation(_ submission: Submission, expectedHash: String) async -> Outcome {
        var committed = false
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            if let receipt = readInstallResult(), receipt.operation_id == submission.operation_id {
                if receipt.status == "error" {
                    return .failure(receipt.message ?? "后台服务安装或升级失败，旧服务已保留")
                }
                if receipt.status == "success" {
                    guard receipt.binary_sha256?.lowercased() == expectedHash else {
                        return .failure("安装记录的版本与 App 不一致")
                    }
                    committed = true
                }
            }
            if committed, let identity = await serviceIdentity(), identityProblem(identity) == nil,
               identity.ready && identity.binary_sha256.lowercased() == expectedHash { return .ready }
            try? await Task.sleep(for: .seconds(1))
        }
        return .failure("等待后台服务就绪超时；请在维护面板查看安装结果")
    }

    private func readInstallResult() -> InstallResult? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: resultPath)) else { return nil }
        return try? JSONDecoder().decode(InstallResult.self, from: data)
    }
}


/// 代理页的高频数据源（见 DaemonClient.connections）。
@MainActor
final class ProxyLiveStore: ObservableObject {
    static let shared = ProxyLiveStore()
    @Published var connections: ConnectionsResponse?
}
