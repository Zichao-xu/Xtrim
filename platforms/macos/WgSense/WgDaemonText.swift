import Foundation

/// 守护进程（Go）文字的显示翻译。
///
/// 守护进程的日志与接口提示是中文原文（日志文件、诊断包保持原文，方便对照代码排查）。App 显示时按“句式”认出来，
/// 换成当前界面语言：句式由 scripts/l10n/daemon_collect.py 从 Go 源码收进 Daemon.xcstrings，
/// 格式动词统一为 %@；运行时把句式变成正则，抠出参数，参数本身再递归翻译一遍（Go 里常把一段提示嵌进另一段）。
/// 认不出的文字原样返回。
enum WgDaemonText {
    private struct Template {
        let regex: NSRegularExpression
        let anchor: String      // 最长的一段固定文字：先用 contains 粗筛，命中才跑正则
        let value: String
        let weight: Int         // 固定文字总长：多个句式都能匹配时取最具体的
    }

    private struct Table {
        var templates: [Template] = []
        var fragments: [(String, String)] = []   // 无参数句式，按长度倒序，用于整句认不出时的片段替换
        var cache: [String: String] = [:]
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var tables: [String: Table] = [:]
    private static let cjk = try! NSRegularExpression(pattern: "[\\u4e00-\\u9fff]")

    /// 接口返回的文字：只做整句匹配（避免误改配置名、主机名这类数据）。
    static func localize(_ text: String) -> String { translate(text, fragments: false, depth: 0) }

    /// 日志行：整句认不出时，再按已知片段逐段替换。
    static func localizeLog(_ text: String) -> String { translate(text, fragments: true, depth: 0) }

    /// 接口 JSON：把其中每个字符串值按整句翻译后再交给解码器。日志接口不要走这里（日志页自己翻、可切回原文）。
    static func localizeJSON(_ data: Data) -> Data {
        guard currentLanguage().map({ !$0.hasPrefix("zh-Hans") }) ?? false,
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return data }
        let mapped = map(object)
        return (try? JSONSerialization.data(withJSONObject: mapped, options: [.fragmentsAllowed])) ?? data
    }

    private static func map(_ value: Any) -> Any {
        switch value {
        case let s as String: return localize(s)
        case let a as [Any]: return a.map(map)
        case let d as [String: Any]: return d.mapValues(map)
        default: return value
        }
    }

    // MARK: -

    private static func currentLanguage() -> String? {
        let bundle = Bundle.wgLocalized
        if bundle == .main { return Bundle.main.preferredLocalizations.first }
        return (bundle.bundlePath as NSString).lastPathComponent.replacingOccurrences(of: ".lproj", with: "")
    }

    private static func hasCJK(_ s: String) -> Bool {
        cjk.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    private static func translate(_ text: String, fragments: Bool, depth: Int) -> String {
        guard depth < 4, hasCJK(text), let lang = currentLanguage(), !lang.hasPrefix("zh-Hans") else { return text }
        lock.lock(); defer { lock.unlock() }
        var table = tables[lang] ?? load(lang)
        let cacheKey = (fragments ? "f|" : "s|") + text
        if let hit = table.cache[cacheKey] { return hit }
        lock.unlock()
        let result = compute(text, table: table, fragments: fragments, depth: depth)
        lock.lock()
        if table.cache.count > 4000 { table.cache.removeAll() }
        table.cache[cacheKey] = result
        tables[lang] = table
        return result
    }

    private static func compute(_ text: String, table: Table, fragments: Bool, depth: Int) -> String {
        let range = NSRange(text.startIndex..., in: text)
        for t in table.templates where text.contains(t.anchor) {
            guard let m = t.regex.firstMatch(in: text, range: range) else { continue }
            let args: [String] = (1..<max(1, m.numberOfRanges)).compactMap { i in
                Range(m.range(at: i), in: text).map { translate(String(text[$0]), fragments: fragments, depth: depth + 1) }
            }
            return args.isEmpty ? t.value : String(format: t.value, arguments: args.map { $0 as NSString })
        }
        // 整句对不上：Go 常用「；」「，」把几段提示拼成一句 → 拆段逐段翻，再按目标语言的标点接回去。
        for separator in ["；", "，"] where text.contains(separator) {
            let segments = text.components(separatedBy: separator)
            guard segments.count > 1 else { continue }
            let translated = segments.map { translate($0, fragments: fragments, depth: depth + 1) }
            guard translated != segments else { continue }
            return translated.joined(separator: joiner(for: separator))
        }
        guard fragments else { return text }
        var out = text
        for (source, target) in table.fragments where out.contains(source) {
            out = out.replacingOccurrences(of: source, with: target)
        }
        return out
    }

    /// 拆段后接回去用的标点：中日文保持全角，其他语言用半角加空格。
    private static func joiner(for separator: String) -> String {
        let lang = currentLanguage() ?? ""
        if lang.hasPrefix("zh") || lang.hasPrefix("ja") { return separator }
        return separator == "；" ? "; " : ", "
    }

    private static func load(_ lang: String) -> Table {
        var table = Table()
        guard let path = Bundle.main.path(forResource: "Daemon", ofType: "strings", inDirectory: nil, forLocalization: lang),
              let dict = NSDictionary(contentsOfFile: path) as? [String: String] else { return table }
        for (key, value) in dict where key != value {
            let parts = key.components(separatedBy: "%@").map { $0.replacingOccurrences(of: "%%", with: "%") }
            if parts.count == 1 {
                if parts[0].count >= 2 { table.fragments.append((parts[0], value.replacingOccurrences(of: "%%", with: "%"))) }
            }
            let pattern = "^" + parts.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "(.*?)") + "$"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { continue }
            let value = parts.count == 1 ? value.replacingOccurrences(of: "%%", with: "%") : value
            table.templates.append(Template(regex: regex, anchor: parts.max(by: { $0.count < $1.count }) ?? "",
                                            value: value, weight: parts.reduce(0) { $0 + $1.count }))
        }
        table.templates.sort { $0.weight > $1.weight }
        table.fragments.sort { $0.0.count > $1.0.count }
        return table
    }
}
