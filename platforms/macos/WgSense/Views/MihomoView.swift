import SwiftUI

// 代理：WgSense 内置的本机 mihomo 内核（自建 throughput 版，与 op 同一提交）。
// 「面板」管的是 op 路由器上的 mihomo；这里管的是这台 Mac 自己的内核。
//
// 本阶段：内核随网络服务分发，由服务释放并以 nobody 身份运行；只监听本机端口，
// 不开 TUN、不接管 DNS、不改系统代理，启停不影响本机网络。
// 规划（2026-11-01 小企划）：裸二进制 + 单个 yaml、不分层；作为 WgSense 下与隧道并列的出口，
// 与纯良同属一个场景状态机；接入后节点按身份放行，不再靠放行名单。
//
// 页面组织与概览、纯良同构：主视觉条 → 卡片网格 → 列表。

/// 页面与磁贴共用的内核状态。
struct MihomoPresentation: Equatable {
    enum Phase: Equatable {
        case unsupported   // 运行中的网络服务还没有这个接口
        case notBundled    // 服务有接口，但这份构建没带内核
        case stopped
        case running
        case crashed       // 希望运行，但进程已退出
    }

    var phase: Phase
    var status: MihomoStatus?

    init(status: MihomoStatus?, error: String?) {
        self.status = status
        guard let status else {
            phase = .unsupported
            return
        }
        if !status.bundled {
            phase = .notBundled
        } else if status.running {
            phase = .running
        } else if status.desired {
            phase = .crashed
        } else {
            phase = .stopped
        }
    }

    var title: LocalizedStringKey {
        switch phase {
        case .unsupported: return "未接入"
        case .notBundled: return "未内置"
        case .stopped: return "已停止"
        case .running: return "运行中"
        case .crashed: return "意外退出"
        }
    }
}

struct MihomoView: View {
    @EnvironmentObject var client: DaemonClient
    /// 嵌进 VPN 板块（mihomo 子页）时不显示自己的页头。
    var showsHeader = true
    @State private var busy = false

    private var m: MihomoPresentation { MihomoPresentation(status: client.mihomo, error: client.mihomoError) }

