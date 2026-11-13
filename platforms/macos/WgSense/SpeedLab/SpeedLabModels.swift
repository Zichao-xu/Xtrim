import Foundation

// 测速台的数据模型（规格见 docs/speedtest-spec.md）。
//
// 一次测量 = 执行端 A + 路径 B + 目标 C。执行端在哪台机器上跑 speedlab.sh，
// 目标是公网（HTTP 多源测速）或名册里另一个端点（iperf3）。

// MARK: - 端点

enum SLEndpointKind: String, Codable {
    /// 这台 Mac。
    case local
    /// 能 SSH 上去的机器：可当执行端，也可临时起 iperf3 服务端当目标。
    case ssh
    /// 只知道地址的 WG peer：只能当目标，要求它自己开着 iperf3 服务端。
    case peer
    /// 公网测速源。
    case publicNet
}

struct SLEndpoint: Codable, Identifiable, Hashable {
    var id: String
    var kind: SLEndpointKind
    var host: String = ""
    var sshPort: Int = 22
    var sshUser: String = "root"
    /// 用户起的名字；空 = 没起。
    var label: String = ""
    /// 扫描时设备自己报的主机名；报不出为空。
    var hostname: String = ""
    /// 在哪发现：本机探测 / 代理后端 x.x.x.x / <路由器> · wg0 / 手动添加 / 测速源列表。
    var via: String = ""
    /// 最近一次扫描成功登上去（或看到它）的时刻。
    var seenAt: Date?

    var canRun: Bool { kind == .local || kind == .ssh }
    var isPublic: Bool { kind == .publicNet }

    /// 显示名：你起的名字 → 设备报的主机名 → 地址。不替你挑别的字段。
    var name: String { !label.isEmpty ? label : !hostname.isEmpty ? hostname : address }

    static func local(hostname: String) -> SLEndpoint {
        SLEndpoint(id: "local", kind: .local, hostname: hostname, via: String(localized: "本机探测", bundle: .wgLocalized))
    }

    static func publicNet(sources: Int) -> SLEndpoint {
        SLEndpoint(id: "public", kind: .publicNet, via: String(localized: "测速源列表 · \(sources) 个源", bundle: .wgLocalized))
    }

    static func ssh(host: String, port: Int, user: String, via: String) -> SLEndpoint {
        SLEndpoint(id: "ssh:\(user)@\(host):\(port)", kind: .ssh, host: host, sshPort: port, sshUser: user, via: via)
    }

    static func peer(ip: String, via: String) -> SLEndpoint {
        SLEndpoint(id: "peer:\(ip)", kind: .peer, host: ip, via: via)
    }

    /// 地址。
    var address: String {
        switch kind {
        case .local: return "localhost"
        case .ssh: return "\(sshUser)@\(host):\(sshPort)"
        case .peer: return host
        case .publicNet: return String(localized: "公网", bundle: .wgLocalized)
        }
    }

    /// 能做什么。
    var ability: String {
        switch kind {
        case .local, .ssh: return String(localized: "可执行 · 可当目标", bundle: .wgLocalized)
        case .peer: return String(localized: "仅目标 · 需自备 iperf3 服务端", bundle: .wgLocalized)
        case .publicNet: return String(localized: "仅目标 · HTTP 测速", bundle: .wgLocalized)
        }
    }
}

// MARK: - 路径与参数

/// 执行端上的一张网卡（probe 探测得来）：路径 B 的选项。
struct SLIface: Codable, Hashable, Identifiable {
    var name: String
    var addr: String
    /// 承载它的物理口（pppoe-wan → wan）；不同于 name 时才有意义。
    var phy: String
    /// 物理口协商速率，原始 "1000 full"；虚拟口、Wi-Fi 为空。
    var link: String
    /// 是不是默认路由出口。
    var isDefault: Bool
    var id: String { name }
    /// 「跟随系统路由与 DNS」这一项的名字；phy = 探测时系统路由实际走的网卡。
    static let system = "@system"
    var isSystem: Bool { name == Self.system }
}

