import SwiftUI

// 域名穿透弹窗（P-R01…P-R07）与域名子视图（P-M01…P-M05）。
// 两者共用规则浏览模型与明细表；表格用原生 Table（懒加载，几万行也流畅，等价于原版滚动分页）。

@MainActor
final class PPRuleBrowserModel: ObservableObject {
    @Published var family: RuleFamily = .all
    @Published var search = ""
    @Published var sortOrder: [KeyPathComparator<RuleEntry>] = []
    @Published private(set) var items: [RuleEntry] = []
    @Published private(set) var totalRules = 0
    @Published private(set) var missingProviders: [String] = []
    @Published private(set) var rules: [MihomoRule] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?

    let cache = RuleCacheStore.shared

    func fetchRules() async -> Bool {
        let store = MihomoBackendStore.shared
        guard let backend = store.active else { error = String(localized: "未配置后端", bundle: .wgLocalized); return false }
        do {
            rules = try await MihomoAPI(backend: backend, secret: store.secret(for: backend)).rules()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    /// group 可以是策略组名或前置/后置自定义键；provider 为 nil 表示全部。
    func load(group: String, provider: String?, refetch: Bool = true) async {
        loading = true
        error = nil
        defer { loading = false }
        cache.loadIfNeeded()
        if refetch || rules.isEmpty { guard await fetchRules() else { return } }
        if group == RulePenetration.customPreKey || group == RulePenetration.customPostKey {
            // 与原版一致：自定义区读路由器上的自定义规则文件（可编辑），而非控制器规则。
            do {
                if cache.snapshot == nil { await cache.sync() }
                let list = try await cache.customRules(mode: group == RulePenetration.customPreKey ? "pre" : "post")
                items = list
                totalRules = list.count
                missingProviders = []
            } catch {
                self.error = error.localizedDescription
            }
            return
        }
        let result = RulePenetration.expand(group: group, rules: rules, cache: cache, provider: provider)
        items = result.items
        totalRules = result.totalRules
        missingProviders = result.missingProviders
    }

    func count(_ family: RuleFamily) -> Int {
        family == .all ? items.count : items.filter { $0.family == family }.count
    }

    var visible: [RuleEntry] {
        var list = items
        if family != .all { list = list.filter { $0.family == family } }
        let q = search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { list = list.filter { RulePenetration.matches($0, search: q) } }
        if !sortOrder.isEmpty { list.sort(using: sortOrder) }
        return list
    }

    var cacheHint: String? {
        if cache.isEmpty { return String(localized: "本地规则缓存为空，请先更新规则缓存。", bundle: .wgLocalized) }
        var parts: [String] = []
        if !missingProviders.isEmpty {
            parts.append(String(localized: "以下规则集未在本地缓存中找到：\(missingProviders.joined(separator: "、"))", bundle: .wgLocalized))
        }
        if let unsupported = cache.snapshot?.unsupported, !unsupported.isEmpty {
            parts.append(String(localized: "\(unsupported.count) 个 .mrs 规则集转换失败：\(unsupported.joined(separator: "、"))", bundle: .wgLocalized))
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }
}

// MARK: - 明细表

struct PPRuleTable: View {
    @ObservedObject var model: PPRuleBrowserModel

    var body: some View {
        let rows = model.visible
        Group {
            if model.loading && model.items.isEmpty {
                ProgressView("正在加载规则明细…").frame(maxWidth: .infinity, minHeight: 220)
            } else if let error = model.error {
                PPInlineMessage(symbol: "exclamationmark.triangle.fill", text: error)
            } else if rows.isEmpty {
                PPInlineMessage(symbol: "tray", text: String(localized: "暂无匹配的规则明细", bundle: .wgLocalized))
            } else {
                Table(rows, sortOrder: $model.sortOrder) {
                    TableColumn("类别", value: \.displayType) { Text(verbatim: $0.displayType) }
                        .width(min: 60, ideal: 80, max: 120)
                    TableColumn("域名/IP", value: \.content) { Text(verbatim: $0.content.isEmpty ? "-" : $0.content).textSelection(.enabled) }
                        .width(min: 140, ideal: 240)
                    TableColumn("节点", value: \.params) { Text(verbatim: $0.params.isEmpty ? "-" : $0.params) }
                        .width(min: 60, ideal: 110)
                    TableColumn("原始内容", value: \.raw) {
                        Text(verbatim: $0.raw).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    .width(min: 160, ideal: 300)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
    }
}

struct PPFamilyTabs: View {
    @ObservedObject var model: PPRuleBrowserModel

    var body: some View {
        Picker("", selection: $model.family) {
            ForEach([RuleFamily.all, .domain, .ip, .port]) { family in
                Text("\(family.title) \(model.count(family))").tag(family)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

struct PPInlineMessage: View {
    var symbol: String
    var text: String
    var body: some View {
        VStack(spacing: WgSpace.s) {
            Image(systemName: symbol).font(.system(size: WgType.readout)).foregroundStyle(.tertiary)
            Text(verbatim: text).font(.system(size: WgType.sub)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }
}

struct PPCacheHintBar: View {
    @ObservedObject var model: PPRuleBrowserModel
    @ObservedObject var cache = RuleCacheStore.shared
    var reload: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: WgSpace.m) {
            Image(systemName: cache.isEmpty ? "externaldrive.badge.exclamationmark" : "info.circle")
                .foregroundStyle(cache.isEmpty ? .orange : .secondary)
            VStack(alignment: .leading, spacing: WgSpace.zero) {
                if let hint = model.cacheHint {
                    Text(verbatim: hint).font(.system(size: WgType.body)).foregroundStyle(.secondary)
                }
                if let snap = cache.snapshot {
                    Text(verbatim: String(localized: "规则源 \(snap.plugin) · 更新于 \(snap.syncedAt.formatted(date: .abbreviated, time: .shortened))", bundle: .wgLocalized))
                        .font(.system(size: WgType.body)).foregroundStyle(.tertiary)
                }
                if let error = cache.lastError {
                    Text(verbatim: error).font(.system(size: WgType.body)).foregroundStyle(.red)
                }
            }
            Spacer()
            Button {
                Task {
                    await cache.sync()
                    reload()
                }
            } label: {
                if cache.syncing {
                    HStack(spacing: WgSpace.s) { ProgressView().controlSize(.small); Text(verbatim: cache.progress) }
                } else {
                    Label("更新缓存", systemImage: "arrow.clockwise")
                }
            }
            .buttonStyle(WgPillButtonStyle())
            .font(.system(size: WgType.body, weight: .medium))
            .disabled(cache.syncing)
        }
        .wgPadding(.m)
        .background(RoundedRectangle(cornerRadius: WgRadius.s, style: .continuous).fill(Color.primary.opacity(0.04)))
    }
}

// MARK: - 域名穿透弹窗（从策略组卡片打开）

struct PPRulePenetrationSheet: View {
    var group: String
    @StateObject private var model = PPRuleBrowserModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: WgSpace.m) {
            HStack {
                VStack(alignment: .leading, spacing: WgSpace.zero) {
                    Text("域名穿透").font(.system(size: WgType.body, weight: .bold))
                    Text(verbatim: String(localized: "\(group) · 规则 \(model.totalRules) 条，明细 \(model.items.count) 条", bundle: .wgLocalized))
                        .font(.system(size: WgType.sub)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            HStack(spacing: WgSpace.m) {
                PPFamilyTabs(model: model)
                PPSearchField(text: $model.search, placeholder: "输入关键字查询")
            }
            if model.cacheHint != nil || RuleCacheStore.shared.isEmpty {
                PPCacheHintBar(model: model) { Task { await model.load(group: group, provider: nil) } }
            }
            PPRuleTable(model: model)
        }
        .wgPadding(.m)
        .frame(minWidth: 760, minHeight: 520)
        .task { await model.load(group: group, provider: nil) }
    }
}

struct PPSearchField: View {
    @Binding var text: String
    var placeholder: LocalizedStringKey

    var body: some View {
        HStack(spacing: WgSpace.s) {
            Image(systemName: "magnifyingglass").font(.system(size: WgType.body)).foregroundStyle(.secondary)
            TextField(placeholder, text: $text).textFieldStyle(.plain).font(.system(size: WgType.sub))
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain)
            }
        }
        .wgPadding(.horizontal, .m)
        .frame(height: 28)
        .frame(minWidth: 140, maxWidth: 320)
        .wgInteractiveSurface(cornerRadius: WgRadius.s)
    }
}

// MARK: - 域名子视图

struct PPDomainGroupView: View {
    @EnvironmentObject private var store: ProxyPanelStore
    @StateObject private var model = PPRuleBrowserModel()
    @AppStorage("pp.domainGroup") private var selectedGroup = ""
    @State private var selectedProvider: String?
    @State private var groups: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: WgSpace.m) {
            HStack(spacing: WgSpace.m) {
                Menu {
                    ForEach(groups, id: \.self) { name in
                        Button(title(name)) { select(name) }
                    }
                } label: {
                    Label(title(selectedGroup), systemImage: "list.bullet")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .wgPadding(.horizontal, .m)
                .frame(height: 28)
                .wgInteractiveSurface(cornerRadius: WgRadius.s)

                let options = RulePenetration.ruleSetOptions(group: selectedGroup, rules: model.rules)
                Picker("", selection: Binding(
                    get: { selectedProvider ?? "" },
                    set: { value in
                        selectedProvider = value.isEmpty ? nil : value
                        Task { await model.load(group: selectedGroup, provider: selectedProvider, refetch: false) }
                    }
                )) {
                    Text("全部规则集").tag("")
                    ForEach(options, id: \.self) { option in
                        Text(option == RulePenetration.customSourceKey ? String(localized: "自定义", bundle: .wgLocalized) : option).tag(option)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(options.count <= 1)

                Spacer()
                PPFamilyTabs(model: model)
                PPCustomRuleActions(enabled: isCustom, mode: customMode) { reload() }
            }
            PPCacheHintBar(model: model) { reload() }
            if isCustom {
                PPCustomRuleList(model: model, mode: customMode) { reload() }
                    .frame(maxHeight: .infinity)
            } else {
                PPRuleTable(model: model)
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onChange(of: store.filter) { _, value in model.search = value }
        .task { await setup() }
    }

    private var isCustom: Bool {
        selectedGroup == RulePenetration.customPreKey || selectedGroup == RulePenetration.customPostKey
    }
    private var customMode: String { selectedGroup == RulePenetration.customPostKey ? "post" : "pre" }

    private func title(_ name: String) -> String {
        switch name {
        case RulePenetration.customPreKey: return String(localized: "前置自定义", bundle: .wgLocalized)
        case RulePenetration.customPostKey: return String(localized: "后置自定义", bundle: .wgLocalized)
        case "": return String(localized: "选择组", bundle: .wgLocalized)
        default: return name
        }
    }

    private func setup() async {
        model.search = store.filter
        _ = await model.fetchRules()
        RuleCacheStore.shared.loadIfNeeded()
        groups = RulePenetration.domainGroups(policyGroups: store.policyGroups, rules: model.rules,
                                              includeEmptyCustom: RuleCacheStore.shared.snapshot?.customRulesEnabled ?? false)
        if !groups.contains(selectedGroup) { selectedGroup = groups.first(where: { !$0.hasPrefix("__custom") }) ?? groups.first ?? "" }
        await model.load(group: selectedGroup, provider: selectedProvider, refetch: false)
    }

    private func select(_ name: String) {
        selectedGroup = name
        selectedProvider = nil
        Task { await model.load(group: name, provider: nil, refetch: false) }
    }

    private func reload() {
        Task { await model.load(group: selectedGroup, provider: selectedProvider) }
    }
}
