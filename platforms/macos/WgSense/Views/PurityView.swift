import SwiftUI

// 纯良：一条不变量 ——「去境外的包，要么从可信出口走，要么根本不出去」。
//
// 页面的组织方式与概览页同构（不是照搬内容）：
//   1. 主视觉条：徽标 + 结论 + 一句事实 + 唯一的主操作；
//   2. 出口图：本页的主图 —— 五条去向在物理网卡这道闸上各自放行还是拒绝；
//   3. 卡片网格：每个检查点 / 选项一张卡，开关在卡片右上角；
//   4. 列表：放行名单、运行信息，只读事实，右侧等宽读数。
//
// 三态按「谁是出口」划分：
//   S1 出口在线：全局隧道连着，物理网卡只放行局域网与 WG 服务器（隧道锁定）；
//   S2 在家：没有本机出口，境外流量交给家里网关，物理网卡放行国内与局域网；
//   S3 离家无出口：同样的规则，但没有网关兜底，境外一律拒绝。

/// 当前所在的位置（由隧道与所在网络决定，不由设置决定）。
enum PurityPosition: Equatable, CaseIterable {
    case exit, home, away

    var code: String {
        switch self {
        case .exit: return "S1"
        case .home: return "S2"
        case .away: return "S3"
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .exit: return "出口在线"
        case .home: return "在家"
        case .away: return "离家无出口"
        }
    }

    var condition: LocalizedStringKey {
        switch self {
        case .exit: return "全局隧道已连接"
        case .home: return "在受信任网络，隧道按设计保持断开"
        case .away: return "不在受信任网络，隧道未连接"
        }
    }

    /// 这一态下物理网卡放行什么。
    var allows: LocalizedStringKey {
        switch self {
        case .exit: return "只放行局域网与 WG 服务器，其余必须走隧道"
        case .home: return "放行国内与局域网，境外交给家里网关"
        case .away: return "放行国内与局域网，境外一律拒绝"
        }
    }
}

/// 一个检查点：不变量在某一处是否成立。
struct PurityCheck: Identifiable, Equatable {
    enum Verdict: Equatable { case holds, fails, idle }
    /// 不成立时可执行的动作。
    enum Fix: Equatable { case enableBlock, enableLock }
    enum Kind: String { case direct, lock, ipv6, dns }

    var kind: Kind
    var verdict: Verdict
    /// 当前事实，一行。
    var fact: String
    var fix: Fix? = nil

    var id: String { kind.rawValue }

    var name: LocalizedStringKey {
        switch kind {
        case .direct: return "境外直连"
        case .lock: return "隧道锁定"
        case .ipv6: return "IPv6"
        case .dns: return "域名查询"
        }
    }

    /// 术语定义，全页只在这里出现一次（悬停显示）。
    var definition: LocalizedStringKey {
        switch kind {
        case .direct: return "境外直连：不经隧道或网关代理、从物理网卡直接发往境外地址的连接。开启后立即拒绝，不等超时。"
        case .lock: return "隧道锁定：全局隧道连着时，物理网卡只放行局域网与 WG 服务器，绑定物理网卡的程序也不能绕开隧道。隧道断开即解除。"
        case .ipv6: return "IPv6：与 IPv4 并行的另一套地址。隧道没有 IPv6 出口时直接拒绝，程序退回 IPv4。"
        case .dns: return "域名查询：连接之前先向 DNS 服务器询问地址。查询发给谁，谁就知道访问目标。"
        }
    }

    var fixTitle: LocalizedStringKey? {
        switch fix {
        case .enableBlock: return "启用拦截"
        case .enableLock: return "启用隧道锁定"
        case nil: return nil
        }
    }
}

/// 页面与磁贴共用的纯良状态，全部由 daemon 的状态推出。
struct PurityPresentation: Equatable {
    enum Mode: Equatable {
        case unavailable          // 服务没给出拦截状态
        case off                  // 没有任何规则在生效
        case domestic             // 国内模式：所有出口只放行国内
        case on                   // 按三态规则拦截
    }