    var body: some View {
        let m = m
        return VStack(alignment: .leading, spacing: WgSpace.m) {
            if showsHeader {
                WgPageHeader(title: "代理", subtitleText: "WGSENSE · MIHOMO", word: "PROXY") { EmptyView() }
            }
            hero(m)
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: WgSpace.m), GridItem(.flexible(), spacing: WgSpace.m)],
                spacing: WgSpace.m
            ) {
                InfoCard(symbol: "cpu", tint: .gray, title: "内核",
                         value: Text(verbatim: m.status?.version ?? "—"),
                         detail: Text(kernelDetail(m)))
                InfoCard(symbol: "doc.text", tint: .gray, title: "配置",
                         value: Text(verbatim: configValue(m)),
                         detail: Text(verbatim: m.status?.source ?? String(localized: "默认配置：只监听本机、全部直连，不能作为出口", bundle: .wgLocalized))) {
                    if m.status?.bundled == true {
                        Button {
                            Task { await client.syncMihomoFromOp() }
                        } label: {
                            if client.syncingMihomo { ProgressView().controlSize(.small) } else { Text("从 op 同步") }
                        }
                        .controlSize(.small)
                        .disabled(client.syncingMihomo)
                        .help("用 SSH 从「面板」当前路由器拉取 /etc/mihomo 的配置，改写成 Mac 版后替换")
                    }
                }
                InfoCard(symbol: "point.3.connected.trianglepath.dotted", tint: .gray, title: "本机端口",
                         value: Text(verbatim: m.phase == .running ? "127.0.0.1:\(m.status?.mixed_port ?? 0)" : "—"),
                         detail: Text(verbatim: m.status.map { String(localized: "控制接口 \($0.controller)", bundle: .wgLocalized) } ?? String(localized: "只监听本机，不对局域网开放", bundle: .wgLocalized)))
                InfoCard(symbol: "arrow.up.forward", tint: .gray, title: "出口",
                         value: Text(takingOver(m) ? "接管中" : "未接管"),
                         detail: Text(verbatim: exitDetail(m)))
            }
            if let dropped = m.status?.dropped, !dropped.isEmpty {
                droppedList(dropped)
            }
            sceneList
            Spacer(minLength: 0)
        }
        .frame(maxWidth: WgLayout.pageMaxWidth, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .top)
        .task {
            // 页面可见时 2 秒一轮；离开页面即停（任务随视图取消）
            while !Task.isCancelled {
                await client.fetchMihomo()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // MARK: - 主视觉条

    private func hero(_ m: MihomoPresentation) -> some View {
        HStack(spacing: WgSpace.m) {
            StatusOrb(symbol: "globe", tint: m.phase == .crashed ? .orange : .green,
                      isActive: m.phase == .running, isBusy: busy || client.switchingExit == .mihomo, logo: .mihomo)
            VStack(alignment: .leading, spacing: WgSpace.xs) {
                (client.switchingExit == .mihomo ? Text("切换中") : Text(m.title))
                    .font(.system(size: WgType.readout, weight: .semibold))
                    .foregroundStyle(m.phase == .crashed ? WgInk.warn : WgInk.ink)
                    .contentTransition(.opacity)
                Text(verbatim: heroDetail(m))
                    .font(.system(size: WgType.body))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 12)
            // 内核的启停只属于「出口已经是 mihomo」的情况：出口还不是它、或正在切换时，
            // 不提供单独启动——那会绕开切换流程（同步配置、升级服务、拆旧出口），切换只走上面的切换条。
            if client.switchingExit != nil {
                EmptyView()
            } else if client.currentExit == .mihomo {
                switch m.phase {
                case .running:
                    Button("停止") { toggle(false) }
                        .buttonStyle(WgCapsuleButtonStyle(tint: .red, prominent: false))
                        .disabled(busy)
                case .stopped, .crashed:
                    Button(m.phase == .crashed ? "重新启动" : "启动") { toggle(true) }
                        .buttonStyle(WgCapsuleButtonStyle(tint: m.phase == .crashed ? .orange : .green))
                        .disabled(busy)
                case .unsupported, .notBundled:
                    EmptyView()
                }
            }
        }
        .wgPadding(.m)
        .wgInteractiveSurface(cornerRadius: WgDesign.heroRadius)
    }

    private func toggle(_ running: Bool) {
        Task {
            busy = true
            _ = await client.setMihomo(running: running)
            busy = false
        }
    }

    private func heroDetail(_ m: MihomoPresentation) -> String {
        if client.switchingExit == .mihomo {
            return (client.exitProgress ?? String(localized: "正在切换到 mihomo", bundle: .wgLocalized)) + "…"
        }
        switch m.phase {
        case .unsupported:
            return String(localized: "运行中的网络服务还不支持内置内核，更新网络服务后可用", bundle: .wgLocalized)
        case .notBundled:
            return String(localized: "这份网络服务构建时没有带上内核", bundle: .wgLocalized)
        case .stopped:
            return String(localized: "内核已就绪，启动后只监听本机端口，不影响本机网络", bundle: .wgLocalized)
        case .running:
            let since = WgCoverageFormat.clock(m.status?.started_at).map { String(localized: " · \($0) 启动", bundle: .wgLocalized) } ?? ""
            return String(localized: "pid \(m.status?.pid ?? 0) · 以 \(m.status?.user ?? "—") 身份运行\(since)", bundle: .wgLocalized)
        case .crashed:
            return m.status?.last_exit ?? m.status?.error ?? String(localized: "进程已退出", bundle: .wgLocalized)
        }
    }

    private func configValue(_ m: MihomoPresentation) -> String {
        guard let st = m.status else { return "—" }
        guard st.source != nil else { return String(localized: "默认配置", bundle: .wgLocalized) }
        let at = WgCoverageFormat.clock(st.synced_at).map { " · \($0)" } ?? ""
        return String(localized: "op 同步\(at)", bundle: .wgLocalized)
    }

    private func takingOver(_ m: MihomoPresentation) -> Bool {
        m.phase == .running && m.status?.source != nil && client.currentExit == .mihomo
    }

    private func exitDetail(_ m: MihomoPresentation) -> String {
        if takingOver(m) {
            let dns = m.status?.dns_service.map { String(localized: "DNS 已接管「\($0)」", bundle: .wgLocalized) } ?? String(localized: "DNS 未接管", bundle: .wgLocalized)
            return String(localized: "TUN 接管整机流量 · \(dns) · 纯良休眠，内核一停立即接管", bundle: .wgLocalized)
        }
        if m.status?.source == nil { return String(localized: "先从 op 同步配置，才能作为出口", bundle: .wgLocalized) }
        return String(localized: "在 VPN 板块切到 mihomo 后接管整机流量与 DNS", bundle: .wgLocalized)
    }

    /// 同步时剔除的节点：只能在路由器上用（依赖路由器本机的 SSH 私钥等）。
    private func droppedList(_ names: [String]) -> some View {
        VStack(alignment: .leading, spacing: WgSpace.s) {
            Text("Mac 上不可用的节点")
                .font(.system(size: WgType.sub, weight: .semibold))
                .foregroundStyle(.secondary)
                .wgPadding(.leading, .xs)
            VStack(spacing: 0) {
                ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                    if index > 0 { rule }
                    sceneRow("nosign", LocalizedStringKey(name), "已剔除", "依赖路由器本机文件（SSH 私钥等），同步时连同经它中转的节点一起去掉")
                }
            }
            .wgInteractiveSurface(cornerRadius: WgDesign.cardRadius)
        }
    }

    private func kernelDetail(_ m: MihomoPresentation) -> LocalizedStringKey {
        switch m.phase {
        case .unsupported: return "自建 throughput 版，随网络服务分发"
        case .notBundled: return "这份构建未内置"
        default: return "自建 throughput 版，与 op 同一提交"
        }
    }

    // MARK: - 场景（规划）

    private var sceneList: some View {
        VStack(alignment: .leading, spacing: WgSpace.s) {
            Text("场景")
                .font(.system(size: WgType.sub, weight: .semibold))
                .foregroundStyle(.secondary)
                .wgPadding(.leading, .xs)
            VStack(spacing: 0) {
                sceneRow("house", "在家", "不启用", "境外流量由 op 上的 mihomo 处理")
                rule
                sceneRow("lock.shield", "离家 · 隧道可用", "不启用", "隧道是出口，DNS 经隧道")
                rule
                sceneRow("globe", "特殊场景", "启用", "不必回家的地区（如在香港）：本机内核直接出境")
                rule
                sceneRow("arrow.triangle.2.circlepath", "切换场景", "清 DNS 缓存", "避免旧解析结果绕过新出口")
            }
            .wgInteractiveSurface(cornerRadius: WgDesign.cardRadius)
            Text("规划中，尚未实现。场景与纯良同属一个状态机，菜单栏显示当前场景与原因。")
                .font(.system(size: WgType.body))
                .foregroundStyle(.secondary)
                .wgPadding(.horizontal, .xs)
        }
    }

    private func sceneRow(_ symbol: String, _ name: LocalizedStringKey, _ value: LocalizedStringKey,
                          _ detail: LocalizedStringKey) -> some View {
        HStack(alignment: .center, spacing: WgSpace.m) {
            WgSquareBadge(symbol: symbol, tint: .gray, size: 24, dimmed: true)
            VStack(alignment: .leading, spacing: WgSpace.zero) {
                HStack(spacing: WgSpace.s) {
                    Text(name).font(.system(size: WgType.body, weight: .medium))
                    Spacer(minLength: 8)
                    Text(value)
                        .font(.system(size: WgType.body))
                        .foregroundStyle(WgInk.ink3)
                }
                Text(detail)
                    .font(.system(size: WgType.body))
                    .foregroundStyle(.secondary)
            }
        }
        .wgPadding(.horizontal, .l)
        .wgPadding(.vertical, .s)
    }

    private var rule: some View {
        Divider().opacity(0.5).wgInset(.leading, 50)
    }
}
