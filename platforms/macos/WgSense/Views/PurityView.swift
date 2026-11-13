import SwiftUI

// 纯良：与 op 上的纯良同一语义——出口在线时完全休眠，全听出口的；出口不在了才接管。
//   · 休眠：当前出口（WireGuard / mihomo）健康，网络服务不下发任何拦截规则；
//   · 接管：没有出口、出口掉线或切换空档，物理网卡只放行国内、局域网与出口服务器，境外直连立即拒绝；
//   · 国内模式：不随出口休眠，所有出口只放行国内。
// 出口健康由网络服务每 3 秒判断一次（WireGuard 握手新鲜 / 内核在跑且控制接口有响应）。
//
// 页面组织与概览同构：主视觉条 → 出口图 → 卡片网格 → 列表。

/// 接管时所处的位置（决定网关代理那条去向是否可用）。
enum PurityPosition: Equatable {
    case home, away

    var code: String { self == .home ? "S2" : "S3" }
    var title: LocalizedStringKey { self == .home ? "在家" : "离家" }
}

/// 页面与磁贴共用的纯良状态，全部由网络服务报告推出。
struct PurityPresentation: Equatable {
    enum Mode: Equatable {
        case unavailable   // 网络服务没给出拦截状态
        case off           // 纯良未启用
        case domestic      // 国内模式
        case dormant       // 出口在线，休眠
        case guarding      // 无可用出口，接管中
    }

    var mode: Mode
    var position: PurityPosition
    var exit: String
    var exitOnline: Bool
    var exitDetail: String
    var blocked: UInt64
    var allowCount: Int

    init(status: DaemonStatus?, tunnelUp: Bool, settings: FirewallSettings? = nil, proxyDNSService: String? = nil) {
        let fw = status?.firewall
        position = status?.isTrustedNetwork == true ? .home : .away
        exit = fw?.exit ?? status?.exit ?? "wireguard"
        // 旧版网络服务不报出口健康：用隧道状态近似
        exitOnline = fw?.exit_online ?? tunnelUp
        exitDetail = fw?.exit_detail ?? (tunnelUp ? "隧道已连接" : "隧道未连接")
        blocked = fw?.blocked_packets ?? 0
        allowCount = fw?.allowed_hosts?.count ?? 0
        guard let fw else { mode = .unavailable; return }
        if fw.forced {
            mode = .domestic
        } else if fw.dormant == true {
            mode = .dormant
        } else if fw.active {
            mode = .guarding
        } else {
            mode = .off
        }
    }

    var exitTitle: String {
        switch exit {
        case "mihomo": return "mihomo"
        case "gateway": return "网关代理"
        case "tailscale": return "Tailscale"
        default: return "WireGuard"
        }
    }

    /// 结论：磁贴状态行与主视觉共用。
    var verdict: LocalizedStringKey {
        switch mode {
        case .unavailable: return "不可用"
        case .off: return "未启用"
        case .domestic: return "国内模式"
        case .dormant: return "休眠"
        case .guarding: return "接管中"
        }
    }

    /// 需要注意：纯良没开，或正在接管（没有可用出口，境外上不去）。
    var needsAttention: Bool { mode == .off || mode == .guarding }

    /// 处境标注（等宽注记用）。
    var code: String {
        switch mode {
        case .unavailable: return "N/A"
        case .off: return "OFF"
        case .domestic: return "CN"
        case .dormant: return "IDLE"
        case .guarding: return position.code
        }
    }

    var situation: LocalizedStringKey {
        switch mode {
        case .unavailable: return "服务不可用"
        case .off: return "纯良未启用"
        case .domestic: return "国内模式"
        case .dormant: return "出口在线"
        case .guarding: return position == .home ? "在家 · 无出口" : "离家 · 无出口"
        }
    }
}

struct PurityView: View {
    @EnvironmentObject var client: DaemonClient
    @State private var saving = false
    @State private var hostDraft = ""

