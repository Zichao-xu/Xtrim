import SwiftUI

// 纯良：一条不变量 ——「去境外的包，要么从可信出口走，要么根本不出去」。
// 这个板块把后台在做的事摊开：现在落在哪一态、物理网卡放行什么、不变量哪里有缺口、怎么改。
//
// 三态按「谁是出口」划分，而不是按目的地：
//   S1 出口在线：全局隧道连着，物理网卡只放行局域网与 WG 服务器（隧道锁定）；
//   S2 在家：没有本机出口，境外流量交给家里网关，物理网卡放行国内与局域网；
//   S3 离家无出口：同样的规则，但没有网关兜底，境外一律拒绝。

/// 当前所在的位置（由隧道与所在网络决定，不由设置决定）。
enum PurityPosition: Equatable {
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

    /// 这一态下物理网卡放行什么。
    var allows: LocalizedStringKey {
        switch self {
        case .exit: return "只放行局域网与 WG 服务器，其余必须走隧道"
        case .home: return "放行国内与局域网，境外交给家里网关"
        case .away: return "放行国内与局域网，境外一律拒绝"
        }
    }
}

/// 页面与磁贴共用的纯良状态，全部由 daemon 的状态推出，不自己猜。
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

    init(status: DaemonStatus?, tunnelUp: Bool) {
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
    }

    /// 出口在线却没锁定：绑定物理网卡的程序可以绕开隧道。
    var lockGap: Bool { mode == .on && position == .exit && !locked }

    /// 需要用户注意（磁贴状态行着警示色）。
    var needsAttention: Bool { mode == .off || lockGap }

    /// 磁贴上的一行状态：只说现在生效的规则。
    var tileStatus: LocalizedStringKey {
        switch mode {
        case .unavailable: return "不可用"
        case .off: return "未开启"
        case .domestic: return "国内模式"
        case .on:
            switch position {
            case .exit: return locked ? "已锁定" : "未锁定"
            case .home: return "网关兜底"
            case .away: return "仅国内"
            }
        }
    }

    var title: LocalizedStringKey {
        switch mode {
        case .unavailable: return "不可用"
        case .off: return "未开启"
        case .domestic: return "国内模式"
        case .on: return position.title
        }
    }

    var code: String {
        switch mode {
        case .unavailable: return "N/A"
        case .off: return "OFF"
        case .domestic: return "CN"
        case .on: return position.code
        }
    }
}

struct PurityView: View {
    @EnvironmentObject var client: DaemonClient
    @State private var saving = false
    @State private var hostDraft = ""

    /// 状态优先取轮询里的那份（计数会更新），设置页接口那份只在打开和保存时刷新。
    private var status: FirewallStatus? { client.status?.firewall ?? client.firewall?.status }
    private var settings: FirewallSettings? { client.firewall?.settings }
    private var purity: PurityPresentation { PurityPresentation(status: client.status, tunnelUp: client.isTunnelUp) }

    var body: some View {
        let p = purity
        return VStack(alignment: .leading, spacing: WgSpace.m) {
            WgPageHeader(title: "纯良", subtitleText: "WGSENSE · PURITY", word: "PURITY") { EmptyView() }
            hero(p)
            ladder(p)
            invariantSection(p)
            rulesSection
            allowSection
            limitsSection
            Spacer(minLength: 0)
        }
        .frame(maxWidth: WgLayout.pageMaxWidth, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .top)
        .task { await client.fetchFirewall() }
    }

    // MARK: - 主视觉：现在是哪一态

