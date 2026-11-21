import SwiftUI

// 界面语言：可选语言与运行中切换用的翻译包。
// 单独成文件、只依赖 SwiftUI：外观、HUD、排版等检查脚本只编译少数几个界面文件，
// 这些文件里的 `String(localized:, bundle: .wgLocalized)` 需要它才能编译。

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
