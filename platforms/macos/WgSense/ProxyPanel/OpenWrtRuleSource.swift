import CryptoKit
import Foundation

// 规则源：原版由 AnGe 服务端 SSH 到 OpenWrt 完成，这里由 App 直接完成。
//
// 与原版的差异（功能等价、更稳）：
//   - 规则集正文直接读路由器上 Mihomo 已下载的缓存文件（原版是服务端再去网上下载一遍，
//     国内访问 GitHub 常失败；读路由器缓存也保证与内核实际生效的规则完全一致）。
//   - `.mrs` 在路由器上用内核自带的 `convert-ruleset` 转成文本（原版需要服务端自备 mihomo 二进制）。

// MARK: - 规则条目（对应 server buildRuleEntry / parseRuleEntryFromTextLine）

enum RuleFamily: String, CaseIterable, Identifiable {
    case all, domain, ip, port, other
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "全部"
        case .domain: return "域名"
        case .ip: return "IP"
        case .port: return "端口"
        case .other: return "其他"
        }
    }
}

struct RuleEntry: Identifiable, Hashable, Sendable {
    var id: String { "\(type)|\(content)|\(params)|\(raw)" }
    var type: String
    var family: RuleFamily
    var content: String
    var params: String
    var raw: String
    var source: String
    var line: Int?

    static let displayNames: [String: String] = [
        "DOMAIN": "域名", "DOMAIN-SUFFIX": "域名后缀", "DOMAIN-KEYWORD": "关键字",
        "IP-CIDR": "目标IP", "IP-CIDR6": "目标IP", "SRC-IP": "源IP", "SRC-IP-CIDR": "源IP",
        "SRC-IP-CIDR6": "源IP", "DST-PORT": "目标端口", "SRC-PORT": "源端口", "IN-PORT": "入站端口",
        "GEOIP": "目标IP", "MATCH": "匹配", "FINAL": "最终",
    ]

    var displayType: String { Self.displayNames[type] ?? type }

    private static let aliases: [String: String] = [
        "DOMAIN": "DOMAIN", "DOMAINSUFFIX": "DOMAIN-SUFFIX", "DOMAINKEYWORD": "DOMAIN-KEYWORD",
        "IPCIDR": "IP-CIDR", "IPCIDR6": "IP-CIDR6", "SRCIP": "SRC-IP", "SRCIPCIDR": "SRC-IP-CIDR",
        "SRCIPCIDR6": "SRC-IP-CIDR6", "DSTPORT": "DST-PORT", "SRCPORT": "SRC-PORT", "INPORT": "IN-PORT",
        "GEOIP": "GEOIP", "RULESET": "RULE-SET", "FINAL": "FINAL", "MATCH": "MATCH",
        "SUFFIX": "DOMAIN-SUFFIX", "KEYWORD": "DOMAIN-KEYWORD",
    ]

    static func normalizeType(_ value: String) -> String {
        let key = value.uppercased().filter { $0.isLetter || $0.isNumber }
        return aliases[key] ?? value.trimmingCharacters(in: .whitespaces).uppercased()
    }

    static func family(of type: String) -> RuleFamily {
        switch type {
        case "DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD": return .domain
        case "IP-CIDR", "IP-CIDR6", "SRC-IP", "SRC-IP-CIDR", "SRC-IP-CIDR6", "GEOIP": return .ip
        case "DST-PORT", "SRC-PORT", "IN-PORT": return .port
        default: return .other
        }
    }

    static func make(type: String, content: String, params: [String], raw: String? = nil, source: String, line: Int?) -> RuleEntry {
        let t = normalizeType(type)
        let c = content.trimmingCharacters(in: .whitespaces)
        let p = params.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return RuleEntry(type: t, family: family(of: t), content: c, params: p.joined(separator: ", "),
                         raw: raw ?? ([t, c] + p).filter { !$0.isEmpty }.joined(separator: ","),
                         source: source, line: line)
    }

