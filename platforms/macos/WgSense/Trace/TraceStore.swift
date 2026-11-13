import Combine
import Foundation

// 路由追踪：调系统 traceroute（setuid，免提权）逐行解析；公网跳点批量查 ip-api 定位。
//
//   · 走系统当前路由：WG 全局时第一跳就是隧道网关，页面写明经哪块网卡。
//   · 定位只发公网地址，内网 / 运营商内网 / 隧道地址不出本机；结果缓存，同一地址不重复查。
//   · App 不允许明文 http（ATS），定位接口经 curl 调，与测速台的外部命令同一做法。

struct TraceGeo: Codable, Equatable {
    var lat: Double
    var lon: Double
    var city: String
    var country: String
    var code: String
    var isp: String
    var asn: String

    /// 地图标注用的短地名：城市优先，城市缺失用国家代码。
    var place: String { city.isEmpty ? code : city }
}

enum TraceHopKind: Equatable {
    case lan, tunnel, carrier, reserved, publicNet, silent

    var label: String {
        switch self {
        case .lan: return String(localized: "内网", bundle: .wgLocalized)
        case .tunnel: return String(localized: "隧道", bundle: .wgLocalized)
        case .carrier: return String(localized: "运营商内网", bundle: .wgLocalized)
        case .reserved: return String(localized: "保留地址", bundle: .wgLocalized)
        case .publicNet: return String(localized: "公网", bundle: .wgLocalized)
        case .silent: return String(localized: "无响应", bundle: .wgLocalized)
        }
    }
}

struct TraceHop: Identifiable, Equatable {
    let ttl: Int
    var ip: String?
    /// 同一跳里回应的其他地址（负载均衡）。
    var alternates: [String] = []
    var rtts: [Double?] = []
    var geo: TraceGeo?
    var kind: TraceHopKind = .silent
    let arrivedAt: Date
    /// 坐标到手的时刻（缓存命中 = 到达时刻）：地图从这一刻开始画这段航线。
    var locatedAt: Date?

    var id: Int { ttl }
    var answered: [Double] { rtts.compactMap { $0 } }
    var best: Double? { answered.min() }
    var average: Double? { answered.isEmpty ? nil : answered.reduce(0, +) / Double(answered.count) }
    var loss: Double { rtts.isEmpty ? 1 : 1 - Double(answered.count) / Double(rtts.count) }
}

/// 某个网络的公网出口边缘：直连追踪里出现的第一个有坐标的公网跳。按网络指纹（默认网关 + 网关 MAC）存，换网络不串用。
struct TraceOrigin: Codable, Equatable {
    var ip: String
    var geo: TraceGeo
    var network: String
    var learnedAt: Date
}

/// 目标被本地代理接管（fake-ip / 劫持解析）时的真实去向。字段全部来自探测，拿不到就留空、不猜。
struct TraceProxyPath: Equatable {
    /// 系统解析拿到的地址（traceroute 实际追的那个）。
    var systemIP: String
    /// 代理后端解析出的真实地址。
    var realIP: String?
    var realGeo: TraceGeo?
    /// 命中的规则与节点链（节点在前，与 mihomo 连接表一致）。
    var rule: String?
    var chain: [String] = []
    /// 出站节点服务器（连接表 remoteDestination：可能是域名）及其地址、位置。
    var nodeServer: String?
    var nodeIP: String?
    var nodeGeo: TraceGeo?
    /// 代理后端是否答得上话；答不上时只凭地址段判断，信息最少。
    var backend: Bool
    /// 本地起点（学习记录）：本机路径被网关截断、没有公网跳时，用本网络此前直连追踪学到的出口边缘。
    var origin: TraceOrigin?
    var resolvedAt: Date

    var node: String? { chain.first }
    /// 直连规则（DIRECT）：接管了但没走节点。
    var isDirect: Bool { node.map { $0.uppercased() == "DIRECT" } ?? false }
}

@MainActor
final class TraceStore: ObservableObject {
    static let shared = TraceStore()

    static let maxHops = 30
    static let probes = 3

