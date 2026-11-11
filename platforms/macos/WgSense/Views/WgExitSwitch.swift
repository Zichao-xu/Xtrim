import SwiftUI

/// VPN 的三个出口：同一时刻只有一个接管流量，只能切换。
enum WgExit: String, CaseIterable, Identifiable {
    case wireguard, tailscale, mihomo
    var id: String { rawValue }

    var title: String {
        switch self {
        case .wireguard: return "WireGuard"
        case .tailscale: return "Tailscale"
        case .mihomo: return "mihomo"
        }
    }

    var code: String {
        switch self {
        case .wireguard: return "WG"
        case .tailscale: return "TS"
        case .mihomo: return "MH"
        }
    }
}

/// 出口切换：三段平行排列，当前出口白色弱玻璃；点另一段即切换。
/// 紧凑形态（磁贴）用两字母代号，常规形态（页面）用全名。
struct WgExitSwitch: View {
    @EnvironmentObject var client: DaemonClient
    var compact = false
    var isEnabled = true

    var body: some View {
        let current = client.currentExit
        HStack(spacing: WgSpace.xs) {
            ForEach(WgExit.allCases) { exit in
                segment(exit, current: current)
            }
        }
    }

    private func segment(_ exit: WgExit, current: WgExit) -> some View {
        let selected = exit == current
        let switching = client.switchingExit == exit
        let available = client.exitAvailable(exit)
        let shape = ChamferShape(tr: WgInk.cutControl)
        return Button {
            Task { await client.setExit(exit) }
        } label: {
            HStack(spacing: WgSpace.xs) {
                if switching { ProgressView().controlSize(.mini) }
                Text(verbatim: compact ? exit.code : exit.title)
                    .font(compact ? WgInk.mono(.caption, .semibold) : .system(size: WgType.body, weight: selected ? .semibold : .medium))
                    .tracking(compact ? 1.2 : 0)
            }
            .foregroundStyle(selected ? WgInk.ink : (available ? WgInk.ink2 : WgInk.ink4))
            .frame(maxWidth: .infinity)
            .frame(height: compact ? 24 : 30)
            .background {
                if selected {
                    Color.clear.wgGlassAccent(shape)
                } else {
                    WgShapePlate(shape: shape, fill: .clear, border: WgInk.rule, highlight: .clear)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || selected || !available || client.switchingExit != nil)
        .help(help(exit, selected: selected, available: available))
    }

    private func help(_ exit: WgExit, selected: Bool, available: Bool) -> String {
        if selected { return "当前出口：\(exit.title)" }
        switch exit {
        case .tailscale: return "Tailscale 尚未接入"
        case .mihomo where !available:
            return client.status?.exit == nil ? "需要更新网络服务后才能切换出口" : "这份网络服务没有内置 mihomo 内核"
        default: return "切换到 \(exit.title)：先断开当前出口，再启用它"
        }
    }
}