    /// 规则集/自定义规则的一行文本 → 条目。
    static func parse(line rawLine: String, index: Int?, source: String) -> RuleEntry? {
        var line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("//") { return nil }
        if line.lowercased().hasPrefix("payload:") { return nil }
        if line.hasPrefix("- ") { line = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
        // YAML 规则集的条目常带引号（原版未处理，这里顺带去掉）。
        if line.count >= 2, let f = line.first, let l = line.last, (f == "'" && l == "'") || (f == "\"" && l == "\"") {
            line = String(line.dropFirst().dropLast())
        }
        guard !line.isEmpty else { return nil }

        if let match = line.range(of: #"^(domain|suffix|keyword|ip-cidr|ip-cidr6):\s*(.+)$"#, options: [.regularExpression, .caseInsensitive]) {
            let body = String(line[match])
            let parts = body.split(separator: ":", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { return nil }
            let t = normalizeType(parts[0])
            return make(type: t, content: parts[1], params: [], raw: "\(t),\(parts[1])", source: source, line: index)
        }
        if line.hasPrefix("+.") {
            let value = String(line.dropFirst(2))
            return make(type: "DOMAIN-SUFFIX", content: value, params: [], raw: "DOMAIN-SUFFIX,\(value)", source: source, line: index)
        }
        if !line.contains(",") {
            if IPMatcher.parseCIDR(line) != nil {
                return make(type: "IP-CIDR", content: line, params: [], raw: "IP-CIDR,\(line)", source: source, line: index)
            }
            return make(type: "DOMAIN", content: line, params: [], raw: "DOMAIN,\(line)", source: source, line: index)
        }
        let parts = line.split(separator: ",", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespaces) }
        let t = normalizeType(parts[0])
        let content = parts.count > 1 ? parts[1] : ""
        guard !t.isEmpty, !content.isEmpty else { return nil }
        return make(type: t, content: content, params: Array(parts.dropFirst(2)), source: source, line: index)
    }

    static func parse(body: String, source: String) -> [RuleEntry] {
        var result: [RuleEntry] = []
        var index = 0
        body.enumerateLines { line, _ in
            index += 1
            if let entry = parse(line: line, index: index, source: source) { result.append(entry) }
        }
        return result
    }
}

// MARK: - IP 工具（对应 server parseIpCidr / isIpInCidr）

enum IPMatcher {
    static func parseCIDR(_ value: String) -> (bytes: [UInt8], prefix: Int)? {
        let parts = value.split(separator: "/", maxSplits: 1).map(String.init)
        guard let bytes = parseIP(parts[0]) else { return nil }
        let maxPrefix = bytes.count * 8
        let prefix = parts.count > 1 ? Int(parts[1]) ?? -1 : maxPrefix
        guard (0...maxPrefix).contains(prefix) else { return nil }
        return (bytes, prefix)
    }

    static func parseIP(_ value: String) -> [UInt8]? {
        var v4 = in_addr()
        if inet_pton(AF_INET, value, &v4) == 1 {
            return withUnsafeBytes(of: v4) { Array($0) }
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, value, &v6) == 1 {
            return withUnsafeBytes(of: v6) { Array($0) }
        }
        return nil
    }

    static func contains(cidr: String, ip: [UInt8]) -> Bool {
        guard let (net, prefix) = parseCIDR(cidr), net.count == ip.count else { return false }
        var remaining = prefix
        for i in 0..<net.count where remaining > 0 {
            let bits = min(8, remaining)
            let mask: UInt8 = bits == 8 ? 0xFF : UInt8(0xFF << (8 - bits) & 0xFF)
            if net[i] & mask != ip[i] & mask { return false }
            remaining -= bits
        }
        return true
    }
}

// MARK: - SSH

struct OpenWrtSSH {
    var host: String
    var port: Int
    var user: String

