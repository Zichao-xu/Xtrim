import SwiftUI

// 纯良：一条不变量 ——「去境外的包，要么从可信出口走，要么根本不出去」。
//
// 页面三层：
//   1. 结论：不变量成立 / N 项不成立（全页唯一高光），不成立的项就地给出动作；
//   2. 检查项：一行一个检查点，状态、事实、开关同在一行，同一件事只出现一次；
//   3. 资料（默认折叠）：三态定义、放行名单、运行信息、已知局限。
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

    /// `settings` 只有页面拿得到（磁贴只有轮询状态），缺省时少一条「总开关已关」的判断。
    init(status: DaemonStatus?, tunnelUp: Bool, settings: FirewallSettings? = nil) {
        let fw = status?.firewall
        if tunnelUp, status?.coverage?.full_tunnel == true {
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
            Self.dnsCheck(mode: mode, position: position, dns: status?.coverage?.dns),
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
    @AppStorage("purity.open.states") private var statesOpen = false
    @AppStorage("purity.open.allow") private var allowOpen = false
    @AppStorage("purity.open.runtime") private var runtimeOpen = false
    @AppStorage("purity.open.limits") private var limitsOpen = false

    /// 状态优先取轮询里的那份（计数会更新），设置接口那份只在打开和保存时刷新。
    private var status: FirewallStatus? { client.status?.firewall ?? client.firewall?.status }
    private var settings: FirewallSettings? { client.firewall?.settings }
    private var purity: PurityPresentation {
        PurityPresentation(status: client.status, tunnelUp: client.isTunnelUp, settings: settings)
    }

    var body: some View {
        let p = purity
        return VStack(alignment: .leading, spacing: WgSpace.m) {
            WgPageHeader(title: "纯良", subtitleText: "WGSENSE · PURITY", word: "PURITY") { EmptyView() }
            verdictCard(p)
            checkTable(p)
            reference(p)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: WgLayout.pageMaxWidth, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .top)
        .task { await client.fetchFirewall() }
    }

    // MARK: - 第一层：结论

    private func verdictCard(_ p: PurityPresentation) -> some View {
        VStack(alignment: .leading, spacing: WgSpace.m) {
            VStack(alignment: .leading, spacing: WgSpace.xs) {
                HStack(spacing: WgSpace.s) {
                    Text(verbatim: p.code)
                    Text(p.situation)
                    if saving { ProgressView().controlSize(.mini) }
                }
                .font(WgInk.mono(.caption, .medium))
                .tracking(1.8)
                .foregroundStyle(WgInk.ink3)
                // 全页唯一高光：成立为墨色，不成立为警示色
                Text(p.verdict)
                    .font(.system(size: WgType.display, weight: .heavy))
                    .foregroundStyle(p.needsAttention ? WgInk.warn : WgInk.ink)
                    .contentTransition(.opacity)
                Text("去境外的包，要么从可信出口走，要么不出去。")
                    .font(.system(size: WgType.body))
                    .foregroundStyle(WgInk.ink3)
            }
            if p.mode == .unavailable {
                Text(verbatim: client.firewallError ?? "需要以 root 运行的正式网络服务")
                    .font(.system(size: WgType.body))
                    .foregroundStyle(.secondary)
            }
            // 不成立的项就地列出，动作只在这里出现一次
            ForEach(p.failing) { check in
                Rectangle().fill(WgInk.rule).frame(height: 1)
                HStack(alignment: .center, spacing: WgSpace.m) {
                    // 只点名；事实写在下方检查项那一行，不重复
                    Text(check.name)
                        .font(.system(size: WgType.body, weight: .semibold))
                    Spacer(minLength: WgSpace.l)
                    if let title = check.fixTitle, let fix = check.fix, let current = settings {
                        Button(title) { apply(fix, to: current) }
                            .buttonStyle(WgCapsuleButtonStyle(tint: WgInk.signal))
                            .disabled(saving)
                    } else {
                        Text("无开关")
                            .font(WgInk.mono(.caption, .medium))
                            .foregroundStyle(WgInk.ink4)
                    }
                }
            }
        }
        .wgPadding(.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .wgInteractiveSurface(cornerRadius: WgDesign.cardRadius)
    }

    private func apply(_ fix: PurityCheck.Fix, to current: FirewallSettings) {
        var next = client.firewall?.settings ?? current
        switch fix {
        case .enableBlock: next.auto_block = true
        case .enableLock: next.allow_bypass = false
        }
        save(next)
    }

    // MARK: - 第二层：检查项（状态 · 事实 · 开关）

    private func checkTable(_ p: PurityPresentation) -> some View {
        VStack(alignment: .leading, spacing: WgSpace.s) {
            subheading("检查项")
            VStack(spacing: 0) {
                ForEach(Array(p.checks.enumerated()), id: \.element.id) { index, check in
                    if index > 0 { tableRule }
                    tableRow(verdict: check.verdict, name: check.name, fact: check.fact) {
                        checkControl(check)
                    }
                    .help(Text(check.definition))
                }
                if let probes = binding(\.block_probes), let domestic = binding(\.force_domestic),
                   let block = binding(\.auto_block) {
                    // 新版服务总会返回 block_probes；没有这个字段 = 运行中的服务还不支持，开关不能装作生效
                    let probesSupported = probes.wrappedValue != nil
                    tableRule
                    tableRow(verdict: nil, name: "诊断探测",
                             fact: probesSupported ? "放行 ping / traceroute 的 ICMP 回显；隧道锁定与国内模式下不放"
                                                   : "当前网络服务不支持，诊断探测仍被拦截") {
                        toggle(Binding(get: { probesSupported && probes.wrappedValue != true },
                                       set: { probes.wrappedValue = !$0 }))
                            .disabled(!block.wrappedValue || !probesSupported)
                    }
                    tableRule
                    tableRow(verdict: nil, name: "国内模式", fact: "隧道与网关代理的境外流量也拒绝") {
                        toggle(domestic)
                    }
                }
            }
            .wgInteractiveSurface(cornerRadius: WgDesign.cardRadius)
        }
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

    /// 表格行：状态点 · 名称（定宽） · 事实（单行） · 控件。`verdict == nil` 是选项行，不参与结论。
    private func tableRow<Accessory: View>(verdict: PurityCheck.Verdict?, name: LocalizedStringKey, fact: String,
                                           @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(spacing: WgSpace.m) {
            Rectangle()
                .fill(dotColor(verdict))
                .frame(width: 6, height: 6)
            Text(name)
                .font(.system(size: WgType.body, weight: .medium))
                .frame(width: 76, alignment: .leading)
            Text(verbatim: fact)
                .font(.system(size: WgType.body))
                .foregroundStyle(verdict == .fails ? WgInk.ink2 : WgInk.ink3)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: WgSpace.m)
            accessory()
        }
        .wgPadding(.horizontal, .l)
        .frame(height: 40)
        .contentShape(Rectangle())
    }

    private func dotColor(_ verdict: PurityCheck.Verdict?) -> Color {
        switch verdict {
        case .holds: return WgInk.ink2
        case .fails: return WgInk.warn
        case .idle: return WgInk.ink4
        case nil: return .clear
        }
    }

    private var tableRule: some View {
        Rectangle().fill(WgInk.rule).frame(height: 1).wgInset(.leading, 34)
    }

    private func subheading(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.system(size: WgType.sub, weight: .semibold))
            .foregroundStyle(.secondary)
            .wgPadding(.leading, .xs)
            .wgPadding(.top, .s)
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

    // MARK: - 第三层：资料（默认折叠）

    private func reference(_ p: PurityPresentation) -> some View {
        VStack(alignment: .leading, spacing: WgSpace.s) {
            subheading("资料")
            VStack(spacing: 0) {
                drawer("三态定义", summary: p.mode == .on ? "当前 \(p.position.code)" : p.code, open: $statesOpen) {
                    statesContent(p)
                }
                tableRule
                drawer("放行名单", summary: "\(settings?.allow_hosts?.count ?? p.allowCount) 项", open: $allowOpen) {
                    allowContent
                }
                tableRule
                drawer("运行信息", summary: "已拒绝 \(p.blocked) 包", open: $runtimeOpen) {
                    runtimeContent(p)
                }
                tableRule
                drawer("已知局限", summary: "3 项", open: $limitsOpen) {
                    limitsContent
                }
            }
            .wgInteractiveSurface(cornerRadius: WgDesign.cardRadius)
        }
    }

    /// 折叠行：箭头 · 标题 · 右侧等宽摘要；展开内容缩进到标题下方。
    private func drawer<Content: View>(_ title: LocalizedStringKey, summary: String, open: Binding<Bool>,
                                       @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(WgDesign.spring) { open.wrappedValue.toggle() }
            } label: {
                HStack(spacing: WgSpace.m) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: WgType.micro, weight: .bold))
                        .rotationEffect(.degrees(open.wrappedValue ? 90 : 0))
                        .foregroundStyle(WgInk.ink3)
                        .frame(width: 6)
                    Text(title)
                        .font(.system(size: WgType.body, weight: .medium))
                    Spacer(minLength: WgSpace.m)
                    Text(verbatim: summary)
                        .font(WgInk.mono(.caption))
                        .foregroundStyle(WgInk.ink3)
                }
                .wgPadding(.horizontal, .l)
                .frame(height: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open.wrappedValue {
                VStack(alignment: .leading, spacing: WgSpace.s) { content() }
                    .wgInset(.leading, 34)
                    .wgPadding(.trailing, .l)
                    .wgPadding(.bottom, .m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
        }
    }

    private func statesContent(_ p: PurityPresentation) -> some View {
        ForEach(PurityPosition.allCases, id: \.code) { position in
            let current = p.mode == .on && p.position == position
            HStack(alignment: .firstTextBaseline, spacing: WgSpace.m) {
                Text(verbatim: position.code)
                    .font(WgInk.mono(.caption, .medium))
                    .foregroundStyle(current ? WgInk.ink : WgInk.ink3)
                    .frame(width: 22, alignment: .leading)
                Text(position.title)
                    .font(.system(size: WgType.body, weight: current ? .semibold : .regular))
                    .foregroundStyle(current ? WgInk.ink : WgInk.ink2)
                    .frame(width: 76, alignment: .leading)
                VStack(alignment: .leading, spacing: WgSpace.zero) {
                    Text(position.condition)
                    Text(position.allows)
                }
                .font(.system(size: WgType.body))
                .foregroundStyle(WgInk.ink3)
                Spacer(minLength: 0)
                if current {
                    Text("当前").font(WgInk.mono(.caption, .medium)).foregroundStyle(WgInk.ink2)
                }
            }
        }
    }

    @ViewBuilder
    private var allowContent: some View {
        note("本机代理软件直连的自建节点。每分钟重新解析；按解析出的 IP 放行，同一 IP 上的其他站点一并放开。只在 S2 / S3 生效。")
        // 新版服务总会返回 allow_hosts；没有这个字段 = 运行中的服务还不支持，不能装作生效
        if let current = settings, let hosts = current.allow_hosts {
            ForEach(hosts, id: \.self) { host in
                HStack(spacing: WgSpace.m) {
                    Text(verbatim: host)
                        .font(WgInk.mono(.footnote))
                        .textSelection(.enabled)
                    Text(verbatim: allowDetail(host))
                        .font(WgInk.mono(.caption))
                        .foregroundStyle(WgInk.ink3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
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
            }
            HStack(spacing: WgSpace.s) {
                TextField("jp.example.com", text: $hostDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .onSubmit { addHost(current) }
                Button("放行") { addHost(current) }
                    .disabled(hostDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } else {
            note(settings == nil ? "需要以 root 运行的正式网络服务" : "需要新版网络服务：当前服务不支持")
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

    private func allowDetail(_ host: String) -> String {
        guard let status, status.active, status.locked != true, !status.forced else {
            return "当前规则下不放行"
        }
        let ips = status.allowed_hosts?.first { $0.host == host }?.ips ?? []
        return ips.isEmpty ? "未解析到地址，尚未放行" : ips.joined(separator: "  ")
    }

    @ViewBuilder
    private func runtimeContent(_ p: PurityPresentation) -> some View {
        field("拒绝计数", "\(p.blocked) 包（本套规则加载以来，规则重新加载后归零）")
        field("生效网卡", status?.interfaces?.joined(separator: " ") ?? "—")
        field("当前规则", status?.error.map { "应用失败：\($0)" } ?? status?.reason ?? "—")
        field("紧急解除", "sudo /usr/local/libexec/wgsense-daemon --firewall-clear")
        note("规则作用于整台电脑。网络服务意外退出时规则保持生效。")
    }

    @ViewBuilder
    private var limitsContent: some View {
        field("国内 IP 段", "发版时的快照，不随时间更新；S1 不使用这份名单")
        field("开机空窗", "系统启动到网络服务装好规则之前，没有拦截")
        field("pf 被关闭", "规则挂在系统自带的 pf 上，其他软件整体关闭 pf 时失效且不会察觉")
    }

    private func field(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: WgSpace.m) {
            Text(label)
                .font(.system(size: WgType.body))
                .foregroundStyle(WgInk.ink2)
                .frame(width: 76, alignment: .leading)
            Text(verbatim: value)
                .font(.system(size: WgType.body))
                .foregroundStyle(WgInk.ink3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private func note(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(size: WgType.body))
            .foregroundStyle(WgInk.ink3)
            .fixedSize(horizontal: false, vertical: true)
    }
}