enum SLDirections: String, Codable, CaseIterable, Identifiable {
    case both, down, up
    var id: String { rawValue }
    var title: String {
        switch self {
        case .both: return String(localized: "双向", bundle: .wgLocalized)
        case .down: return String(localized: "仅下行", bundle: .wgLocalized)
        case .up: return String(localized: "仅上行", bundle: .wgLocalized)
        }
    }
    var script: String {
        switch self {
        case .both: return "dl ul"
        case .down: return "dl"
        case .up: return "ul"
        }
    }
}

enum SLUnit: String, Codable, CaseIterable, Identifiable {
    case mbps, mBps
    var id: String { rawValue }
    var title: String { self == .mbps ? "Mbps" : "MB/s" }
    func value(_ mbps: Double) -> Double { self == .mbps ? mbps : mbps / 8 }
}

/// 测法：一次测速里每一个会影响结果的决定。全部在「测法」抽屉里摊开、可改；
/// 下面的初值只是出厂配方，界面上标明哪些被改过、可逐项恢复。脚本自己不带任何取值。
struct SLParams: Codable, Equatable {
    // 通用
    var duration: Int = 10
    var directions: SLDirections = .both
    var unit: SLUnit = .mbps
    var tick: Double = 0.1
    var idleSeconds: Int = 3
    var dns: String = "223.5.5.5"
    /// 空载/负载延迟 ping 谁；空 = 公网测速 ping 上面的 DNS，iperf3 ping 对端。
    var pingHost: String = ""
    var userAgent: String = "Mozilla/5.0 (Macintosh) WgSense-SpeedLab"
    /// 查出口 IP 的地址；空 = 不查。
    var exitIPURL: String = "https://myip.ipip.net/"
    var watchdogExtra: Int = 60
    /// 探测时解析哪个域名来判断系统 DNS 是否被 fake-ip 接管。
    var probeDomain: String = "www.baidu.com"

    // 公网 · 选源
    var pickDownConns: Int = 3
    var pickDownSeconds: Int = 3
    var pickUpMB: Int = 64
    var pickUpSeconds: Int = 2
    var pickSlowRatio: Double = 4
    var pickDownKeep: Int = 3
    var pickUpKeep: Int = 2
    var redirectMax: Int = 5
    var redirectTimeout: Int = 8
    var retireAfter: Int = 3

    // 公网 · 下行 / 上行
    var httpDownThreads: Int = 12
    var stallMBps: Double = 1
    var stallSeconds: Int = 2
    var httpUpThreads: Int = 4
    var upChunkMB: Int = 8192

    // iperf3
    var iperfStreams: Int = 4
    var iperfPort: Int = 5201
    var iperfPortSpan: Int = 9
    var iperfRate: SLRateSource = .tool
    var directionGap: Int = 1
    var iperfServerTTL: Int = 600

    // 结果
    var statistic: SLStatistic = .median
    var warmupSeconds: Double = 2
    var peakWindow: Double = 1
    var flatWindow: Double = 4
    var flatTolerance: Double = 0.05
    var flatShare: Double = 0.9

    init() {}

