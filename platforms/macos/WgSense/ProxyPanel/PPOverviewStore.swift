import Foundation
import Combine
import SwiftUI

// 概览页数据层（O-*）。高频数据的设计原则：
//   - 图表样本放在非 @Published 的缓冲区里，图表在自己的时间线里逐帧读取，不触发界面失效；
//   - 统计条等 1Hz 数值单独 @Published，只让显示它们的小视图订阅；
//   - 拓扑图输入节流（最多每秒一次），悬停/暂停时冻结。

/// 带时间戳的样本缓冲（环形，保留最近 windowSeconds + 余量）。
final class PPSampleBuffer: ObservableObject {
    struct Sample { var time: TimeInterval; var values: [Double] }
    private(set) var samples: [Sample] = []
    /// 最新样本时间：图表只订阅自己的缓冲区，每来一个样本刷新一次。
    @Published private(set) var version: TimeInterval = 0
    let seriesCount: Int
    let keep: TimeInterval

    init(series: Int, keep: TimeInterval = 75) {
        seriesCount = series
        self.keep = keep
    }

    func append(_ values: [Double], at time: TimeInterval = Date().timeIntervalSince1970) {
        samples.append(Sample(time: time, values: values))
        let cutoff = time - keep
        if let first = samples.firstIndex(where: { $0.time >= cutoff }), first > 0 {
            samples.removeFirst(first)
        }
        let key = "pp.buffer.\(ObjectIdentifier(self).hashValue)"
        MainActor.assumeIsolated { WgScrollActivity.whenIdle(key) { [weak self] in self?.version = time } }
    }

    func reset() { samples.removeAll(); version = 0 }
}

enum PPOverviewCard: String, CaseIterable, Codable, Identifiable {
    case charts, network, providerTraffic, topology, history, ruleHits
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .charts: return "图表卡片"
        case .network: return "网络卡片"
        case .providerTraffic: return "提供商流量概览"
        case .topology: return "连接拓扑"
        case .history: return "连接统计"
        case .ruleHits: return "规则命中统计"
        }
    }
    var symbol: String {
        switch self {
        case .charts: return "chart.xyaxis.line"
        case .network: return "network"
        case .providerTraffic: return "chart.bar.fill"
        case .topology: return "point.3.filled.connected.trianglepath.dotted"
        case .history: return "clock.arrow.circlepath"
        case .ruleHits: return "target"
        }
    }
}

struct PPCardSetting: Codable, Equatable, Identifiable {
    var card: PPOverviewCard
    var visible: Bool
    var id: String { card.rawValue }
}

enum PPHistoryType: String, CaseIterable, Codable, Identifiable {
    case sourceIP, destination, process, outbound
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .sourceIP: return "按源IP"
        case .destination: return "按目标地址"
        case .process: return "按进程"
        case .outbound: return "按出站节点"
        }
    }
    var columnTitle: String {
        switch self {
        case .sourceIP: return String(localized: "源IP", bundle: .wgLocalized)
        case .destination: return String(localized: "目标地址", bundle: .wgLocalized)
        case .process: return String(localized: "进程", bundle: .wgLocalized)
        case .outbound: return String(localized: "出站节点", bundle: .wgLocalized)
        }
    }
}

struct PPHistoryRow: Codable, Identifiable, Hashable {
    var key: String
    var download: Int64
    var upload: Int64
    var count: Int
    var id: String { key }
    var total: Int64 { download + upload }
}

enum PPCleanupInterval: String, CaseIterable, Identifiable {
    case never, week, month, quarter
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .never: return "永不"
        case .week: return "每周"
        case .month: return "每月"
        case .quarter: return "每季度"
        }
    }
    var seconds: TimeInterval? {
        switch self {
        case .never: return nil
        case .week: return 7 * 86400
        case .month: return 30 * 86400
        case .quarter: return 90 * 86400
        }
    }
}

enum PPIPInfoAPI: String, CaseIterable, Identifiable {
    case ipsb, ipwhois, ipapi
    var id: String { rawValue }
    var title: String {
        switch self {
        case .ipsb: return "ip.sb"
        case .ipwhois: return "ipwho.is"
        case .ipapi: return "ipapi.is"
        }
    }
}

struct PPIPResult: Equatable {
    var location: String
    var ip: String
}

@MainActor
final class PPOverviewStore: ObservableObject {
    static let shared = PPOverviewStore()

    // MARK: 图表缓冲（不 @Published）
    // 下载、上传各一个缓冲：两条图各自有镜头，互不压制。
    let downSpeed = PPSampleBuffer(series: 1)
    let upSpeed = PPSampleBuffer(series: 1)
    let memory = PPSampleBuffer(series: 1)
    let connectionCount = PPSampleBuffer(series: 1)