    @Published var target: String = UserDefaults.standard.string(forKey: "trace.target") ?? "" {
        didSet { UserDefaults.standard.set(target, forKey: "trace.target") }
    }
    /// 追踪过的目标（最近在前）。快捷目标只来自这里和 WG 配置，不预置。
    @Published private(set) var recent: [String] = UserDefaults.standard.stringArray(forKey: "trace.recent") ?? []
    @Published private(set) var hops: [TraceHop] = []
    @Published private(set) var destination: String?
    @Published private(set) var reached = false
    @Published private(set) var interface: String?
    @Published private(set) var running = false
    @Published private(set) var startedAt: Date?
    @Published private(set) var finishedAt: Date?
    @Published private(set) var error: String?
    @Published private(set) var locating = false
    /// 代理接管时的真实去向；nil = 没被接管（或目标本身就是 IP）。
    @Published private(set) var proxied: TraceProxyPath?
    @Published private(set) var inspectingProxy = false
    /// 表格悬停的跳点：地图上同步高亮。
    @Published var focus: Int?

    private var process: Process?
    private var pending: Set<String> = []
    private var lookupTask: Task<Void, Never>?
    private var cache: [String: TraceGeo] = TraceStore.loadCache()
    /// 本次追踪所在网络的指纹；读不到为 nil。
    private var network: String?
    private var origins: [String: TraceOrigin] = TraceStore.loadOrigins()

    /// 正在探测的下一跳（地图上的扫描头）。
    var frontier: Int? {
        guard running else { return nil }
        return (hops.last?.ttl ?? 0) + 1
    }

    func start(_ raw: String? = nil, tunnelInterface: String?) {
        let host = (raw ?? target).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !running else { return }
        target = host
        remember(host)
        hops = []; destination = nil; reached = false; error = nil; focus = nil; gaveUp = false; proxied = nil
        TraceFakeIPAdapter.shared.begin(target: host)
        // 网络指纹要起两个子进程（route / arp），放到后台：在主线程等子进程会让地图卡一下
        network = nil
        Task.detached(priority: .userInitiated) { [weak self] in
            let n = Self.networkFingerprint()
            await MainActor.run { self?.network = n }
        }
        interface = nil; tunnelIface = nil; finishedAt = nil; startedAt = Date(); running = true

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/traceroute")
        // -n 不反查域名（快、也不泄露）；-I 用 ICMP，终点主机回应率比 UDP 高
        p.arguments = ["-n", "-I", "-q", "\(Self.probes)", "-w", "2", "-m", "\(Self.maxHops)", host]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        // 主队列按到达顺序处理（Task 不保证先后）
        let outLines = LineBuffer { [weak self] line in DispatchQueue.main.async { MainActor.assumeIsolated { self?.consume(line) } } }
        let errLines = LineBuffer { [weak self] line in DispatchQueue.main.async { MainActor.assumeIsolated { self?.consumeHeader(line, tunnel: tunnelInterface) } } }
        out.fileHandleForReading.readabilityHandler = { h in outLines.feed(h.availableData) }
        err.fileHandleForReading.readabilityHandler = { h in errLines.feed(h.availableData) }
        p.terminationHandler = { [weak self] proc in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            outLines.flush(); errLines.flush()
            let status = proc.terminationStatus, reason = proc.terminationReason
            Task { @MainActor in
                // 等最后几行解析完再收尾
                try? await Task.sleep(for: .milliseconds(80))
                self?.finish(status: status, killed: reason == .uncaughtSignal)
            }
        }
        do {
            try p.run()
            process = p
        } catch {
            running = false
            self.error = String(localized: "无法启动 traceroute：\(error.localizedDescription)", bundle: .wgLocalized)
        }
    }

    func stop() {
        process?.terminate()
    }

    func forget(_ host: String) {
        recent.removeAll { $0 == host }
        UserDefaults.standard.set(recent, forKey: "trace.recent")
    }

    // MARK: 解析

    /// 标准错误第一行：`traceroute to x (1.2.3.4), 30 hops max, …`；其余是错误信息。
    private func consumeHeader(_ line: String, tunnel: String?) {
        if line.hasPrefix("traceroute to "), let open = line.firstIndex(of: "("), let close = line.firstIndex(of: ")"), open < close {
            let ip = String(line[line.index(after: open)..<close])
            destination = ip
            // 出口网卡同样要起子进程，后台查完再回主线程
            Task.detached(priority: .userInitiated) { [weak self] in
                let iface = Self.routeInterface(to: ip)
                await MainActor.run {
                    guard let self, self.destination == ip else { return }
                    self.interface = iface
                    if let tunnel, iface == tunnel {
                        self.tunnelIface = tunnel
                        // 第一跳若已先到，按隧道重新归类
                        if let i = self.hops.firstIndex(where: { $0.ttl == 1 }) { self.hops[i].kind = self.classify(self.hops[i]) }
                    }
                }
            }
            if !Self.isIP(target) { inspectProxy(host: target, systemIP: ip) }
            return
        }
        if line.contains("Warning") { return }
        let msg = line.replacingOccurrences(of: "traceroute: ", with: "")
        if !msg.isEmpty { error = msg }
    }

