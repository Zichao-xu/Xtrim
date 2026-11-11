import Foundation

// 自定义规则的写操作（P-M06…P-M10），对应 AnGe 服务端：
//   normalizeProxyDomainRuleInput / add… / update… / delete… / reorder…InYamlContent / reloadProxyDomainRulesOnOpenWrt
// 自定义规则文件是简单的 `rules:` 列表，这里做行级编辑：只改动目标条目，其余内容与缩进原样保留。

enum CustomRuleError: LocalizedError {
    case invalid(String)
    case notFound
    case duplicated

    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .notFound: return "未找到原规则，文件可能已被修改，请刷新后重试"
        case .duplicated: return "该域名规则已存在，未重复写入"
        }
    }
}

struct CustomRuleInput {
    static let domainTypes = ["DOMAIN-SUFFIX", "DOMAIN", "DOMAIN-KEYWORD"]
    static let ipTypes = ["IP-CIDR", "IP-CIDR6", "SRC-IP-CIDR", "SRC-IP-CIDR6"]
    static let allTypes = domainTypes + ipTypes

    static let typeTitles: [String: String] = [
        "DOMAIN-SUFFIX": "域名后缀", "DOMAIN": "域名", "DOMAIN-KEYWORD": "关键字",
        "IP-CIDR": "目标IP", "IP-CIDR6": "目标IPv6", "SRC-IP-CIDR": "源IP", "SRC-IP-CIDR6": "源IPv6",
    ]

    enum InsertMode: String, CaseIterable { case append, beforeTypes }

    var type: String
    var value: String
    var target: String
    var insertMode: InsertMode = .append
    var beforeTypes: [String] = []

    /// 校验并规范化，返回 `TYPE,VALUE,TARGET`（normalizeProxyDomainRuleInput）。
    func normalizedRule() throws -> String {
        let t = Self.allTypes.contains(RuleEntry.normalizeType(type)) ? RuleEntry.normalizeType(type) : "DOMAIN-SUFFIX"
        let v = try Self.normalizeValue(value, type: t)
        let target = self.target.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { throw CustomRuleError.invalid("请选择目标节点或节点组") }
        guard !target.contains(where: { $0 == "," || $0 == "\n" || $0 == "\r" }) else {
            throw CustomRuleError.invalid("目标名称不能包含逗号或换行")
        }
        return "\(t),\(v),\(target)"
    }

    static func normalizeValue(_ raw: String, type: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw CustomRuleError.invalid("请先输入域名、关键字或 IP。") }
        if ipTypes.contains(type) {
            guard !value.contains(where: { $0 == " " || $0 == "," || $0 == "\n" }) else {
                throw CustomRuleError.invalid("不要包含空格、逗号或换行。")
            }
            guard let parsed = IPMatcher.parseCIDR(value) else {
                let example = type.hasSuffix("6") ? "2001:db8::/32" : "1.2.3.4/32"
                throw CustomRuleError.invalid("请输入正确的 IP 或 CIDR，例如 \(example)。")
            }
            let isV6 = parsed.bytes.count == 16
            if type.hasSuffix("6") != isV6 {
                throw CustomRuleError.invalid("当前规则类型需要填写 \(type.hasSuffix("6") ? "IPv6" : "IPv4")。")
            }
            return value
        }
        // 域名：允许粘贴 URL，取主机名；去掉 *. 前缀与首尾点。
        var host = value
        if host.range(of: #"^[a-z][a-z0-9+.-]*://"#, options: [.regularExpression, .caseInsensitive]) != nil,
           let parsedHost = URL(string: host)?.host {
            host = parsedHost
        }
        if host.hasPrefix("*.") { host = String(host.dropFirst(2)) }
        host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !host.isEmpty else { throw CustomRuleError.invalid("请先输入域名、关键字或 IP。") }
        guard !host.contains(where: { $0 == " " || $0 == "," || $0 == "\n" }) else {
            throw CustomRuleError.invalid("不要包含空格、逗号或换行。")
        }
        guard host.count <= 253 else { throw CustomRuleError.invalid("域名过长") }
        if type != "DOMAIN-KEYWORD" {
            if IPMatcher.parseIP(host) != nil {
                throw CustomRuleError.invalid("当前规则类型需要填域名，但输入看起来是 IP。")
            }
            let labels = host.split(separator: ".", omittingEmptySubsequences: false)
            let valid = labels.count >= 1 && labels.allSatisfy { label in
                !label.isEmpty && label.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
                    && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
            }
            guard valid else { throw CustomRuleError.invalid("请输入正确的域名，例如 example.com。") }
        }
        return host
    }

