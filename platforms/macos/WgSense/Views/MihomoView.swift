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
                         value: Text(verbatim: m.status.map { ($0.config_path as NSString).lastPathComponent } ?? "—"),
                         detail: Text(verbatim: m.status.map { ($0.config_path as NSString).deletingLastPathComponent } ?? "单个 yaml，不分层"))
                InfoCard(symbol: "point.3.connected.trianglepath.dotted", tint: .gray, title: "本机端口",
                         value: Text(verbatim: m.phase == .running ? "127.0.0.1:\(m.status?.mixed_port ?? 0)" : "—"),
                         detail: Text(verbatim: m.status.map { "控制接口 \($0.controller)" } ?? "只监听本机，不对局域网开放"))
                InfoCard(symbol: "arrow.up.forward", tint: .gray, title: "出口",
                         value: Text("未接管"),
                         detail: Text("不开 TUN、不接管 DNS、不改系统代理；纯良暂不把它当作可信出口"))
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
                      isActive: m.phase == .running, isBusy: busy)
            VStack(alignment: .leading, spacing: WgSpace.xs) {
                Text(m.title)
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
        switch m.phase {
        case .unsupported:
            return "运行中的网络服务还不支持内置内核，更新网络服务后可用"
        case .notBundled:
            return "这份网络服务构建时没有带上内核"
        case .stopped:
            return "内核已就绪，启动后只监听本机端口，不影响本机网络"
        case .running:
            let since = WgCoverageFormat.clock(m.status?.started_at).map { " · \($0) 启动" } ?? ""
            return "pid \(m.status?.pid ?? 0) · 以 \(m.status?.user ?? "—") 身份运行\(since)"
        case .crashed:
            return m.status?.last_exit ?? m.status?.error ?? "进程已退出"
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