    private var tunnelIface: String?

    /// ` 5  211.148.197.178  7.615 ms *  7.2 ms` / ` 4  * * *` / 同一跳多个地址。
    private func consume(_ line: String) {
        let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = tokens.first, let ttl = Int(first) else { return }
        var ip: String?
        var alternates: [String] = []
        var rtts: [Double?] = []
        var i = 1
        while i < tokens.count {
            let t = tokens[i]
            if t == "*" {
                rtts.append(nil)
            } else if Self.isIP(t) {
                if ip == nil { ip = t } else if t != ip, !alternates.contains(t) { alternates.append(t) }
            } else if let v = Double(t), i + 1 < tokens.count, tokens[i + 1] == "ms" {
                rtts.append(v); i += 1
            }
            i += 1
        }
        var hop = TraceHop(ttl: ttl, ip: ip, alternates: alternates, rtts: rtts, arrivedAt: Date())
        hop.kind = classify(hop)
        if let ip, hop.kind == .publicNet {
            if let g = cache[ip] { hop.geo = g; hop.locatedAt = hop.arrivedAt } else { enqueue(ip) }
        }
        if let idx = hops.firstIndex(where: { $0.ttl == ttl }) { hops[idx] = hop } else { hops.append(hop) }
        if let ip, ip == destination { reached = true }
        // 连续这么多跳无响应：后面多半也不会有了，不再干等（每跳 3 × 2 秒）
        let tail = hops.suffix(Self.silentLimit)
        if !reached, tail.count == Self.silentLimit, tail.allSatisfy({ $0.ip == nil }) {
            gaveUp = true
            stop()
        }
    }

    static let silentLimit = 12
    /// 因连续无响应提前结束。
    @Published private(set) var gaveUp = false

    /// 全程没有任何一跳回应。
    var allSilent: Bool { !hops.isEmpty && hops.allSatisfy { $0.ip == nil } }

    /// 路径起点：第一个有坐标的跳点（通常是本地运营商的公网边缘）。
    var firstLocated: TraceHop? { hops.first { $0.geo != nil } }

    private func classify(_ hop: TraceHop) -> TraceHopKind {
        guard let ip = hop.ip else { return .silent }
        guard let v4 = Self.octets(ip) else { return .publicNet }
        if hop.ttl == 1, tunnelIface != nil { return .tunnel }
        switch (v4[0], v4[1]) {
        case (10, _), (192, 168), (172, 16...31), (169, 254), (127, _): return .lan
        case (100, 64...127): return .carrier
        case (198, 18...19): return .reserved
        default: return .publicNet
        }
    }

    private func finish(status: Int32, killed: Bool) {
        guard running else { return }
        running = false
        process = nil
        finishedAt = Date()
        if !killed, status != 0, error == nil, hops.isEmpty { error = String(localized: "traceroute 退出码 \(status)", bundle: .wgLocalized) }
        learnOrigin()
    }

    /// 直连、未被接管的追踪结束后，记下本网络的出口边缘。定位晚到时（flushLookups）再试一次。
    private func learnOrigin() {
        guard let network, proxied == nil, tunnelIface == nil, !running,
              let hop = firstLocated, let ip = hop.ip, let geo = hop.geo else { return }
        origins[network] = TraceOrigin(ip: ip, geo: geo, network: network, learnedAt: Date())
        if let data = try? JSONEncoder().encode(origins) { UserDefaults.standard.set(data, forKey: "trace.origins") }
    }

    private static func loadOrigins() -> [String: TraceOrigin] {
        guard let data = UserDefaults.standard.data(forKey: "trace.origins"),
              let map = try? JSONDecoder().decode([String: TraceOrigin].self, from: data) else { return [:] }
        return map
    }

    /// 网络指纹：默认网关地址 + 网关 MAC（读不到 MAC 就用网卡名）。
    nonisolated private static func networkFingerprint() -> String? {
        let route = run("/sbin/route", ["-n", "get", "default"])
        func field(_ key: String) -> String? {
            route.split(separator: "\n").first { $0.contains("\(key):") }
                .map { $0.replacingOccurrences(of: "\(key):", with: "").trimmingCharacters(in: .whitespaces) }
        }
        guard let gw = field("gateway"), isIP(gw) else { return nil }
        let arp = run("/usr/sbin/arp", ["-n", gw])
        let mac = arp.split(separator: " ").drop { $0 != "at" }.dropFirst().first.map(String.init)
        return "\(gw) · \(mac ?? field("interface") ?? "?")"
    }

