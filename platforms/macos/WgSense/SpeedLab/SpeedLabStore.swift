import AppKit
import CoreWLAN
import Foundation

// 测速台的引擎与状态：端点名册、各执行端的网卡、一次测量的编排、历史。
//
// 磁贴和页面共用这一个实例：从哪里开测都是同一次测量，切页不中断。
// 空闲时零开销——没有轮询、没有常驻连接；事件解析在后台线程，主线程每秒只收一次读数。

@MainActor
final class SpeedLabStore: ObservableObject {
    static let shared = SpeedLabStore()

    // MARK: 名册与选择

    /// 名册：只来自「发现」与「添加」，没有内置项。A 执行端、C 目标都从这里选。
    @Published private(set) var roster: [SLEndpoint] = [] { didSet { save(roster, Keys.roster) } }
    @Published private(set) var discovering = false
    @Published private(set) var discoverNote: String?
    /// 选择：初始为空，由用户选定。
    @Published var runnerID: String = "" { didSet { defaults.set(runnerID, forKey: Keys.runner) } }
    @Published var targetID: String = "" { didSet { defaults.set(targetID, forKey: Keys.target) } }
    /// 每台执行端选的路径（runnerID → 网卡名，或 SLIface.system 表示跟随系统路由）；没有 = 未选。
    @Published private var routes: [String: String] = [:] { didSet { save(routes, Keys.routes) } }
    /// 各执行端探测到的网卡（路径 B 的选项）。
    @Published private(set) var ifaces: [String: [SLIface]] = [:]
    @Published private(set) var ifaceErrors: [String: String] = [:]
    @Published private(set) var probing: Set<String> = []
    @Published var params = SLParams() { didSet { save(params, Keys.params) } }
    /// 用户手动添加的源（远程源列表见 SLSourceCatalog）。
    @Published var downloadSources: [String] = [] { didSet { save(downloadSources, Keys.dlSources) } }
    @Published var uploadSources: [String] = [] { didSet { save(uploadSources, Keys.ulSources) } }
    /// 本次被跳过的方向（没有可用源）。
    @Published private(set) var skipped: Set<String> = []

    // MARK: 一次测量

    @Published private(set) var running = false
    @Published private(set) var phase: SLPhase = .prepare
    @Published private(set) var downNow: Double?
    @Published private(set) var upNow: Double?
    @Published private(set) var rttNow: Double?
    @Published private(set) var downSeries: [Double] = []
    @Published private(set) var upSeries: [Double] = []
    /// 上行读数在哪一端量的；没有读数时为空。
    @Published private(set) var upSide: SLRateSide?
    @Published private(set) var info: [String: String] = [:]
    @Published private(set) var note: String = ""
    @Published private(set) var error: String?
    /// 表盘满刻度（Mbps）：开测时按协商速率定，跑中只在超出时放大，不来回缩放。
    @Published private(set) var scaleMax: Double = 1000
    @Published private(set) var history: [SLResult] = []

    private var task: Task<Void, Never>?
    /// 本次（或上一次）测量开跑时冻结的测法：跑中改参数不影响这一次。
    private var runMethod: SLParams?
    var activeMethod: SLParams { runMethod ?? params }
    private(set) var idleRTTs: [Double] = []
    private(set) var downRTTs: [Double] = []
    private(set) var upRTTs: [Double] = []

