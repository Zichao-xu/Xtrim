import Foundation
import Combine
import SwiftUI

// 代理面板的数据与逻辑层。一比一对应 AnGe-ClashBoard：
//   store/proxies.ts（拉取、测速、选择、链路）· composables/proxies.ts（组划分、隐藏、GLOBAL）
//   composables/renderProxies.ts（排序过滤）· store/smart.ts（Smart 权重）
// 编号对照 docs/proxy-panel-parity.md。

enum PPTab: String, CaseIterable, Identifiable {
    case policy, domain, node, provider
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .policy: return "策略"
        case .domain: return "域名"
        case .node: return "节点"
        case .provider: return "订阅"
        }
    }
}

enum PPSortType: String, CaseIterable, Identifiable {
    case defaultsort, nameasc, namedesc, latencyasc, latencydesc
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .defaultsort: return "按配置排序"
        case .nameasc: return "按名称升序"
        case .namedesc: return "按名称降序"
        case .latencyasc: return "按延迟升序"
        case .latencydesc: return "按延迟降序"
        }
    }
}

enum PPPreviewType: String, CaseIterable, Identifiable {
    case auto, dots, bar
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .auto: return "自动"
        case .dots: return "点"
        case .bar: return "条"
        }
    }
}

enum PPPenetrationMode: String { case stepwise, full }

/// 进度型通知（原版 showNotification 同 key 原地更新）。
struct PPNotice: Identifiable, Equatable {
    enum Kind { case info, success, warning, error }
    var id: String
    var title: String
    var detail: String
    var kind: Kind
}

@MainActor
final class ProxyPanelStore: ObservableObject {
    static let shared = ProxyPanelStore()

    static let testURLDefault = "https://www.gstatic.com/generate_204"
    static let ipv6TestURL = "https://ipv6.google.com/generate_204"
    static let global = "GLOBAL"

    // MARK: 数据（P-D01…）

    @Published private(set) var proxyMap: [String: MihomoProxy] = [:]
    @Published private(set) var proxyGroupList: [String] = []
    @Published private(set) var providers: [MihomoProxyProvider] = []
    @Published private(set) var config: MihomoRuntimeConfig?
    @Published private(set) var version: MihomoVersionInfo?
    @Published private(set) var lastError: String?
    @Published private(set) var smartWeights: [String: [String: String]] = [:]
    @Published private(set) var smartOrder: [String: [String: Int]] = [:]
    /// 本地补记的测速历史（逐节点测速结果，原版 setHistory）。
    @Published private(set) var localHistory: [String: [MihomoDelayHistory]] = [:]
    @Published var ipv6Map: [String: Bool] = PPPersist.dict("ipv6Map")

    /// 组 → 下载速度（P-G08）放在独立的 PPLiveStats：每秒变化，挂在这里会让整页重算。
    var groupDownloadSpeed: [String: Int64] { PPLiveStats.shared.groupDownloadSpeed }
    private var activeConnections: [MihomoConnection] = []
    private var lastConnectionBytes: [String: Int64] = [:]
    private var lastConnectionTime: Date?

    @Published private(set) var testingKeys: Set<String> = []
    @Published private(set) var notices: [PPNotice] = []

    // MARK: 界面状态

    @Published var tab: PPTab = PPTab(rawValue: UserDefaults.standard.string(forKey: "pp.tab") ?? "") ?? .policy {
        didSet { UserDefaults.standard.set(tab.rawValue, forKey: "pp.tab") }
    }
    @Published var filter = ""
    /// 展开状态：true = 展开。没有记录时按默认（策略组/订阅默认展开——打开页面第一眼就能直接点选节点）。
    @Published var collapseMap: [String: Bool] = ProxyPanelStore.loadCollapseMap() {
        didSet { PPPersist.save(collapseMap, "collapseGroupMap") }
    }

    func isExpanded(_ key: String, default value: Bool = true) -> Bool { collapseMap[key] ?? value }

    /// 旧版默认全部折叠、只存“展开过的”；改为默认展开时清一次旧记录，否则历史里的折叠会一直压着。
    private static func loadCollapseMap() -> [String: Bool] {
        let migrated = "pp.collapseDefaultExpanded"
        if !UserDefaults.standard.bool(forKey: migrated) {
            UserDefaults.standard.set(true, forKey: migrated)
            PPPersist.save([String: Bool](), "collapseGroupMap")
            return [:]
        }
        return PPPersist.dict("collapseGroupMap")
    }
    @Published var hiddenGroupMap: [String: Bool] = PPPersist.dict("hiddenGroupMap") {
        didSet { PPPersist.save(hiddenGroupMap, "hiddenGroupMap") }
    }
    @Published var penetrationModeMap: [String: String] = PPPersist.dict("penetrationModeMap") {
        didSet { PPPersist.save(penetrationModeMap, "penetrationModeMap") }
    }
    // 订阅通配符分类（P-V04）：按提供商记住开关、通配符、分类顺序、分类折叠。
    @Published var categoryEnabledMap: [String: Bool] = PPPersist.dict("categoryEnabledMap") {
        didSet { PPPersist.save(categoryEnabledMap, "categoryEnabledMap") }
    }
    @Published var categoryWildcardMap: [String: String] = PPPersist.dict("categoryWildcardMap") {
        didSet { PPPersist.save(categoryWildcardMap, "categoryWildcardMap") }
    }
    @Published var categoryOrderMap: [String: [String]] = PPPersist.dict("categoryOrderMap") {
        didSet { PPPersist.save(categoryOrderMap, "categoryOrderMap") }
    }
    @Published var categoryCollapseMap: [String: Bool] = PPPersist.dict("categoryCollapseMap") {
        didSet { PPPersist.save(categoryCollapseMap, "categoryCollapseMap") }
    }

    // MARK: 设置（默认值与原版一致）