    nonisolated private static func run(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    private func remember(_ host: String) {
        recent.removeAll { $0 == host }
        recent.insert(host, at: 0)
        recent = Array(recent.prefix(8))
        UserDefaults.standard.set(recent, forKey: "trace.recent")
    }

    // MARK: 代理接管（Fake-IP 适配模块，见 TraceFakeIP.swift）

    private func inspectProxy(host: String, systemIP: String) {
        inspectingProxy = true
        Task {
            defer { inspectingProxy = false }
            let path = await TraceFakeIPAdapter.shared.inspect(host: host, systemIP: systemIP) { [weak self] ips in
                await self?.locate(ips) ?? [:]
            }
            // 期间又开了新的追踪就丢弃
            guard destination == systemIP else { return }
            proxied = path.map(attachOrigin)
        }
    }

    /// 07 本地起点：本机路径被截断（没有公网跳）时，套用本网络的学习记录；每种情况都在板块里写明。
    private func attachOrigin(_ path: TraceProxyPath) -> TraceProxyPath {
        var path = path
        let fip = TraceFakeIPAdapter.shared
        if let hop = firstLocated, let geo = hop.geo {
            fip.setOrigin(.ok, String(localized: "本机实测已有公网跳 \(hop.ip ?? "") · \(geo.place)，不用学习记录", bundle: .wgLocalized))
        } else if tunnelIface != nil {
            fip.setOrigin(.skip, String(localized: "经隧道：出口在隧道对端，不套用本网络的学习记录", bundle: .wgLocalized))
        } else if let network {
            if let o = origins[network] {
                path.origin = o
                let when = o.learnedAt.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute())
                fip.setOrigin(.ok, String(localized: "学习记录：网络 \(network) 在 \(when) 直连追踪的首个公网跳 \(o.ip) · \(o.geo.place)", bundle: .wgLocalized))
            } else {
                fip.setOrigin(.miss, String(localized: "网络 \(network) 还没有记录：先追一次直连目标（不经代理的地址）即可学到", bundle: .wgLocalized))
            }
        } else {
            fip.setOrigin(.miss, String(localized: "读不到网络指纹（默认网关），无法套用学习记录", bundle: .wgLocalized))
        }
        return path
    }

    /// 定位一组地址：先查缓存，缺的批量查。
    private func locate(_ ips: [String]) async -> [String: TraceGeo] {
        var out: [String: TraceGeo] = [:]
        for ip in ips { if let g = cache[ip] { out[ip] = g } }
        let missing = ips.filter { out[$0] == nil }
        guard !missing.isEmpty else { return out }
        locating = true
        let found = await Self.lookup(missing)
        locating = false
        for (ip, g) in found { out[ip] = g; cache[ip] = g }
        Self.saveCache(cache)
        return out
    }

    // MARK: 定位

