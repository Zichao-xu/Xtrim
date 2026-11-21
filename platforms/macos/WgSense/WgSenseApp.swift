import SwiftUI
import AppKit

enum WgAppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

// AppDelegate：防止关闭主窗口后应用退出，保证菜单栏入口常驻
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: WgStatusBarController?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 如果是通过 Finder/单击图标启动，不自动弹窗（菜单栏优先）
        // 保留窗口逻辑由 SwiftUI 管理
        statusBar = WgStatusBarController(client: WgSenseApp.sharedClient)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 不在 App 退出时自动关闭 daemon。网络连接属于用户显式状态，
        // 只能通过界面里的停止/维护操作关闭，避免菜单栏或窗口生命周期误断 VPN。
    }
}

@main
struct WgSenseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    /// 主窗口与菜单栏（AppKit 管理，不在 Scene 里）共用同一个 client。
    @MainActor static let sharedClient = DaemonClient()
    @StateObject private var client = WgSenseApp.sharedClient

    init() {
        WgAppLanguage.applyPreferredLocalization()
        WgFrameProbe.startIfRequested()
        #if DEBUG
        WgTunePanelController.showIfRequested()
        #endif
    }

    var body: some Scene {
        // 主窗口：Surge 风格 sidebar + 详情
        WindowGroup(id: "main") {
            MainView()
                .environmentObject(client)
                // 仪表语言：全局强调色 = 克莱因蓝（开关、选中、焦点环统一）。
                .tint(WgInk.control)
                .frame(minWidth: 720, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
                .alert("操作失败", isPresented: Binding(
                    get: { client.alertMsg != nil },
                    set: { if !$0 { client.alertMsg = nil } }
                )) {
                    Button("确定", role: .cancel) { client.alertMsg = nil }
                } message: {
                    Text(client.alertMsg ?? "")
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 900, height: 600)
        #if DEBUG
        .commands { WgTuneCommands() }
        #endif
        // 菜单栏入口见 WgStatusBarController（盾牌 + 网速 + 日期 + 时间）
    }

}
