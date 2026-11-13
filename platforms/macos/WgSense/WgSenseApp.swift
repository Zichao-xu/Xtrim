import SwiftUI
import AppKit

enum WgAppLanguage: String, CaseIterable, Identifiable {
    case system
    case zhHans
    case zhHant
    case english
    case japanese
    case korean
    case russian
    case persian
    case arabic
    case turkish
    case vietnamese

    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .system: return "跟随系统"
        case .zhHans: return "简体中文"
        case .zhHant: return "繁體中文"
        case .english: return "English"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        case .russian: return "Русский"
        case .persian: return "فارسی"
        case .arabic: return "العربية"
        case .turkish: return "Türkçe"
        case .vietnamese: return "Tiếng Việt"
        }
    }
    /// Bundle 本地化目录名；跟随系统时为 nil。
    var localizationID: String? {
        switch self {
        case .system: return nil
        case .zhHans: return "zh-Hans"
        case .zhHant: return "zh-Hant"
        case .english: return "en"
        case .japanese: return "ja"
        case .korean: return "ko"
        case .russian: return "ru"
        case .persian: return "fa"
        case .arabic: return "ar"
        case .turkish: return "tr"
        case .vietnamese: return "vi"
        }
    }

    /// 是否需要用 environment locale 强制指定语言。
    ///
    /// 强制指定会让 SwiftUI 每次解析文字都走“按指定语言查表”的路径，该路径不缓存，
    /// 每个 Text 都重新读取并解析一次 Localizable.strings。启动时已把所选语言写入本 App 的
    /// AppleLanguages，Bundle 默认就是该语言，只有运行中刚切换、尚未重启时才需要强制指定。
    var needsLocaleOverride: Bool {
        guard let id = localizationID else { return false }
        return Bundle.main.preferredLocalizations.first != id
    }

    /// 启动时调用：让 Bundle 以所选语言为首选（只写本 App 域，不影响系统）。
    static func applyPreferredLocalization() {
        let defaults = UserDefaults.standard
        let raw = defaults.string(forKey: "appLanguage") ?? WgAppLanguage.system.rawValue
        if let id = WgAppLanguage(rawValue: raw)?.localizationID {
            defaults.set([id], forKey: "AppleLanguages")
        } else {
            defaults.removeObject(forKey: "AppleLanguages")
        }
    }

    var locale: Locale {
        switch self {
        case .system: return .current
        case .zhHans: return Locale(identifier: "zh-Hans")
        case .zhHant: return Locale(identifier: "zh-Hant")
        case .english: return Locale(identifier: "en")
        case .japanese: return Locale(identifier: "ja")
        case .korean: return Locale(identifier: "ko")
        case .russian: return Locale(identifier: "ru")
        case .persian: return Locale(identifier: "fa")
        case .arabic: return Locale(identifier: "ar")
        case .turkish: return Locale(identifier: "tr")
        case .vietnamese: return Locale(identifier: "vi")
        }
    }
}

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


// MARK: - 运行中切换语言

extension Bundle {
    /// 当前所选界面语言的翻译包。所有 `String(localized:)` 都要带 `bundle: .wgLocalized`：
    /// 不带的话它按进程启动时的语言取文字，App 里切换语言后要重启才变，界面会中外混排
    /// （`Text("…")` 走 environment locale 已立即切换）。由 scripts/l10n 检查强制。
    static var wgLocalized: Bundle { WgLocalizedBundle.current }
}

enum WgLocalizedBundle {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Bundle] = [:]

    static var current: Bundle {
        let raw = UserDefaults.standard.string(forKey: "appLanguage") ?? WgAppLanguage.system.rawValue
        // 跟随系统，或所选语言已是进程首选（启动时写入了 AppleLanguages）→ 主包即可，走系统缓存。
        guard let id = WgAppLanguage(rawValue: raw)?.localizationID,
              Bundle.main.preferredLocalizations.first != id else { return .main }
        lock.lock(); defer { lock.unlock() }
        if let bundle = cache[id] { return bundle }
        let bundle = Bundle.main.path(forResource: id, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
        cache[id] = bundle
        return bundle
    }
}