    private func enqueue(_ ip: String) {
        pending.insert(ip)
        guard lookupTask == nil else { return }
        // 攒 0.4 秒一批：一次追踪通常两三批查完
        lookupTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            await self?.flushLookups()
        }
    }

    private func flushLookups() async {
        let batch = Array(pending.prefix(100))
        pending.subtract(batch)
        locating = true
        let found = await Self.lookup(batch)
        locating = false
        for (ip, g) in found { cache[ip] = g }
        if !found.isEmpty {
            for i in hops.indices { if let ip = hops[i].ip, hops[i].geo == nil, let g = found[ip] { hops[i].geo = g; hops[i].locatedAt = Date() } }
            Self.saveCache(cache)
        }
        lookupTask = nil
        learnOrigin()
        if !pending.isEmpty { enqueue(pending.first!) }
    }

    private static let fields = "status,query,country,countryCode,city,lat,lon,isp,as"

    private struct IPAPIRow: Decodable {
        var status: String?
        var query: String?
        var country: String?
        var countryCode: String?
        var city: String?
        var lat: Double?
        var lon: Double?
        var isp: String?
        var `as`: String?

        var geo: TraceGeo? {
            guard status == "success", let lat, let lon else { return nil }
            let asn = (`as` ?? "").split(separator: " ").first.map(String.init) ?? ""
            return TraceGeo(lat: lat, lon: lon, city: city ?? "", country: country ?? "",
                            code: countryCode ?? "", isp: isp ?? "", asn: asn)
        }
    }

    private static func lookup(_ ips: [String]) async -> [String: TraceGeo] {
        guard !ips.isEmpty, let body = try? JSONEncoder().encode(ips), let text = String(data: body, encoding: .utf8) else { return [:] }
        let r = await curl(["-sm8", "-X", "POST", "-H", "Content-Type: application/json",
                            "--data", text, "http://ip-api.com/batch?fields=\(fields)&lang=zh-CN"])
        guard let data = r, let rows = try? JSONDecoder().decode([IPAPIRow].self, from: data) else { return [:] }
        var out: [String: TraceGeo] = [:]
        for row in rows { if let q = row.query, let g = row.geo { out[q] = g } }
        return out
    }

    nonisolated static func curl(_ args: [String]) async -> Data? {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { _ in
                cont.resume(returning: pipe.fileHandleForReading.readDataToEndOfFile())
            }
            do { try p.run() } catch { cont.resume(returning: nil) }
        }
    }

    private static let cacheKey = "trace.geoCache"

    private static func loadCache() -> [String: TraceGeo] {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let map = try? JSONDecoder().decode([String: TraceGeo].self, from: data) else { return [:] }
        return map
    }

    private static func saveCache(_ map: [String: TraceGeo]) {
        // 上限 600 条：超出就整份丢掉重来，够用且不必维护淘汰顺序
        let kept = map.count > 600 ? [:] : map
        if let data = try? JSONEncoder().encode(kept) { UserDefaults.standard.set(data, forKey: cacheKey) }
    }

    // MARK: 工具

    nonisolated static func isIP(_ s: String) -> Bool {
        octets(s) != nil || (s.contains(":") && s.allSatisfy { $0.isHexDigit || $0 == ":" })
    }

    nonisolated static func octets(_ s: String) -> [Int]? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let v = parts.compactMap { Int($0) }
        return v.count == 4 && v.allSatisfy { (0...255).contains($0) } ? v : nil
    }

    /// `route -n get <ip>` 的出口网卡。
    nonisolated private static func routeInterface(to ip: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/sbin/route")
        p.arguments = ["-n", "get", ip]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return text.split(separator: "\n").first { $0.contains("interface:") }
            .map { $0.replacingOccurrences(of: "interface:", with: "").trimmingCharacters(in: .whitespaces) }
    }
}

/// 管道字节流按行切分（回调在读线程上）。
private final class LineBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    private let onLine: (String) -> Void

    init(_ onLine: @escaping (String) -> Void) { self.onLine = onLine }

    func feed(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        data.append(chunk)
        var lines: [String] = []
        while let nl = data.firstIndex(of: 0x0A) {
            lines.append(String(decoding: data[data.startIndex..<nl], as: UTF8.self))
            data.removeSubrange(data.startIndex...nl)
        }
        lock.unlock()
        lines.forEach(onLine)
    }

    func flush() {
        lock.lock()
        let rest = String(decoding: data, as: UTF8.self)
        data.removeAll()
        lock.unlock()
        if !rest.trimmingCharacters(in: .whitespaces).isEmpty { onLine(rest) }
    }
}

/// 侧栏「路由追踪」磁贴的一行状态：只在这行字真变了时才通知侧栏。
@MainActor
final class TraceTileSummary: ObservableObject {
    static let shared = TraceTileSummary()

    @Published private(set) var running = false
    /// nil = 待机（显示「世界航线」）。
    @Published private(set) var text: String?
    private var watch: AnyCancellable?

    private init() {
        // objectWillChange 在改动之前发出：下一轮主循环再读新值
        watch = TraceStore.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.refresh() } }
        }
        refresh()
    }

    private func refresh() {
        let trace = TraceStore.shared
        let t: String?
        if trace.running {
            t = String(format: String(localized: "追踪中 · %02d 跳", bundle: .wgLocalized), trace.hops.last?.ttl ?? 0)
        } else if let place = trace.hops.last(where: { $0.geo != nil })?.geo?.place, trace.reached {
            t = String(localized: "\(trace.hops.count) 跳 · \(place)", bundle: .wgLocalized)
        } else {
            t = nil
        }
        if running != trace.running { running = trace.running }
        if text != t { text = t }
    }
}
