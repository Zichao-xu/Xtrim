import Foundation

// Fake-IP 适配：目标被本地代理接管（fake-ip / 劫持解析）时，查出真实去向。独立模块，页面上有自己的板块。
//
//   判定依据（按顺序，每一步的结果都写进 steps 摆在前台）：
//     01 系统解析      traceroute 实际追的地址
//     02 后端解析      问当前配置的代理后端（经 WgSense 服务转发）同一个域名的真实 A 记录
//     03 判定          系统地址不在真实解析里 = 被接管；后端答不上时，只在地址落在「兜底网段」里提示疑似
//     04 连接表        后端连接表里这个域名的最近一条连接：规则、节点链（可选：没有就主动访问一次）
//     05 节点服务器    连接的 remoteDestination，域名再经后端解析成地址
//     06 定位          节点与真实目标的地理位置
//     07 本地起点      本机路径被网关截断时，套用本网络此前直连追踪学到的出口边缘（TraceStore 判断）
//
//   不认具体网段、节点名或路由器：换网络、换代理、换 fake-ip 段都按同一套依据走；兜底网段与主动访问都可在板块里改。

struct TraceFIPStep: Identifiable, Equatable {
    enum State: Equatable { case pending, ok, hit, miss, skip }

    let id: Int
    var title: String
    var detail: String = ""
    var state: State = .pending

    var code: String { String(format: "%02d", id) }
}

@MainActor
final class TraceFakeIPAdapter: ObservableObject {
    static let shared = TraceFakeIPAdapter()

    /// RFC 2544 基准测试保留段：公网不会出现，Clash 系代理默认拿它当 fake-ip 段。只作兜底默认值，可改。
    static let defaultRanges = "198.18.0.0/15"

    @Published var enabled = UserDefaults.standard.object(forKey: "trace.fip.enabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: "trace.fip.enabled") }
    }
    /// 连接表里查不到这个域名时，主动访问一次目标（HTTPS HEAD）让连接出现。会产生一次真实请求，所以可关。
    @Published var probeConnection = UserDefaults.standard.object(forKey: "trace.fip.probe") as? Bool ?? true {
        didSet { UserDefaults.standard.set(probeConnection, forKey: "trace.fip.probe") }
    }
    /// 兜底网段（CIDR，逗号或空格分隔）：后端答不上时，系统地址落在这里才提示「疑似接管」。
    @Published var fallbackRanges = UserDefaults.standard.string(forKey: "trace.fip.ranges") ?? TraceFakeIPAdapter.defaultRanges {
        didSet { UserDefaults.standard.set(fallbackRanges, forKey: "trace.fip.ranges") }
    }

    /// 代理后端地址（来自 WgSense 服务的代理设置）；nil = 没配或服务无响应。
    @Published private(set) var backend: String?
    @Published private(set) var steps: [TraceFIPStep] = TraceFakeIPAdapter.blankSteps(String(localized: "尚未追踪", bundle: .wgLocalized))

    private let api = ProxyAPIClient()

    static func blankSteps(_ note: String, state: TraceFIPStep.State = .skip) -> [TraceFIPStep] {
        [String(localized: "系统解析", bundle: .wgLocalized), String(localized: "后端解析", bundle: .wgLocalized), String(localized: "判定", bundle: .wgLocalized), String(localized: "连接表", bundle: .wgLocalized), String(localized: "节点服务器", bundle: .wgLocalized), String(localized: "定位", bundle: .wgLocalized), String(localized: "本地起点", bundle: .wgLocalized)].enumerated().map {
            TraceFIPStep(id: $0.offset + 1, title: $0.element, detail: note, state: state)
        }
    }

    /// 新追踪开始：步骤行数恒定，先全部置为等待 / 跳过。
    func begin(target: String) {
        if !enabled {
            steps = Self.blankSteps(String(localized: "适配已关闭：只显示系统解析的原始路径", bundle: .wgLocalized))
        } else if TraceStore.isIP(target) {
            steps = Self.blankSteps(String(localized: "目标是 IP，不经过解析，无需适配", bundle: .wgLocalized))
        } else {
            steps = Self.blankSteps("", state: .pending)
        }
    }