    private var status: FirewallStatus? { client.status?.firewall ?? client.firewall?.status }
    private var settings: FirewallSettings? { client.firewall?.settings }
    private var purity: PurityPresentation {
        PurityPresentation(status: client.status, tunnelUp: client.isTunnelUp, settings: settings)
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
                purityCard(p)
                exitCard(p)
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

    // MARK: - 主视觉条

    private func hero(_ p: PurityPresentation) -> some View {
        HStack(spacing: WgSpace.m) {
            StatusOrb(symbol: p.mode == .dormant ? "moon.zzz.fill" : "hand.raised.fill",
                      tint: p.needsAttention ? .orange : .green,
                      isActive: p.mode != .off && p.mode != .unavailable, isBusy: saving)
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
            if p.mode == .off, let current = settings {
                Button("启用纯良") {
                    var next = current
                    next.auto_block = true
                    save(next)
                }
                .buttonStyle(WgCapsuleButtonStyle(tint: .orange))
                .disabled(saving)
            }
        }
        .wgPadding(.m)
        .wgInteractiveSurface(cornerRadius: WgDesign.heroRadius)
    }

    private func heroDetail(_ p: PurityPresentation) -> String {
        if let error = status?.error { return "规则应用失败：\(error)" }
        switch p.mode {
        case .unavailable:
            return client.firewallError ?? "需要以 root 运行的正式网络服务"
        case .off:
            return "出口不在时，境外连接可以从物理网卡直接出去"
        case .domestic:
            return "所有出口（含隧道和代理）只放行国内"
        case .dormant:
            return "出口 \(p.exitTitle) 在线（\(p.exitDetail)），纯良不干预，流量全听出口的"
        case .guarding:
            return "出口 \(p.exitTitle) 不可用（\(p.exitDetail)）：境外直连一律拒绝，国内与局域网照常"
        }
    }

    // MARK: - 卡片

    private func purityCard(_ p: PurityPresentation) -> some View {
        InfoCard(symbol: "hand.raised", tint: .gray, title: "纯良",
                 value: p.needsAttention ? Text(p.verdict).foregroundColor(WgInk.warn) : Text(p.verdict),
                 detail: Text("出口在线时休眠，出口不在时拒绝境外直连")) {
            if let block = binding(\.auto_block) { toggle(block) }
        }
    }

    private func exitCard(_ p: PurityPresentation) -> some View {
        InfoCard(symbol: "arrow.up.forward", tint: .gray, title: "出口",
                 value: Text(verbatim: "\(p.exitTitle) · \(p.exitOnline ? "在线" : "不可用")"),
                 detail: Text(verbatim: p.exitDetail + " · 每 3 秒检查一次"))
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
                     detail: Text(supported ? "接管时仍放行 ping / traceroute 的 ICMP 回显；国内模式下不放"
                                            : "当前网络服务不支持，诊断探测仍被拦截")) {
                toggle(Binding(get: { allowed }, set: { probes.wrappedValue = !$0 }))
                    .disabled(!block.wrappedValue || !supported)
            }
            InfoCard(symbol: "lock.fill", tint: .gray, title: "国内模式",
                     value: Text(domestic.wrappedValue ? "开启" : "关闭"),
                     detail: Text("不随出口休眠：隧道与代理的境外流量也拒绝")) {
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
        guard let status, status.active, !status.forced else { return "未放行" }
        let ips = status.allowed_hosts?.first { $0.host == host }?.ips ?? []
        return ips.isEmpty ? "未解析" : ips.joined(separator: "  ")
    }

    private func allowDetail(_ host: String) -> String {
        guard let status else { return "拦截未启用" }
        if status.forced { return "国内模式下不放行" }
        if status.dormant == true { return "纯良休眠中，不需要放行；出口不在、纯良接管时生效" }
        if !status.active { return "纯良未启用" }
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
                detail: "不随时间更新；纯良接管时用它判断哪些是国内") { EmptyView() }
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
        let home = p.position == .home
        switch p.mode {
        case .unavailable:
            return Self.all(.idle)
        case .off:
            // 不拦：出口不在时境外直连就是缺口
            var lanes = Self.all(.pass)
            lanes[0].result = p.exitOnline ? .pass : .idle
            lanes[3].result = home ? .pass : .idle
            lanes[4].breach = !p.exitOnline
            return lanes
        case .domestic:
            var lanes = Self.all(.reject)
            lanes[1].result = .pass
            lanes[2].result = .pass
            return lanes
        case .dormant:
            // 休眠：闸门全开，流量由出口接管
            var lanes = Self.all(.pass)
            lanes[3].result = home ? .pass : .idle
            lanes[4].via = "交给出口 \(p.exitTitle)"
            return lanes
        case .guarding:
            var lanes = Self.all(.reject)
            lanes[0].result = .idle
            lanes[0].via = "\(p.exitTitle) 不可用"
            lanes[1].result = .pass
            lanes[2].result = .pass
            lanes[3].result = home ? .pass : .idle
            // 放行名单是「境外直连一律拒绝」的例外，生效时在这一条上写明
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