    // MARK: 统计条（1Hz）：放在独立的 PPOverviewStats，避免每秒的变化牵连其他卡片重算。
    var stats: Stats {
        get { PPOverviewStats.shared.stats }
        set {
            // 滚动中暂缓上屏（见 WgScrollActivity）。
            WgScrollActivity.whenIdle("pp.stats") {
                if PPOverviewStats.shared.stats != newValue { PPOverviewStats.shared.stats = newValue }
            }
        }
    }
    struct Stats: Equatable {
        var connections = 0
        var memory: Int64 = 0
        var downloadTotal: Int64 = 0
        var uploadTotal: Int64 = 0
        var downSpeed: Int64 = 0
        var upSpeed: Int64 = 0
    }

    // MARK: 拓扑输入（节流）
    @Published private(set) var topologyConnections: [MihomoConnection] = []
    @Published var topologyPaused = false
    private var lastTopologyUpdate = Date.distantPast

    // MARK: 连接统计
    @Published private(set) var history: [PPHistoryType: [PPHistoryRow]] = [:]
    @Published var historyType: PPHistoryType = PPHistoryType(rawValue: UserDefaults.standard.string(forKey: "pp.historyType") ?? "") ?? .sourceIP {
        didSet { UserDefaults.standard.set(historyType.rawValue, forKey: "pp.historyType") }
    }
    @Published var cleanupInterval: PPCleanupInterval = PPCleanupInterval(rawValue: UserDefaults.standard.string(forKey: "pp.historyCleanup") ?? "") ?? .month {
        didSet { UserDefaults.standard.set(cleanupInterval.rawValue, forKey: "pp.historyCleanup") }
    }
    @Published private(set) var historyStart: Date?
    private var lastSnapshot: [String: MihomoConnection] = [:]
    private var historyLoadedFor: UUID?
    private var historyDirty = false

    // MARK: 规则命中
    @Published private(set) var rules: [MihomoRule] = []

    // MARK: 网络信息
    @Published private(set) var chinaIP: PPIPResult?
    @Published private(set) var globalIP: PPIPResult?
    @Published private(set) var ipChecking = false
    @Published var showPrivacy = false
    @Published private(set) var latencies: [String: Int] = [:]   // 名称 → ms（0=失败）
    @Published private(set) var latencyChecking = false
    @Published var ipInfoAPI: PPIPInfoAPI = PPIPInfoAPI(rawValue: UserDefaults.standard.string(forKey: "pp.ipInfoAPI") ?? "") ?? .ipsb {
        didSet { UserDefaults.standard.set(ipInfoAPI.rawValue, forKey: "pp.ipInfoAPI") }
    }
    @Published var autoIPCheck = PPPersist.value("pp.autoIPCheck", true) { didSet { UserDefaults.standard.set(autoIPCheck, forKey: "pp.autoIPCheck") } }
    @Published var autoConnectionCheck = PPPersist.value("pp.autoConnectionCheck", true) { didSet { UserDefaults.standard.set(autoConnectionCheck, forKey: "pp.autoConnectionCheck") } }

    static let latencyTargets: [(name: String, url: String)] = [
        ("Baidu", "https://apps.bdimg.com/favicon.ico"),
        ("Cloudflare", "https://www.cloudflare.com/favicon.ico"),
        ("GitHub", "https://github.githubassets.com/favicon.ico"),
        ("YouTube", "https://yt3.ggpht.com/favicon.ico"),
    ]

    // MARK: 卡片设置（O-C01）
    @Published var cards: [PPCardSetting] = PPOverviewStore.loadCards() {
        didSet {
            if let data = try? JSONEncoder().encode(cards) { UserDefaults.standard.set(data, forKey: "pp.overviewCards") }
        }
    }

    private static func loadCards() -> [PPCardSetting] {
        var cards: [PPCardSetting] = []
        if let data = UserDefaults.standard.data(forKey: "pp.overviewCards"),
           let saved = try? JSONDecoder().decode([PPCardSetting].self, from: data) {
            cards = saved
        }
        // 缺失的新卡片补到末尾（与原版一致）。
        for card in PPOverviewCard.allCases where !cards.contains(where: { $0.card == card }) {
            cards.append(PPCardSetting(card: card, visible: true))
        }
        return cards
    }

    private var streamTasks: [Task<Void, Never>] = []
    private var rulesTask: Task<Void, Never>?

    private init() {}