    /// 跑一遍判定。返回 nil = 没被接管（或关闭 / 无从判断）。
    func inspect(host: String, systemIP: String,
                 locate: @escaping ([String]) async -> [String: TraceGeo]) async -> TraceProxyPath? {
        guard enabled, !TraceStore.isIP(host) else { return nil }
        backend = (try? await api.status()).flatMap { $0.connected ? ($0.baseURL ?? $0.address) : nil }
        set(1, .ok, "\(host) → \(systemIP)")

        // 02 后端解析
        let real = await realAddresses(host)
        guard let real else {
            set(2, .miss, backend == nil ? String(localized: "代理后端未配置或无响应", bundle: .wgLocalized) : String(localized: "\(backend!) 未答复 DNS 查询", bundle: .wgLocalized))
            if let range = matchedRange(systemIP) {
                set(3, .hit, String(localized: "疑似接管：\(systemIP) 落在兜底网段 \(range)；后端答不上，无法确认真实去向", bundle: .wgLocalized))
                skipRest(from: 4, String(localized: "后端无响应，无从查起", bundle: .wgLocalized))
                return TraceProxyPath(systemIP: systemIP, backend: false, resolvedAt: Date())
            }
            set(3, .ok, String(localized: "按未接管处理：后端答不上，且 \(systemIP) 不在兜底网段", bundle: .wgLocalized))
            skipRest(from: 4, String(localized: "未接管", bundle: .wgLocalized))
            return nil
        }
        set(2, .ok, String(localized: "\(backend ?? String(localized: "代理后端", bundle: .wgLocalized))：\(real.isEmpty ? String(localized: "无 A 记录", bundle: .wgLocalized) : real.joined(separator: ", "))", bundle: .wgLocalized))

        // 03 判定
        guard !real.isEmpty, !real.contains(systemIP) else {
            set(3, .ok, real.isEmpty ? String(localized: "无法比对：后端没有 A 记录", bundle: .wgLocalized) : String(localized: "未接管：系统地址就在真实解析里", bundle: .wgLocalized))
            skipRest(from: 4, String(localized: "未接管", bundle: .wgLocalized))
            return nil
        }
        set(3, .hit, String(localized: "接管：系统地址 \(systemIP) 不在真实解析中", bundle: .wgLocalized))
        var path = TraceProxyPath(systemIP: systemIP, realIP: real.first, backend: true, resolvedAt: Date())

        // 04 连接表
        var conn = await latestConnection(host: host, realIPs: real)
        var probed = false
        if conn == nil, probeConnection {
            probed = true
            set(4, .pending, String(localized: "表里没有，主动访问一次 https://\(host) …", bundle: .wgLocalized))
            _ = await TraceStore.curl(["-sI", "-o", "/dev/null", "-m6", "https://\(host)"])
            try? await Task.sleep(for: .milliseconds(600))
            conn = await latestConnection(host: host, realIPs: real)
        }
        guard let conn else {
            set(4, .miss, probed ? String(localized: "主动访问后仍无此域名的连接", bundle: .wgLocalized) : String(localized: "表里没有此域名的连接（主动访问已关闭）", bundle: .wgLocalized))
            set(5, .skip, String(localized: "没有连接，查不到节点", bundle: .wgLocalized))
            await finishLocate(&path, locate: locate)
            return path
        }
        path.chain = conn.chains ?? []
        path.rule = conn.rule
        if let d = conn.metadata.destinationIP, TraceStore.isIP(d), matchedRange(d) == nil, !real.isEmpty { path.realIP = d }
        let chainText = path.chain.isEmpty ? String(localized: "无节点链", bundle: .wgLocalized) : path.chain.reversed().joined(separator: " › ")
        set(4, .ok, [path.rule.map { String(localized: "规则 \($0)", bundle: .wgLocalized) }, chainText].compactMap { $0 }.joined(separator: " · ") + (probed ? String(localized: "（主动访问得到）", bundle: .wgLocalized) : ""))

        // 05 节点服务器
        if path.isDirect {
            set(5, .skip, String(localized: "规则直连出站，没有节点", bundle: .wgLocalized))
        } else if let remote = conn.metadata.remoteDestination, !remote.isEmpty {
            path.nodeServer = remote
            path.nodeIP = TraceStore.isIP(remote) ? remote : await realAddresses(remote)?.first
            set(5, path.nodeIP == nil ? .miss : .ok,
                remote == path.nodeIP ? remote : String(localized: "\(remote) → \(path.nodeIP ?? String(localized: "解析失败", bundle: .wgLocalized))", bundle: .wgLocalized))
        } else {
            set(5, .miss, String(localized: "连接表没有给出节点服务器地址", bundle: .wgLocalized))
        }

        await finishLocate(&path, locate: locate)
        return path
    }