    // 动效时间线：每个事件带到达时刻，HUD 按"触发后第几帧"取动作
    @Published private(set) var startedAt: Date?
    @Published private(set) var finishedAt: Date?
    @Published private(set) var phaseDates: [SLPhase: Date] = [:]
    @Published private(set) var infoDates: [String: Date] = [:]
    @Published private(set) var downTimed: [SLTimedSample] = []
    @Published private(set) var upTimed: [SLTimedSample] = []
    @Published private(set) var idleTimed: [SLTimedSample] = []
    @Published private(set) var sourceResults: [SLSourceResult] = []
    @Published private(set) var reconnects: [SLConnEvent] = []
    /// HUD 用的统计轨迹：样本到达时增量更新一次。
    @Published private(set) var trails = SLTrails()
    /// 上行读数现在听谁的：接收端的实时回传接上之前先等一等，不把发送端的数字画上去。
    private enum UpFeed { case sender, waiting, receiver }
    private var upFeed = UpFeed.sender
    /// 等接收端时压着的发送端样本：超时没等到就放出来。
    private var upHeld: [SLTimedSample] = []
    /// 测完时服务端回传的区间（速率, 区间长度）：实时那条断过或根本没有时用它。
    private var upReport: [(v: Double, dt: Double)] = []
    /// 接收端的区间（秒）；nil = 和采样间隔相同。
    private var upInterval: Double?
    private var capabilities: [String: [String: String]] = [:]
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let roster = "speedLab.roster"
        static let runner = "speedLab.runner"
        static let target = "speedLab.target"
        static let routes = "speedLab.routes"
        static let params = "speedLab.params"
        static let dlSources = "speedLab.downloadSources"
        static let ulSources = "speedLab.uploadSources"
    }

    private init() {
        // 旧版手动添加的主机并入名册；旧版的内置端点、自动 peer 缓存一律不带过来
        roster = load(Keys.roster) ?? (load("speedLab.manualEndpoints") ?? [])
        defaults.removeObject(forKey: "speedLab.manualEndpoints")
        defaults.removeObject(forKey: "speedLab.peers")
        routes = load(Keys.routes) ?? [:]
        // 旧版的写死场景与二选一路径，已由探测出的网卡取代
        defaults.removeObject(forKey: "speedLab.scenes")
        defaults.removeObject(forKey: "speedLab.path")
        params = load(Keys.params) ?? SLParams()
        downloadSources = load(Keys.dlSources) ?? []
        uploadSources = load(Keys.ulSources) ?? []
        SLSourceCatalog.shared.refreshIfStale()
        history = Self.loadHistory()
        runnerID = defaults.string(forKey: Keys.runner) ?? ""
        targetID = defaults.string(forKey: Keys.target) ?? ""
    }

    // MARK: - 名册（发现 / 添加）

    var endpoints: [SLEndpoint] { roster }
    var runners: [SLEndpoint] { roster.filter(\.canRun) }
    var targets: [SLEndpoint] { roster }
    var runner: SLEndpoint? { roster.first { $0.id == runnerID } }
    var target: SLEndpoint? { roster.first { $0.id == targetID } }

    /// 当前组合不能测的原因；能测为空。
    var blocker: String? {
        guard let runner else { return roster.isEmpty ? "名册为空：先发现或添加端点" : "选择执行端" }
        guard let target else { return "选择目标" }
        if runner.id == target.id { return "执行端和目标是同一台机器" }
        if target.kind == .local, runner.kind == .local { return "执行端和目标是同一台机器" }
        if target.isPublic, route == nil { return "选择路径" }
        return nil
    }

    /// 目标为公网时才有路径可选；其余由地址决定走哪张网卡（台账里注明）。
    var pathSelectable: Bool { target?.isPublic ?? false }

    /// 添加能 SSH 登录的主机：可当执行端，也可当目标。
    func addSSH(name: String, host: String, port: Int, user: String) {
        var endpoint = SLEndpoint.ssh(host: host, port: port, user: user, via: "手动添加")
        endpoint.label = name
        merge([endpoint])
        Task {
            guard let events = try? await SLShell(endpoint: endpoint).collect(params.scriptVars.merging(["MODE": "probe"]) { $1 }) else { return }
            let caps = remember(endpoint, events)
            endpoint.hostname = caps["hostname"] ?? ""
            endpoint.seenAt = Date()
            merge([endpoint])
        }
    }

    /// 添加只知道地址的机器：只能当目标，要求它自己开着 iperf3 服务端。
    func addAddress(name: String, ip: String) {
        var endpoint = SLEndpoint.peer(ip: ip, via: "手动添加")
        endpoint.label = name
        merge([endpoint])
    }

    func remove(_ endpoint: SLEndpoint) {
        roster.removeAll { $0.id == endpoint.id }
        routes[endpoint.id] = nil
        ifaces[endpoint.id] = nil
        if runnerID == endpoint.id { runnerID = "" }
        if targetID == endpoint.id { targetID = "" }
    }

    /// 给名册里的一项起名（空 = 不起名，显示主机名或地址）。
    func rename(_ id: String, to label: String) {
        guard let i = roster.firstIndex(where: { $0.id == id }) else { return }
        roster[i].label = label.trimmingCharacters(in: .whitespaces)
    }

    /// 同 id 更新扫描到的事实（保留你起的名字），新的追加；地址已被可登录主机占用的 peer 不重复列。
    private func merge(_ found: [SLEndpoint]) {
        var list = roster
        for var e in found {
            if let i = list.firstIndex(where: { $0.id == e.id }) {
                if e.label.isEmpty { e.label = list[i].label }
                list[i] = e
            } else {
                list.append(e)
            }
        }
        let sshHosts = Set(list.filter(\.canRun).map(\.host))
        list.removeAll { $0.kind == .peer && sshHosts.contains($0.host) }
        roster = list
    }

    /// 发现：逐个来源去探，探到什么入册什么，名字只用设备自己报的主机名。
    ///   · 这台 Mac：本地跑一次 probe
    ///   · 代理后端里配了 SSH 的机器、名册里已有的 SSH 主机：登上去 probe，登得上才入册；顺带它们 WireGuard 配置里的 peer 地址
    ///   · 公网：测速源列表里有可用源才入册
    var discoverScope: [String] {
        ["本机"] + discoverCandidates.filter { $0.kind == .ssh }.map(\.address) + ["测速源列表"]
    }

    private var discoverCandidates: [SLEndpoint] {
        var list = [SLEndpoint.local(hostname: "")]
        for backend in MihomoBackendStore.shared.backends where !backend.isLocal {   // 本机内核没有 SSH
            let host = backend.effectiveSSHHost
            guard !host.isEmpty else { continue }
            let e = SLEndpoint.ssh(host: host, port: backend.sshPort, user: backend.sshUser, via: "代理后端 \(backend.host)")
            if !list.contains(where: { $0.id == e.id }) { list.append(e) }
        }
        for e in roster where e.canRun && !list.contains(where: { $0.id == e.id }) { list.append(e) }
        return list
    }

    func discover() {
        guard !discovering, !running else { return }
        discovering = true
        discoverNote = "发现中：" + discoverScope.joined(separator: "、")
        Task {
            var found: [SLEndpoint] = [], failed: [String] = [], peers: [SLEndpoint] = []
            for var endpoint in discoverCandidates {
                capabilities[endpoint.id] = nil
                guard let events = try? await SLShell(endpoint: endpoint).collect(params.scriptVars.merging(["MODE": "probe"]) { $1 }) else {
                    failed.append(endpoint.address); continue
                }
                let caps = remember(endpoint, events)
                endpoint.hostname = caps["hostname"] ?? ""
                endpoint.seenAt = Date()
                found.append(endpoint)
                for event in events where event.ev == "peer" {
                    guard let ip = event.ip, !peers.contains(where: { $0.host == ip }) else { continue }
                    var peer = SLEndpoint.peer(ip: ip, via: "\(endpoint.name) · \(event.iface ?? "wg")")
                    peer.seenAt = Date()
                    peers.append(peer)
                }
            }
            let mine = Self.localIPv4s()
            peers.removeAll { mine.contains($0.host) }
            found += peers.sorted { $0.host.localizedStandardCompare($1.host) == .orderedAscending }
            let catalog = SLSourceCatalog.shared
            let n = catalog.candidates("dl", manual: downloadSources, retireAfter: params.retireAfter).count
                + catalog.candidates("ul", manual: uploadSources, retireAfter: params.retireAfter).count
            if n > 0 { var pub = SLEndpoint.publicNet(sources: n); pub.seenAt = Date(); found.append(pub) }
            merge(found)
            discovering = false
            let note = "发现 \(found.count) 个" + (failed.isEmpty ? "" : " · 连不上：\(failed.joined(separator: "、"))")
            discoverNote = note
            try? await Task.sleep(for: .seconds(6))
            if discoverNote == note { discoverNote = nil }
        }
    }

    // MARK: - 路径（执行端的网卡）

    /// 当前执行端选的路径；nil = 未选。
    var route: String? {
        get { routes[runnerID] }
        set { routes[runnerID] = newValue }
    }

    var runnerIfaces: [SLIface] { ifaces[runnerID] ?? [] }

    /// 探测当前执行端的网卡（每台每次启动一次，结果在 remember 里落到 ifaces）。
    func refreshIfaces() {
        guard let runner, !probing.contains(runner.id) else { return }
        capabilities[runner.id] = nil
        probing.insert(runner.id)
        ifaceErrors[runner.id] = nil
        Task {
            do { _ = try await probe(runner) } catch { ifaceErrors[runner.id] = error.localizedDescription }
            probing.remove(runner.id)
        }
    }

    /// 线路上 B 的文字：网卡名或"系统路由"；非公网目标由对端地址决定。
    func pathTitle(_ target: SLEndpoint) -> String {
        guard target.isPublic else { return "iperf3" }
        return route.map { $0 == SLIface.system ? "系统路由" : $0 } ?? "—"
    }

    // MARK: - 最近线路（从历史得出，不写死）

    /// 历史里最近用过的不同线路（端点仍在名册里的），最多 n 条。
    func recentRoutes(_ n: Int = 3) -> [SLResult] {
        var seen = Set<String>(), out: [SLResult] = []
        for r in history {
            guard let ids = ids(of: r) else { continue }
            let key = "\(ids.runner)|\(ids.target)|\(r.iface ?? "")"
            if seen.insert(key).inserted { out.append(r) }
            if out.count == n { break }
        }
        return out
    }

    /// 套用一条历史线路。
    func use(_ r: SLResult) {
        guard !running, let ids = ids(of: r) else { return }
        runnerID = ids.runner
        targetID = ids.target
        if endpoints.first(where: { $0.id == ids.target })?.isPublic == true {
            route = r.iface ?? (r.path == "系统路由" ? SLIface.system : nil)
        }
    }

    private func ids(of r: SLResult) -> (runner: String, target: String)? {
        let runner = r.runnerID ?? endpoints.first { $0.name == r.runner }?.id
        let target = r.targetID ?? endpoints.first { $0.name == r.target }?.id
        guard let runner, let target, endpoints.contains(where: { $0.id == runner }),
              endpoints.contains(where: { $0.id == target }) else { return nil }
        return (runner, target)
    }

    // MARK: - 结果

    var lastResult: SLResult? { history.first }

    /// 当前组合的上一次结果（待机时表盘停在这里）。
    var lastForCurrent: SLResult? {
        guard let runner, let target else { return nil }
        let key = SLResult(runner: runner.name, target: target.name, path: pathTitle(target), engine: "").sceneKey
        return history.first { $0.sceneKey == key && $0.error == nil }
    }

    /// 执行端回报的采样间隔（秒）：默认每秒 10 次，执行端不支持亚秒等待时退回 1。
    var tick: Double { info["tick"].flatMap(Double.init) ?? 1 }
    var downStat: SLStat? { SLStat.from(downSeries, rtts: downRTTs, tick: tick, method: runMethod ?? params) }
    var upTick: Double { upInterval ?? tick }
    var upStat: SLStat? { SLStat.from(upSeries, rtts: upRTTs, tick: upTick, method: runMethod ?? params) }
    var idleRTT: Double? { idleRTTs.isEmpty ? nil : SLStat.median(idleRTTs) }

    func clearHistory() {
        history = []
        Self.saveHistory(history)
    }

    // MARK: - 运行

    func start() {
        guard !running, blocker == nil, let runner, let target else { return }
        running = true
        phase = .prepare
        downNow = nil; upNow = nil; rttNow = nil
        downSeries = []; upSeries = []
        upSide = nil; upFeed = .sender; upHeld = []; upReport = []; upInterval = nil
        idleRTTs = []; downRTTs = []; upRTTs = []
        info = [:]; error = nil; note = "连接执行端…"
        startedAt = Date(); finishedAt = nil
        phaseDates = [.prepare: Date()]; infoDates = [:]
        downTimed = []; upTimed = []; idleTimed = []; sourceResults = []; reconnects = []; skipped = []
        runMethod = params
        trails = SLTrails()
        scaleMax = 1000
        task = Task { await execute(runner: runner, target: target) }
    }

    /// 测速页可见时预热到执行端的 SSH（每 50 秒续一次，ControlPersist 是 60 秒）。
    func warmRunner() {
        guard !running, let runner else { return }
        SLShell(endpoint: runner).warm()
    }

    func stop() {
        task?.cancel()
    }

    private func execute(runner: SLEndpoint, target: SLEndpoint) async {
        var result = SLResult(runner: runner.name, target: target.name, path: pathTitle(target),
                              engine: target.isPublic ? "HTTP" : "iperf3",
                              runnerID: runner.id, targetID: target.id, iface: target.isPublic && route != SLIface.system ? route : nil,
                              method: runMethod)
        do {
            if target.isPublic {
                try await runHTTP(runner: runner)
            } else {
                try await runIperf(runner: runner, target: target)
            }
            if Task.isCancelled { throw CancellationError() }
        } catch is CancellationError {
            result.error = "已停止"
        } catch {
            result.error = error.localizedDescription
        }
        if Task.isCancelled, result.error == nil { result.error = "已停止" }
        if target.isPublic { SLSourceCatalog.shared.record(sourceResults) }
        settleUp()

        result.down = downStat
        result.up = upStat
        result.idleRTT = idleRTT
        result.downSeries = downSeries
        result.upSeries = upSeries
        result.tick = tick
        result.upSide = upSide
        result.upTick = upTick
        result.linkText = info["link"] ?? ""
        result.linkMbps = linkMbps
        result.exit = info["exit"] ?? ""
        result.sources = sourceList
        if result.down != nil || result.up != nil || (result.error != nil && result.error != "已停止") {
            history.insert(result, at: 0)
            if history.count > 300 { history.removeLast(history.count - 300) }
            Self.saveHistory(history)
        }
        error = result.error == "已停止" ? nil : result.error
        note = result.error ?? "完成"
        phase = .done
        finishedAt = Date()
        phaseDates[.done] = finishedAt
        running = false
        downNow = nil; upNow = nil
        task = nil
    }

    // MARK: HTTP（公网）

    private func runHTTP(runner: SLEndpoint) async throws {
        note = "公网测速：\(runner.name) · \(pathTitle(.publicNet(sources: 0)))"
        var vars = commonVars()
        vars["MODE"] = "http"
        if let route, route != SLIface.system { vars["IFACE"] = route }
        let catalog = SLSourceCatalog.shared
        let dl = catalog.candidates("dl", manual: downloadSources, retireAfter: params.retireAfter)
        let ul = catalog.candidates("ul", manual: uploadSources, retireAfter: params.retireAfter)
        guard !dl.isEmpty || !ul.isEmpty else {
            throw SLShell.Failure(message: catalog.url.isEmpty ? "未配置测速源 · 在「测速源」里填源列表地址" : "测速源列表为空")
        }
        vars["DL_URLS"] = dl.joined(separator: " ")
        vars["UL_URLS"] = ul.joined(separator: " ")
        try await consume(SLShell(endpoint: runner).stream(vars), runner: runner)
    }

    // MARK: iperf3（两端之间）

    private func runIperf(runner: SLEndpoint, target: SLEndpoint) async throws {
        let targetShell = SLShell(endpoint: target)
        var port = params.iperfPort
        var deployed: String?
        var receiverLog: String?
        var tail: Task<Void, Never>?

        // 目标端：能登上去就临时起服务端，测完必停；WG peer 要求它自己开着。
        if target.kind != .peer {
            note = "在 \(target.name) 上启动 iperf3 服务端…"
            let bin = try await ensureIperf(on: target)
            deployed = bin.deployed
            var vars = params.scriptVars.merging(["MODE": "iperf-server", "IPERF_PORT": "\(port)"]) { $1 }
            if let path = bin.path { vars["IPERF_BIN"] = path }
            let events = try await targetShell.collect(vars)
            if let p = events.first(where: { $0.k == "port" })?.v.flatMap(Int.init) { port = p }
            receiverLog = events.first(where: { $0.k == "log" })?.v
        }

        do {
            let host = target.kind == .local ? try await Self.localAddress(toward: runner.host) : target.host
            note = "iperf3：\(runner.name) ⇄ \(target.name)"
            let bin = try await ensureIperf(on: runner)
            var vars = commonVars()
            vars["MODE"] = "iperf"
            vars["IPERF_HOST"] = host
            vars["IPERF_PORT"] = "\(port)"
            if let path = bin.path { vars["IPERF_BIN"] = path }
            info["target"] = "\(host):\(port)"
            if let receiverLog, params.directions != .down { tail = followReceiver(on: target, log: receiverLog) }
            try await consume(SLShell(endpoint: runner).stream(vars), runner: runner)
            if let deployedRunner = bin.deployed, runner.kind == .ssh {
                _ = try? await SLShell(endpoint: runner).collect(["MODE": "iperf-stop", "DEPLOYED": deployedRunner])
            }
        } catch {
            tail?.cancel()
            await stopServer(on: target, deployed: deployed)
            throw error
        }
        tail?.cancel()
        await stopServer(on: target, deployed: deployed)
    }

    /// 实时回传目标端的区间日志。回传接不上不算错：上行退回发送端，并如实标注。
    private func followReceiver(on target: SLEndpoint, log: String) -> Task<Void, Never> {
        var vars = params.scriptVars
        vars["MODE"] = "iperf-tail"
        vars["IPERF_LOG"] = log
        return Task {
            do {
                for try await event in SLShell(endpoint: target).stream(vars) {
                    if event.ev == "info", event.k == "tail" { upFeed = .waiting }
                    if event.ev == "r" { takeReceiver(event) }
                }
            } catch {}
        }
    }

    private func stopServer(on target: SLEndpoint, deployed: String?) async {
        guard target.kind != .peer else { return }
        var vars = ["MODE": "iperf-stop"]
        if let deployed { vars["DEPLOYED"] = deployed }
        // 收尾不受“停止”影响：放到独立任务里跑完。
        await Task.detached { _ = try? await SLShell(endpoint: target).collect(vars) }.value
    }

    /// 这台机器上能用的 iperf3：自带的直接用；没有就把 App 里打包的静态版传过去（测完删除）。
    private func ensureIperf(on endpoint: SLEndpoint) async throws -> (path: String?, deployed: String?) {
        let caps = try await probe(endpoint)
        if caps["has_iperf3"] == "1" { return (nil, nil) }
        let os = (caps["os"] ?? "").lowercased()
        let arch = (caps["arch"] ?? "").lowercased()
        let name = "iperf3-\(os)-\(arch == "arm64" && os == "linux" ? "aarch64" : arch)"
        guard let bundled = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "iperf3") else {
            throw SLShell.Failure(message: "\(endpoint.name) 没有 iperf3，App 里也没有 \(os)/\(arch) 的静态版可部署")
        }
        if endpoint.kind == .local { return (bundled.path, nil) }
        note = "给 \(endpoint.name) 临时部署 iperf3…"
        let remote = "/tmp/wgsense-iperf3"
        try await SLShell(endpoint: endpoint).upload(bundled, to: remote)
        return (remote, remote)
    }

    /// 能力探测（每台机器每次启动探一次）。
    private func probe(_ endpoint: SLEndpoint) async throws -> [String: String] {
        if let cached = capabilities[endpoint.id] { return cached }
        let events = try await SLShell(endpoint: endpoint).collect(params.scriptVars.merging(["MODE": "probe"]) { $1 })
        return remember(endpoint, events)
    }

    @discardableResult
    private func remember(_ endpoint: SLEndpoint, _ events: [SLEvent]) -> [String: String] {
        var caps: [String: String] = [:]
        for event in events where event.ev == "info" {
            if let k = event.k { caps[k] = event.v ?? "" }
        }
        capabilities[endpoint.id] = caps
        ifaces[endpoint.id] = events.filter { $0.ev == "iface" }.compactMap { e in
            guard let name = e.name else { return nil }
            return SLIface(name: name, addr: e.ip ?? "", phy: e.k ?? name, link: e.v ?? "", isDefault: e.keep ?? false)
        }
        // 系统路由也是探测结果：它此刻实际走哪张网卡
        if let via = caps["sysroute"], !via.isEmpty {
            ifaces[endpoint.id]?.insert(SLIface(name: SLIface.system, addr: "", phy: via, link: "", isDefault: false), at: 0)
        }
        return caps
    }

    // MARK: 事件

    private func commonVars() -> [String: String] { params.scriptVars }

    private func consume(_ stream: AsyncThrowingStream<SLEvent, Error>, runner: SLEndpoint) async throws {
        for try await event in stream {
            try Task.checkCancellation()
            switch event.ev {
            case "info":
                guard let k = event.k else { break }
                info[k] = event.v ?? ""
                infoDates[k] = Date()
                if k == "link" { applyLink(runner: runner) }
            case "phase":
                if let p = event.ph.flatMap(SLPhase.init(rawValue:)) {
                    phase = p
                    phaseDates[p] = Date()
                    note = p.title
                }
            case "src":
                if let dir = event.ph, let url = event.v {
                    sourceResults.append(SLSourceResult(dir: dir, url: url, mbps: event.rx ?? 0,
                                                        keep: event.keep ?? false, at: Date()))
                }
            case "skip":
                if let dir = event.ph { skipped.insert(dir) }
            case "conn":
                if let dir = event.ph { reconnects.append(SLConnEvent(dir: dir, n: event.n ?? 0, at: Date())) }
            case "s":
                take(event)
            case "r":
                takeReceiver(event)
            case "err":
                throw SLShell.Failure(message: event.msg ?? "执行端报错")
            default:
                break
            }
        }
    }

    private func take(_ event: SLEvent) {
        let rtt = event.rtt
        if let ph = event.ph, ph != "ul" {
            let v = ph == "dl" ? (event.rx ?? 0) : (rtt ?? 0)
            trails.add(ph, value: v, rtt: rtt, at: Date(), tick: tick, method: activeMethod)
        }
        rttNow = rtt
        switch event.ph {
        case "idle":
            if let rtt { idleRTTs.append(rtt); idleTimed.append(SLTimedSample(v: rtt, rtt: rtt, at: Date())) }
        case "dl":
            let v = event.rx ?? 0
            downNow = v
            downSeries.append(v)
            downTimed.append(SLTimedSample(v: v, rtt: rtt, at: Date()))
            if let rtt { downRTTs.append(rtt) }
            grow(v)
        case "ul":
            let sample = SLTimedSample(v: event.tx ?? 0, rtt: rtt, at: Date())
            switch upFeed {
            case .sender:
                showUp(sample, side: .sender)
            case .receiver:
                break  // 这条事件只带来了 rtt
            case .waiting:
                upHeld.append(sample)
                if Double(upHeld.count) * tick >= Self.receiverGrace { releaseHeld() }
            }
        default:
            break
        }
    }

    /// 上行开跑后等接收端的第一条回传最多这么久（秒）。
    private static let receiverGrace = 2.0

    private func showUp(_ s: SLTimedSample, side: SLRateSide) {
        upSide = side
        trails.add("ul", value: s.v, rtt: s.rtt, at: s.at, tick: upTick, method: activeMethod)
        upNow = s.v
        upSeries.append(s.v)
        upTimed.append(s)
        if let rtt = s.rtt { upRTTs.append(rtt) }
        grow(s.v)
    }

    /// 接收端没等到：压着的发送端样本放出来，之后听发送端的。
    private func releaseHeld() {
        upFeed = .sender
        upHeld.forEach { showUp($0, side: .sender) }
        upHeld = []
    }

    /// 接收端的一条区间：实时回传直接上屏；测完回传的先收着，settleUp 再决定用不用。
    private func takeReceiver(_ event: SLEvent) {
        guard let v = event.rx, let a = event.a, let b = event.b else { return }
        if event.k == "end" { upReport.append((v, b - a)); return }
        // 日志里也有下行的区间（服务端是发送方），只取上行阶段；已退回发送端就不再半路换
        guard phase == .ul, upFeed != .sender else { return }
        if upFeed == .waiting {
            upFeed = .receiver
            upHeld = []
            upInterval = b - a
        }
        showUp(SLTimedSample(v: v, rtt: rttNow, at: Date()), side: .receiver)
    }

    /// 上行收尾：实时那条断过或根本没有（对端不是我们起的），用服务端回传的全程换掉曲线；
    /// 两样都没有就是发送端，upSide 如实留着。
    private func settleUp() {
        if upFeed == .waiting { releaseHeld() }
        let n = upReport.count
        guard n > 0, upFeed != .receiver || Double(upSeries.count) < Double(n) * 0.9 else { return }
        let old = upTimed, began = phaseDates[.ul] ?? Date()
        upInterval = SLStat.median(upReport.map(\.dt))
        upSeries = upReport.map(\.v)
        // 回传的样本没有到达时刻：沿用原来那条的时刻与延迟，时间线不变
        upTimed = upReport.enumerated().map { i, r in
            let o = old.isEmpty ? nil : old[min(i * old.count / n, old.count - 1)]
            return SLTimedSample(v: r.v, rtt: o?.rtt, at: o?.at ?? began)
        }
        upSide = .receiver
        trails = .replay(idle: idleTimed, down: downTimed, up: upTimed, tick: tick, upTick: upTick, method: activeMethod)
    }

    var linkMbps: Int? {
        guard let first = info["link"]?.split(separator: " ").first, let v = Int(first), v > 0 else { return nil }
        return v
    }

    /// 协商速率到手：定表盘满刻度。本机 Wi-Fi 读不到网卡速率时，用 CoreWLAN 的发送速率。
    private func applyLink(runner: SLEndpoint) {
        if linkMbps == nil, runner.kind == .local, let phy = info["phy"],
           let wifi = CWWiFiClient.shared().interface(withName: phy), wifi.transmitRate() > 0 {
            info["link"] = "\(Int(wifi.transmitRate())) Wi-Fi"
        }
        scaleMax = Self.niceScale(Double(linkMbps ?? 1000))
    }

    /// 读数明显超出满刻度才放大（单个采样的毛刺不算）。
    private func grow(_ value: Double) {
        if value > scaleMax * 1.1 { scaleMax = Self.niceScale(value * 1.05) }
    }

    static func niceScale(_ v: Double) -> Double {
        for step in [100.0, 300, 500, 1000, 2500, 5000, 10000, 25000, 40000, 100000] where v <= step { return step }
        return v
    }

    private var sourceList: [String] {
        if let target = info["target"] { return [target] }
        return [info["dl_sources"], info["ul_sources"]].compactMap { $0 }.filter { !$0.isEmpty }
    }

    // MARK: - 本机地址

    /// 本机在通往某台机器那张网卡上的 IPv4（对端要连回本机的 iperf3 服务端）。
    static func localAddress(toward host: String) async throws -> String {
        try await Task.detached {
            let route = Self.shell("/sbin/route", ["-n", "get", host])
            guard let iface = route.split(separator: "\n").first(where: { $0.contains("interface:") })?
                .split(separator: ":").last?.trimmingCharacters(in: .whitespaces) else {
                throw SLShell.Failure(message: "找不到通往 \(host) 的网卡")
            }
            let conf = Self.shell("/sbin/ifconfig", [iface])
            for line in conf.split(separator: "\n") {
                let parts = line.split(whereSeparator: \.isWhitespace)
                if let i = parts.firstIndex(of: "inet"), i + 1 < parts.count { return String(parts[i + 1]) }
            }
            throw SLShell.Failure(message: "\(iface) 上没有 IPv4 地址")
        }.value
    }

    static func localIPv4s() -> Set<String> {
        let conf = shell("/sbin/ifconfig", [])
        var set = Set<String>()
        for line in conf.split(separator: "\n") {
            let parts = line.split(whereSeparator: \.isWhitespace)
            if let i = parts.firstIndex(of: "inet"), i + 1 < parts.count { set.insert(String(parts[i + 1])) }
        }
        return set
    }

    nonisolated private static func shell(_ exe: String, _ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - 持久化

    private func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    private func load<T: Decodable>(_ key: String) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private static var historyURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WgSense", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("speedlab-history.json")
    }

    private static func loadHistory() -> [SLResult] {
        guard let data = try? Data(contentsOf: historyURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([SLResult].self, from: data)) ?? []
    }

    private static func saveHistory(_ history: [SLResult]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(history) else { return }
        try? data.write(to: historyURL, options: .atomic)
    }
}

// MARK: - HUD 快照

extension SLHUDData {
    @MainActor init(_ lab: SpeedLabStore) {
        self.init()
        runner = lab.runner?.name ?? "—"
        target = lab.target?.name ?? "—"
        isPublic = lab.target?.isPublic ?? true
        path = isPublic ? (lab.route.map { $0 == SLIface.system ? "system" : $0 } ?? "—") : "iperf3"
        running = lab.running
        startedAt = lab.startedAt
        finishedAt = lab.finishedAt
        phaseDates = lab.phaseDates
        infoDates = lab.infoDates
        info = lab.info
        link = lab.linkMbps
        down = lab.downTimed
        up = lab.upTimed
        idle = lab.idleTimed
        sources = lab.sourceResults
        reconnects = lab.reconnects
        skipped = lab.skipped
        downThreads = isPublic ? lab.activeMethod.httpDownThreads : lab.activeMethod.iperfStreams
        upThreads = isPublic ? lab.activeMethod.httpUpThreads : lab.activeMethod.iperfStreams
        unit = lab.params.unit
        tick = lab.tick
        upTick = lab.upTick
        upSide = lab.upSide
        method = lab.activeMethod
        trails = lab.trails
        error = lab.error
    }

}