    /// 用于判重的规范形式（getComparableProxyDomainRule）。
    static func comparable(_ rule: String) -> String? {
        let parts = rule.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 3 else { return nil }
        let type = RuleEntry.normalizeType(parts[0])
        guard allTypes.contains(type), let v = try? normalizeValue(parts[1], type: type) else { return nil }
        return [type, v, parts[2]].joined(separator: "\n")
    }

    static func ordered(_ rule: String) -> String {
        rule.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ",")
    }
}

/// 行级 YAML 编辑器：只处理顶层 `rules:` 下的 `- 值` 条目。
struct CustomRuleDocument {
    var lines: [String]

    init(_ text: String) {
        var parts = text.components(separatedBy: "\n")
        if parts.last == "" { parts.removeLast() }
        lines = parts
        if !lines.contains(where: { $0.hasPrefix("rules:") }) { lines.append("rules:") }
    }

    var text: String { lines.joined(separator: "\n") + "\n" }

    struct Item { var lineIndex: Int; var value: String; var indent: String }

    var items: [Item] {
        guard let start = lines.firstIndex(where: { $0.hasPrefix("rules:") }) else { return [] }
        var result: [Item] = []
        for i in (start + 1)..<lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !line.isEmpty, !line.hasPrefix(" "), !line.hasPrefix("-"), !trimmed.hasPrefix("#") { break }
            guard trimmed.hasPrefix("- ") else { continue }
            let indent = String(line.prefix { $0 == " " })
            var value = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let f = value.first, let l = value.last, (f == "'" && l == "'") || (f == "\"" && l == "\"") {
                value = String(value.dropFirst().dropLast())
            }
            result.append(Item(lineIndex: i, value: value, indent: indent))
        }
        return result
    }

    private var rulesLine: Int { lines.firstIndex(where: { $0.hasPrefix("rules:") }) ?? 0 }
    private var defaultIndent: String { items.first?.indent ?? "  " }

    private func type(of item: Item) -> String {
        RuleEntry.normalizeType(String(item.value.split(separator: ",").first ?? ""))
    }

    /// 插入位置（getProxyDomainRuleInsertIndex）：前置=第一个 RULE-SET 前，后置=最后一个 RULE-SET 后，
    /// 否则按“插入到指定规则类型前”或追加到末尾。
    mutating func add(_ rule: String, mode: String, input: CustomRuleInput) throws {
        let list = items
        if let target = CustomRuleInput.comparable(rule), list.contains(where: { CustomRuleInput.comparable($0.value) == target }) {
            throw CustomRuleError.duplicated
        }
        let endLine = (list.last?.lineIndex ?? rulesLine) + 1
        var insertLine = endLine
        let ruleSets = list.filter { type(of: $0) == "RULE-SET" }
        if mode == "pre", let first = ruleSets.first {
            insertLine = first.lineIndex
        } else if mode == "post", let last = ruleSets.last {
            insertLine = last.lineIndex + 1
        } else if input.insertMode == .beforeTypes, !input.beforeTypes.isEmpty,
                  let match = list.first(where: { input.beforeTypes.contains(type(of: $0)) }) {
            insertLine = match.lineIndex
        }
        lines.insert("\(defaultIndent)- \(rule)", at: insertLine)
    }

    mutating func update(original: String, to rule: String) throws {
        let list = items
        let target = CustomRuleInput.ordered(original)
        guard let index = list.firstIndex(where: { CustomRuleInput.ordered($0.value) == target }) else { throw CustomRuleError.notFound }
        if let comparable = CustomRuleInput.comparable(rule),
           list.enumerated().contains(where: { $0.offset != index && CustomRuleInput.comparable($0.element.value) == comparable }) {
            throw CustomRuleError.invalid("修改后的规则已存在")
        }
        let item = list[index]
        lines[item.lineIndex] = "\(item.indent)- \(rule)"
    }

    mutating func delete(_ rule: String) throws {
        let target = CustomRuleInput.ordered(rule)
        guard let item = items.first(where: { CustomRuleInput.ordered($0.value) == target }) else { throw CustomRuleError.notFound }
        lines.remove(at: item.lineIndex)
    }

    /// 重排：新顺序必须是当前条目的一个排列（reorderProxyDomainRulesInYamlContent）。
    mutating func reorder(_ ordered: [String]) throws {
        let list = items
        let current = list.map { CustomRuleInput.ordered($0.value) }
        let next = ordered.map(CustomRuleInput.ordered)
        guard current.sorted() == next.sorted() else { throw CustomRuleError.invalid("新的顺序与当前规则不一致，请刷新后重试") }
        for (item, value) in zip(list, next) {
            lines[item.lineIndex] = "\(item.indent)- \(value)"
        }
    }
}