    var mode: Mode
    var position: PurityPosition
    /// 隧道锁定正在生效。
    var locked: Bool
    var blocked: UInt64
    var allowCount: Int
    var checks: [PurityCheck]
    /// 出口是内置 mihomo（代理锁定），而不是 WireGuard 隧道。
    var viaProxy: Bool

    /// `settings` 只有页面拿得到（磁贴只有轮询状态），缺省时少一条「总开关已关」的判断。
    init(status: DaemonStatus?, tunnelUp: Bool, settings: FirewallSettings? = nil, proxyDNSService: String? = nil) {
        let fw = status?.firewall
        viaProxy = fw?.lock_kind == "proxy" || (status?.exit == "mihomo" && proxyDNSService != nil)
        if tunnelUp, status?.coverage?.full_tunnel == true {
            position = .exit
        } else if viaProxy {
            position = .exit
        } else if status?.isTrustedNetwork == true {
            position = .home
        } else {
            position = .away
        }
        locked = fw?.locked == true
        blocked = fw?.blocked_packets ?? 0
        allowCount = fw?.allowed_hosts?.count ?? 0
        if let fw {
            mode = fw.forced ? .domestic : (fw.active ? .on : .off)
        } else {
            mode = .unavailable
        }
        checks = []
        guard mode != .unavailable else { return }
        checks = [
            Self.directCheck(mode: mode, settings: settings),
            Self.lockCheck(mode: mode, position: position, locked: locked, blocked: blocked),
            Self.ipv6Check(mode: mode, position: position, v6: status?.coverage?.ipv6),
            Self.dnsCheck(mode: mode, position: position,
                          dns: viaProxy ? proxyDNSService.map { ["内置代理（\($0)）"] } : status?.coverage?.dns),
        ]
    }

    var failing: [PurityCheck] { checks.filter { $0.verdict == .fails } }

    /// 结论：磁贴状态行与页面第一层共用。
    var verdict: LocalizedStringKey {
        switch mode {
        case .unavailable: return "不可用"
        case .off: return "未启用"
        case .domestic, .on:
            let n = failing.count
            return n == 0 ? "成立" : "\(n) 项不成立"
        }
    }

    var needsAttention: Bool { mode == .off || !failing.isEmpty }

    /// 处境标注（等宽注记用）。
    var code: String {
        switch mode {
        case .unavailable: return "N/A"
        case .off: return "OFF"
        case .domestic: return "CN"
        case .on: return position.code
        }
    }

    var situation: LocalizedStringKey {
        switch mode {
        case .unavailable: return "服务不可用"
        case .off: return "拦截未启用"
        case .domestic: return "国内模式"
        case .on: return position.title
        }
    }

    // MARK: 检查点

    private static func directCheck(mode: Mode, settings: FirewallSettings?) -> PurityCheck {
        switch mode {
        case .off:
            return PurityCheck(kind: .direct, verdict: .fails, fact: "未拦截：境外连接可从物理网卡直接出去", fix: .enableBlock)
        case .domestic:
            return PurityCheck(kind: .direct, verdict: .holds, fact: "国内模式：所有出口只放行国内")
        default:
            if settings?.auto_block == false {
                return PurityCheck(kind: .direct, verdict: .fails,
                                   fact: "仅靠隧道锁定在拦，隧道断开后不再拦截", fix: .enableBlock)
            }
            return PurityCheck(kind: .direct, verdict: .holds, fact: "物理网卡上的境外直连立即拒绝")
        }
    }

    private static func lockCheck(mode: Mode, position: PurityPosition, locked: Bool, blocked: UInt64) -> PurityCheck {
        guard mode == .on, position == .exit else {
            return PurityCheck(kind: .lock, verdict: .idle,
                               fact: mode == .domestic ? "国内模式下不适用" : "全局隧道未连接，不适用")
        }
        if locked {
            return PurityCheck(kind: .lock, verdict: .holds,
                               fact: blocked == 0 ? "生效：没有程序试图绕开隧道" : "生效：已拒绝 \(blocked) 个绕开隧道的包")
        }
        return PurityCheck(kind: .lock, verdict: .fails,
                           fact: "已关闭：绑定物理网卡的程序可绕开隧道，直连国内段与放行名单", fix: .enableLock)
    }

