import SwiftUI

/// VPN 当前该怎么“说”：侧栏模块、概览主视觉、主按钮共用这一份，保证全界面口径一致。
struct WgVPNPresentation {
    enum Phase: Equatable {
        case offline        // daemon 不可达
        case setupFailed    // 后台服务安装失败，等待用户重试
        case connected
        case connecting
        case disconnecting
        case retrying       // 想连但还没连上
        case home           // 受信任网络 + 守护：设计上保持断开
        case idle           // 断开，且没有自动策略要连
    }

    let phase: Phase
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let symbol: String
    let tint: Color

    /// 隧道真实建立。只有这时徽章才上色。
    var isConnected: Bool { phase == .connected }
    var isBusy: Bool { phase == .connecting || phase == .disconnecting || phase == .retrying }
    /// 主按钮能否执行“连接”。在家受守护约束时不能。
    var canConnect: Bool { phase == .idle || phase == .retrying }
    var canDisconnect: Bool { phase == .connected || phase == .connecting || phase == .retrying }
}

extension DaemonClient {
    var vpnPresentation: WgVPNPresentation {
        guard let s = status else {
            if serviceNeedsRetry {
                return .init(phase: .setupFailed, title: "后台服务未安装",
                             detail: LocalizedStringKey(serviceLifecycleError ?? String(localized: "安装失败", bundle: .wgLocalized)),
                             symbol: "exclamationmark.triangle.fill", tint: .orange)
            }
            if isAuthorizingDaemon {
                return .init(phase: .offline, title: "正在安装后台服务", detail: "请在系统弹窗中输入管理员密码（仅需一次）",
                             symbol: "power", tint: .gray)
            }
            return .init(phase: .offline, title: "服务未运行", detail: "首次连接时会安装后台服务，只需授权一次",
                         symbol: "power", tint: .gray)
        }
        if pendingConnected == true || s.state == "Connecting" {
            return .init(phase: .connecting, title: "连接中", detail: "正在建立隧道…",
                         symbol: "lock.shield.fill", tint: .green)
        }
        if pendingConnected == false || s.state == "Disconnecting" {
            return .init(phase: .disconnecting, title: "断开中", detail: "正在关闭隧道…",
                         symbol: "lock.shield.fill", tint: .gray)
        }
        if s.state == "Connected" {
            let detail: LocalizedStringKey
            if let age = s.last_handshake_age_seconds {
                detail = "隧道已建立 · 握手 \(WgFormat.age(age))"
            } else {
                detail = "隧道已建立"
            }
            return .init(phase: .connected, title: "已连接", detail: detail,
                         symbol: "lock.shield.fill", tint: .green)
        }
        let guardOn = s.desired_guard_enabled ?? !s.paused
        if s.isTrustedNetwork && guardOn {
            return .init(phase: .home, title: "在家", detail: "受信任网络，守护保持 VPN 断开",
                         symbol: "house.fill", tint: .teal)
        }
        if s.desired_vpn_enabled == true {
            let detail: LocalizedStringKey
            if let failures = s.auto_failures, failures > 0 {
                detail = "连接失败，正在重试（第 \(failures) 次）"
            } else {
                detail = "正在尝试连接…"
            }
            return .init(phase: .retrying, title: "重新连接中", detail: detail,
                         symbol: "lock.shield.fill", tint: .orange)
        }
        return .init(phase: .idle, title: "未连接",
                     detail: guardOn ? "外部网络，守护将自动连接" : "守护已关闭，需要时手动连接",
                     symbol: "shield.slash.fill", tint: .gray)
    }
}