    private var api: MihomoAPI? {
        let store = MihomoBackendStore.shared
        guard let backend = store.active else { return nil }
        return MihomoAPI(backend: backend, secret: store.secret(for: backend))
    }

    // MARK: 生命周期

    /// 概览页是否在显示（主窗口可能仍被收起）。
    private var pageActive = false
    private var visibilityObserver: AnyCancellable?

    /// 概览可见时启动流量/内存推送与规则轮询。
    func activate() {
        pageActive = true
        loadHistoryIfNeeded()
        observeWindowVisibility()
        guard WgWindowVisibility.shared.isMainWindowVisible else { return }
        startSampling()
        startRulesPolling()
        if autoIPCheck && chinaIP == nil { Task { await checkIP() } }
        if autoConnectionCheck && latencies.isEmpty { Task { await checkLatency() } }
    }

    private func startRulesPolling() {
        guard rulesTask == nil, let api else { return }
        rulesTask = Task { [weak self] in
            while !Task.isCancelled {
                if let rules = try? await api.rules() { self?.applyRules(rules) }
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }

    /// 图表采样只在主窗口可见时运行（App 启动后第一次出现主窗口即开始，收起后停止）：
    /// 曲线是视觉内容，菜单栏常驻时不在后台每秒解码 mihomo 推送。
    private func observeWindowVisibility() {
        guard visibilityObserver == nil else { return }
        visibilityObserver = WgWindowVisibility.shared.$isMainWindowVisible
            .removeDuplicates()
            .sink { [weak self] visible in
                guard let self else { return }
                if visible {
                    self.startSampling()
                    if self.pageActive { self.startRulesPolling() }
                } else {
                    self.stopSampling()
                    self.rulesTask?.cancel()
                    self.rulesTask = nil
                    self.flushHistory()
                }
            }
    }

    /// 主窗口出现时开始图表采样，并订阅之后的收起/再现。
    func startSamplingWhileVisible() {
        observeWindowVisibility()
    }

    private func stopSampling() {
        streamTasks.forEach { $0.cancel() }
        streamTasks.removeAll()
    }

    /// 速度/内存采样（图表缓存）：主窗口可见期间常开，不随概览页启停，切回概览时曲线直接接上。
    private func startSampling() {
        guard WgWindowVisibility.shared.isMainWindowVisible else { return }
        guard streamTasks.isEmpty, let api else { return }
        streamTasks.append(Task { [weak self] in
            for await traffic in api.trafficStream() {
                guard let self, !Task.isCancelled else { break }
                let now = Date().timeIntervalSince1970
                self.downSpeed.append([Double(traffic.down)], at: now)
                self.upSpeed.append([Double(traffic.up)], at: now)
                var s = self.stats
                s.upSpeed = traffic.up
                s.downSpeed = traffic.down
                self.stats = s
            }
        })
        streamTasks.append(Task { [weak self] in
            for await mem in api.memoryStream() {
                guard let self, !Task.isCancelled else { break }
                guard mem.inuse > 0 else { continue }   // O-G02：内存为 0 的推送忽略
                self.memory.append([Double(mem.inuse)])
                self.connectionCount.append([Double(self.stats.connections)])
                var s = self.stats
                s.memory = mem.inuse
                self.stats = s
            }
        })
    }

    /// 离开概览页时只停规则轮询；速度/内存推送（1Hz、极轻）继续在后台采样，
    /// 回到概览时曲线直接接上最近 75 秒，而不是从右边从零开始。
    func deactivate() {
        rulesTask?.cancel()
        rulesTask = nil
        flushHistory()
    }

    func backendChanged() {
        rulesTask?.cancel()
        rulesTask = nil
        flushHistory()
        stopSampling()
        downSpeed.reset(); upSpeed.reset(); memory.reset(); connectionCount.reset()
        stats = Stats()
        topologyConnections = []
        lastSnapshot = [:]
        historyLoadedFor = nil
        history = [:]
        rules = []
        startSampling()
        if pageActive && WgWindowVisibility.shared.isMainWindowVisible {
            loadHistoryIfNeeded()
            startRulesPolling()
        }
    }

    private func applyRules(_ new: [MihomoRule]) {
        WgScrollActivity.whenIdle("pp.rules") { [weak self] in
            if self?.rules != new { self?.rules = new }
        }
    }

    // MARK: 连接快照（由 ProxyPanelStore 的连接推送转发）

    func ingest(_ snapshot: MihomoConnectionsSnapshot) {
        let connections = snapshot.connections ?? []
        var s = stats
        s.connections = connections.count
        s.downloadTotal = snapshot.downloadTotal
        s.uploadTotal = snapshot.uploadTotal
        if let mem = snapshot.memory, mem > 0 { s.memory = mem }
        stats = s

        // 拓扑：最多每秒一次，暂停（悬停）时冻结。
        if !topologyPaused, Date().timeIntervalSince(lastTopologyUpdate) >= 2 {
            lastTopologyUpdate = Date()
            if topologyConnections.map(\.id) != connections.map(\.id) || topologyConnections.count != connections.count {
                WgScrollActivity.whenIdle("pp.topology") { [weak self] in self?.topologyConnections = connections }
            }
        }

        // 连接统计：上次有、这次没有 = 已关闭，按上次的累计流量记账（O-H01）。
        let current = Dictionary(connections.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let closed = lastSnapshot.values.filter { current[$0.id] == nil }
        lastSnapshot = current
        if !closed.isEmpty { recordClosed(Array(closed)) }
    }

    // MARK: 连接统计（O-H01…O-H05）

    private var historyURL: URL? {
        guard let backend = MihomoBackendStore.shared.active else { return nil }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WgSense/connection-history", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(backend.id.uuidString).json")
    }

    private struct HistoryFile: Codable {
        var start: Date
        var data: [String: [PPHistoryRow]]
    }

    private func loadHistoryIfNeeded() {
        guard let backend = MihomoBackendStore.shared.active, historyLoadedFor != backend.id else { return }
        historyLoadedFor = backend.id
        var file = HistoryFile(start: Date(), data: [:])
        if let url = historyURL, let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode(HistoryFile.self, from: data) {
            file = saved
        }
        // 自动清理：超过间隔则重新开始统计。
        if let interval = cleanupInterval.seconds, Date().timeIntervalSince(file.start) > interval {
            file = HistoryFile(start: Date(), data: [:])
            historyDirty = true
        }
        var result: [PPHistoryType: [PPHistoryRow]] = [:]
        for type in PPHistoryType.allCases {
            var rows = file.data[type.rawValue] ?? []
            if rows.count > 2000 {   // O-H03
                rows = Array(rows.sorted { $0.download > $1.download }.prefix(1500))
                historyDirty = true
            }
            result[type] = rows
        }
        WgScrollActivity.whenIdle("pp.history") { [weak self] in self?.history = result }
        historyStart = file.start
    }

    private func historyKey(_ conn: MihomoConnection, _ type: PPHistoryType) -> String {
        switch type {
        case .sourceIP:
            return conn.metadata.sourceIP.isEmpty ? "-" : conn.metadata.sourceIP
        case .destination:
            let host = [conn.metadata.host, conn.metadata.sniffHost, conn.metadata.destinationIP].first { !$0.isEmpty } ?? "-"
            if IPMatcher.parseIP(host) != nil { return host }
            return host.split(separator: ".").suffix(2).joined(separator: ".")
        case .process:
            if !conn.metadata.process.isEmpty { return conn.metadata.process }
            if !conn.metadata.processPath.isEmpty { return URL(fileURLWithPath: conn.metadata.processPath).lastPathComponent }
            return "-"
        case .outbound:
            return conn.chains.first ?? "-"
        }
    }

    private func recordClosed(_ closed: [MihomoConnection]) {
        loadHistoryIfNeeded()
        var result = history
        for type in PPHistoryType.allCases {
            var index = Dictionary((result[type] ?? []).enumerated().map { ($1.key, $0) }, uniquingKeysWith: { a, _ in a })
            var rows = result[type] ?? []
            for conn in closed {
                let key = historyKey(conn, type)
                if let i = index[key] {
                    rows[i].download += conn.download
                    rows[i].upload += conn.upload
                    rows[i].count += 1
                } else {
                    index[key] = rows.count
                    rows.append(PPHistoryRow(key: key, download: conn.download, upload: conn.upload, count: 1))
                }
            }
            result[type] = rows
        }
        WgScrollActivity.whenIdle("pp.history") { [weak self] in self?.history = result }
        historyDirty = true
        scheduleFlush()
    }

    private var flushTask: Task<Void, Never>?

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            self?.flushHistory()
            self?.flushTask = nil
        }
    }

