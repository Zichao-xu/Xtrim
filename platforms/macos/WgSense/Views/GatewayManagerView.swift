import SwiftUI

// 网络与受信任网关：受信任（在家）= 当前默认网关的 MAC 在列表里。
// 以前按 IP 网段判定在家，同网段的别人家会被误判；网关 MAC 是那台路由器自己的地址。
//
//   当前网关     IP · MAC · 网卡，受信任与否，一键信任 / 取消
//   受信任网关   改名、移除
//   最近见过的   离开那个网络后也能一键补加信任
//   判定记录     每次网关变化判成什么

/// 网络卡：在不在家，以及「这是家」开关（= 信任当前网关）。VPN 页与守护页共用，点开是网关管理面板。
/// 在不在家只看网关 MAC：网段谁都能撞上，网关是自家路由器自己的地址。
struct NetworkCard: View {
    @EnvironmentObject var client: DaemonClient
    @State private var showManager = false

    var body: some View {
        let s = client.status
        let v = s?.gateway
        let home = s?.isTrustedNetwork ?? false
        InfoCard(symbol: home ? "house.fill" : "wifi",
                 tint: s == nil ? .gray : (home ? .teal : (v?.legacy_match == true ? .orange : .blue)),
                 title: "网络", value: value(s, v), detail: detail(s, v)) {
            accessory(v)
        }
        .contentShape(Rectangle())
        .onTapGesture { if v != nil { showManager = true } }
        .sheet(isPresented: $showManager) {
            GatewayManagerView { showManager = false }
                .environmentObject(client)
        }
    }

    private func value(_ s: DaemonStatus?, _ v: GatewayVerdict?) -> Text {
        guard let s else { return Text("未知") }
        if let name = v?.name, v?.trusted == true { return Text("在家 · \(name)") }
        return Text(s.isTrustedNetwork ? "在家" : "外部网络")
    }

    private func detail(_ s: DaemonStatus?, _ v: GatewayVerdict?) -> Text {
        guard let s else { return Text("等待后台服务") }
        if v?.legacy_match == true && v?.trusted == false { return Text("升级后待确认 · 是家就打开开关") }
        let iface = s.network_interfaces?.first
        var parts: [String] = []
        if let name = iface?.hardware_port ?? iface?.name { parts.append(name) }
        if let ip = s.primaryIPv4 { parts.append(ip) }
        if let cur = v?.current {
            if let mac = cur.mac, !mac.isEmpty {
                parts.append(String(localized: "网关 \(mac)", bundle: .wgLocalized))
            } else {
                parts.append(String(localized: "网关 \(cur.ip) 读不到 MAC", bundle: .wgLocalized))
            }
        }
        if parts.isEmpty { return Text(s.isTrustedNetwork ? "受信任网络" : "非受信任网络") }
        return Text(verbatim: parts.joined(separator: " · "))
    }

