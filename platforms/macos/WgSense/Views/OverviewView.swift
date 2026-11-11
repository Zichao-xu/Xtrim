import SwiftUI

// 概览：一眼看清三件事 —— 现在是什么状态、为什么、能做什么。
//
//   主视觉   状态光球 + 标题 + 原因 + 唯一的主操作
//   信息卡   网络 / 守护（可直接开关）/ 流量 / 隧道
//   模块     系统设置式分组列表
struct OverviewView: View {
    @EnvironmentObject var client: DaemonClient
    /// 嵌进 VPN 板块（WireGuard 子页）时不显示自己的页头。
    var showsHeader = true

    var body: some View {
        VStack(alignment: .leading, spacing: WgSpace.m) {
            if showsHeader {
                WgPageHeader(title: "概览", subtitleText: "WGSENSE · STATUS", word: "OVERVIEW") { EmptyView() }
            }

            hero

            linkStage

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: WgSpace.m), GridItem(.flexible(), spacing: WgSpace.m)],
                spacing: WgSpace.m
            ) {
                networkCard
                guardCard
                trafficCard
                tunnelCard
            }

            coverage

            modules

            Spacer(minLength: 0)
        }
        .frame(maxWidth: WgLayout.pageMaxWidth, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .top)
        .animation(WgDesign.spring, value: client.vpnPresentation.phase)
        .task {
            async let transfer: Void = client.fetchTransferState()
            async let proxy: Void = client.fetchProxyStatus()
            _ = await (transfer, proxy)
        }

    }

    // MARK: - 主视觉

    private var hero: some View {
        let vpn = client.vpnPresentation
        return HStack(spacing: WgSpace.m) {
            StatusOrb(symbol: vpn.symbol, tint: vpn.tint, isActive: vpn.phase == .connected || vpn.phase == .home, isBusy: vpn.isBusy,
                      logo: .wireguard)

            VStack(alignment: .leading, spacing: WgSpace.xs) {
                Text(vpn.title)
                    .font(.system(size: WgType.readout, weight: .semibold))
                    .contentTransition(.opacity)
                Text(vpn.detail)
                    .font(.system(size: WgType.body))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
            }

            Spacer(minLength: 12)

            primaryAction(vpn)
        }
        .wgPadding(.m)
        .wgInteractiveSurface(cornerRadius: WgDesign.heroRadius)
    }

    @ViewBuilder
    private func primaryAction(_ vpn: WgVPNPresentation) -> some View {
        switch vpn.phase {
        case .connected, .connecting, .retrying:
            Button("断开") { Task { await client.post("disconnect") } }
                .buttonStyle(WgCapsuleButtonStyle(tint: .red, prominent: false))
        case .home:
            // 在家保持断开是设计本意，不提供“破例”的主操作；守护开关在下方卡片里。
            EmptyView()
        case .idle, .offline:
            Button("连接") { Task { await client.post("connect") } }
                .buttonStyle(WgCapsuleButtonStyle(tint: .green))
                .disabled(client.isAuthorizingDaemon)
        case .setupFailed:
            Button("重试安装") { Task { await client.retryServiceInstall() } }
                .buttonStyle(WgCapsuleButtonStyle(tint: .orange))
                .disabled(client.isAuthorizingDaemon)
                .help("会再弹一次管理员密码框")
        case .disconnecting:
            ProgressView().controlSize(.small)
        }
    }

    // MARK: - 链路舞台

    /// 事件驱动 HUD：收发构成、握手刻度与最近 30 秒遥测轨迹。
    private var linkStage: some View {
        let phase: WgLinkPhase
        switch client.vpnPresentation.phase {
        case .connected: phase = .linked
        case .home: phase = .home
        case .connecting, .retrying: phase = .connecting
        case .idle, .disconnecting: phase = .idle
        case .offline, .setupFailed: phase = .offline
        }
        return WgLinkStage(phase: phase, monitor: client.linkMonitor)
            .wgInteractiveSurface(cornerRadius: WgDesign.cardRadius)
    }

    // MARK: - 信息卡

    private var networkCard: some View {
        let s = client.status
        let trusted = s?.isTrustedNetwork ?? false
        return InfoCard(
            symbol: trusted ? "house.fill" : "wifi",
            tint: s == nil ? .gray : (trusted ? .teal : .blue),
            title: "网络",
            value: s == nil ? Text("未知") : Text(trusted ? "在家" : "外部网络"),
            detail: networkDetail(s)
        )
    }

    private func networkDetail(_ s: DaemonStatus?) -> Text {
        guard let s else { return Text("等待后台服务") }
        let iface = s.network_interfaces?.first
        let name = iface?.hardware_port ?? iface?.name
        let ip = s.primaryIPv4
        switch (name, ip) {
        case let (n?, i?): return Text(verbatim: "\(n) · \(i)")
        case let (n?, nil): return Text(verbatim: n)
        case let (nil, i?): return Text(verbatim: i)
        default: return Text(s.isTrustedNetwork ? "受信任网络" : "非受信任网络")
        }
    }

    private var guardCard: some View {
        let online = client.status != nil
        let on = online && client.isGuardOn
        return InfoCard(
            symbol: on ? "shield.fill" : "shield.slash.fill",
            tint: on ? .blue : .gray,
            title: "守护",
            value: online ? Text(on ? "运行中" : "已关闭") : Text(verbatim: "—"),
            detail: online ? Text(on ? "在家断开，外出自动连接" : "不会自动连接或断开") : Text("等待后台服务")
        ) {
            Toggle("", isOn: Binding(
                get: { on },
                set: { value in Task { await client.setGuardEnabled(value) } }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
            .disabled(client.pendingGuardRunning != nil)
        }
    }

    private var trafficCard: some View {
        let up = client.isTunnelUp
        let t = client.traffic
        return InfoCard(
            symbol: "arrow.up.arrow.down",
            tint: up ? .cyan : .gray,
            title: "流量",
            value: up
                ? Text(verbatim: "↓ \(WgFormat.speed(t?.rx_speed ?? 0))   ↑ \(WgFormat.speed(t?.tx_speed ?? 0))")
                : Text(verbatim: "—"),
            detail: up
                ? Text(verbatim: "累计 ↓ \(WgFormat.size(t?.rx_bytes ?? 0)) · ↑ \(WgFormat.size(t?.tx_bytes ?? 0))")
                : Text("隧道未建立")
        )
    }

    private var tunnelCard: some View {
        let s = client.status
        let up = client.isTunnelUp
        let service = (s?.service.isEmpty == false) ? s!.service : "—"
        let detail: Text
        if up, let s {
            let iface = s.tunnel_interface ?? "utun"
            if let age = s.last_handshake_age_seconds {
                detail = Text(verbatim: "\(iface) · ") + Text("握手 \(WgFormat.age(age))")
            } else {
                detail = Text(verbatim: iface)
            }
        } else {
            detail = Text("未建立")
        }
        return InfoCard(
            symbol: "point.3.connected.trianglepath.dotted",
            tint: up ? .green : .gray,
            title: "隧道",
            value: Text(verbatim: service),
            detail: detail
        )
    }

    // MARK: - 隧道覆盖

    /// 隧道接管了什么、哪些不走隧道以及原因 —— 后台做的事都要在这里看得见。
    private var coverage: some View {
        VStack(alignment: .leading, spacing: WgSpace.s) {
            Text("隧道覆盖")
                .font(.system(size: WgType.sub, weight: .semibold))
                .foregroundStyle(.secondary)
                .wgPadding(.leading, .xs)

            VStack(spacing: 0) {
                let rows = coverageRows
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { RowDivider() }
                    CoverageRow(row: row)
                }
            }
            .wgInteractiveSurface(cornerRadius: WgDesign.cardRadius)
        }
    }

    private var coverageRows: [CoverageRowModel] {
        guard client.isTunnelUp, let s = client.status, let c = s.coverage else {
            return [CoverageRowModel(symbol: "point.3.connected.trianglepath.dotted", tint: .gray,
                                     name: "隧道未建立", value: Text(verbatim: "—"),
                                     detail: Text("流量按出站拦截规则直连；连上全局隧道后在这里列出接管情况"))]
        }
        guard c.full_tunnel else {
            return [CoverageRowModel(symbol: "arrow.triangle.branch", tint: .blue,
                                     name: "分流配置", value: Text("部分走隧道"),
                                     detail: Text("只有配置里列出的网段走隧道，其余（含 IPv6）照常直连"))]
        }
        var rows = [ipv6Row(c.ipv6), lockRow(s.firewall), dnsRow(c)]
        for path in c.bypass ?? [] {
            rows.append(CoverageRowModel(symbol: "arrow.uturn.right", tint: .gray, name: "不走隧道",
                                         value: Text(verbatim: path.destination),
                                         detail: Text(verbatim: path.via.isEmpty ? path.reason : "\(path.reason) · 经 \(path.via)")))
        }
        return rows
    }

    private func ipv6Row(_ v6: TunnelIPv6Status) -> CoverageRowModel {
        var parts: [String] = []
        if let address = v6.address {
            parts.append(v6.derived == true ? "隧道地址 \(address)（按约定推出）" : "隧道地址 \(address)")
        }
        if let last = WgCoverageFormat.clock(v6.last_probe) {
            parts.append("\(last) 探测\(v6.last_probe_ok == true ? "可出网" : "不通")")
        }
        if let next = WgCoverageFormat.clock(v6.next_probe), v6.state != "tunnel" || v6.last_probe != nil {
            parts.append("下次 \(next)")
        }
        if let error = v6.error { parts.append("路由切换失败：\(error)") }
        let value: Text, tint: Color, symbol: String
        switch v6.state {
        case "tunnel":
            value = Text("走隧道"); tint = .green; symbol = "checkmark.shield.fill"
        case "probing":
            value = Text("已拦截 · 探测中"); tint = .orange; symbol = "hourglass"
        case "blocked" where v6.mode == "block":
            value = Text("始终拦截"); tint = .blue; symbol = "nosign"
            parts.insert("设置为始终拦截，程序全部改用 IPv4 走隧道", at: 0)
        case "blocked":
            value = Text("已拦截 · 改用 IPv4"); tint = .blue; symbol = "nosign"
            parts.insert("隧道暂无 IPv6 出口，程序立即改用 IPv4 走隧道", at: 0)
        default:
            value = Text("未接管"); tint = .gray; symbol = "questionmark.circle"
        }
        return CoverageRowModel(symbol: symbol, tint: tint, name: "IPv6", value: value,
                                detail: Text(verbatim: parts.joined(separator: " · ")))
    }

    /// 纯良：出口在线时休眠，出口不在时才接管（与 op 上的纯良同一语义）。
    private func lockRow(_ fw: FirewallStatus?) -> CoverageRowModel {
        guard let fw else {
            return CoverageRowModel(symbol: "hand.raised", tint: .gray, name: "纯良", value: Text("不可用"),
                                    detail: Text("需要以 root 运行的正式网络服务"))
        }
        if let error = fw.error {
            return CoverageRowModel(symbol: "hand.raised", tint: .orange, name: "纯良", value: Text("应用失败"),
                                    detail: Text(verbatim: error))
        }
        if fw.dormant == true {
            return CoverageRowModel(symbol: "moon.zzz", tint: .green, name: "纯良", value: Text("休眠"),
                                    detail: Text(verbatim: "出口在线（\(fw.exit_detail ?? "")），不干预；出口一断立即接管"))
        }
        if fw.active {
            return CoverageRowModel(symbol: "hand.raised.fill", tint: .orange, name: "纯良", value: Text("接管中"),
                                    detail: Text(verbatim: fw.reason))
        }
        return CoverageRowModel(symbol: "hand.raised", tint: .orange, name: "纯良", value: Text("未启用"),
                                detail: Text("出口不在时境外连接可从物理网卡直接出去"))
    }

    private func dnsRow(_ c: TunnelCoverage) -> CoverageRowModel {
        if let dns = c.dns, !dns.isEmpty {
            let service = c.dns_service.map { "接管「\($0)」的 DNS，断开时恢复" } ?? "断开时恢复"
            return CoverageRowModel(symbol: "text.magnifyingglass", tint: .green, name: "DNS",
                                    value: Text(verbatim: dns.joined(separator: ", ")),
                                    detail: Text(verbatim: "查询经隧道 · \(service)"))
        }
        return CoverageRowModel(symbol: "text.magnifyingglass", tint: .orange, name: "DNS",
                                value: Text("未接管"),
                                detail: Text("配置未指定 DNS，查询仍发往当前网络的 DNS 服务器"))
    }

    // MARK: - 模块

    private var modules: some View {
        VStack(alignment: .leading, spacing: WgSpace.s) {
            Text("模块")
                .font(.system(size: WgType.sub, weight: .semibold))
                .foregroundStyle(.secondary)
                .wgPadding(.leading, .xs)

            VStack(spacing: 0) {
                ModuleRow(
                    symbol: "lock.shield.fill", tint: .green, name: "WireGuard",
                    status: Text(client.vpnPresentation.title), isOn: client.isTunnelUp
                )
                RowDivider()
                ModuleRow(
                    symbol: "arrow.down", tint: .blue, name: "传输",
                    status: Text(client.transferState?.running == true ? "接收服务运行中" : "未运行"),
                    isOn: client.transferState?.running == true
                )
                RowDivider()
                ModuleRow(
                    symbol: "rectangle.3.group", tint: .purple, name: "面板",
                    status: Text(client.proxyRunning ? "控制器已连接" : (client.proxyServiceRunning ? "等待认证" : "未连接")),
                    isOn: client.proxyRunning
                )
            }
            .wgInteractiveSurface(cornerRadius: WgDesign.cardRadius)
        }
    }
}