    func flushHistory() {
        guard historyDirty, let url = historyURL else { return }
        historyDirty = false
        let file = HistoryFile(start: historyStart ?? Date(),
                               data: Dictionary(history.map { ($0.key.rawValue, $0.value) }, uniquingKeysWith: { a, _ in a }))
        if let data = try? JSONEncoder().encode(file) { try? data.write(to: url, options: .atomic) }
    }

    func clearHistory() {
        history = Dictionary(PPHistoryType.allCases.map { ($0, []) }, uniquingKeysWith: { a, _ in a })
        historyStart = Date()
        historyDirty = true
        flushHistory()
        ProxyPanelStore.shared.post(PPNotice(id: "history", title: String(localized: "连接历史数据清空成功", bundle: .wgLocalized), detail: "", kind: .success), autoDismiss: 3)
    }

    // MARK: 网络信息（O-N01…O-N04）

    func checkIP() async {
        ipChecking = true
        defer { ipChecking = false }
        chinaIP = PPIPResult(location: String(localized: "获取中...", bundle: .wgLocalized), ip: "")
        globalIP = PPIPResult(location: String(localized: "获取中...", bundle: .wgLocalized), ip: "")
        async let china = Self.fetchChinaIP()
        async let global = Self.fetchGlobalIP(api: ipInfoAPI)
        chinaIP = await china ?? PPIPResult(location: String(localized: "测速超时", bundle: .wgLocalized), ip: "")
        globalIP = await global ?? PPIPResult(location: String(localized: "测速超时", bundle: .wgLocalized), ip: "")
    }