    /// 旧版存档只有部分字段：缺的按出厂配方补，不整份丢弃。
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: Key.self)
        func take<T: Decodable>(_ k: WritableKeyPath<SLParams, T>, _ name: String) {
            if let key = Key(stringValue: name), let v = try? c.decodeIfPresent(T.self, forKey: key) { self[keyPath: k] = v }
        }
        take(\.duration, "duration"); take(\.directions, "directions"); take(\.unit, "unit"); take(\.tick, "tick")
        take(\.idleSeconds, "idleSeconds"); take(\.dns, "dns"); take(\.pingHost, "pingHost"); take(\.userAgent, "userAgent")
        take(\.exitIPURL, "exitIPURL"); take(\.watchdogExtra, "watchdogExtra")
        take(\.probeDomain, "probeDomain"); take(\.iperfServerTTL, "iperfServerTTL")
        take(\.pickDownConns, "pickDownConns"); take(\.pickDownSeconds, "pickDownSeconds"); take(\.pickUpMB, "pickUpMB")
        take(\.pickUpSeconds, "pickUpSeconds"); take(\.pickSlowRatio, "pickSlowRatio"); take(\.pickDownKeep, "pickDownKeep")
        take(\.pickUpKeep, "pickUpKeep"); take(\.redirectMax, "redirectMax"); take(\.redirectTimeout, "redirectTimeout")
        take(\.retireAfter, "retireAfter")
        take(\.httpDownThreads, "httpDownThreads"); take(\.stallMBps, "stallMBps"); take(\.stallSeconds, "stallSeconds")
        take(\.httpUpThreads, "httpUpThreads"); take(\.upChunkMB, "upChunkMB")
        take(\.iperfStreams, "iperfStreams"); take(\.iperfPort, "iperfPort"); take(\.iperfPortSpan, "iperfPortSpan")
        take(\.iperfRate, "iperfRate"); take(\.directionGap, "directionGap")
        take(\.statistic, "statistic"); take(\.warmupSeconds, "warmupSeconds"); take(\.peakWindow, "peakWindow")
        take(\.flatWindow, "flatWindow"); take(\.flatTolerance, "flatTolerance"); take(\.flatShare, "flatShare")
    }

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// 传给执行端脚本的全部变量。
    var scriptVars: [String: String] {
        [
            "DUR": "\(duration)", "DIRS": directions.script, "TICK": Self.num(tick), "IDLE": "\(idleSeconds)",
            "DNS": dns, "PING_HOST": pingHost, "UA": userAgent, "EXIT_URL": exitIPURL, "WATCHDOG": "\(watchdogExtra)", "PROBE_DOMAIN": probeDomain,
            "PICK_DL_CONNS": "\(pickDownConns)", "PICK_DL_SEC": "\(pickDownSeconds)",
            "PICK_UL_MB": "\(pickUpMB)", "PICK_UL_SEC": "\(pickUpSeconds)", "PICK_RATIO": Self.num(pickSlowRatio),
            "PICK_DL_KEEP": "\(pickDownKeep)", "PICK_UL_KEEP": "\(pickUpKeep)",
            "REDIR_MAX": "\(redirectMax)", "REDIR_TIMEOUT": "\(redirectTimeout)",
            "DL_THREADS": "\(httpDownThreads)", "STALL_BPS": "\(Int(stallMBps * 1_048_576))", "STALL_SEC": "\(stallSeconds)",
            "UL_THREADS": "\(httpUpThreads)", "UL_CHUNK_MB": "\(upChunkMB)",
            "IPERF_P": "\(iperfStreams)", "IPERF_PORT": "\(iperfPort)", "IPERF_SPAN": "\(iperfPortSpan)",
            "IPERF_RATE": iperfRate.rawValue, "GAP": "\(directionGap)", "IPERF_TTL": "\(iperfServerTTL)",
        ]
    }

    static func num(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%g", v)
    }
}

/// 速率从哪来：读网卡字节计数，或用测速工具自己报的数。
enum SLRateSource: String, Codable, CaseIterable, Identifiable {
    case nic, tool
    var id: String { rawValue }
    var title: String { self == .nic ? String(localized: "网卡计数", bundle: .wgLocalized) : String(localized: "iperf3 自报", bundle: .wgLocalized) }
}

/// 上行读数在哪一端量的。发送端的数字是写进发送缓冲的量，会比链路实际到达的更抖、峰值更高；
/// 接收端才是到达量。下行本来就是接收端，不需要这个。
enum SLRateSide: String, Codable {
    case receiver, sender
    /// HUD 用。
    var key: String { rawValue }
    var title: String { self == .receiver ? String(localized: "接收端", bundle: .wgLocalized) : String(localized: "发送端", bundle: .wgLocalized) }
}

/// 稳定值取什么统计量。
enum SLStatistic: String, Codable, CaseIterable, Identifiable {
    case median, mean
    var id: String { rawValue }
    var title: String { self == .median ? String(localized: "中位数", bundle: .wgLocalized) : String(localized: "平均值", bundle: .wgLocalized) }
}

// MARK: - 测量过程

enum SLPhase: String, Codable {
    case prepare, idle, pick, dl, ul, done
    var title: String {
        switch self {
        case .prepare: return String(localized: "准备", bundle: .wgLocalized)
        case .idle: return String(localized: "空载延迟", bundle: .wgLocalized)
        case .pick: return String(localized: "选源", bundle: .wgLocalized)
        case .dl: return String(localized: "下行", bundle: .wgLocalized)
        case .ul: return String(localized: "上行", bundle: .wgLocalized)
        case .done: return String(localized: "完成", bundle: .wgLocalized)
        }
    }
}