    private static func ipv6Check(mode: Mode, position: PurityPosition, v6: TunnelIPv6Status?) -> PurityCheck {
        guard mode == .on else {
            return mode == .domestic
                ? PurityCheck(kind: .ipv6, verdict: .holds, fact: "只放行国内 IPv6 段")
                : PurityCheck(kind: .ipv6, verdict: .fails, fact: "未拦截：IPv6 同样直接出网")
        }
        guard position == .exit, let v6 else {
            return PurityCheck(kind: .ipv6, verdict: .holds, fact: "与 IPv4 同一套规则：只放行国内段与局域网")
        }
        switch v6.state {
        case "tunnel":
            return PurityCheck(kind: .ipv6, verdict: .holds, fact: "公网 IPv6 走隧道")
        case "blocked", "probing":
            return PurityCheck(kind: .ipv6, verdict: .holds, fact: "隧道无 IPv6 出口：公网 IPv6 立即拒绝，程序改用 IPv4")
        default:
            return PurityCheck(kind: .ipv6, verdict: .fails, fact: "隧道未接管 IPv6：公网 IPv6 可能从物理网卡直接出去")
        }
    }

    private static func dnsCheck(mode: Mode, position: PurityPosition, dns: [String]?) -> PurityCheck {
        if mode == .off {
            return PurityCheck(kind: .dns, verdict: .fails, fact: "发给当前网络的 DNS，访问目标对其可见")
        }
        switch position {
        case .exit:
            if let dns, !dns.isEmpty {
                return PurityCheck(kind: .dns, verdict: .holds, fact: "经隧道发给 \(dns.joined(separator: ", "))")
            }
            return PurityCheck(kind: .dns, verdict: .fails, fact: "配置未指定 DNS：查询仍发给当前网络")
        case .home:
            return PurityCheck(kind: .dns, verdict: .holds, fact: "发给家里网关，由网关代理接管")
        case .away:
            return PurityCheck(kind: .dns, verdict: .fails, fact: "发给当前网络的 DNS：连接被拒，但访问目标对其可见；隧道连上后消失")
        }
    }
}

struct PurityView: View {
    @EnvironmentObject var client: DaemonClient
    @State private var saving = false
    @State private var hostDraft = ""

    /// 状态优先取轮询里的那份（计数会更新），设置接口那份只在打开和保存时刷新。
    private var status: FirewallStatus? { client.status?.firewall ?? client.firewall?.status }
    private var settings: FirewallSettings? { client.firewall?.settings }
    private var purity: PurityPresentation {
        PurityPresentation(status: client.status, tunnelUp: client.isTunnelUp, settings: settings,
                           proxyDNSService: client.mihomo?.dns_service)
    }