extension OpenWrtSSH {
    /// 写远端文件：内容经 stdin 传输，先写临时文件再原子替换；写前备份为 .wgsense.bak。
    func write(path: String, content: String) async throws {
        let q = Self.quote(path)
        let script = "set -e\nF=\(q)\n[ -f \"$F\" ] && cp \"$F\" \"$F.wgsense.bak\"\nmkdir -p \"$(dirname \"$F\")\"\ncat > \"$F.wgsense.tmp\" <<'WGSENSE_EOF'\n\(content)WGSENSE_EOF\nmv \"$F.wgsense.tmp\" \"$F\"\n"
        _ = try await run(script)
    }
}

extension RuleCacheStore {
    private func customPath(_ mode: String) -> String? {
        guard let snap = snapshot else { return nil }
        return mode == "pre" ? snap.preCustomPath : snap.postCustomPath
    }

    private func editCustom(_ mode: String, _ change: (inout CustomRuleDocument) throws -> Void) async throws {
        guard let backend = MihomoBackendStore.shared.active else { throw CustomRuleError.invalid("未配置后端") }
        guard !backend.isLocal else { throw CustomRuleError.invalid(MihomoBackendStore.localReadOnlyNote) }
        if snapshot == nil { await sync() }
        guard let path = customPath(mode), !path.isEmpty else { throw CustomRuleError.invalid("未检测到规则源，请先更新规则缓存") }
        let ssh = OpenWrtSSH(backend: backend)
        let current = try await ssh.run("[ -f \(OpenWrtSSH.quote(path)) ] && cat \(OpenWrtSSH.quote(path)) || echo 'rules:'")
        var doc = CustomRuleDocument(String(decoding: current, as: UTF8.self))
        try change(&doc)
        try await ssh.write(path: path, content: doc.text)
        pendingRestart = true
    }

    func addCustomRule(mode: String, input: CustomRuleInput) async throws {
        let rule = try input.normalizedRule()
        try await editCustom(mode) { try $0.add(rule, mode: mode, input: input) }
    }

    func updateCustomRule(mode: String, original: String, input: CustomRuleInput) async throws {
        let rule = try input.normalizedRule()
        try await editCustom(mode) { try $0.update(original: original, to: rule) }
    }

    func deleteCustomRule(mode: String, rule: String) async throws {
        try await editCustom(mode) { try $0.delete(rule) }
    }

    func reorderCustomRules(mode: String, ordered: [String]) async throws {
        try await editCustom(mode) { try $0.reorder(ordered) }
    }

    /// 重启代理（OpenClash / Nikki 服务），让写入的规则生效。
    func restartPlugin() async throws {
        guard let backend = MihomoBackendStore.shared.active else { return }
        if backend.isLocal {
            // 本机内核：交给网络服务停了再起（不走 SSH）
            let api = DaemonControlAPIClient()
            _ = try await api.mihomo(action: "stop")
            _ = try await api.mihomo(action: "start")
            pendingRestart = false
            return
        }
        let service = snapshot?.plugin == "nikki" ? "/etc/init.d/nikki" : "/etc/init.d/openclash"
        _ = try await OpenWrtSSH(backend: backend).run("[ -x \(service) ] || { echo 'service missing' >&2; exit 1; }\n\(service) restart >/dev/null 2>&1 &\n", timeout: 30)
        pendingRestart = false
    }
}