/// 执行端脚本的一行事件（`@{"ev":…}`）。
struct SLEvent: Decodable {
    var ev: String
    var k: String?
    var v: String?
    var ph: String?
    var rx: Double?
    var tx: Double?
    var rtt: Double?
    var msg: String?
    var name: String?
    var ip: String?
    var iface: String?
    /// src：该候选源是否入选；conn：第几条连接。
    var keep: Bool?
    var n: Int?
    /// r：iperf3 区间的起止秒。
    var a: Double?
    var b: Double?

    static func parse(_ line: Substring) -> SLEvent? {
        guard line.first == "@" else { return nil }
        return try? JSONDecoder().decode(SLEvent.self, from: Data(line.dropFirst().utf8))
    }
}

/// 一个方向的统计：稳定值取预热 2 秒后的中位数；
/// 最后 4 秒里九成采样贴着中位数（±5%）= 平顶：被运营商限速，或到了网口上限。
struct SLStat: Codable, Equatable {
    var stable: Double
    var peak: Double
    var flat: Bool
    var loadedRTT: Double?

    /// - tick: 采样间隔（秒）；m: 测法里的结果算法。
    static func from(_ series: [Double], rtts: [Double], tick: Double, method m: SLParams) -> SLStat? {
        guard !series.isEmpty else { return nil }
        let perSecond = 1 / max(tick, 0.05)
        let warmup = Int((m.warmupSeconds * perSecond).rounded())
        let body = series.count > warmup + Int(2 * perSecond) ? Array(series.dropFirst(warmup)) : series
        let stable = m.statistic == .median ? Self.median(body) : body.reduce(0, +) / Double(body.count)
        let tail = body.suffix(Int((m.flatWindow * perSecond).rounded()))
        let close = tail.filter { stable > 0 && abs($0 - stable) / stable < m.flatTolerance }.count
        let flat = Double(tail.count) >= m.flatWindow * perSecond * 0.75 && stable > 1 && Double(close) >= Double(tail.count) * m.flatShare
        // 峰值取 peakWindow 秒滑动平均的最大值，不让单个采样的毛刺当峰值
        let w = max(1, Int((m.peakWindow * perSecond).rounded()))
        var peak = 0.0
        if series.count >= w {
            for i in 0...(series.count - w) {
                peak = max(peak, series[i..<(i + w)].reduce(0, +) / Double(w))
            }
        } else {
            peak = series.max() ?? 0
        }
        return SLStat(stable: stable, peak: peak, flat: flat,
                      loadedRTT: rtts.isEmpty ? nil : Self.median(rtts))
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}

// MARK: - 动效时间线（HUD 只读这些带时刻的事件）

/// 候选源的试跑结果。
struct SLSourceResult: Identifiable, Equatable {
    var id: String { dir + url }
    var dir: String
    var url: String
    var mbps: Double
    var keep: Bool
    var at: Date
    var host: String { URL(string: url)?.host ?? url }
    /// 短名：去掉通用后缀后的最后一段。baidupcs.com → baidupcs，dldir1.qq.com → qq，test.ustc.edu.cn → ustc。
    var shortName: String {
        let generic: Set<String> = ["com", "cn", "net", "org", "edu", "gov", "ac", "io", "co"]
        let parts = host.split(separator: ".").map(String.init)
        return parts.dropLast().last(where: { !generic.contains($0) }) ?? host
    }
}

/// 一次连接中途断开后重连。
struct SLConnEvent: Equatable {
    var dir: String
    var n: Int
    var at: Date
}

/// 带到达时刻的采样。
struct SLTimedSample: Equatable {
    var v: Double
    var rtt: Double?
    var at: Date
}

// MARK: - 统计轨迹（HUD 每帧只查表，不重算）

/// 一个量随时间的取值：每个新样本到达时记一笔，查询 = 时刻 t 之前最后一笔。
struct SLTrail {
    private(set) var at: [Date] = []
    private(set) var v: [Double] = []