// MARK: - 组件

/// 状态块：同心方框收束到一枚实心方块（取自图纸的层层等高线）。
/// 已连接 = 克莱因蓝；在家 = 实墨（安全、无需 VPN）；其余只剩线框。
struct StatusOrb: View {
    var symbol: String
    var tint: Color
    var isActive: Bool
    var isBusy: Bool
    /// 设了就画出口标识（龙 / 猫）代替 SF 图标。
    var logo: WgExit? = nil


    var body: some View {
        let normalized = WgInk.normalize(tint)
        let fill: Color = normalized == WgInk.warn || normalized == WgInk.alert ? normalized
            : (tint == .green ? WgInk.signal : WgInk.ink)
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                Rectangle()
                    .strokeBorder(Color.primary.opacity(0.28 - Double(i) * 0.08), lineWidth: 1)
                    .frame(width: 60 + CGFloat(i) * 12, height: 60 + CGFloat(i) * 12)
            }
            Rectangle()
                .fill(isActive ? fill : Color.clear)
                .frame(width: 48, height: 48)
            Group {
                if let logo {
                    WgExitLogo(exit: logo, size: 30)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: WgType.readout, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .foregroundStyle(isActive ? Color(nsColor: .windowBackgroundColor) : Color.primary.opacity(0.6))
            if isBusy {
                // 沿最外一圈方框绕行，与三层框同一几何，不甩出去
                WgPerimeterRunner(shape: Rectangle().inset(by: 1), color: fill, lineWidth: 2, period: 1.6, length: 0.18)
                    .frame(width: 84, height: 84)
            }
        }
        .frame(width: 86, height: 86)
        .animation(WgDesign.spring, value: isActive)
    }
}