    @Published var sortTypeRaw = PPPersist.value("pp.sortType", PPSortType.defaultsort.rawValue) { didSet { UserDefaults.standard.set(sortTypeRaw, forKey: "pp.sortType") } }
    @Published var useSmartGroupSort = PPPersist.value("pp.useSmartGroupSort", false) { didSet { UserDefaults.standard.set(useSmartGroupSort, forKey: "pp.useSmartGroupSort") } }
    @Published var groupProxiesByProvider = PPPersist.value("pp.groupProxiesByProvider", false) { didSet { UserDefaults.standard.set(groupProxiesByProvider, forKey: "pp.groupProxiesByProvider") } }
    @Published var hideUnavailableProxies = PPPersist.value("pp.hideUnavailableProxies", false) { didSet { UserDefaults.standard.set(hideUnavailableProxies, forKey: "pp.hideUnavailableProxies") } }
    @Published var manageHiddenGroup = PPPersist.value("pp.manageHiddenGroup", false) { didSet { UserDefaults.standard.set(manageHiddenGroup, forKey: "pp.manageHiddenGroup") } }
    @Published var automaticDisconnection = PPPersist.value("pp.automaticDisconnection", true) { didSet { UserDefaults.standard.set(automaticDisconnection, forKey: "pp.automaticDisconnection") } }
    @Published var displayFinalOutbound = PPPersist.value("pp.displayFinalOutbound", false) { didSet { UserDefaults.standard.set(displayFinalOutbound, forKey: "pp.displayFinalOutbound") } }
    @Published var minProxyCardWidth = PPPersist.value("pp.minProxyCardWidth", 180.0) { didSet { UserDefaults.standard.set(minProxyCardWidth, forKey: "pp.minProxyCardWidth") } }
    @Published var speedtestUrl = PPPersist.value("pp.speedtestUrl", ProxyPanelStore.testURLDefault) { didSet { UserDefaults.standard.set(speedtestUrl, forKey: "pp.speedtestUrl") } }
    @Published var speedtestTimeout = PPPersist.value("pp.speedtestTimeout", 5000) { didSet { UserDefaults.standard.set(speedtestTimeout, forKey: "pp.speedtestTimeout") } }
    @Published var independentLatencyTest = PPPersist.value("pp.independentLatencyTest", false) { didSet { UserDefaults.standard.set(independentLatencyTest, forKey: "pp.independentLatencyTest") } }
    @Published var ipv6Test = PPPersist.value("pp.ipv6Test", false) { didSet { UserDefaults.standard.set(ipv6Test, forKey: "pp.ipv6Test") } }
    @Published var lowLatency = PPPersist.value("pp.lowLatency", 400) { didSet { UserDefaults.standard.set(lowLatency, forKey: "pp.lowLatency") } }
    @Published var mediumLatency = PPPersist.value("pp.mediumLatency", 800) { didSet { UserDefaults.standard.set(mediumLatency, forKey: "pp.mediumLatency") } }
    @Published var previewTypeRaw = PPPersist.value("pp.previewType", PPPreviewType.auto.rawValue) { didSet { UserDefaults.standard.set(previewTypeRaw, forKey: "pp.previewType") } }
    @Published var smallCard = PPPersist.value("pp.smallCard", false) { didSet { UserDefaults.standard.set(smallCard, forKey: "pp.smallCard") } }
    @Published var truncateProxyName = PPPersist.value("pp.truncateProxyName", true) { didSet { UserDefaults.standard.set(truncateProxyName, forKey: "pp.truncateProxyName") } }
    @Published var useLargeProxyGroupIcon = PPPersist.value("pp.largeGroupIcon", false) { didSet { UserDefaults.standard.set(useLargeProxyGroupIcon, forKey: "pp.largeGroupIcon") } }
    @Published var proxyGroupIconSize = PPPersist.value("pp.groupIconSize", 24.0) { didSet { UserDefaults.standard.set(proxyGroupIconSize, forKey: "pp.groupIconSize") } }
    @Published var proxyGroupIconMargin = PPPersist.value("pp.groupIconMargin", 6.0) { didSet { UserDefaults.standard.set(proxyGroupIconMargin, forKey: "pp.groupIconMargin") } }
    @Published var displayGlobalByMode = PPPersist.value("pp.displayGlobalByMode", false) { didSet { UserDefaults.standard.set(displayGlobalByMode, forKey: "pp.displayGlobalByMode") } }
    @Published var groupTestUrlsRaw = PPPersist.value("pp.groupTestUrls", "{}") { didSet { UserDefaults.standard.set(groupTestUrlsRaw, forKey: "pp.groupTestUrls") } }
    @Published var categoryFeatureEnabled = PPPersist.value("pp.categoryFeatureEnabled", true) { didSet { UserDefaults.standard.set(categoryFeatureEnabled, forKey: "pp.categoryFeatureEnabled") } }

