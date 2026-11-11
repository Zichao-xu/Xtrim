import SwiftUI

// VPN 板块：三个出口（WireGuard / Tailscale / mihomo）互斥，只能切换。
// 顶部是出口切换，下面是当前出口的子页；切换由网络服务先拆旧出口再起新出口。
// 本阶段只做手动切换；Tailscale 只占位。
struct VPNView: View {
    @EnvironmentObject var client: DaemonClient

    var body: some View {
        let exit = client.currentExit
        return VStack(alignment: .leading, spacing: WgSpace.m) {
            WgPageHeader(title: "VPN", subtitleText: "WGSENSE · EXIT · \(exit.code)", word: "VPN") { EmptyView() }
            VStack(alignment: .leading, spacing: WgSpace.s) {
                WgExitSwitch()
                Text(verbatim: switchNote(exit))
                    .font(.system(size: WgType.body))
                    .foregroundStyle(.secondary)
                    .wgPadding(.horizontal, .xs)
            }
            Group {
                switch exit {
                case .wireguard: OverviewView(showsHeader: false)
                case .tailscale: tailscalePlaceholder
                case .mihomo: MihomoView(showsHeader: false)
                }
            }
            .id(exit)
        }
        .frame(maxWidth: WgLayout.pageMaxWidth, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .top)
        .task { await client.fetchMihomo() }
    }

    private func switchNote(_ exit: WgExit) -> String {
        if let target = client.switchingExit {
            return (client.exitProgress ?? "正在切换到 \(target.title)") + " …"
        }
        if client.status?.exit == nil { return "运行中的网络服务还不支持切换出口；点 mihomo 会先更新网络服务再切换" }
        return "三个出口互斥，同一时刻只有一个接管流量。切换时先断开当前出口，空档内出站拦截照常生效。"
    }

    private var tailscalePlaceholder: some View {
        HStack(spacing: WgSpace.m) {
            WgSquareBadge(symbol: "point.3.filled.connected.trianglepath.dotted", tint: .gray, size: 24, dimmed: true)
            VStack(alignment: .leading, spacing: WgSpace.xs) {
                Text("Tailscale 尚未接入").font(.system(size: WgType.body, weight: .medium))
                Text("待定").font(.system(size: WgType.body)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .wgPadding(.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .wgInteractiveSurface(cornerRadius: WgDesign.cardRadius)
    }
}
