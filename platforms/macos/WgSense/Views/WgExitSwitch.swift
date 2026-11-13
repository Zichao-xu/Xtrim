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

/// 出口标识：单色、跟随前景色（图纸语言只有黑白灰）。
/// WireGuard 的龙与 mihomo 的猫取自各自官方标识，抽成单色剪影；Tailscale 的九点格直接绘制。
struct WgExitLogo: View {
    var exit: WgExit
    var size: CGFloat = 14

    var body: some View {
        Group {
            switch exit {
            case .wireguard: Image("ExitWireGuard").renderingMode(.template).resizable().interpolation(.high).scaledToFit()
            case .mihomo: Image("ExitMihomo").renderingMode(.template).resizable().interpolation(.high).scaledToFit()
            case .tailscale: TailscaleDots()
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(Text(verbatim: exit.title))
    }
}

/// Tailscale 标识：3×3 圆点，中行与下中实心（T 字），其余淡出。
private struct TailscaleDots: View {
    var body: some View {
        Canvas { ctx, sz in
            let cell = min(sz.width, sz.height) / 3
            let d = cell * 0.72
            let solid: Set<Int> = [3, 4, 5, 7]
            for i in 0..<9 {
                let x = CGFloat(i % 3) * cell + (cell - d) / 2
                let y = CGFloat(i / 3) * cell + (cell - d) / 2
                var dot = ctx
                dot.opacity = solid.contains(i) ? 1 : 0.35
                dot.fill(Path(ellipseIn: CGRect(x: x, y: y, width: d, height: d)), with: .foreground)
            }
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
        // 点击即高亮目标段，不等网络服务做完切换
        let current = client.displayedExit
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
            if exit == .tailscale {
                // Tailscale 还在开发：正常可点，只给一条提示，不灰显
                client.showInAppToast(title: String(localized: "Tailscale 开发中", bundle: .wgLocalized), detail: String(localized: "暂不能切换到 Tailscale 出口", bundle: .wgLocalized), symbol: "hammer")
                return
            }
            Task { await client.setExit(exit) }
        } label: {
            // 紧凑形态只放标识；常规形态标识 + 全名
            HStack(spacing: WgSpace.s) {
                WgExitLogo(exit: exit, size: compact ? 22 : 22)
                if !compact {
                    Text(verbatim: exit.title)
                        .font(.system(size: WgType.title, weight: selected ? .semibold : .medium))
                }
            }
            // 当前出口墨色，其余淡一档：一眼看出哪个在用
            .foregroundStyle(selected ? WgInk.ink : (available ? WgInk.ink3 : WgInk.ink4))
            .frame(maxWidth: .infinity)
            .frame(height: compact ? 38 : 48)
            .background {
                if selected {
                    Color.clear.wgGlassAccent(shape)
                } else {
                    WgShapePlate(shape: shape, fill: .clear, border: WgInk.rule, highlight: .clear)
                }
            }
            .overlay {
                // 切换进行中：亮线沿这一段的外框绕行，完成即消失
                if switching {
                    WgPerimeterRunner(shape: shape, color: WgInk.ink, lineWidth: 1.5, period: 1.0, length: 0.25)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || selected || !available || (client.switchingExit != nil && exit != .tailscale))
        .help(help(exit, selected: selected, available: available))
    }

    private func help(_ exit: WgExit, selected: Bool, available: Bool) -> String {
        if selected { return String(localized: "当前出口：\(exit.title)", bundle: .wgLocalized) }
        switch exit {
        case .tailscale: return String(localized: "Tailscale 开发中", bundle: .wgLocalized)
        case .mihomo where !available:
            return String(localized: "这份网络服务没有内置 mihomo 内核", bundle: .wgLocalized)
        case .mihomo where client.status?.exit == nil:
            return String(localized: "切换到 mihomo：先断开 WireGuard、更新网络服务，再启用 mihomo", bundle: .wgLocalized)
        default: return String(localized: "切换到 \(exit.title)：先断开当前出口，再启用它", bundle: .wgLocalized)
        }
    }
}