    private func hero(_ p: PurityPresentation) -> some View {
        HStack(alignment: .center, spacing: WgSpace.l) {
            VStack(alignment: .leading, spacing: WgSpace.xs) {
                HStack(spacing: WgSpace.m) {
                    Text(verbatim: "STATE · \(p.code)")
                        .foregroundStyle(WgInk.ink3)
                    // 状态色只给异常：有缺口时在这里点一句，标题本身保持墨色
                    let gaps = checks(p).filter { $0.verdict == .gap }.count
                    if gaps > 0 {
                        Text("\(gaps) 处缺口").foregroundStyle(WgInk.warn)
                    }
                }
                .font(WgInk.mono(.caption, .medium))
                .tracking(1.8)
                Text(p.title)
                    .font(.system(size: WgType.readout, weight: .semibold))
                    .contentTransition(.opacity)
                Text(heroDetail(p))
                    .font(.system(size: WgType.body))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: WgSpace.l)
            // 计数固定占位：位数变化不推动左边的文字
            VStack(alignment: .trailing, spacing: WgSpace.xs) {
                Text(verbatim: "BLOCKED")
                    .font(WgInk.mono(.caption, .medium))
                    .tracking(1.8)
                    .foregroundStyle(WgInk.ink3)
                WgReadout(text: "\(p.blocked) 包", size: .readout)
                Text("本套规则生效以来")
                    .font(.system(size: WgType.body))
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 150, alignment: .trailing)
        }
        .wgPadding(.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .wgInteractiveSurface(cornerRadius: WgDesign.cardRadius)
    }

    private func heroDetail(_ p: PurityPresentation) -> String {
        switch p.mode {
        case .unavailable:
            return client.firewallError ?? "需要以 root 运行的正式网络服务"
        case .off:
            return "没有规则在生效：境外连接可以从物理网卡直接出去"
        case .domestic:
            return "所有出口（含隧道和网关代理）只放行国内"
        case .on:
            if let error = status?.error { return "规则应用失败：\(error)" }
            return status?.reason ?? ""
        }
    }

    // MARK: - 三态阶梯

    private func ladder(_ p: PurityPresentation) -> some View {
        HStack(spacing: WgSpace.m) {
            ForEach([PurityPosition.exit, .home, .away], id: \.code) { position in
                ladderCell(position, current: p.mode == .on && p.position == position, lockGap: p.lockGap)
            }
        }
    }

    private func ladderCell(_ position: PurityPosition, current: Bool, lockGap: Bool) -> some View {
        // 出口在线但锁定关着：实际生效的不是 S1 的规则，格子里照实写
        let unlocked = current && position == .exit && lockGap
        let shape = ChamferShape(tr: WgInk.cutTile)
        return VStack(alignment: .leading, spacing: WgSpace.xs) {
            HStack(spacing: WgSpace.s) {
                Text(verbatim: position.code)
                    .font(WgInk.mono(.caption, .medium))
                    .tracking(1.2)
                    .foregroundStyle(current ? WgInk.ink : WgInk.ink3)
                Spacer(minLength: 0)
                if current {
                    Text("当前")
                        .font(WgInk.mono(.caption, .medium))
                        .foregroundStyle(WgInk.ink)
                }
            }
            Text(position.title)
                .font(.system(size: WgType.title, weight: .bold))
                .foregroundStyle(current ? WgInk.ink : WgInk.ink2)
                .lineLimit(1)
            Text(unlocked ? "隧道锁定已关：物理网卡仍放行国内与局域网直连" : position.allows)
                .font(.system(size: WgType.body))
                .foregroundStyle(current ? WgInk.ink2 : WgInk.ink3)
                .lineLimit(2, reservesSpace: true)
                .fixedSize(horizontal: false, vertical: true)
        }
        .wgPadding(.l)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background {
            if current {
                Color.clear.wgGlassAccent(shape)
            } else {
                WgShapePlate(shape: shape, fill: .clear, border: WgInk.rule, highlight: .clear)
            }
        }
    }

    // MARK: - 不变量逐条核对

    private struct Check: Identifiable {
        enum Verdict { case holds, gap, idle }
        var id: String
        var symbol: String
        var name: LocalizedStringKey
        var verdict: Verdict
        var detail: String
        /// 缺口可以一键补上时的按钮。
        var fixTitle: LocalizedStringKey? = nil
        var fix: ((inout FirewallSettings) -> Void)? = nil
    }

    private func invariantSection(_ p: PurityPresentation) -> some View {
        WgSection(title: "不变量",
                  footer: "去境外的包，要么从可信出口走，要么根本不出去。下面每一行是这句话在当前网络下的一处落点：成立，或者有缺口。") {
            let checks = checks(p)
            ForEach(Array(checks.enumerated()), id: \.element.id) { index, check in
                if index > 0 { WgRowDivider() }
                WgRow(symbol: check.symbol, title: check.name, subtitle: Text(verbatim: check.detail)) {
                    HStack(spacing: WgSpace.s) {
                        if let title = check.fixTitle, let fix = check.fix, let current = settings {
                            Button(title) {
                                var next = current
                                fix(&next)
                                save(next)
                            }
                            .controlSize(.small)
                            .disabled(saving)
                        }
                        verdictLabel(check.verdict)
                    }
                }
            }
        }
    }

    private func verdictLabel(_ verdict: Check.Verdict) -> some View {
        let (text, color): (LocalizedStringKey, Color) = switch verdict {
        case .holds: ("成立", WgInk.ink2)
        case .gap: ("缺口", WgInk.warn)
        case .idle: ("—", WgInk.ink4)
        }
        // 固定宽度：成立 / 缺口切换时右侧不跳
        return Text(text)
            .font(WgInk.mono(.footnote, .medium))
            .foregroundStyle(color)
            .frame(width: 36, alignment: .trailing)
    }

    private func checks(_ p: PurityPresentation) -> [Check] {
        guard p.mode != .unavailable else {
            return [Check(id: "unavailable", symbol: "hand.raised", name: "拦截不可用", verdict: .idle,
                          detail: client.firewallError ?? "需要以 root 运行的正式网络服务")]
        }
        return [directCheck(p), bypassCheck(p), ipv6Check(p), dnsCheck(p)]
    }

    /// 境外直连：物理网卡上有没有拒绝规则。
    private func directCheck(_ p: PurityPresentation) -> Check {
        let enable: (inout FirewallSettings) -> Void = { $0.auto_block = true }
        switch p.mode {
        case .off:
            return Check(id: "direct", symbol: "hand.raised", name: "境外直连", verdict: .gap,
                         detail: "拦截未开启：境外连接可以从物理网卡直接出去",
                         fixTitle: "开启", fix: enable)
        case .domestic:
            return Check(id: "direct", symbol: "hand.raised.fill", name: "境外直连", verdict: .holds,
                         detail: "国内模式：所有出口只放行国内")
        default:
            if settings?.auto_block == false {
                return Check(id: "direct", symbol: "hand.raised", name: "境外直连", verdict: .gap,
                             detail: "现在靠隧道锁定在拦；「拦截境外直连」已关，隧道一断开就不再拦",
                             fixTitle: "开启", fix: enable)
            }
            return Check(id: "direct", symbol: "hand.raised.fill", name: "境外直连", verdict: .holds,
                         detail: "物理网卡上的境外直连立即被拒绝，不等超时")
        }
    }

    /// 绕开隧道：出口在线时，绑定物理网卡的程序出不出得去。
    private func bypassCheck(_ p: PurityPresentation) -> Check {
        guard p.mode == .on, p.position == .exit else {
            return Check(id: "bypass", symbol: "lock.open", name: "绕开隧道", verdict: .idle,
                         detail: p.mode == .domestic ? "国内模式下隧道本身也只放行国内" : "隧道没有接管全部流量，这一条不适用")
        }
        if p.locked {
            return Check(id: "bypass", symbol: "lock.fill", name: "绕开隧道", verdict: .holds,
                         detail: p.blocked == 0 ? "隧道锁定生效：没有程序试图绕开"
                                                : "隧道锁定生效：已拦下 \(p.blocked) 个绕开隧道的包")
        }
        return Check(id: "bypass", symbol: "lock.open", name: "绕开隧道", verdict: .gap,
                     detail: "隧道锁定已关：绑定物理网卡的程序可以绕开隧道，直连国内段和放行名单",
                     fixTitle: "锁定", fix: { $0.allow_bypass = false })
    }

    private func ipv6Check(_ p: PurityPresentation) -> Check {
        guard p.mode == .on else {
            return Check(id: "ipv6", symbol: "6.circle", name: "IPv6", verdict: p.mode == .domestic ? .holds : .gap,
                         detail: p.mode == .domestic ? "只放行国内 IPv6 段" : "拦截未开启，IPv6 同样直接出网")
        }
        guard p.position == .exit, let v6 = client.status?.coverage?.ipv6 else {
            return Check(id: "ipv6", symbol: "6.circle", name: "IPv6", verdict: .holds,
                         detail: "与 IPv4 同一套规则：只放行国内 IPv6 段和局域网")
        }
        switch v6.state {
        case "tunnel":
            return Check(id: "ipv6", symbol: "6.circle.fill", name: "IPv6", verdict: .holds, detail: "公网 IPv6 走隧道")
        case "blocked", "probing":
            return Check(id: "ipv6", symbol: "6.circle.fill", name: "IPv6", verdict: .holds,
                         detail: "隧道暂无 IPv6 出口：公网 IPv6 立即被拒，程序改用 IPv4 走隧道")
        default:
            return Check(id: "ipv6", symbol: "6.circle", name: "IPv6", verdict: .gap,
                         detail: "隧道没有接管 IPv6：公网 IPv6 可能从物理网卡直接出去")
        }
    }

    /// 域名查询：连接被拒之前，「查了哪个域名」发给了谁。
    private func dnsCheck(_ p: PurityPresentation) -> Check {
        if p.mode == .off {
            return Check(id: "dns", symbol: "text.magnifyingglass", name: "域名查询", verdict: .gap,
                         detail: "发给当前网络的 DNS，查过哪个境外域名对方看得到")
        }
        switch p.position {
        case .exit:
            if let dns = client.status?.coverage?.dns, !dns.isEmpty {
                return Check(id: "dns", symbol: "text.magnifyingglass", name: "域名查询", verdict: .holds,
                             detail: "经隧道发给 \(dns.joined(separator: ", "))，当前网络看不到")
            }
            return Check(id: "dns", symbol: "text.magnifyingglass", name: "域名查询", verdict: .gap,
                         detail: "配置没有指定 DNS：查询仍发给当前网络的 DNS 服务器")
        case .home:
            return Check(id: "dns", symbol: "text.magnifyingglass", name: "域名查询", verdict: .holds,
                         detail: "发给家里网关，由网关上的代理统一接管")
        case .away:
            return Check(id: "dns", symbol: "text.magnifyingglass", name: "域名查询", verdict: .gap,
                         detail: "发给当前网络的 DNS：连接会被拒，但查过哪个境外域名对方看得到。连上隧道后消失")
        }
    }

    // MARK: - 规则开关

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

    @ViewBuilder
    private var rulesSection: some View {
        WgSection(title: "规则",
                  footer: "作用于整台电脑，与所在网络无关。网络服务意外退出时规则保持生效；紧急解除：sudo /usr/local/libexec/wgsense-daemon --firewall-clear") {
            if let block = binding(\.auto_block),
               let forceDomestic = binding(\.force_domestic),
               let allowBypass = binding(\.allow_bypass),
               let blockProbes = binding(\.block_probes) {
                WgRow(symbol: "hand.raised.fill", title: "拦截境外直连",
                      subtitle: Text("没走隧道或网关代理的境外连接一律拒绝，含 IPv6")) {
                    HStack(spacing: WgSpace.s) {
                        if saving { ProgressView().controlSize(.small) }
                        toggle(block)
                    }
                }
                WgRowDivider()
                WgRow(symbol: "lock.shield", title: "隧道锁定",
                      subtitle: Text("全局隧道连着时，物理网卡只放行局域网和 WG 服务器；隧道一断开立即退回上一条规则")) {
                    toggle(Binding(get: { allowBypass.wrappedValue != true }, set: { allowBypass.wrappedValue = !$0 }))
                }
                WgRowDivider()
                // 新版服务总会返回 block_probes；没有这个字段 = 运行中的服务还不支持，开关不能装作生效
                let probesSupported = blockProbes.wrappedValue != nil
                WgRow(symbol: "point.3.connected.trianglepath.dotted", title: "放行诊断探测",
                      subtitle: Text(probesSupported
                          ? "仍让 ping / traceroute 的 ICMP 回显出去，路由追踪能看到真实路径；隧道锁定与国内模式下不放"
                          : "需要新版网络服务：当前服务不支持，诊断探测仍被拦截")) {
                    toggle(Binding(get: { probesSupported && blockProbes.wrappedValue != true },
                                   set: { blockProbes.wrappedValue = !$0 }))
                        .disabled(!block.wrappedValue || !probesSupported)
                }
                WgRowDivider()
                WgRow(symbol: "lock.fill", title: "国内模式",
                      subtitle: Text("只上国内：隧道和网关代理的境外流量也挡")) {
                    toggle(forceDomestic)
                }
            } else {
                WgRow(symbol: "hand.raised", title: "规则不可用",
                      subtitle: Text(client.firewallError ?? "需要以 root 运行的正式网络服务"))
            }
        }
    }

    private func toggle(_ isOn: Binding<Bool>) -> some View {
        Toggle("", isOn: isOn)
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
    }

    // MARK: - 放行名单

    @ViewBuilder
    private var allowSection: some View {
        WgSection(title: "放行名单",
                  footer: "本机代理软件直连的自建节点填这里。每分钟重新解析、跟随 DDNS；按解析出的 IP 放行，同一 IP 上的其他网站也会一并放开。只在 S2 / S3 生效，隧道锁定与国内模式下不放。") {
            // 新版服务总会返回 allow_hosts；没有这个字段 = 运行中的服务还不支持，不能装作生效
            if let current = settings, let hosts = current.allow_hosts {
                ForEach(hosts, id: \.self) { host in
                    WgRow(symbol: "checkmark.shield", title: LocalizedStringKey(host),
                          subtitle: Text(verbatim: allowSubtitle(host))) {
                        Button {
                            var next = current
                            next.allow_hosts = hosts.filter { $0 != host }
                            save(next)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("移出放行名单")
                    }
                    WgRowDivider()
                }
                WgRow(symbol: "plus.circle", title: "放行域名", subtitle: Text("填域名或 IP")) {
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
                WgRow(symbol: "plus.circle", title: "放行域名",
                      subtitle: Text(settings == nil ? (client.firewallError ?? "需要以 root 运行的正式网络服务")
                                                     : "需要新版网络服务：当前服务不支持"))
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

    private func allowSubtitle(_ host: String) -> String {
        guard let status, status.active, status.locked != true, !status.forced else {
            return "当前规则下不放行"
        }
        let ips = status.allowed_hosts?.first { $0.host == host }?.ips ?? []
        return ips.isEmpty ? "暂未解析到地址，尚未放行" : ips.joined(separator: "  ")
    }

    // MARK: - 已知局限（不藏）

    private var limitsSection: some View {
        WgSection(title: "已知局限") {
            WgRow(symbol: "calendar.badge.clock", title: "国内 IP 段是发版时的快照",
                  subtitle: Text("不随时间更新：新划给国内的段会被误拦，转去境外的段会被误放。S1 不用这份名单"))
            WgRowDivider()
            WgRow(symbol: "power", title: "开机到网络服务启动之前没有规则",
                  subtitle: Text("这段时间里的连接不受拦截"))
            WgRowDivider()
            WgRow(symbol: "exclamationmark.shield", title: "其他软件关掉系统防火墙时失效",
                  subtitle: Text("规则挂在系统自带的 pf 上，pf 被整体关闭时这里察觉不到"))
        }
    }
}