    init(backend: MihomoBackend) {
        host = backend.effectiveSSHHost
        port = backend.sshPort
        user = backend.sshUser
    }

    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// 在路由器上执行一段 sh 脚本（经 stdin 传入，避免多层引号）。
    func run(_ script: String, timeout: TimeInterval = 120) async throws -> Data {
        let host = host, port = port, user = user
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                process.arguments = [
                    "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
                    "-o", "StrictHostKeyChecking=accept-new",
                    "-p", "\(port)", "\(user)@\(host)", "sh -s",
                ]
                let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
                process.standardInput = stdin
                process.standardOutput = stdout
                process.standardError = stderr
                var output = Data()
                let outHandle = stdout.fileHandleForReading
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    output = outHandle.readDataToEndOfFile()
                    group.leave()
                }
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: Failure(message: "无法启动 ssh：\(error.localizedDescription)"))
                    return
                }
                stdin.fileHandleForWriting.write(Data(script.utf8))
                try? stdin.fileHandleForWriting.close()
                let deadline = DispatchTime.now() + timeout
                let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: deadline, execute: timer)
                process.waitUntilExit()
                timer.cancel()
                group.wait()
                let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if process.terminationStatus != 0 {
                    let reason = err.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: Failure(message: reason.isEmpty ? "SSH 退出码 \(process.terminationStatus)" : reason))
                } else {
                    continuation.resume(returning: output)
                }
            }
        }
    }

    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - 配置解析（只解析需要的 rule-providers 段，避免引入 YAML 依赖）

struct RuleProviderSource: Codable, Hashable, Identifiable {
    var id: String { name }
    var name: String
    var behavior: String
    var format: String
    var path: String
    var url: String

    var isMRS: Bool { format.lowercased().hasPrefix("mrs") || url.lowercased().hasSuffix(".mrs") }

    /// 未写 path 时 Mihomo 的默认落盘位置：HomeDir/rules/<md5(url)>（C.Path.GetPathByHash("rules", url)）。
    var effectivePath: String {
        if !path.isEmpty { return path }
        guard !url.isEmpty else { return "" }
        let digest = Insecure.MD5.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined()
        return "./rules/\(digest)"
    }
    /// mrs 转换时的 behavior：ipcidr 或 domain。
    var mrsBehavior: String {
        behavior.lowercased() == "ipcidr" || url.lowercased().contains("/geoip/") ? "ipcidr" : "domain"
    }
}