    var sortType: PPSortType {
        get { PPSortType(rawValue: sortTypeRaw) ?? .defaultsort }
        set { sortTypeRaw = newValue.rawValue }
    }
    var previewType: PPPreviewType {
        get { PPPreviewType(rawValue: previewTypeRaw) ?? .auto }
        set { previewTypeRaw = newValue.rawValue }
    }
    var groupTestUrls: [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(groupTestUrlsRaw.utf8))) ?? [:]
    }

    private var fetchGeneration = 0
    private var connectionTask: Task<Void, Never>?
    private var autoRefreshTask: Task<Void, Never>?

    private init() {}

    // MARK: 后端

    private var api: MihomoAPI? {
        let store = MihomoBackendStore.shared
        guard let backend = store.active else { return nil }
        return MihomoAPI(backend: backend, secret: store.secret(for: backend))
    }

    /// 正在显示、需要实时数据的页面数（概览、代理两页都用连接推送，切页时出现/消失回调的先后不定）。
    private var liveUsers = 0
    private var visibilityObserver: AnyCancellable?

    /// 代理页出现时调用：拉数据 + 开连接推送。与 deactivate 成对调用。
    func activate() {
        liveUsers += 1
        Task { await fetchAll() }
        observeWindowVisibility()
        if WgWindowVisibility.shared.isMainWindowVisible { startConnectionStream() }
    }

    /// 代理页离开时调用：最后一个页面离开才停掉推送与自动刷新，不在后台消耗。
    func deactivate() {
        liveUsers = max(0, liveUsers - 1)
        if liveUsers == 0 { stopLive() }
    }

    private func stopLive() {
        connectionTask?.cancel()
        connectionTask = nil
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
    }

    /// 页面仍在但主窗口被遮挡/最小化/关闭时同样停流，回到前台再接上。
    private func observeWindowVisibility() {
        guard visibilityObserver == nil else { return }
        visibilityObserver = WgWindowVisibility.shared.$isMainWindowVisible
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] visible in
                guard let self, self.liveUsers > 0 else { return }
                if visible {
                    self.startConnectionStream()
                    Task { await self.fetchProxies() }
                } else {
                    self.stopLive()
                }
            }
    }

    func backendChanged() {
        PPOverviewStore.shared.backendChanged()
        proxyMap = [:]
        proxyGroupList = []
        providers = []
        config = nil
        smartWeights = [:]
        smartOrder = [:]
        stopLive()
        Task { await fetchAll() }
        if liveUsers > 0 && WgWindowVisibility.shared.isMainWindowVisible { startConnectionStream() }
    }

    func fetchAll() async {
        guard let api else { lastError = String(localized: "未配置后端", bundle: .wgLocalized); return }
        async let cfg = try? api.config()
        async let ver = try? api.version()
        await fetchProxies()
        if let c = await cfg, config != c { config = c }
        if let v = await ver, version != v { version = v }
    }

    // MARK: 拉取（P-D01…P-D05）

    func fetchProxies() async {
        guard let api else { return }
        fetchGeneration += 1
        let generation = fetchGeneration
        do {
            async let proxiesReq = api.proxies()
            async let providersReq = api.providers()
            let (proxyData, providerData) = try await (proxiesReq, providersReq)
            // P-D03：后发的请求已返回时，丢弃这次旧结果。
            guard generation == fetchGeneration else { return }

            let sortIndex: [String] = proxyData.proxies[Self.global]?.all ?? []
            let validProviders: [MihomoProxyProvider] = providerData.providers.values
                .filter { $0.name != "default" && $0.vehicleType != "Compatible" }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

            var merged: [String: MihomoProxy] = [:]
            for provider in validProviders {
                for var proxy in provider.proxies {
                    if proxy.providerName == nil { proxy.providerName = provider.name }
                    merged[proxy.name] = proxy
                }
            }
            for (name, proxy) in proxyData.proxies {
                if var base = merged[name] {
                    // 控制器数据覆盖提供商数据，但保留提供商名。
                    let providerName = base.providerName
                    base = proxy
                    if base.providerName == nil { base.providerName = providerName }
                    merged[name] = base
                } else {
                    merged[name] = proxy
                }
            }

            let groups: [String] = proxyData.proxies.values
                .filter { $0.isGroup && $0.name != Self.global }
                .map(\.name)
                .sorted { a, b in
                    let ia = sortIndex.firstIndex(of: a) ?? Int.max
                    let ib = sortIndex.firstIndex(of: b) ?? Int.max
                    return ia < ib
                }

            if ipv6Test {
                var map = ipv6Map
                for (name, proxy) in merged where proxy.extra[Self.ipv6TestURL]?.last.map({ $0.delay > mihomoNotConnected }) == true {
                    map[name] = true
                }
                if map != ipv6Map { ipv6Map = map; PPPersist.save(map, "ipv6Map") }
            }

            // 合并远端历史后，本地补记的历史里已被远端覆盖的部分丢弃。
            localHistory = localHistory.filter { name, _ in merged[name]?.history.isEmpty ?? true }

            if proxyMap != merged { proxyMap = merged; proxyMapVersion += 1 }
            if proxyGroupList != groups { proxyGroupList = groups }
            if providers != validProviders { providers = validProviders }
            if lastError != nil { lastError = nil }

            if merged.values.contains(where: { $0.type.lowercased() == "smart" }) {
                await fetchSmartWeights()
            }
            scheduleAutoRefresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func fetchSmartWeights() async {
        guard let api, let response = try? await api.smartWeights() else { return }
        var weights: [String: [String: String]] = [:]
        var order: [String: [String: Int]] = [:]
        for (group, ranks) in response.weights {
            guard let ranks, !ranks.isEmpty else { continue }
            weights[group] = Dictionary(ranks.map { ($0.name, $0.rank) }, uniquingKeysWith: { a, _ in a })
            order[group] = Dictionary(ranks.enumerated().map { ($1.name, $0) }, uniquingKeysWith: { a, _ in a })
        }
        if smartWeights != weights { smartWeights = weights }
        if smartOrder != order { smartOrder = order }
    }

    // MARK: 组划分（P-D06…P-D09）

    func isGroup(_ name: String) -> Bool { proxyMap[name]?.isGroup ?? false }

    /// 原版 helper/isProxyGroup：除真正的组外，DIRECT/REJECT/PASS/DNS/Compatible 等内置出口也算“组”。
    /// 组划分（P-D06）和“子组排在节点前”（P-S01）都依赖这个口径。
    private static let groupLikeTypes: Set<String> = [
        "dns", "compatible", "direct", "reject", "rejectdrop", "pass",
        "fallback", "urltest", "loadbalance", "selector", "smart",
    ]

    func isProxyGroupLike(_ name: String) -> Bool {
        guard let proxy = proxyMap[name] else { return false }
        return proxy.isGroup || Self.groupLikeTypes.contains(proxy.type.lowercased())
    }

    func isHidden(_ name: String) -> Bool {
        hiddenGroupMap[name] ?? proxyMap[name]?.hidden ?? false
    }

    private func filterHidden(_ names: [String]) -> [String] {
        manageHiddenGroup ? names : names.filter { !isHidden($0) }
    }

    var currentGroups: [String] { classified().current }

    /// P-D08：根据模式显示 GLOBAL。
    private func computeCurrentGroups() -> [String] {
        if displayGlobalByMode {
            if config?.mode.uppercased() == Self.global { return [Self.global] }
            return filterHidden(proxyGroupList)
        }
        return filterHidden(proxyGroupList + (proxyMap[Self.global] != nil ? [Self.global] : []))
    }

    private struct ClassificationKey: Equatable {
        var proxies: Int, groups: [String], mode: String?, hidden: [String: Bool], manage: Bool, byMode: Bool
    }
    private var classificationKey: ClassificationKey?
    private var classificationCache: (nodes: Set<String>, current: [String], policy: [String], node: [String], blocks: [[String]]) = ([], [], [], [], [])
    private var proxyMapVersion = 0

    /// 组划分只在代理数据、模式、隐藏组相关设置变化时重算（原先每次渲染都递归一遍）。
    private func classified() -> (nodes: Set<String>, current: [String], policy: [String], node: [String], blocks: [[String]]) {
        let key = ClassificationKey(proxies: proxyMapVersion, groups: proxyGroupList, mode: config?.mode,
                                    hidden: hiddenGroupMap, manage: manageHiddenGroup, byMode: displayGlobalByMode)
        if key == classificationKey { return classificationCache }
        let current = computeCurrentGroups()
        let nodes = computeNodeGroupNames(current)
        let policy = current.filter { !nodes.contains($0) }
        let node = current.filter { nodes.contains($0) }
        classificationCache = (nodes, current, policy, node, computeNodeGroupBlocks(node))
        classificationKey = key
        return classificationCache
    }

    var nodeGroupNames: Set<String> { classified().nodes }
    var policyGroups: [String] { classified().policy }
    var nodeGroups: [String] { classified().node }
    var nodeGroupBlocks: [[String]] { classified().blocks }

    /// P-D06：成员全是节点（或全是节点组）的组 = 节点组。递归判定，防环。
    private func computeNodeGroupNames(_ currentGroups: [String]) -> Set<String> {
        var resolved: [String: Bool] = [:]
        var visiting: Set<String> = []
        func isNodeGroup(_ name: String) -> Bool {
            if let cached = resolved[name] { return cached }
            guard let proxy = proxyMap[name], let all = proxy.all, !all.isEmpty, !visiting.contains(name) else {
                resolved[name] = false
                return false
            }
            visiting.insert(name)
            let result = all.allSatisfy { member in
                guard proxyMap[member] != nil else { return false }
                return isProxyGroupLike(member) ? isNodeGroup(member) : true
            }
            visiting.remove(name)
            resolved[name] = result
            return result
        }
        return Set(currentGroups.filter { isNodeGroup($0) })
    }

    /// P-D07：节点组按引用关系打包。
    private func computeNodeGroupBlocks(_ groups: [String]) -> [[String]] {
        let groupSet = Set(groups)
        func children(_ name: String) -> [String] { (proxyMap[name]?.all ?? []).filter { groupSet.contains($0) } }
        var referenced: Set<String> = []
        groups.forEach { children($0).forEach { referenced.insert($0) } }
        var assigned: Set<String> = []
        var blocks: [[String]] = []
        func appendBlock(_ root: String) {
            guard !assigned.contains(root), groupSet.contains(root) else { return }
            var block: [String] = []
            var visited: Set<String> = []
            func walk(_ name: String) {
                guard !visited.contains(name), !assigned.contains(name), groupSet.contains(name) else { return }
                visited.insert(name)
                assigned.insert(name)
                block.append(name)
                children(name).forEach(walk)
            }
            walk(root)
            if !block.isEmpty { blocks.append(block) }
        }
        groups.filter { !referenced.contains($0) }.forEach(appendBlock)
        groups.forEach(appendBlock)
        return blocks
    }

    func count(for tab: PPTab) -> Int {
        switch tab {
        case .policy: return policyGroups.count
        case .domain: return 0
        case .node: return nodeGroups.count
        case .provider: return providers.count
        }
    }

    // MARK: 延迟（P-D10）

    func testURL(for group: String?) -> String {
        let fallback = speedtestUrl.isEmpty ? Self.testURLDefault : speedtestUrl
        guard let group, independentLatencyTest else { return fallback }
        if let url = groupTestUrls[group], !url.isEmpty { return url }
        return proxyMap[group]?.testUrl ?? providers.first { $0.name == group }?.testUrl ?? fallback
    }

    func history(_ name: String, group: String? = nil) -> [MihomoDelayHistory] {
        guard let proxy = proxyMap[name] else { return localHistory[name] ?? [] }
        if independentLatencyTest, let group {
            let url = testURL(for: group)
            if let extra = proxy.extra[url], !extra.isEmpty { return extra }
        }
        if proxy.history.isEmpty { return localHistory[name] ?? [] }
        return proxy.history
    }

    func latency(_ name: String, group: String? = nil) -> Int {
        // 组的延迟取其当前选中节点（原版 LatencyTag 传 group.now）。
        history(name, group: group).last?.delay ?? mihomoNotConnected
    }

    enum LatencyLevel { case none, low, medium, high }

    func level(_ latency: Int) -> LatencyLevel {
        if latency == mihomoNotConnected { return .none }
        if latency < lowLatency { return .low }
        if latency < mediumLatency { return .medium }
        return .high
    }

    // MARK: 排序过滤（P-S01…P-S04）

    func renderProxies(of group: String) -> [String] {
        var names = proxyMap[group]?.all ?? []
        if hideUnavailableProxies {
            names = names.filter { isProxyGroupLike($0) || latency($0, group: group) > mihomoNotConnected }
        }
        let keywords = filter.lowercased().split(separator: " ").map { String($0) }.filter { !$0.isEmpty }
        if !keywords.isEmpty {
            names = names.filter { name in
                let lower = name.lowercased()
                return keywords.allSatisfy { lower.contains($0) }
            }
        }
        if useSmartGroupSort, let order = smartOrder[group] {
            return names.sorted { (order[$0] ?? .max) < (order[$1] ?? .max) }
        }
        if sortType == .defaultsort { return names }
        let groups = names.filter { isProxyGroupLike($0) }
        var nodes = names.filter { !isProxyGroupLike($0) }
        func sortLatency(_ n: String) -> Int {
            let l = latency(n, group: group)
            return l == 0 ? .max : l
        }
        switch sortType {
        case .nameasc: nodes.sort { $0.localizedCompare($1) == .orderedAscending }
        case .namedesc: nodes.sort { $0.localizedCompare($1) == .orderedDescending }
        case .latencyasc: nodes.sort { sortLatency($0) < sortLatency($1) }
        case .latencydesc: nodes.sort { sortLatency($0) > sortLatency($1) }
        case .defaultsort: break
        }
        return groups + nodes
    }

    func availabilityText(of group: String) -> String {
        let all = proxyMap[group]?.all ?? []
        let alive = all.filter { latency($0, group: group) != mihomoNotConnected }.count
        return "\(alive)/\(all.count)"
    }

    // MARK: 链路（P-G03 · 策略穿透）

    /// 递归取组当前最终节点。
    func nowNodeName(_ name: String) -> String {
        var visited: Set<String> = []
        var current = name
        while let now = proxyMap[current]?.now, !visited.contains(current), isGroup(current) {
            visited.insert(current)
            current = now
        }
        return current
    }

    /// 组 → 子组 → 最终节点（不含组自身）。
    func routeChain(_ name: String) -> [String] {
        var chain: [String] = []
        var visited: Set<String> = [name]
        var current = name
        while let now = proxyMap[current]?.now, !visited.contains(now) {
            chain.append(now)
            visited.insert(now)
            guard isGroup(now) else { break }
            current = now
        }
        return chain
    }

    /// 从组本身开始、沿当前选择向下的组链（原版 getProxyGroupChains）。
    func groupChain(_ name: String) -> [String] {
        [name] + routeChain(name).filter { isGroup($0) }
    }

    func descendantGroups(_ name: String) -> [String] {
        var result: [String] = []
        var visited: Set<String> = [name]
        var queue = (proxyMap[name]?.all ?? []).filter { isGroup($0) }
        while !queue.isEmpty {
            let next = queue.removeFirst()
            guard !visited.contains(next) else { continue }
            visited.insert(next)
            result.append(next)
            queue.append(contentsOf: (proxyMap[next]?.all ?? []).filter { isGroup($0) })
        }
        return result
    }

    func descendantNames(_ name: String) -> [String] {
        var result: Set<String> = []
        var visited: Set<String> = [name]
        var queue = proxyMap[name]?.all ?? []
        while !queue.isEmpty {
            let next = queue.removeFirst()
            guard !visited.contains(next) else { continue }
            visited.insert(next)
            result.insert(next)
            queue.append(contentsOf: proxyMap[next]?.all ?? [])
        }
        return Array(result)
    }

    func isFixed(_ group: String) -> Bool {
        guard let proxy = proxyMap[group], let fixed = proxy.fixed else { return false }
        return fixed == proxy.now
    }

    // MARK: 选择（P-N05 · P-N06）

    func select(group: String, node: String) async {
        guard let api, let proxyGroup = proxyMap[group] else { return }
        if proxyGroup.type.lowercased() == "loadbalance" { return }
        if proxyGroup.now == node {
            await fetchProxies()
            if proxyMap[group]?.now == node { return }
        }
        do {
            try await api.select(group: group, name: node)
            proxyMap[group]?.now = node
            proxyMapVersion += 1
            if automaticDisconnection {
                let targets = activeConnections.filter { $0.chains.contains(group) }
                for conn in targets { try? await api.closeConnection(conn.id) }
            }
            await fetchProxies()
        } catch {
            post(PPNotice(id: "select", title: String(localized: "切换失败", bundle: .wgLocalized), detail: error.localizedDescription, kind: .error))
        }
    }

    func setMode(_ mode: String) async {
        guard let api else { return }
        do {
            try await api.patchConfig(["mode": mode])
            config?.mode = mode
            await fetchProxies()
        } catch {
            post(PPNotice(id: "mode", title: String(localized: "切换模式失败", bundle: .wgLocalized), detail: error.localizedDescription, kind: .error))
        }
    }

    // MARK: 测速（P-G16 · P-C04 · P-T01…）

    private func latencyForSingle(_ api: MihomoAPI, _ name: String, url: String, timeout: Int) async -> (delay: Int, ok: Bool) {
        let now = nowNodeName(name)
        if ipv6Test {
            let v6 = await nodeDelay(api, now, url: Self.ipv6TestURL, timeout: 2000)
            ipv6Map[now] = v6.delay > mihomoNotConnected
            PPPersist.save(ipv6Map, "ipv6Map")
        }
        return await nodeDelay(api, independentLatencyTest ? name : now, url: url, timeout: timeout)
    }

    private func nodeDelay(_ api: MihomoAPI, _ name: String, url: String, timeout: Int) async -> (delay: Int, ok: Bool) {
        if let provider = proxyMap[name]?.providerName, providers.contains(where: { $0.name == provider }) {
            return await api.providerDelay(provider: provider, proxy: name, url: url, timeout: timeout)
        }
        return await api.delay(proxy: name, url: url, timeout: timeout)
    }

    private func noticeName(_ name: String, url: String) -> String {
        independentLatencyTest ? "\(name)\n@\(url)" : name
    }

    /// 单节点测速（P-N03）。
    func testNode(_ name: String, group: String?) async {
        guard let api else { return }
        let key = "node:\(group ?? "")/\(name)"
        guard !testingKeys.contains(key) else { return }
        testingKeys.insert(key)
        defer { testingKeys.remove(key) }
        let url = testURL(for: group)
        let result = await latencyForSingle(api, name, url: url, timeout: speedtestTimeout)
        await fetchProxies()
        if !result.ok {
            post(PPNotice(id: "single:\(name)", title: noticeName(name, url: url), detail: String(localized: "测速超时", bundle: .wgLocalized), kind: .error), autoDismiss: 3)
        }
    }

    /// 逐个测速（5 路并发，超时 ≤1.5s，进度通知原地更新）。
    private func testOneByOne(scope: String, nodes: [String], url: String, displayName: String, keyName: String) async {
        guard let api, !nodes.isEmpty else { return }
        let total = nodes.count
        var done = 0
        var failed = 0
        let timeout = min(1500, speedtestTimeout)
        let noticeID = "test:\(keyName)"
        await withTaskGroup(of: (String, Int, Bool).self) { group in
            var iterator = nodes.makeIterator()
            func addNext() {
                guard let name = iterator.next() else { return }
                group.addTask { [self] in
                    let r = await self.latencyForSingle(api, name, url: url, timeout: timeout)
                    return (name, r.delay, r.ok)
                }
            }
            for _ in 0..<5 { addNext() }
            for await (name, delay, ok) in group {
                if !ok { failed += 1 }
                appendLocalHistory(name, delay: ok ? delay : mihomoNotConnected)
                done += 1
                post(PPNotice(id: noticeID, title: noticeName(displayName, url: url), detail: String(localized: "\(done)/\(total) 测试完成", bundle: .wgLocalized), kind: .info))
                addNext()
            }
        }
        post(PPNotice(id: noticeID, title: noticeName(displayName, url: url),
                      detail: String(localized: "测试完成：\(total - failed) 成功，\(failed) 超时", bundle: .wgLocalized),
                      kind: failed > 0 ? .warning : .success), autoDismiss: 3)
        await fetchProxies()
    }

    private func appendLocalHistory(_ name: String, delay: Int) {
        let entry = MihomoDelayHistory(time: ISO8601DateFormatter().string(from: Date()), delay: delay)
        if proxyMap[name] != nil, !(proxyMap[name]?.history.isEmpty ?? true) {
            proxyMap[name]?.history.append(entry)
        } else {
            localHistory[name, default: []].append(entry)
        }
    }

    /// 组测速（P-G16）。
    func testGroup(_ group: String) async {
        guard let api, let proxy = proxyMap[group] else { return }
        let key = "group:\(group)"
        guard !testingKeys.contains(key) else { return }
        testingKeys.insert(key)
        defer { testingKeys.remove(key) }
        let all = proxy.all ?? []
        let url = testURL(for: group)
        let type = proxy.type.lowercased()
        if ["selector", "loadbalance", "smart"].contains(type) {
            if proxy.fixed != nil { try? await api.deleteFixed(group: group) }
            await testOneByOne(scope: group, nodes: all, url: url, displayName: group, keyName: group)
            return
        }
        let timeout = max(5000, speedtestTimeout)
        if ipv6Test {
            let result = (try? await api.groupDelay(group: group, url: Self.ipv6TestURL, timeout: timeout)) ?? [:]
            for name in all { ipv6Map[nowNodeName(name)] = (result[name] ?? 0) > mihomoNotConnected }
            PPPersist.save(ipv6Map, "ipv6Map")
        }
        _ = try? await api.groupDelay(group: group, url: url, timeout: timeout)
        await fetchProxies()
        let failed = all.filter { latency($0, group: group) == mihomoNotConnected }.count
        post(PPNotice(id: "test:\(group)", title: noticeName(group, url: url),
                      detail: String(localized: "测试完成：\(all.count - failed) 成功，\(failed) 超时", bundle: .wgLocalized),
                      kind: failed > 0 ? .warning : .success), autoDismiss: 3)
    }

    /// 分类/子集测速（订阅分类用）。
    func testNodes(scope: String, nodes: [String], displayName: String, keyName: String) async {
        let key = "nodes:\(keyName)"
        guard !testingKeys.contains(key) else { return }
        testingKeys.insert(key)
        defer { testingKeys.remove(key) }
        await testOneByOne(scope: scope, nodes: nodes, url: testURL(for: scope), displayName: displayName, keyName: keyName)
    }

    /// 全部测速（P-C04）。
    func testAll() async {
        let key = "all"
        guard !testingKeys.contains(key) else { return }
        testingKeys.insert(key)
        defer { testingKeys.remove(key) }
        if independentLatencyTest {
            await withTaskGroup(of: Void.self) { group in
                var iterator = proxyGroupList.makeIterator()
                func addNext() {
                    guard let name = iterator.next() else { return }
                    group.addTask { [self] in await self.testGroup(name) }
                }
                for _ in 0..<3 { addNext() }
                for await _ in group { addNext() }
            }
            return
        }
        let nodes = proxyMap.keys.filter { !isProxyGroupLike($0) }.sorted()
        await testOneByOne(scope: "all", nodes: nodes, url: testURL(for: nil), displayName: String(localized: "全部", bundle: .wgLocalized), keyName: "all")
    }

    func isTesting(_ key: String) -> Bool { testingKeys.contains(key) }

    // MARK: 订阅（P-V03）

    func updateProvider(_ name: String) async {
        guard let api else { return }
        testingKeys.insert("update:\(name)")
        defer { testingKeys.remove("update:\(name)") }
        do {
            try await api.updateProvider(name)
            post(PPNotice(id: "update:\(name)", title: name, detail: String(localized: "更新完成", bundle: .wgLocalized), kind: .success), autoDismiss: 3)
        } catch {
            post(PPNotice(id: "update:\(name)", title: name, detail: error.localizedDescription, kind: .error), autoDismiss: 4)
        }
        await fetchProxies()
    }

    func updateAllProviders() async {
        testingKeys.insert("updateAll")
        defer { testingKeys.remove("updateAll") }
        var done = 0
        for provider in providers where provider.vehicleType != "Inline" {
            await updateProvider(provider.name)
            done += 1
            post(PPNotice(id: "updateAll", title: String(localized: "订阅", bundle: .wgLocalized), detail: String(localized: "\(done) 更新完成", bundle: .wgLocalized), kind: .info))
        }
        post(PPNotice(id: "updateAll", title: String(localized: "订阅", bundle: .wgLocalized), detail: String(localized: "\(done) 更新完成", bundle: .wgLocalized), kind: .success), autoDismiss: 3)
    }

    func healthCheckProvider(_ name: String) async {
        guard let api else { return }
        testingKeys.insert("health:\(name)")
        defer { testingKeys.remove("health:\(name)") }
        try? await api.healthCheckProvider(name)
        await fetchProxies()
    }

    // MARK: 连接推送（P-G08）

    private func startConnectionStream() {
        guard connectionTask == nil, let api else { return }
        connectionTask = Task { [weak self] in
            for await snapshot in api.connectionsStream() {
                guard let self, !Task.isCancelled else { break }
                self.consume(snapshot)
            }
        }
    }

    private func consume(_ snapshot: MihomoConnectionsSnapshot) {
        PPOverviewStore.shared.ingest(snapshot)
        let connections = snapshot.connections ?? []
        let now = Date()
        let elapsed = lastConnectionTime.map { max(now.timeIntervalSince($0), 0.2) } ?? 1
        var speed: [String: Int64] = [:]
        var bytes: [String: Int64] = [:]
        for conn in connections {
            bytes[conn.id] = conn.download
            let delta = max(0, conn.download - (lastConnectionBytes[conn.id] ?? conn.download))
            let rate = Int64(Double(delta) / elapsed)
            guard rate > 0 else { continue }
            for chain in conn.chains { speed[chain, default: 0] += rate }
        }
        activeConnections = connections
        lastConnectionBytes = bytes
        lastConnectionTime = now
        WgScrollActivity.whenIdle("pp.groupSpeed") {
            if PPLiveStats.shared.groupDownloadSpeed != speed { PPLiveStats.shared.groupDownloadSpeed = speed }
        }
    }

    // MARK: 自动刷新（P-D11）

    private func refreshInterval(_ name: String) -> TimeInterval? {
        guard let proxy = proxyMap[name], proxy.history.count >= 2 else { return nil }
        let times = proxy.history.compactMap { PPPersist.parseDate($0.time) }
        guard times.count >= 2 else { return nil }
        let intervals = zip(times.dropFirst(), times).map { $0.timeIntervalSince($1) }.filter { $0 > 0 }
        guard !intervals.isEmpty else { return nil }
        let sorted = intervals.sorted()
        // 下限 60 秒：几次间隔很近的手动测速不能让自动刷新退化成每秒整包拉取（实测曾占用约 10% CPU）。
        let median = max(sorted[sorted.count / 2], 60)
        let autoTypes: Set<String> = ["urltest", "fallback", "loadbalance", "smart"]
        if autoTypes.contains(proxy.type.lowercased()) { return median }
        // 间隔稳定（全部落在中位数 ±20% 内）才认为是核心定时测速。
        let stable = intervals.allSatisfy { abs($0 - median) <= median * 0.2 }
        return stable ? median : nil
    }

    private func scheduleAutoRefresh() {
        autoRefreshTask?.cancel()
        guard connectionTask != nil else { return }
        var candidates: Set<String> = []
        switch tab {
        case .provider:
            providers.forEach { $0.proxies.forEach { candidates.insert($0.name) } }
        case .node:
            nodeGroupBlocks.flatMap { $0 }.forEach { candidates.insert($0); descendantNames($0).forEach { candidates.insert($0) } }
        case .policy, .domain:
            policyGroups.forEach { candidates.insert($0); descendantNames($0).forEach { candidates.insert($0) } }
        }
        var next: (due: Date, interval: TimeInterval)?
        for name in candidates {
            guard let interval = refreshInterval(name),
                  let last = proxyMap[name]?.history.last.flatMap({ PPPersist.parseDate($0.time) }) else { continue }
            let due = last.addingTimeInterval(interval)
            if next == nil || due < next!.due { next = (due, interval) }
        }
        guard let schedule = next else { return }
        var fireAt = schedule.due.addingTimeInterval(30)
        let now = Date()
        if fireAt <= now {
            let behind = floor(now.timeIntervalSince(fireAt) / schedule.interval) + 1
            fireAt = fireAt.addingTimeInterval(behind * schedule.interval)
        }
        let delay = max(1, fireAt.timeIntervalSince(now))
        autoRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.fetchProxies()
        }
    }

    // MARK: 通知

    func post(_ notice: PPNotice, autoDismiss seconds: Double? = nil) {
        if let index = notices.firstIndex(where: { $0.id == notice.id }) {
            notices[index] = notice
        } else {
            notices.append(notice)
        }
        guard let seconds else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            self?.notices.removeAll { $0 == notice }
        }
    }

    func dismiss(_ id: String) { notices.removeAll { $0.id == id } }

    // MARK: 按提供商分组 / 通配符分类（P-G12 · P-V04，对应 helper/proxyCategory.ts）

    struct CategoryGroup: Identifiable, Equatable {
        var id: String { name }
        var name: String
        var proxies: [String]
        var available: Int
        var total: Int
    }

    struct ProviderSection: Identifiable, Equatable {
        var id: String
        var title: String
        var providerName: String
        var categoryName: String?
        var proxies: [String]
    }

    /// 节点所属提供商（优先用控制器给的 provider-name）。
    func providerName(of proxy: String) -> String {
        if let hinted = proxyMap[proxy]?.providerName {
            return providers.contains { $0.name == hinted } ? hinted : ""
        }
        return providers.first { $0.proxies.contains { $0.name == proxy } }?.name ?? ""
    }

    static func categoryName(_ proxy: String, wildcard: String, fallback: String) -> String {
        let w = wildcard.trimmingCharacters(in: .whitespaces)
        guard !w.isEmpty, let range = proxy.range(of: w), range.lowerBound > proxy.startIndex else { return fallback }
        let name = String(proxy[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? fallback : name
    }

    func categoryActive(provider: String) -> Bool {
        guard categoryFeatureEnabled, categoryEnabledMap[provider] == true else { return false }
        let w = (categoryWildcardMap[provider] ?? "").trimmingCharacters(in: .whitespaces)
        guard !w.isEmpty else { return false }
        let all = providers.first { $0.name == provider }?.proxies.map(\.name) ?? []
        return all.contains { name in name.range(of: w).map { $0.lowerBound > name.startIndex } ?? false }
    }

    func categoryGroups(provider: String, proxies: [String]) -> [CategoryGroup] {
        let wildcard = categoryWildcardMap[provider] ?? ""
        let all = providers.first { $0.name == provider }?.proxies.map(\.name) ?? proxies
        var totals: [String: Int] = [:]
        var alive: [String: Int] = [:]
        for name in all {
            let c = Self.categoryName(name, wildcard: wildcard, fallback: String(localized: "其他", bundle: .wgLocalized))
            totals[c, default: 0] += 1
            if latency(name) != mihomoNotConnected { alive[c, default: 0] += 1 }
        }
        var order: [String] = []
        var grouped: [String: [String]] = [:]
        for name in proxies {
            let c = Self.categoryName(name, wildcard: wildcard, fallback: String(localized: "其他", bundle: .wgLocalized))
            if grouped[c] == nil { order.append(c) }
            grouped[c, default: []].append(name)
        }
        var groups = order.map { CategoryGroup(name: $0, proxies: grouped[$0] ?? [], available: alive[$0] ?? 0, total: totals[$0] ?? 0) }
        let saved = categoryOrderMap[categoryOrderKey(provider)] ?? []
        if !saved.isEmpty {
            let index = Dictionary(saved.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            groups.sort { (index[$0.name] ?? .max) < (index[$1.name] ?? .max) }
        }
        return groups
    }

    func categoryOrderKey(_ provider: String) -> String {
        "\(provider)::\((categoryWildcardMap[provider] ?? "").trimmingCharacters(in: .whitespaces))"
    }

    func moveCategory(provider: String, from: String, to: String) {
        var names = categoryGroups(provider: provider, proxies: providers.first { $0.name == provider }?.proxies.map(\.name) ?? []).map(\.name)
        guard let src = names.firstIndex(of: from), let dst = names.firstIndex(of: to), src != dst else { return }
        names.remove(at: src)
        names.insert(from, at: dst)
        categoryOrderMap[categoryOrderKey(provider)] = names
    }

    /// 组卡片“节点根据提供商分组”：无提供商的节点排最前，其余按首次出现顺序；启用分类的提供商再细分。
    func providerSections(of proxies: [String]) -> [ProviderSection] {
        var order: [String] = []
        var grouped: [String: [String]] = [:]
        for name in proxies {
            let p = providerName(of: name)
            if grouped[p] == nil {
                if p.isEmpty { order.insert(p, at: 0) } else { order.append(p) }
            }
            grouped[p, default: []].append(name)
        }
        var sections: [ProviderSection] = []
        for p in order {
            let items = grouped[p] ?? []
            if p.isEmpty {
                sections.append(ProviderSection(id: "provider:root", title: "", providerName: "", proxies: items))
            } else if categoryActive(provider: p) {
                for c in categoryGroups(provider: p, proxies: items) {
                    sections.append(ProviderSection(id: "\(p)::\(c.name)", title: "\(p) - \(c.name)", providerName: p, categoryName: c.name, proxies: c.proxies))
                }
            } else {
                sections.append(ProviderSection(id: "provider:\(p)", title: p, providerName: p, proxies: items))
            }
        }
        return sections
    }
}

/// 小型持久化工具：界面状态字典存 UserDefaults（前缀 pp.）。
/// 每秒变化的统计单独成一个数据源，只让显示它的小视图订阅。
@MainActor
final class PPLiveStats: ObservableObject {
    static let shared = PPLiveStats()
    @Published var groupDownloadSpeed: [String: Int64] = [:]
}

enum PPPersist {
    static func value<T>(_ key: String, _ fallback: T) -> T {
        UserDefaults.standard.object(forKey: key) as? T ?? fallback
    }

    static func dict<V: Codable>(_ key: String) -> [String: V] {
        guard let data = UserDefaults.standard.data(forKey: "pp." + key),
              let value = try? JSONDecoder().decode([String: V].self, from: data) else { return [:] }
        return value
    }

    static func save<V: Codable>(_ value: [String: V], _ key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: "pp." + key) }
    }

    private static var dateCache: [String: Date] = [:]

    /// 手写解析 `YYYY-MM-DDTHH:MM:SS[.fraction](Z|±HH:MM)`：Mihomo 的时间带纳秒，
    /// DateFormatter 既不认 9 位小数又很慢（自动刷新推算时要解析上千条，实测是最大热点）。
    static func parseDate(_ string: String) -> Date? {
        if let cached = dateCache[string] { return cached }
        let b = Array(string.utf8)
        func num(_ from: Int, _ len: Int) -> Int? {
            guard from + len <= b.count else { return nil }
            var v = 0
            for i in from..<(from + len) {
                let c = b[i]
                guard c >= 48 && c <= 57 else { return nil }
                v = v * 10 + Int(c - 48)
            }
            return v
        }
        guard b.count >= 19, let y = num(0, 4), let mo = num(5, 2), let d = num(8, 2),
              let h = num(11, 2), let mi = num(14, 2), let sec = num(17, 2) else { return nil }
        var i = 19
        var fraction = 0.0
        if i < b.count, b[i] == 46 { // '.'
            var scale = 0.1
            i += 1
            while i < b.count, b[i] >= 48, b[i] <= 57 { fraction += Double(b[i] - 48) * scale; scale /= 10; i += 1 }
        }
        var offset = 0
        if i < b.count, b[i] == 43 || b[i] == 45, let oh = num(i + 1, 2), let om = num(i + 4, 2) { // '+' / '-'
            offset = (oh * 3600 + om * 60) * (b[i] == 45 ? -1 : 1)
        }
        var t = tm()
        t.tm_year = Int32(y - 1900); t.tm_mon = Int32(mo - 1); t.tm_mday = Int32(d)
        t.tm_hour = Int32(h); t.tm_min = Int32(mi); t.tm_sec = Int32(sec)
        let epoch = TimeInterval(timegm(&t)) - TimeInterval(offset) + fraction
        let date = Date(timeIntervalSince1970: epoch)
        if dateCache.count > 20000 { dateCache.removeAll() }
        dateCache[string] = date
        return date
    }
}