    // MARK: 步骤

    private func finishLocate(_ path: inout TraceProxyPath, locate: ([String]) async -> [String: TraceGeo]) async {
        let ips = [path.isDirect ? nil : path.nodeIP, path.realIP].compactMap { $0 }
        guard !ips.isEmpty else { set(6, .skip, String(localized: "没有可定位的地址", bundle: .wgLocalized)); return }
        set(6, .pending, String(localized: "定位中…", bundle: .wgLocalized))
        let geos = await locate(ips)
        path.nodeGeo = path.isDirect ? nil : path.nodeIP.flatMap { geos[$0] }
        path.realGeo = path.realIP.flatMap { geos[$0] }
        path.resolvedAt = Date()
        var parts: [String] = []
        if !path.isDirect, path.nodeIP != nil { parts.append(String(localized: "节点 ", bundle: .wgLocalized) + (path.nodeGeo.map { "\($0.place) · \($0.country)" } ?? String(localized: "未定位", bundle: .wgLocalized))) }
        if path.realIP != nil { parts.append(String(localized: "目标 ", bundle: .wgLocalized) + (path.realGeo.map { "\($0.place) · \($0.country)" } ?? String(localized: "未定位", bundle: .wgLocalized))) }
        set(6, geos.isEmpty ? .miss : .ok, parts.joined(separator: "  ·  "))
    }

    /// 07 本地起点由追踪引擎判断（它知道本机路径与网络指纹）。
    func setOrigin(_ state: TraceFIPStep.State, _ detail: String) { set(7, state, detail) }

    private func set(_ id: Int, _ state: TraceFIPStep.State, _ detail: String) {
        guard let i = steps.firstIndex(where: { $0.id == id }) else { return }
        steps[i].state = state
        steps[i].detail = detail
    }

    private func skipRest(from id: Int, _ note: String) {
        for i in steps.indices where steps[i].id >= id { steps[i].state = .skip; steps[i].detail = note }
    }

    // MARK: 后端

    /// 代理后端的 A 记录；后端不可用返回 nil，查无记录返回空数组。
    private func realAddresses(_ name: String) async -> [String]? {
        guard let r = try? await api.dnsQuery(name: name, type: "A") else { return nil }
        return (r.answer ?? []).filter { $0.type == 1 }.compactMap(\.data)
    }

    /// 连接表里这个域名最近的一条连接。
    private func latestConnection(host: String, realIPs: [String]) async -> ConnectionInfo? {
        guard let list = try? await api.connections().connections else { return nil }
        let hits = list.filter { $0.metadata.host == host || realIPs.contains($0.metadata.destinationIP ?? "") }
        return hits.max { ($0.start ?? "") < ($1.start ?? "") }
    }

    // MARK: 兜底网段

    /// 地址落在哪个兜底网段（原文返回，便于展示）；不在返回 nil。
    func matchedRange(_ ip: String) -> String? {
        guard let addr = Self.v4(ip) else { return nil }
        return Self.parseRanges(fallbackRanges).first { r in
            let mask: UInt32 = r.bits == 0 ? 0 : ~UInt32(0) << (32 - UInt32(r.bits))
            return addr & mask == r.base & mask
        }?.text
    }

    /// 兜底网段里写不对的条目（板块上标警示）。
    var invalidRanges: [String] {
        Self.tokens(fallbackRanges).filter { Self.parseRange($0) == nil }
    }

    private static func tokens(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
    }

    private static func parseRanges(_ s: String) -> [(base: UInt32, bits: Int, text: String)] {
        tokens(s).compactMap(parseRange)
    }

    private static func parseRange(_ t: String) -> (base: UInt32, bits: Int, text: String)? {
        let parts = t.split(separator: "/")
        guard parts.count == 2, let base = v4(String(parts[0])), let bits = Int(parts[1]), (0...32).contains(bits) else { return nil }
        return (base, bits, t)
    }

    private static func v4(_ s: String) -> UInt32? {
        guard let o = TraceStore.octets(s) else { return nil }
        return o.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }
}