    // 开 = 这是家（信任当前网关），关 = 不是（取消信任）。读不到 MAC 时不能开；旧版网络服务没有这个开关。
    @ViewBuilder
    private func accessory(_ v: GatewayVerdict?) -> some View {
        if let v {
            let mac = v.current?.mac ?? ""
            Toggle("", isOn: Binding(
                get: { v.trusted },
                set: { on in Task { await client.gatewayAction(on ? "trust" : "untrust", mac: on ? "" : mac) } }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
            .disabled(mac.isEmpty || client.gatewayBusy)
            .help(v.trusted ? "关掉：这里不再算家，守护会连上 VPN" : "打开：这里是家（信任当前网关），守护会保持 VPN 断开")
        }
    }
}

struct GatewayManagerView: View {
    @EnvironmentObject var client: DaemonClient
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("网关").font(.system(size: WgType.title, weight: .semibold))
                Spacer()
                Button("完成", action: onClose).buttonStyle(.bordered).keyboardShortcut(.defaultAction)
            }
            .wgPadding(.m)

            ScrollView {
                VStack(alignment: .leading, spacing: WgSpace.m) {
                    if let st = client.gatewayState {
                        current(st)
                        group("受信任网关") { trustedRows(st) }
                        if !otherSeen(st).isEmpty {
                            group("最近见过的网关") { seenRows(st) }
                        }
                        group("判定记录") { decisionRows(st) }
                        footer(st)
                    } else {
                        Text("网络服务还不支持受信任网关，更新网络服务后可用。")
                            .foregroundStyle(.secondary)
                    }
                }
                .wgPadding(.horizontal, .m)
                .wgPadding(.bottom, .m)
            }
        }
        .frame(width: 520, height: 560)
        .task { await client.fetchGateway() }
        .disabled(client.gatewayBusy)
    }

    /// 小窗里的分组：小号灰字标题 + 一块圆角实体（不用整页级别的大标题）。
    private func group<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: WgSpace.xs) {
            Text(title)
                .font(.system(size: WgType.body, weight: .semibold))
                .foregroundStyle(.secondary)
                .wgPadding(.horizontal, .xs)
            VStack(spacing: 0) { content() }
                .wgInteractiveSurface(cornerRadius: WgDesign.cardRadius)
        }
    }

    // MARK: - 当前网关（开关和 VPN 页的网关卡一致）

    private func current(_ st: GatewayState) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let cur = st.current {
                let mac = cur.mac ?? ""
                WgRow(symbol: st.trusted ? "house.fill" : "wifi.router",
                      tint: st.trusted ? .teal : .gray,
                      title: st.trusted ? LocalizedStringKey(stringLiteral: st.name ?? "") : "当前网关未受信任",
                      subtitle: Text(verbatim: describe(cur))) {
                    Toggle("", isOn: Binding(
                        get: { st.trusted },
                        set: { on in Task { await client.gatewayAction(on ? "trust" : "untrust", mac: on ? "" : mac) } }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .disabled(mac.isEmpty)
                }
                if st.legacy_match == true && !st.trusted {
                    WgRowDivider()
                    HStack(alignment: .firstTextBaseline, spacing: WgSpace.s) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("受信任规则已改为网关 MAC，旧网段不再算在家。是家就打开开关。")
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: WgSpace.s)
                        Button("不再提示") { Task { await client.gatewayAction("dismiss_legacy") } }
                            .buttonStyle(.borderless)
                    }
                    .font(.system(size: WgType.body))
                    .foregroundStyle(.secondary)
                    .wgPadding(.horizontal, .l)
                    .wgPadding(.vertical, .s)
                }
            } else {
                WgRow(symbol: "wifi.slash", tint: .gray, title: "没有网关", subtitle: Text("没有走物理网卡的默认路由，按外部网络处理"))
            }
        }
        .wgInteractiveSurface(cornerRadius: WgDesign.cardRadius)
    }

    // MARK: - 受信任网关

    @ViewBuilder
    private func trustedRows(_ st: GatewayState) -> some View {
        if st.trusted_list.isEmpty {
            WgRow(symbol: nil, title: "还没有", subtitle: Text("在家时打开上面的开关，或从最近见过的网关里加"))
        }
        ForEach(Array(st.trusted_list.enumerated()), id: \.element.id) { index, item in
            if index > 0 { WgRowDivider() }
            TrustedGatewayRow(item: item, isCurrent: st.current?.mac == item.mac)
        }
    }

    // MARK: - 最近见过的（不含当前网关和已信任的）

    private func otherSeen(_ st: GatewayState) -> [SeenGateway] {
        let trusted = Set(st.trusted_list.map(\.mac))
        return st.seen.filter { $0.mac != st.current?.mac && !trusted.contains($0.mac) }
    }

    @ViewBuilder
    private func seenRows(_ st: GatewayState) -> some View {
        ForEach(Array(otherSeen(st).enumerated()), id: \.element.id) { index, item in
            if index > 0 { WgRowDivider() }
            WgRow(symbol: "wifi.router", tint: .gray,
                  title: LocalizedStringKey(stringLiteral: item.mac),
                  subtitle: seenSubtitle(item)) {
                Button("信任") { Task { await client.gatewayAction("trust", mac: item.mac) } }
                    .buttonStyle(.borderless)
            }
        }
    }

    private func seenSubtitle(_ item: SeenGateway) -> Text {
        var text = Text(verbatim: "\(item.ip) · \(item.hardware_port ?? item.interface) · ")
        if let date = WgGatewayTime.date(item.last_seen) {
            text = text + Text(date, format: .relative(presentation: .named))
        }
        return text
    }

    // MARK: - 判定记录（一行一条）

    @ViewBuilder
    private func decisionRows(_ st: GatewayState) -> some View {
        if st.decisions.isEmpty {
            WgRow(symbol: nil, title: "暂无记录")
        }
        ForEach(Array(st.decisions.prefix(12).enumerated()), id: \.element.id) { index, d in
            if index > 0 { WgRowDivider() }
            HStack(spacing: WgSpace.m) {
                Image(systemName: d.trusted ? "house.fill" : "arrow.triangle.branch")
                    .foregroundStyle(d.trusted ? Color.teal : Color.secondary)
                    .frame(width: 16)
                Text(decisionTitle(d)).lineLimit(1)
                Spacer(minLength: WgSpace.s)
                Text(verbatim: d.ip ?? "—")
                    .font(.system(size: WgType.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
                if let date = WgGatewayTime.date(d.at) {
                    Text(date, format: .dateTime.month(.twoDigits).day(.twoDigits).hour().minute())
                        .font(.system(size: WgType.footnote))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .font(.system(size: WgType.body))
            .wgPadding(.horizontal, .l)
            .wgPadding(.vertical, .s)
        }
    }

    private func decisionTitle(_ d: GatewayDecision) -> LocalizedStringKey {
        if d.trusted { return "受信任「\(d.name ?? "")」· VPN 断开" }
        if d.ip == nil { return "没有网关 · 按外部网络" }
        if (d.mac ?? "").isEmpty { return "读不到 MAC · 按外部网络" }
        return "未受信任 · 按外部网络"
    }

    private func footer(_ st: GatewayState) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("判定只看网关 MAC；不在列表、读不到或没有网关都按外部网络处理。记录只存在本机。")
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: WgSpace.m)
            if !st.seen.isEmpty || !st.decisions.isEmpty {
                Button("清空记录") { Task { await client.gatewayAction("clear_seen") } }
                    .buttonStyle(.borderless)
            }
        }
        .font(.system(size: WgType.footnote))
        .foregroundStyle(.secondary)
        .wgPadding(.horizontal, .xs)
    }

    private func describe(_ cur: GatewayCurrent) -> String {
        let mac = (cur.mac?.isEmpty == false) ? cur.mac! : String(localized: "读不到 MAC", bundle: .wgLocalized)
        return "\(cur.ip) · \(mac) · \(cur.hardware_port ?? cur.interface)"
    }
}