struct InfoCard<Accessory: View>: View {
    var symbol: String
    var tint: Color
    var title: LocalizedStringKey
    var value: Text
    var detail: Text
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: WgSpace.m) {
            HStack(spacing: WgSpace.s) {
                WgSquareBadge(symbol: symbol, tint: tint, size: 22)
                Text(title)
                    .font(.system(size: WgType.sub, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                accessory()
            }
            .frame(height: 22)
            VStack(alignment: .leading, spacing: WgSpace.xs) {
                value
                    .font(.system(size: WgType.body, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                detail
                    .font(.system(size: WgType.body))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .wgPadding(.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .wgInteractiveSurface(cornerRadius: WgDesign.cardRadius)
    }
}

extension InfoCard where Accessory == EmptyView {
    init(symbol: String, tint: Color, title: LocalizedStringKey, value: Text, detail: Text) {
        self.init(symbol: symbol, tint: tint, title: title, value: value, detail: detail) { EmptyView() }
    }
}

private struct ModuleRow: View {
    var symbol: String
    var tint: Color
    var name: LocalizedStringKey
    var status: Text
    var isOn: Bool

    var body: some View {
        HStack(spacing: WgSpace.m) {
            WgSquareBadge(symbol: symbol, tint: tint, size: 24, dimmed: !isOn)
            Text(name)
                .font(.system(size: WgType.body, weight: .medium))
            Spacer()
            status
                .font(.system(size: WgType.sub))
                .foregroundStyle(.secondary)
            WgStatusDot(color: .green, isOn: isOn)
        }
        .wgPadding(.horizontal, .l)
        .wgPadding(.vertical, .m)
    }
}

private struct CoverageRowModel {
    var symbol: String
    var tint: Color
    var name: LocalizedStringKey
    var value: Text
    var detail: Text
}

private struct CoverageRow: View {
    var row: CoverageRowModel

    var body: some View {
        HStack(alignment: .center, spacing: WgSpace.m) {
            WgSquareBadge(symbol: row.symbol, tint: row.tint, size: 24)
            VStack(alignment: .leading, spacing: WgSpace.zero) {
                HStack(spacing: WgSpace.s) {
                    Text(row.name)
                        .font(.system(size: WgType.body, weight: .medium))
                    Spacer(minLength: 8)
                    row.value
                        .font(.system(size: WgType.sub, design: .monospaced))
                        .foregroundStyle(.primary.opacity(0.8))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                row.detail
                    .font(.system(size: WgType.body))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .wgPadding(.horizontal, .l)
        .wgPadding(.vertical, .s)
    }
}

/// 覆盖面板里的时间：只显示时:分。
enum WgCoverageFormat {
    private static let parser = ISO8601DateFormatter()
    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    static func clock(_ rfc3339: String?) -> String? {
        guard let rfc3339, let date = parser.date(from: rfc3339) else { return nil }
        return clockFormatter.string(from: date)
    }
}

private struct RowDivider: View {
    var body: some View {
        Divider().opacity(0.5).wgInset(.leading, 50)
    }
}
