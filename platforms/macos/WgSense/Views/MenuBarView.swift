import SwiftUI
import AppKit

// 菜单栏面板：控制中心 Wi‑Fi 模块的样式。
//
//   顶部   VPN 圆形徽章即开关 + 与主窗口同一口径的状态与原因
//   中部   守护 / 暂停 / 接收 三个等宽模块，开启才上色
//   信息   连接时显示网速，否则显示当前网络
//   底部   系统菜单项样式的“打开 / 退出”
struct MenuBarView: View {
    @EnvironmentObject var client: DaemonClient
    @AppStorage("appLanguage") private var appLanguageRaw = WgAppLanguage.system.rawValue
    @AppStorage("appAppearance") private var appAppearanceRaw = WgAppAppearance.system.rawValue
    @Environment(\.openWindow) var openWindow

    var body: some View {
        let vpn = client.vpnPresentation
        VStack(alignment: .leading, spacing: 0) {
            header(vpn)
                .wgPadding(.horizontal, .l)
                .wgPadding(.top, .l)
                .wgPadding(.bottom, .m)

            HStack(spacing: WgSpace.s) {
                guardModule
                pauseModule
                receiveModule
            }
            .wgPadding(.horizontal, .m)

            infoLine
                .wgPadding(.horizontal, .l)
                .wgPadding(.vertical, .m)

            Divider().wgPadding(.horizontal, .m)

            VStack(spacing: 0) {
                MenuItemRow(title: "打开 Xtrim…", symbol: "macwindow") {
                    openWindow(id: "main")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
                MenuItemRow(title: "退出", symbol: "power", shortcut: "⌘Q") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .wgPadding(.s)
        }
        .frame(width: 300)
        .focusEffectDisabled()
        .modifier(WgLocaleOverride(language: selectedLanguage))
        .preferredColorScheme(selectedAppearance.colorScheme)
        .animation(WgDesign.spring, value: vpn.phase)
        .id("menu-content-\(appLanguageRaw)")
        .task { await refresh() }
    }

    // MARK: - 顶部

    private func header(_ vpn: WgVPNPresentation) -> some View {
        HStack(spacing: WgSpace.m) {
            Button(action: toggleVPN) {
                WgCircleBadge(symbol: vpn.symbol, tint: vpn.tint, isOn: vpn.isConnected, size: 40, isBusy: vpn.isBusy)
            }
            .buttonStyle(.plain)
            .help(toggleHelp(vpn))

            VStack(alignment: .leading, spacing: WgSpace.zero) {
                HStack(spacing: WgSpace.s) {
                    Text("VPN")
                        .font(.system(size: WgType.body, weight: .semibold))
                    Text(vpn.title)
                        .font(.system(size: WgType.body, weight: vpn.isConnected ? .semibold : .regular))
                        .foregroundStyle(vpn.isConnected ? vpn.tint : Color.secondary)
                }
                Text(vpn.detail)
                    .font(.system(size: WgType.body))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func toggleVPN() {
        let vpn = client.vpnPresentation
        Task {
            if vpn.phase == .setupFailed {
                await client.retryServiceInstall()
            } else {
                await client.post(vpn.canDisconnect ? "disconnect" : "connect")
            }
            await client.fetchStatus()
        }
    }

    private func toggleHelp(_ vpn: WgVPNPresentation) -> LocalizedStringKey {
        if vpn.canDisconnect { return "断开 VPN" }
        if vpn.phase == .home { return "在家由守护保持断开；关闭守护后可手动连接" }
        if vpn.phase == .setupFailed { return "重试安装后台服务（会弹一次密码框）" }
        return "连接 VPN"
    }

    // MARK: - 模块

    private var online: Bool { client.status != nil }

    private var guardModule: some View {
        let on = online && client.isGuardOn
        return MenuModule(
            symbol: on ? "shield.fill" : "shield.slash",
            tint: .blue,
            title: "守护",
            status: on ? "运行中" : "已关闭",
            isOn: on,
            isEnabled: online && client.pendingGuardRunning == nil
        ) {
            Task {
                await client.setGuardEnabled(!client.isGuardOn)
                await client.fetchStatus()
            }
        }
    }

    private var pauseModule: some View {
        let on = client.isPauseOn
        return MenuModule(
            symbol: on ? "play.fill" : "pause.fill",
            tint: .orange,
            title: on ? "已暂停" : "暂停",
            status: on ? "点按继续" : "\(client.pauseMinutes) 分钟",
            isOn: on,
            isEnabled: online && client.pendingPaused == nil
        ) {
            Task {
                await client.post(on ? "resume" : "pause")
                await client.fetchStatus()
            }
        }
    }

    private var receiveModule: some View {
        let on = client.transferState?.running ?? false
        return MenuModule(
            symbol: "arrow.down",
            tint: .blue,
            title: "接收",
            status: on ? "已开启" : "已关闭",
            isOn: on,
            isEnabled: client.transferState != nil
        ) {
            Task { _ = await client.setTransferReceiveEnabled(!on) }
        }
    }

    // MARK: - 信息行

    @ViewBuilder
    private var infoLine: some View {
        if client.isTunnelUp {
            HStack(spacing: WgSpace.l) {
                speed("arrow.down", client.traffic?.rx_speed ?? 0)
                speed("arrow.up", client.traffic?.tx_speed ?? 0)
                Spacer()
                Text(verbatim: client.status?.service ?? "")
                    .font(.system(size: WgType.body))
                    .foregroundStyle(.tertiary)
            }
        } else if let s = client.status {
            HStack(spacing: WgSpace.s) {
                // 状态已在顶部说明，这里只给网络事实：网卡 + IP。
                let iface = s.network_interfaces?.first
                Image(systemName: iface?.hardware_port?.localizedCaseInsensitiveContains("wi-fi") == true ? "wifi" : "cable.connector")
                    .font(.system(size: WgType.body, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text(verbatim: iface?.hardware_port ?? iface?.name ?? "—")
                    .font(.system(size: WgType.body, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let ip = s.primaryIPv4 {
                    Text(verbatim: ip)
                        .font(.system(size: WgType.body).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
        } else {
            Text("后台服务未运行")
                .font(.system(size: WgType.body))
                .foregroundStyle(.secondary)
        }
    }

    private func speed(_ symbol: String, _ value: Double) -> some View {
        HStack(spacing: WgSpace.xs) {
            Image(systemName: symbol)
                .font(.system(size: WgType.micro, weight: .bold))
                .foregroundStyle(.tertiary)
            Text(verbatim: WgFormat.speed(value))
                .font(.system(size: WgType.sub, weight: .medium).monospacedDigit())
        }
    }

    // MARK: - 其他

    private var selectedLanguage: WgAppLanguage {
        WgAppLanguage(rawValue: appLanguageRaw) ?? .system
    }

    private var selectedAppearance: WgAppAppearance {
        WgAppAppearance(rawValue: appAppearanceRaw) ?? .system
    }

    private func refresh() async {
        await client.fetchStatus()
        await client.fetchTraffic()
        await client.fetchTransferState()
    }
}

/// 控制中心式小模块：圆形徽章 + 标题 + 状态，整块可点。
private struct MenuModule: View {
    var symbol: String
    var tint: Color
    var title: LocalizedStringKey
    var status: LocalizedStringKey
    var isOn: Bool
    var isEnabled: Bool
    var action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: WgSpace.s) {
            WgCircleBadge(symbol: symbol, tint: tint, isOn: isOn, size: 28)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: WgType.sub, weight: .semibold))
                    .lineLimit(1)
                Text(status)
                    .font(.system(size: WgType.body))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .wgPadding(.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(isEnabled ? 1 : 0.45)
        .wgInteractiveSurface(cornerRadius: WgRadius.s, isEnabled: isEnabled, action: action)
    }
}

/// 系统菜单项样式：悬停整行高亮为强调色。
private struct MenuItemRow: View {
    var title: LocalizedStringKey
    var symbol: String
    var shortcut: String? = nil
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: WgSpace.s) {
                Image(systemName: symbol)
                    .font(.system(size: WgType.sub))
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: WgType.body))
                Spacer()
                if let shortcut {
                    Text(verbatim: shortcut)
                        .font(.system(size: WgType.sub))
                        .foregroundStyle(hovering ? Color.white.opacity(0.8) : Color.secondary)
                }
            }
            .foregroundStyle(hovering ? Color.white : Color.primary)
            .wgPadding(.horizontal, .s)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: WgRadius.s, style: .continuous)
                    .fill(hovering ? WgInk.signal : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
