import SwiftUI

// 代理：WgSense 内置的本机 mihomo 内核（与「面板」不同，面板管的是 op 路由器上的 mihomo）。
//
// 骨架阶段：内核尚未内置，页面先把位置立起来，所有读数如实显示「未接入」，不做任何网络动作。
// 规划（2026-11-01 小企划）：裸二进制 + 单个 yaml、不分层；mihomo 是 WgSense 下的一个出口，
// 与纯良同属一个场景状态机（场景决定是否放行境外），互不打架；菜单栏显示当前场景与原因；
// 切换场景时清系统 DNS 缓存。接入后它就是纯良里的另一个可信出口，节点按身份放行，不再靠放行名单。
//
// 页面组织与概览、纯良同构：主视觉条 → 卡片网格 → 列表。

struct MihomoView: View {
    @EnvironmentObject var client: DaemonClient

    var body: some View {
        VStack(alignment: .leading, spacing: WgSpace.m) {
            WgPageHeader(title: "代理", subtitleText: "WGSENSE · MIHOMO", word: "PROXY") { EmptyView() }
            hero
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: WgSpace.m), GridItem(.flexible(), spacing: WgSpace.m)],
                spacing: WgSpace.m
            ) {
                InfoCard(symbol: "cpu", tint: .gray, title: "内核",
                         value: Text("未内置"), detail: Text("mihomo 裸二进制，随 App 分发"))
                InfoCard(symbol: "doc.text", tint: .gray, title: "配置",
                         value: Text(verbatim: "—"), detail: Text("单个 yaml，不分层"))
                InfoCard(symbol: "arrow.up.forward", tint: .gray, title: "出口",
                         value: Text("未启用"), detail: Text("启用后作为纯良的可信出口"))
                InfoCard(symbol: "text.magnifyingglass", tint: .gray, title: "DNS",
                         value: Text(verbatim: "—"), detail: Text("fake-ip 接管，查询不再发给当前网络"))
            }
            sceneList
            Spacer(minLength: 0)
        }
        .frame(maxWidth: WgLayout.pageMaxWidth, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    // MARK: - 主视觉条

    private var hero: some View {
        HStack(spacing: WgSpace.m) {
            StatusOrb(symbol: "globe", tint: .gray, isActive: false, isBusy: false)
            VStack(alignment: .leading, spacing: WgSpace.xs) {
                Text("未接入")
                    .font(.system(size: WgType.readout, weight: .semibold))
                Text("本机内核尚未内置。接入后是 WgSense 下与隧道并列的出口；op 路由器上的 mihomo 在「面板」")
                    .font(.system(size: WgType.body))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
        }
        .wgPadding(.m)
        .wgInteractiveSurface(cornerRadius: WgDesign.heroRadius)
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
                        .font(.system(size: WgType.sub, design: .monospaced))
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