    private static func json(_ url: String) async -> [String: Any]? {
        guard let u = URL(string: url + (url.contains("?") ? "&" : "?") + "t=\(Int(Date().timeIntervalSince1970))") else { return nil }
        var req = URLRequest(url: u, timeoutInterval: 8)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func fetchChinaIP() async -> PPIPResult? {
        guard let obj = await json("https://myip.ipip.net/json"),
              let data = obj["data"] as? [String: Any], let ip = data["ip"] as? String else { return nil }
        let location = (data["location"] as? [String] ?? []).filter { !$0.isEmpty }.joined(separator: " ")
        return PPIPResult(location: location, ip: ip)
    }

    private static func fetchGlobalIP(api: PPIPInfoAPI) async -> PPIPResult? {
        switch api {
        case .ipsb:
            guard let o = await json("https://api.ip.sb/geoip"), let ip = o["ip"] as? String else { return nil }
            return PPIPResult(location: "\(o["country"] as? String ?? "") \(o["organization"] as? String ?? "")", ip: ip)
        case .ipwhois:
            guard let o = await json("https://ipwho.is"), let ip = o["ip"] as? String else { return nil }
            let conn = o["connection"] as? [String: Any]
            return PPIPResult(location: "\(o["country"] as? String ?? "") \(conn?["org"] as? String ?? "")", ip: ip)
        case .ipapi:
            guard let o = await json("https://api.ipapi.is"), let ip = o["ip"] as? String else { return nil }
            let loc = o["location"] as? [String: Any]
            let asn = o["asn"] as? [String: Any]
            return PPIPResult(location: "\(loc?["country"] as? String ?? "") \(asn?["org"] as? String ?? "")", ip: ip)
        }
    }

    func checkLatency() async {
        latencyChecking = true
        defer { latencyChecking = false }
        await withTaskGroup(of: (String, Int).self) { group in
            for target in Self.latencyTargets {
                group.addTask {
                    guard let url = URL(string: target.url + "?_=\(Int(Date().timeIntervalSince1970 * 1000))") else { return (target.name, 0) }
                    var req = URLRequest(url: url, timeoutInterval: 8)
                    req.cachePolicy = .reloadIgnoringLocalCacheData
                    let start = Date()
                    guard let (_, resp) = try? await URLSession.shared.data(for: req),
                          let http = resp as? HTTPURLResponse, http.statusCode < 400 else { return (target.name, 0) }
                    return (target.name, Int(Date().timeIntervalSince(start) * 1000))
                }
            }
            for await (name, ms) in group { latencies[name] = ms }
        }
    }

    // MARK: 提供商流量（O-P01）

    struct ProviderTraffic: Identifiable {
        var name: String
        var used: Int64
        var total: Int64
        var id: String { name }
        var remaining: Int64 { max(0, total - used) }
        var fraction: Double { total > 0 ? min(1, Double(used) / Double(total)) : 0 }
    }

    func providerTraffic(_ providers: [MihomoProxyProvider]) -> [ProviderTraffic] {
        providers.compactMap { p in
            guard let info = p.subscriptionInfo, info.total > 0 else { return nil }
            return ProviderTraffic(name: p.name, used: info.download + info.upload, total: info.total)
        }
    }
}


@MainActor
final class PPOverviewStats: ObservableObject {
    static let shared = PPOverviewStats()
    @Published var stats = PPOverviewStore.Stats()
}