    var body: some View {
        let p = purity
        return VStack(alignment: .leading, spacing: WgSpace.m) {
            WgPageHeader(title: "纯良", subtitleText: "WGSENSE · PURITY", word: "PURITY") { EmptyView() }
            hero(p)
            PurityEgressDiagram(purity: p, interfaces: status?.interfaces ?? [])
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: WgSpace.m), GridItem(.flexible(), spacing: WgSpace.m)],
                spacing: WgSpace.m
            ) {
                ForEach(p.checks) { check in checkCard(check) }
                optionCards
            }
            allowList(p)
            runtimeList(p)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: WgLayout.pageMaxWidth, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .top)
        .task { await client.fetchFirewall() }
    }

    // MARK: - 主视觉条：结论 + 唯一主操作

    private func hero(_ p: PurityPresentation) -> some View {
        HStack(spacing: WgSpace.m) {
            StatusOrb(symbol: p.needsAttention ? "hand.raised" : "hand.raised.fill",
                      tint: p.needsAttention ? .orange : .green,
                      isActive: p.mode == .on || p.mode == .domestic, isBusy: saving)
            VStack(alignment: .leading, spacing: WgSpace.xs) {
                Text(p.verdict)
                    .font(.system(size: WgType.readout, weight: .semibold))
                    .foregroundStyle(p.needsAttention ? WgInk.warn : WgInk.ink)
                    .contentTransition(.opacity)
                Text(verbatim: heroDetail(p))
                    .font(.system(size: WgType.body))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 12)
            // 主操作只有一个：第一项可修复的不成立项
            if let check = p.failing.first(where: { $0.fix != nil }),
               let fix = check.fix, let title = check.fixTitle, let current = settings {
                Button(title) { apply(fix, to: current) }
                    .buttonStyle(WgCapsuleButtonStyle(tint: .orange))
                    .disabled(saving)
            }
        }
        .wgPadding(.m)
        .wgInteractiveSurface(cornerRadius: WgDesign.heroRadius)
    }

    private func heroDetail(_ p: PurityPresentation) -> String {
        switch p.mode {
        case .unavailable:
            return client.firewallError ?? "需要以 root 运行的正式网络服务"
        case .off:
            return "没有规则在生效：境外连接可从物理网卡直接出去"
        case .domestic, .on:
            if let error = status?.error { return "规则应用失败：\(error)" }
            if let first = p.failing.first { return first.fact }
            return "去境外的包只能从可信出口走 · \(p.code)"
        }
    }

    private func apply(_ fix: PurityCheck.Fix, to current: FirewallSettings) {
        var next = client.firewall?.settings ?? current
        switch fix {
        case .enableBlock: next.auto_block = true
        case .enableLock: next.allow_bypass = false
        }
        save(next)
    }

    // MARK: - 卡片网格：检查点与选项

    private func checkCard(_ check: PurityCheck) -> some View {
        let (symbol, value): (String, Text) = {
            let symbol: String = switch check.kind {
            case .direct: "hand.raised"
            case .lock: "lock"
            case .ipv6: "6.circle"
            case .dns: "text.magnifyingglass"
            }
            switch check.verdict {
            case .holds: return (symbol, Text("成立"))
            case .fails: return (symbol, Text("不成立").foregroundColor(WgInk.warn))
            case .idle: return (symbol, Text("不适用").foregroundColor(WgInk.ink3))
            }
        }()
        return InfoCard(symbol: symbol, tint: .gray, title: check.name, value: value,
                        detail: Text(verbatim: check.fact)) {
            checkControl(check)
        }
        .help(Text(check.definition))
    }

    @ViewBuilder
    private func checkControl(_ check: PurityCheck) -> some View {
        switch check.kind {
        case .direct:
            if let block = binding(\.auto_block) { toggle(block) }
        case .lock:
            if let bypass = binding(\.allow_bypass) {
                toggle(Binding(get: { bypass.wrappedValue != true }, set: { bypass.wrappedValue = !$0 }))
            }
        case .ipv6, .dns:
            EmptyView()
        }
    }

    @ViewBuilder
    private var optionCards: some View {
        if let probes = binding(\.block_probes), let domestic = binding(\.force_domestic),
           let block = binding(\.auto_block) {
            // 新版服务总会返回 block_probes；没有这个字段 = 运行中的服务还不支持，开关不能装作生效
            let supported = probes.wrappedValue != nil
            let allowed = supported && probes.wrappedValue != true
            InfoCard(symbol: "point.3.connected.trianglepath.dotted", tint: .gray, title: "诊断探测",
                     value: Text(allowed ? "放行" : "拦截"),
                     detail: Text(supported ? "ping / traceroute 的 ICMP 回显；隧道锁定与国内模式下不放"
                                            : "当前网络服务不支持，诊断探测仍被拦截")) {
                toggle(Binding(get: { allowed }, set: { probes.wrappedValue = !$0 }))
                    .disabled(!block.wrappedValue || !supported)
            }
            InfoCard(symbol: "lock.fill", tint: .gray, title: "国内模式",
                     value: Text(domestic.wrappedValue ? "开启" : "关闭"),
                     detail: Text("隧道与网关代理的境外流量也拒绝")) {
                toggle(domestic)
            }
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<FirewallSettings, Value>) -> Binding<Value>? {
        guard let settings else { return nil }
        return Binding(
            get: { (client.firewall?.settings ?? settings)[keyPath: keyPath] },
            set: { newValue in
                var next = client.firewall?.settings ?? settings
                next[keyPath: keyPath] = newValue
                save(next)
            }
        )
    }

    private func save(_ settings: FirewallSettings) {
        Task {
            saving = true
            if !(await client.updateFirewall(settings)) { await client.fetchFirewall() }
            await client.refresh()
            saving = false
        }
    }

    private func toggle(_ isOn: Binding<Bool>) -> some View {
        Toggle("", isOn: isOn)
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
    }

    // MARK: - 列表：放行名单

    private func allowList(_ p: PurityPresentation) -> some View {
        list("放行名单") {
            // 新版服务总会返回 allow_hosts；没有这个字段 = 运行中的服务还不支持，不能装作生效
            if let current = settings, let hosts = current.allow_hosts {
                ForEach(hosts, id: \.self) { host in
                    row(symbol: "checkmark.shield", name: LocalizedStringKey(host),
                        value: allowValue(host), detail: allowDetail(host)) {
                        Button {
                            var next = client.firewall?.settings ?? current
                            next.allow_hosts = hosts.filter { $0 != host }
                            save(next)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("移出放行名单")
                    }
                    rowRule
                }
                row(symbol: "plus", name: "添加", value: "",
                    detail: "本机代理软件直连的自建节点。按解析出的 IP 放行，同一 IP 上的其他站点一并放开") {
                    HStack(spacing: WgSpace.s) {
                        TextField("jp.example.com", text: $hostDraft)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)
                            .onSubmit { addHost(current) }
                        Button("放行") { addHost(current) }
                            .disabled(hostDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            } else {
                row(symbol: "plus", name: "放行名单不可用", value: "",
                    detail: settings == nil ? (client.firewallError ?? "需要以 root 运行的正式网络服务")
                                            : "需要新版网络服务：当前服务不支持") { EmptyView() }
            }
        }
    }

    private func addHost(_ current: FirewallSettings) {
        let host = hostDraft.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        var next = client.firewall?.settings ?? current
        next.allow_hosts = (next.allow_hosts ?? []) + [host]
        hostDraft = ""
        save(next)
    }

    private func allowValue(_ host: String) -> String {
        guard let status, status.active, status.locked != true, !status.forced else { return "未放行" }
        let ips = status.allowed_hosts?.first { $0.host == host }?.ips ?? []
        return ips.isEmpty ? "未解析" : ips.joined(separator: "  ")
    }

    private func allowDetail(_ host: String) -> String {
        guard let status, status.active else { return "拦截未启用" }
        if status.locked == true { return "隧道锁定生效中，放行名单不参与；隧道断开后生效" }
        if status.forced { return "国内模式下不放行" }
        return "每分钟重新解析，跟随 DDNS"
    }

    // MARK: - 列表：运行信息

    private func runtimeList(_ p: PurityPresentation) -> some View {
        list("运行信息") {
            row(symbol: "number", name: "拒绝计数", value: "\(p.blocked) 包",
                detail: "本套规则加载以来被拒绝的出站包；规则重新加载后归零") { EmptyView() }
            rowRule
            row(symbol: "cable.connector", name: "生效网卡",
                value: status?.interfaces?.joined(separator: " ") ?? "—",
                detail: status?.error.map { "规则应用失败：\($0)" } ?? status?.reason ?? "—") { EmptyView() }
            rowRule
            row(symbol: "calendar.badge.clock", name: "国内 IP 段", value: "发版快照",
                detail: "不随时间更新；隧道锁定生效时不使用这份名单") { EmptyView() }
            rowRule
            row(symbol: "power", name: "未覆盖时段", value: "开机 · pf 关闭",
                detail: "系统启动到网络服务装好规则之前没有拦截；其他软件整体关闭 pf 时失效且不会察觉") { EmptyView() }
            rowRule
            row(symbol: "exclamationmark.triangle", name: "紧急解除", value: "--firewall-clear",
                detail: "sudo /usr/local/libexec/wgsense-daemon --firewall-clear · 网络服务意外退出时规则保持生效") { EmptyView() }
        }
    }

    // MARK: - 列表构件（与概览「隧道覆盖」同一排法）

    private func list<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: WgSpace.s) {
            Text(title)
                .font(.system(size: WgType.sub, weight: .semibold))
                .foregroundStyle(.secondary)
                .wgPadding(.leading, .xs)
            VStack(spacing: 0) { content() }
                .wgInteractiveSurface(cornerRadius: WgDesign.cardRadius)
        }
    }

    private func row<Accessory: View>(symbol: String, name: LocalizedStringKey, value: String, detail: String,
                                      @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(alignment: .center, spacing: WgSpace.m) {
            WgSquareBadge(symbol: symbol, tint: .gray, size: 24)
            VStack(alignment: .leading, spacing: WgSpace.zero) {
                HStack(spacing: WgSpace.s) {
                    Text(name)
                        .font(.system(size: WgType.body, weight: .medium))
                    Spacer(minLength: 8)
                    Text(verbatim: value)
                        .font(.system(size: WgType.sub, design: .monospaced))
                        .foregroundStyle(.primary.opacity(0.8))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Text(verbatim: detail)
                    .font(.system(size: WgType.body))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            accessory()
        }
        .wgPadding(.horizontal, .l)
        .wgPadding(.vertical, .s)
    }

    private var rowRule: some View {
        Divider().opacity(0.5).wgInset(.leading, 50)
    }
}

// MARK: - 出口图

/// 本页主图：从本机出发的五条去向，在「物理网卡」这道闸上各自放行还是拒绝。
/// 五条去向固定不变，只换每条的结果 —— 三态切换时版面不跳。
struct PurityEgressDiagram: View {
    var purity: PurityPresentation
    var interfaces: [String]

    struct Lane: Identifiable {
        enum Result { case pass, reject, idle }
        var id: String
        var name: LocalizedStringKey
        var via: String
        var result: Result
        /// 这条的结果正是不变量不成立的地方。
        var breach: Bool = false
        /// 可信出口：加粗。
        var trunk: Bool = false
    }

    private var lanes: [Lane] {
        let p = purity
        let exit = p.position == .exit
        let home = p.position == .home
        switch p.mode {
        case .unavailable:
            return Self.all(.idle)
        case .off:
            var lanes = Self.all(.pass)
            lanes[0].result = exit ? .pass : .idle
            lanes[3].result = home ? .pass : .idle
            lanes[4].breach = true
            return lanes
        case .domestic:
            var lanes = Self.all(.reject)
            lanes[1].result = .pass
            lanes[2].result = .pass
            return lanes
        case .on:
            var lanes = Self.all(.reject)
            lanes[0].result = exit ? .pass : .idle
            lanes[1].result = .pass
            lanes[2].result = (exit && p.locked) ? .reject : .pass
            lanes[2].breach = exit && !p.locked
            lanes[3].result = exit ? (p.locked ? .reject : .pass) : (home ? .pass : .idle)
            // 放行名单是「境外直连一律拒绝」的例外，生效时在这一条上写明，不让图说的比规则多
            if p.allowCount > 0 { lanes[4].via = "其余全部地址 · 放行名单 \(p.allowCount) 项除外" }
            return lanes
        }
    }

    private static func all(_ result: Lane.Result) -> [Lane] {
        [
            Lane(id: "tunnel", name: "出口", via: "WG 隧道 / 代理内核", result: result, trunk: true),
            Lane(id: "lan", name: "局域网", via: "本地网段", result: result),
            Lane(id: "cn", name: "国内直连", via: "国内 IP 段", result: result),
            Lane(id: "gateway", name: "网关代理", via: "fake-ip → 家里网关", result: result),
            Lane(id: "foreign", name: "境外直连", via: "其余全部地址", result: result),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WgSpace.m) {
            HStack(spacing: WgSpace.m) {
                SlantShape().fill(WgInk.ink).frame(width: 12, height: 10)
                Text("出口图")
                    .font(.system(size: WgType.body, weight: .semibold))
                Text(verbatim: "WGSENSE / EGRESS")
                    .font(WgInk.mono(.micro))
                    .tracking(3)
                    .foregroundStyle(WgInk.ink3)
                Spacer(minLength: WgSpace.m)
                Text(purity.situation)
                    .font(.system(size: WgType.body, weight: .medium))
                Text(verbatim: purity.code)
                    .font(WgInk.mono(.caption, .medium))
                    .foregroundStyle(WgInk.ink3)
            }
            Rectangle().fill(WgInk.rule).frame(height: 1)
            VStack(spacing: 0) {
                // 列头：本机 / 闸 / 结果
                HStack(spacing: WgSpace.m) {
                    Text("去向").frame(width: Self.nameWidth, alignment: .leading)
                    GeometryReader { geo in
                        Text(verbatim: "物理网卡 " + (interfaces.isEmpty ? "—" : interfaces.joined(separator: " ")))
                            .fixedSize()
                            .position(x: geo.size.width * Self.gate, y: geo.size.height / 2)
                    }
                    Text("结果").frame(width: Self.resultWidth, alignment: .trailing)
                }
                .font(WgInk.mono(.caption))
                .foregroundStyle(WgInk.ink3)
                .frame(height: 22)
                ForEach(lanes) { lane in laneRow(lane) }
            }
        }
        .wgPadding(.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .wgInteractiveSurface(cornerRadius: WgDesign.cardRadius)
        .accessibilityElement(children: .combine)
    }

    private static let nameWidth: CGFloat = 250
    private static let resultWidth: CGFloat = 44
    /// 闸在线段区域里的横向位置。
    private static let gate: CGFloat = 0.42

    private func laneRow(_ lane: Lane) -> some View {
        let ink: Color = lane.breach ? WgInk.warn : (lane.result == .idle ? WgInk.ink4 : WgInk.ink2)
        return HStack(spacing: WgSpace.m) {
            HStack(alignment: .firstTextBaseline, spacing: WgSpace.s) {
                Text(lane.name)
                    .font(.system(size: WgType.body, weight: lane.trunk ? .semibold : .medium))
                    .foregroundStyle(lane.result == .idle ? WgInk.ink3 : WgInk.ink)
                Text(verbatim: lane.via)
                    .font(WgInk.mono(.micro))
                    .foregroundStyle(WgInk.ink4)
                    .lineLimit(1)
            }
            .frame(width: Self.nameWidth, alignment: .leading)
            Canvas { ctx, size in
                let y = size.height / 2
                let gx = (size.width * Self.gate).rounded() + 0.5
                let width: CGFloat = lane.trunk && lane.result == .pass ? 3 : 1
                // 闸：贯穿所有行的竖线
                var gate = Path()
                gate.move(to: CGPoint(x: gx, y: 0)); gate.addLine(to: CGPoint(x: gx, y: size.height))
                ctx.stroke(gate, with: .color(WgInk.ink3), lineWidth: 1)
                // 本机 → 闸
                var approach = Path()
                approach.move(to: CGPoint(x: 0, y: y)); approach.addLine(to: CGPoint(x: gx, y: y))
                ctx.stroke(approach, with: .color(ink),
                           style: StrokeStyle(lineWidth: width, dash: lane.result == .idle ? [3, 4] : []))
                switch lane.result {
                case .pass:
                    // 过闸：延伸到右端，箭头收尾
                    var out = Path()
                    out.move(to: CGPoint(x: gx, y: y)); out.addLine(to: CGPoint(x: size.width - 6, y: y))
                    ctx.stroke(out, with: .color(ink), lineWidth: width)
                    var head = Path()
                    head.move(to: CGPoint(x: size.width - 7, y: y - 4))
                    head.addLine(to: CGPoint(x: size.width, y: y))
                    head.addLine(to: CGPoint(x: size.width - 7, y: y + 4))
                    head.closeSubpath()
                    ctx.fill(head, with: .color(ink))
                case .reject:
                    // 拒绝：止于闸前，一道挡板
                    let bar = CGRect(x: gx - 4, y: y - 6, width: 3, height: 12)
                    ctx.fill(Path(bar), with: .color(ink))
                case .idle:
                    break
                }
            }
            .frame(maxWidth: .infinity)
            Text(resultText(lane.result))
                .font(WgInk.mono(.caption, .medium))
                .foregroundStyle(lane.breach ? WgInk.warn : (lane.result == .pass ? WgInk.ink : WgInk.ink3))
                .frame(width: Self.resultWidth, alignment: .trailing)
        }
        .frame(height: 30)
    }

    private func resultText(_ result: Lane.Result) -> LocalizedStringKey {
        switch result {
        case .pass: return "放行"
        case .reject: return "拒绝"
        case .idle: return "未用"
        }
    }
}