enum MihomoYAML {
    private static func unquote(_ s: String) -> String {
        var v = s.trimmingCharacters(in: .whitespaces)
        if let hash = v.range(of: " #") { v = String(v[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces) }
        if v.count >= 2, let f = v.first, let l = v.last, (f == "\"" && l == "\"") || (f == "'" && l == "'") {
            v = String(v.dropFirst().dropLast())
        }
        return v
    }

    private static func indent(_ line: Substring) -> Int { line.prefix { $0 == " " }.count }

    static func ruleProviders(from yaml: String) -> [RuleProviderSource] {
        let lines = yaml.split(separator: "\n", omittingEmptySubsequences: false)
        guard let start = lines.firstIndex(where: { $0.hasPrefix("rule-providers:") }) else { return [] }
        var result: [RuleProviderSource] = []
        var current: [String: String] = [:]
        var currentName: String?
        var nameIndent = -1
        func flush() {
            guard let name = currentName else { return }
            result.append(RuleProviderSource(name: name, behavior: current["behavior"] ?? "",
                                             format: current["format"] ?? "", path: current["path"] ?? "",
                                             url: current["url"] ?? ""))
        }
        for line in lines[(start + 1)...] {
            if line.trimmingCharacters(in: .whitespaces).isEmpty || line.trimmingCharacters(in: .whitespaces).hasPrefix("#") { continue }
            let ind = indent(line)
            if ind == 0 { break }
            let text = line.trimmingCharacters(in: .whitespaces)
            if nameIndent < 0 || ind <= nameIndent {
                // 新的规则集名：`  名称:` 或 `  名称: {type: http, ...}`
                guard let colon = text.range(of: ":", options: .backwards) ?? text.range(of: ":") else { continue }
                flush()
                current = [:]
                nameIndent = ind
                let head = String(text[..<colon.lowerBound])
                let rest = String(text[colon.upperBound...]).trimmingCharacters(in: .whitespaces)
                if rest.hasPrefix("{"), rest.hasSuffix("}") {
                    // 行内写法：{type: http, behavior: domain, ...}
                    currentName = unquote(String(text[..<(text.range(of: ": {")?.lowerBound ?? colon.lowerBound)]))
                    for pair in rest.dropFirst().dropLast().split(separator: ",") {
                        let kv = pair.split(separator: ":", maxSplits: 1).map { String($0) }
                        if kv.count == 2 { current[unquote(kv[0])] = unquote(kv[1]) }
                    }
                } else {
                    currentName = unquote(head)
                }
            } else {
                let kv = text.split(separator: ":", maxSplits: 1).map { String($0) }
                if kv.count == 2 { current[unquote(kv[0])] = unquote(kv[1]) }
            }
        }
        flush()
        return result
    }

    /// 顶层 rules: 下的条目（自定义规则文件用）。返回 (原始条目文本, 行号)。
    static func ruleItems(from yaml: String) -> [(value: String, line: Int)] {
        let lines = yaml.split(separator: "\n", omittingEmptySubsequences: false)
        var inRules = false
        var items: [(String, Int)] = []
        for (i, line) in lines.enumerated() {
            if line.hasPrefix("rules:") { inRules = true; continue }
            guard inRules else { continue }
            if indent(line) == 0, !line.trimmingCharacters(in: .whitespaces).isEmpty, !line.hasPrefix("-") { break }
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("- ") else { continue }
            items.append((unquote(String(text.dropFirst(2))), i + 1))
        }
        return items
    }
}

// MARK: - 规则源快照与本机缓存

struct RuleSourceSnapshot: Codable {
    var plugin: String
    var configPath: String
    var homeDir: String
    var binary: String
    var customRulesEnabled: Bool
    var preCustomPath: String
    var postCustomPath: String
    var providers: [RuleProviderSource]
    var syncedAt: Date
    var unsupported: [String]
}

@MainActor
final class RuleCacheStore: ObservableObject {
    static let shared = RuleCacheStore()

    @Published private(set) var snapshot: RuleSourceSnapshot?
    @Published private(set) var syncing = false
    @Published private(set) var progress: String = ""
    @Published private(set) var lastError: String?
    /// 自定义规则已写入但尚未重启代理（原版 domainRuleConfigChanged）。
    @Published var pendingRestart = false
    /// 规则集名 → 已解析条目（内存缓存，按需从磁盘加载）。
    private var parsed: [String: [RuleEntry]] = [:]
    private var bodies: [String: String] = [:]
    private var loadedBackend: UUID?