    mutating func append(_ value: Double, _ t: Date) { at.append(t); v.append(value) }

    func value(at t: Date) -> Double? {
        var lo = 0, hi = at.count
        while lo < hi { let m = (lo + hi) / 2; if at[m] <= t { lo = m + 1 } else { hi = m } }
        return lo == 0 ? nil : v[lo - 1]
    }
}

/// 一次测量里 HUD 要的全部统计。样本到达时增量更新一次（每秒约 10 次），
/// 而不是每帧（120 次 × 平滑窗口 8 点）重新排序求中位数。
struct SLTrails {
    /// 按到达时间回放样本重建。上行的区间可能和其余不同（接收端的区间由服务端决定）。
    static func replay(idle: [SLTimedSample], down: [SLTimedSample], up: [SLTimedSample],
                       tick: Double, upTick: Double, method: SLParams) -> SLTrails {
        var t = SLTrails()
        let all = idle.map { ("idle", $0) } + down.map { ("dl", $0) } + up.map { ("ul", $0) }
        for (ph, s) in all.sorted(by: { $0.1.at < $1.1.at }) {
            t.add(ph, value: s.v, rtt: s.rtt, at: s.at, tick: ph == "ul" ? upTick : tick, method: method)
        }
        return t
    }

    var idleMedian = SLTrail(), loadMedian = SLTrail()
    var downStable = SLTrail(), upStable = SLTrail()
    var rttLo = SLTrail(), rttHi = SLTrail()
    private(set) var downStat: SLStat?
    private(set) var upStat: SLStat?
    private var idle: [Double] = [], load: [Double] = []
    private var dl: [Double] = [], ul: [Double] = [], dlR: [Double] = [], ulR: [Double] = []
    private var lo = Double.infinity, hi = -Double.infinity

    mutating func add(_ phase: String, value: Double, rtt sampleRTT: Double?, at t: Date, tick: Double, method: SLParams) {
        // 空载样本的值本身就是延迟
        let rtt = phase == "idle" ? value : sampleRTT
        if let rtt {
            lo = min(lo, rtt); hi = max(hi, rtt)
            rttLo.append(lo, t); rttHi.append(hi, t)
        }
        switch phase {
        case "idle":
            guard let rtt else { return }
            idle.append(rtt); idleMedian.append(SLStat.median(idle), t)
        case "dl", "ul":
            if let rtt { load.append(rtt); loadMedian.append(SLStat.median(load), t) }
            if phase == "dl" {
                dl.append(value); if let rtt { dlR.append(rtt) }
                downStat = SLStat.from(dl, rtts: dlR, tick: tick, method: method)
                if let s = downStat { downStable.append(s.stable, t) }
            } else {
                ul.append(value); if let rtt { ulR.append(rtt) }
                upStat = SLStat.from(ul, rtts: ulR, tick: tick, method: method)
                if let s = upStat { upStable.append(s.stable, t) }
            }
        default:
            break
        }
    }
}

// MARK: - 结果与历史

struct SLResult: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    var runner: String
    var target: String
    var path: String
    var engine: String
    /// 复用这条线路用的身份（旧记录没有，按名字回查）。iface 为空 = 系统路由。
    var runnerID: String?
    var targetID: String?
    var iface: String?
    /// 这次用的测法（旧记录没有）。
    var method: SLParams?
    var down: SLStat?
    var up: SLStat?
    var idleRTT: Double?
    /// 物理口协商速率（Mbps），读不到为空。
    var linkMbps: Int?
    var linkText: String = ""
    var exit: String = ""
    var sources: [String] = []
    var downSeries: [Double] = []
    var upSeries: [Double] = []
    /// 采样间隔（秒）；旧记录没有这个字段，按 1 秒算。
    var tick: Double?
    /// 上行读数在哪一端量的、接收端的区间（秒）；旧记录没有，都按发送端和 tick 算。
    var upSide: SLRateSide?
    var upTick: Double?
    var error: String?

    /// 线路键：同一组 A/B/C 的历史互相比较。
    var sceneKey: String { "\(runner)|\(path)|\(target)" }
}