/// 受信任网关一行：名字可直接改（回车保存），右侧移除。
private struct TrustedGatewayRow: View {
    @EnvironmentObject var client: DaemonClient
    let item: TrustedGateway
    let isCurrent: Bool
    @State private var name = ""

    var body: some View {
        HStack(spacing: WgSpace.m) {
            WgSquareBadge(symbol: isCurrent ? "house.fill" : "wifi.router", tint: isCurrent ? .teal : .gray, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                TextField("名字", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: WgType.body))
                    .onSubmit { rename() }
                subtitle
                    .font(.system(size: WgType.body))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Button {
                Task { await client.gatewayAction("untrust", mac: item.mac) }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("移出受信任列表")
        }
        .wgPadding(.horizontal, .l)
        .wgPadding(.vertical, .s)
        .frame(minHeight: 46)
        .onAppear { name = item.name }
        .onChange(of: item.name) { _, new in name = new }
    }

    private var subtitle: Text {
        var text = Text(verbatim: item.mac)
        if isCurrent {
            text = text + Text(verbatim: " · ") + Text("当前网关")
        } else if let date = WgGatewayTime.date(item.last_seen) {
            text = text + Text(verbatim: " · ") + Text("上次见到 ") + Text(date, format: .relative(presentation: .named))
        }
        return text
    }

    private func rename() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard trimmed != item.name else { return }
        Task { await client.gatewayAction("rename", mac: item.mac, name: trimmed) }
    }
}