    private var cacheDir: URL? {
        guard let backend = MihomoBackendStore.shared.active else { return nil }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WgSense/rule-cache/\(backend.id.uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var totalRules: Int { bodies.values.reduce(0) { $0 + $1.split(separator: "\n").count } }
    func hasProvider(_ name: String) -> Bool { bodies[name] != nil }
    var isEmpty: Bool { bodies.isEmpty }

    /// 切换后端或首次使用时从磁盘加载缓存。
    func loadIfNeeded() {
        guard let backend = MihomoBackendStore.shared.active, loadedBackend != backend.id, let dir = cacheDir else { return }
        loadedBackend = backend.id
        parsed = [:]
        bodies = [:]
        snapshot = nil
        if let data = try? Data(contentsOf: dir.appendingPathComponent("snapshot.json")),
           let snap = try? JSONDecoder().decode(RuleSourceSnapshot.self, from: data) {
            snapshot = snap
        }
        if let data = try? Data(contentsOf: dir.appendingPathComponent("bodies.json")),
           let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            bodies = dict
        }
    }

    func entries(forProvider name: String) -> [RuleEntry]? {
        if let cached = parsed[name] { return cached }
        guard let body = bodies[name] else { return nil }
        let entries = RuleEntry.parse(body: body, source: name)
        parsed[name] = entries
        return entries
    }

    // MARK: 检测与同步

    private static let detectScript = #"""
    set -u
    P="${WG_PLUGIN:-auto}"
    if { [ "$P" = auto ] || [ "$P" = openclash ]; } && [ -f /etc/config/openclash ]; then
      CP=$(uci -q get openclash.config.config_path)
      echo "@@PLUGIN openclash"
      echo "@@CONFIG $CP"
      echo "@@HOME /etc/openclash"
      if [ -x /etc/openclash/core/clash_meta ]; then echo "@@BIN /etc/openclash/core/clash_meta"; else echo "@@BIN /etc/openclash/clash"; fi
      echo "@@CUSTOM $(uci -q get openclash.config.enable_custom_clash_rules)"
      echo "@@PRE /etc/openclash/custom/openclash_custom_rules.list"
      echo "@@POST /etc/openclash/custom/openclash_custom_rules_2.list"
    elif { [ "$P" = auto ] || [ "$P" = nikki ]; } && [ -f /etc/config/nikki ]; then
      CP=$(ps ww 2>/dev/null | grep -o '\-f [^ ]*\.yaml' | head -1 | cut -c4-)
      [ -z "$CP" ] && CP=/etc/nikki/run/config.yaml
      echo "@@PLUGIN nikki"
      echo "@@CONFIG $CP"
      echo "@@HOME $(dirname "$CP")"
      echo "@@BIN $(command -v mihomo || echo /usr/bin/mihomo)"
      echo "@@CUSTOM $(uci -q get nikki.mixin.rules_enabled 2>/dev/null || echo 0)"
      echo "@@PRE $CP"
      echo "@@POST $CP"
    else
      echo "@@PLUGIN none"; exit 0
    fi
    echo "@@BEGIN"
    cat "$CP"
    echo ""
    echo "@@END"
    """#

    func sync() async {
        guard !syncing, let backend = MihomoBackendStore.shared.active else { return }
        // 本机内核没有路由器上的规则源文件可读；规则改动在 op 上做
        guard !backend.isLocal else { lastError = MihomoBackendStore.localReadOnlyNote; return }
        syncing = true
        lastError = nil
        progress = "正在检测规则源…"
        defer { syncing = false; progress = "" }
        let ssh = OpenWrtSSH(backend: backend)
        do {
            let detectOut = try await ssh.run("WG_PLUGIN=\(OpenWrtSSH.quote(backend.rulePlugin))\n" + Self.detectScript)
            let text = String(decoding: detectOut, as: UTF8.self)
            var fields: [String: String] = [:]
            var configBody = ""
            if let begin = text.range(of: "@@BEGIN\n"), let end = text.range(of: "\n@@END", options: .backwards) {
                configBody = String(text[begin.upperBound..<end.lowerBound])
            }
            for line in text.split(separator: "\n") where line.hasPrefix("@@") {
                let parts = line.dropFirst(2).split(separator: " ", maxSplits: 1).map(String.init)
                if parts.count == 2 { fields[parts[0]] = parts[1] } else if parts.count == 1 { fields[parts[0]] = "" }
            }
            guard let plugin = fields["PLUGIN"], plugin != "none" else {
                throw OpenWrtSSH.Failure(message: "路由器上没有检测到 OpenClash 或 Nikki")
            }
            let providers = MihomoYAML.ruleProviders(from: configBody)
            let home = fields["HOME"] ?? "/etc/openclash"
            let bin = fields["BIN"] ?? ""

            progress = "正在读取 \(providers.count) 个规则集…"
            // 一次会话读完全部规则集：text 直接 cat，mrs 用内核 convert-ruleset 转文本。
            var script = "cd \(OpenWrtSSH.quote(home)) || exit 1\nT=/tmp/wgsense-rule.$$\n"
            for (index, provider) in providers.enumerated() where !provider.effectivePath.isEmpty {
                let path = OpenWrtSSH.quote(provider.effectivePath)
                script += "echo '@@FILE \(index)'\n"
                if provider.isMRS {
                    // 先判断文件是否存在：未被引用的规则集内核不会下载，属于“缺失”而非“转换失败”。
                    script += "if [ ! -f \(path) ]; then echo '@@MISSING'; elif \(OpenWrtSSH.quote(bin)) convert-ruleset \(provider.mrsBehavior) mrs \(path) \"$T\" >/dev/null 2>&1; then cat \"$T\"; else echo '@@MRSFAIL'; fi; rm -f \"$T\"\n"
                } else {
                    script += "[ -f \(path) ] && cat \(path) || echo '@@MISSING'\n"
                }
                script += "echo ''\necho '@@ENDFILE'\n"
            }
            let bodyOut = try await ssh.run(script, timeout: 300)
            let bodyText = String(decoding: bodyOut, as: UTF8.self)

            var newBodies: [String: String] = [:]
            var unsupported: [String] = []
            var cursor = bodyText.startIndex
            while let fileMark = bodyText.range(of: "@@FILE ", range: cursor..<bodyText.endIndex) {
                guard let lineEnd = bodyText.range(of: "\n", range: fileMark.upperBound..<bodyText.endIndex),
                      let endMark = bodyText.range(of: "\n@@ENDFILE", range: lineEnd.upperBound..<bodyText.endIndex),
                      let index = Int(bodyText[fileMark.upperBound..<lineEnd.lowerBound]),
                      providers.indices.contains(index) else { break }
                let body = String(bodyText[lineEnd.upperBound..<endMark.lowerBound])
                let name = providers[index].name
                if body.hasPrefix("@@MRSFAIL") {
                    unsupported.append(name)
                } else if !body.hasPrefix("@@MISSING") {
                    newBodies[name] = body
                }
                cursor = endMark.upperBound
            }

            let snap = RuleSourceSnapshot(
                plugin: plugin, configPath: fields["CONFIG"] ?? "", homeDir: home, binary: bin,
                customRulesEnabled: ["1", "true", "yes", "on", "enabled"].contains((fields["CUSTOM"] ?? "").lowercased()),
                preCustomPath: fields["PRE"] ?? "", postCustomPath: fields["POST"] ?? "",
                providers: providers, syncedAt: Date(), unsupported: unsupported
            )
            bodies = newBodies
            parsed = [:]
            snapshot = snap
            if let dir = cacheDir {
                try? JSONEncoder().encode(snap).write(to: dir.appendingPathComponent("snapshot.json"), options: .atomic)
                try? JSONEncoder().encode(newBodies).write(to: dir.appendingPathComponent("bodies.json"), options: .atomic)
            }
            ProxyPanelStore.shared.post(PPNotice(id: "rulecache", title: "规则缓存已更新",
                                                 detail: "规则集 \(newBodies.count)/\(providers.count)，共 \(totalRules) 行",
                                                 kind: unsupported.isEmpty ? .success : .warning), autoDismiss: 4)
        } catch {
            lastError = error.localizedDescription
            ProxyPanelStore.shared.post(PPNotice(id: "rulecache", title: "规则缓存更新失败",
                                                 detail: error.localizedDescription, kind: .error), autoDismiss: 6)
        }
    }

    // MARK: 自定义规则（OpenClash 自定义规则文件 / Nikki 配置）

    func customRules(mode: String) async throws -> [RuleEntry] {
        guard let backend = MihomoBackendStore.shared.active, let snap = snapshot else { return [] }
        let path = mode == "pre" ? snap.preCustomPath : snap.postCustomPath
        let out = try await OpenWrtSSH(backend: backend).run("[ -f \(OpenWrtSSH.quote(path)) ] && cat \(OpenWrtSSH.quote(path)) || echo 'rules:'")
        let yaml = String(decoding: out, as: UTF8.self)
        var entries: [RuleEntry] = []
        var seenRuleSet = false
        for item in MihomoYAML.ruleItems(from: yaml) {
            let type = RuleEntry.normalizeType(String(item.value.split(separator: ",").first ?? ""))
            if type == "RULE-SET" { seenRuleSet = true; continue }
            guard !["MATCH", "FINAL", ""].contains(type) else { continue }
            // OpenClash 的前置/后置是两个独立文件；Nikki 同一文件按 RULE-SET 出现前后区分。
            if snap.plugin == "nikki" && ((seenRuleSet ? "post" : "pre") != mode) { continue }
            if let entry = RuleEntry.parse(line: item.value, index: item.line, source: path) { entries.append(entry) }
        }
        return entries
    }
}

// MARK: - 策略组规则展开（对应 server expandProxyGroupRuleEntries）

struct MihomoRule: Decodable, Equatable {
    var type: String
    var payload: String
    var proxy: String
    var index: Int?
    var disabled: Bool
    /// 规则命中统计（smart/alpha 内核在 extra 里提供）。
    var hitCount: Int
    var missCount: Int
    var hitAt: String?
    var missAt: String?

    init(from decoder: Decoder) throws {
        enum K: String, CodingKey { case type, payload, proxy, index, extra, disabled }
        struct Extra: Decodable {
            var disabled: Bool?
            var hitCount: Int?
            var missCount: Int?
            var hitAt: String?
            var missAt: String?
        }
        let c = try decoder.container(keyedBy: K.self)
        type = (try? c.decode(String.self, forKey: .type)) ?? ""
        payload = (try? c.decode(String.self, forKey: .payload)) ?? ""
        proxy = (try? c.decode(String.self, forKey: .proxy)) ?? ""
        index = try? c.decode(Int.self, forKey: .index)
        let extra = try? c.decode(Extra.self, forKey: .extra)
        disabled = extra?.disabled ?? (try? c.decode(Bool.self, forKey: .disabled)) ?? false
        hitCount = extra?.hitCount ?? 0
        missCount = extra?.missCount ?? 0
        hitAt = extra?.hitAt
        missAt = extra?.missAt
    }
}

struct MihomoRulesResponse: Decodable { var rules: [MihomoRule] }

struct RuleExpansion {
    var items: [RuleEntry]
    var totalRules: Int
    var missingProviders: [String]
    var referencedProviders: [String]
}

enum RulePenetration {
    /// 直接指向 group 的规则，RULE-SET 用本机缓存展开；去重。
    @MainActor
    static func expand(group: String, rules: [MihomoRule], cache: RuleCacheStore, provider: String? = nil) -> RuleExpansion {
        let relevant = rules.filter { !$0.disabled && $0.proxy == group }
            .enumerated().sorted { ($0.element.index ?? $0.offset) < ($1.element.index ?? $1.offset) }.map(\.element)
        var items: [RuleEntry] = []
        var seen: Set<String> = []
        var missing: [String] = []
        var referenced: [String] = []
        func push(_ e: RuleEntry) {
            if seen.insert(e.id).inserted { items.append(e) }
        }
        for rule in relevant {
            let type = RuleEntry.normalizeType(rule.type)
            if type == "RULE-SET" {
                let name = rule.payload.trimmingCharacters(in: .whitespaces)
                if !referenced.contains(name) { referenced.append(name) }
                if let provider, provider != name { continue }
                guard let entries = cache.entries(forProvider: name) else {
                    if !missing.contains(name) { missing.append(name) }
                    continue
                }
                entries.forEach(push)
                continue
            }
            if let provider, provider != customSourceKey { continue }
            let parts = rule.payload.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let content = parts.first ?? ""
            guard !content.isEmpty || type == "MATCH" || type == "FINAL" else { continue }
            push(RuleEntry.make(type: type, content: content, params: Array(parts.dropFirst()) + [rule.proxy],
                                source: "controller", line: rule.index.map { $0 + 1 }))
        }
        return RuleExpansion(items: items, totalRules: relevant.count, missingProviders: missing, referencedProviders: referenced)
    }

    static let customPreKey = "__custom_pre__"
    static let customPostKey = "__custom_post__"
    static let customSourceKey = "__custom_source__"

    static func sortedEnabled(_ rules: [MihomoRule]) -> [MihomoRule] {
        rules.enumerated().filter { !$0.element.disabled }
            .sorted { ($0.element.index ?? $0.offset) < ($1.element.index ?? $1.offset) }.map(\.element)
    }

    private static func isCustomDirect(_ type: String) -> Bool {
        !type.isEmpty && !["RULE-SET", "MATCH", "FINAL"].contains(type)
    }

    /// 前置/后置自定义区：第一个 RULE-SET 之前、最后一个 RULE-SET 之后的直接规则（getCustomDomainGroupSections）。
    static func customSections(_ rules: [MihomoRule]) -> (pre: [MihomoRule], post: [MihomoRule]) {
        let enabled = sortedEnabled(rules)
        let ruleSetIndexes = enabled.indices.filter { RuleEntry.normalizeType(enabled[$0].type) == "RULE-SET" }
        guard let first = ruleSetIndexes.first, let last = ruleSetIndexes.last else {
            return (enabled.filter { isCustomDirect(RuleEntry.normalizeType($0.type)) }, [])
        }
        let pre = enabled.indices.filter { $0 < first && isCustomDirect(RuleEntry.normalizeType(enabled[$0].type)) }.map { enabled[$0] }
        let post = enabled.indices.filter { $0 > last && isCustomDirect(RuleEntry.normalizeType(enabled[$0].type)) }.map { enabled[$0] }
        return (pre, post)
    }

    static func entry(from rule: MihomoRule) -> RuleEntry? {
        let type = RuleEntry.normalizeType(rule.type)
        guard type != "RULE-SET" else { return nil }
        let parts = rule.payload.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let content = parts.first ?? ""
        guard !content.isEmpty || type == "MATCH" || type == "FINAL" else { return nil }
        return RuleEntry.make(type: type, content: content, params: Array(parts.dropFirst()) + [rule.proxy],
                              source: "controller", line: rule.index.map { $0 + 1 })
    }

    /// 某个组的规则集选项（getDomainGroupRuleSetOptions）：有直接规则时首项为“自定义”。
    static func ruleSetOptions(group: String, rules: [MihomoRule]) -> [String] {
        guard group != customPreKey, group != customPostKey else { return [] }
        var options: [String] = []
        var hasCustom = false
        for rule in sortedEnabled(rules) where rule.proxy == group {
            if RuleEntry.normalizeType(rule.type) == "RULE-SET" {
                let name = rule.payload.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty, !options.contains(name) { options.append(name) }
            } else {
                hasCustom = true
            }
        }
        return hasCustom ? [customSourceKey] + options : options
    }

    /// 域名子视图的组列表（getDomainGroupNames）：前置自定义 + 策略组（其他之前/之后保持顺序）+ 后置自定义。
    static func domainGroups(policyGroups: [String], rules: [MihomoRule], includeEmptyCustom: Bool) -> [String] {
        let sections = customSections(rules)
        let showCustom = includeEmptyCustom || !sections.pre.isEmpty || !sections.post.isEmpty
        return (showCustom ? [customPreKey] : []) + policyGroups + (showCustom ? [customPostKey] : [])
    }

    static func matches(_ entry: RuleEntry, search: String) -> Bool {
        guard !search.isEmpty else { return true }
        let q = search.lowercased()
        return [entry.type, entry.displayType, entry.content, entry.params, entry.raw].contains { $0.lowercased().contains(q) }
    }
}
