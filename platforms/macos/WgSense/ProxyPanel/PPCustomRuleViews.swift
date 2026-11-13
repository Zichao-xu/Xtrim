import SwiftUI

// 自定义规则的编辑界面（P-M06…P-M10）。

/// 自定义区：可拖拽排序（仅“全部”且无搜索无排序时），点击行编辑，行尾删除。
struct PPCustomRuleList: View {
    @ObservedObject var model: PPRuleBrowserModel
    var mode: String
    var reload: () -> Void

    @State private var editing: RuleEntry?
    @State private var deleting: RuleEntry?
    @State private var errorText: String?

    private var canReorder: Bool {
        model.family == .all && model.search.isEmpty && model.sortOrder.isEmpty
    }

    var body: some View {
        let rows = model.visible
        VStack(alignment: .leading, spacing: WgSpace.s) {
            if !canReorder {
                Text("切换到全部并清除搜索和排序后可拖拽").font(.system(size: WgType.body)).foregroundStyle(.secondary)
            }
            if let errorText {
                Text(verbatim: errorText).font(.system(size: WgType.body)).foregroundStyle(.red)
            }
            if model.loading && rows.isEmpty {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            } else if rows.isEmpty {
                PPInlineMessage(symbol: "tray", text: model.error ?? String(localized: "暂无匹配的规则明细", bundle: .wgLocalized))
            } else {
                List {
                    ForEach(rows) { entry in
                        HStack(spacing: WgSpace.m) {
                            Image(systemName: "line.3.horizontal")
                                .foregroundStyle(canReorder ? Color.secondary : Color.secondary.opacity(0.3))
                            Text(verbatim: entry.displayType).frame(width: 70, alignment: .leading)
                            Text(verbatim: entry.content).frame(maxWidth: .infinity, alignment: .leading)
                            Text(verbatim: entry.params).foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
                            Text(verbatim: entry.raw).foregroundStyle(.tertiary).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            Button { deleting = entry } label: { Image(systemName: "xmark") }
                                .buttonStyle(WgToolbarIconButtonStyle())
                                .help("删除自定义规则")
                        }
                        .font(.system(size: WgType.sub))
                        .contentShape(Rectangle())
                        .onTapGesture { editing = entry }
                        .help("点击修改这条自定义规则")
                    }
                    .onMove(perform: canReorder ? move : nil)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .sheet(item: $editing) { entry in
            PPCustomRuleSheet(mode: mode, original: entry) { reload() }
        }
        .confirmationDialog("删除自定义规则", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                guard let entry = deleting else { return }
                Task {
                    do {
                        try await RuleCacheStore.shared.deleteCustomRule(mode: mode, rule: entry.raw)
                        ProxyPanelStore.shared.post(PPNotice(id: "customrule", title: String(localized: "自定义规则已删除", bundle: .wgLocalized), detail: String(localized: "点击右上角重启后生效", bundle: .wgLocalized), kind: .success), autoDismiss: 4)
                        reload()
                    } catch { errorText = String(localized: "删除自定义规则失败：\(error.localizedDescription)", bundle: .wgLocalized) }
                }
            }
        } message: {
            Text("是否删除 [\(deleting?.raw ?? "")] 记录？删除只会写入配置文件，点击右上角重启后生效")
        }
    }

    private func move(from source: IndexSet, to destination: Int) {
        var list = model.items.map(\.raw)
        list.move(fromOffsets: source, toOffset: destination)
        Task {
            do {
                try await RuleCacheStore.shared.reorderCustomRules(mode: mode, ordered: list)
                ProxyPanelStore.shared.post(PPNotice(id: "customrule", title: String(localized: "自定义规则顺序已保存", bundle: .wgLocalized), detail: String(localized: "点击右上角重启后生效", bundle: .wgLocalized), kind: .success), autoDismiss: 4)
                reload()
            } catch { errorText = String(localized: "保存自定义规则顺序失败：\(error.localizedDescription)", bundle: .wgLocalized) }
        }
    }
}

/// 域名子视图右上：新增规则 + 重启代理。
struct PPCustomRuleActions: View {
    var enabled: Bool
    var mode: String
    var reload: () -> Void
    @ObservedObject private var cache = RuleCacheStore.shared
    @State private var adding = false
    @State private var restarting = false

    var body: some View {
        HStack(spacing: WgSpace.zero) {
            Button { adding = true } label: { Image(systemName: "plus") }
                .buttonStyle(WgToolbarIconButtonStyle(isActive: enabled))
                .disabled(!enabled)
                .help(enabled ? "新增域名规则" : "仅可在前置或后置自定义规则中添加")
            Button {
                restarting = true
                Task {
                    do {
                        try await cache.restartPlugin()
                        ProxyPanelStore.shared.post(PPNotice(id: "restart", title: String(localized: "已发送重启指令", bundle: .wgLocalized), detail: String(localized: "请等待 30-60 秒后刷新", bundle: .wgLocalized), kind: .success), autoDismiss: 5)
                    } catch {
                        ProxyPanelStore.shared.post(PPNotice(id: "restart", title: String(localized: "重启指令发送失败", bundle: .wgLocalized), detail: error.localizedDescription, kind: .error), autoDismiss: 6)
                    }
                    restarting = false
                }
            } label: {
                if restarting { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise.circle") }
            }
            .buttonStyle(WgToolbarIconButtonStyle(isActive: cache.pendingRestart))
            .disabled(!cache.pendingRestart || restarting)
            .help("重启代理")
        }
        .sheet(isPresented: $adding) { PPCustomRuleSheet(mode: mode, original: nil) { reload() } }
    }
}

/// 新增 / 修改自定义规则。
struct PPCustomRuleSheet: View {
    var mode: String
    var original: RuleEntry?
    var onDone: () -> Void

    @ObservedObject private var store = ProxyPanelStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var type = "DOMAIN-SUFFIX"
    @State private var value = ""
    @State private var target = ""
    @State private var targetTab = 0
    @State private var targetSearch = ""
    @State private var insertMode = CustomRuleInput.InsertMode.append
    @State private var beforeTypes = "MATCH"
    @State private var errorText: String?
    @State private var saving = false

    private var isIP: Bool { CustomRuleInput.ipTypes.contains(type) }

    var body: some View {
        VStack(alignment: .leading, spacing: WgSpace.l) {
            Text(original == nil ? "新增域名规则" : "修改自定义规则").font(.system(size: WgType.body, weight: .bold))
            Text("规则名称：\(mode == "pre" ? String(localized: "前置自定义", bundle: .wgLocalized) : String(localized: "后置自定义", bundle: .wgLocalized))").font(.system(size: WgType.sub)).foregroundStyle(.secondary)

            Picker("规则类型", selection: $type) {
                ForEach(CustomRuleInput.allTypes, id: \.self) { Text(CustomRuleInput.typeTitles[$0] ?? $0).tag($0) }
            }
            TextField(isIP ? "IP" : "域名", text: $value, prompt: Text(isIP ? (type.hasSuffix("6") ? "2001:db8::/32" : "1.2.3.4/32") : "example.com"))
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: WgSpace.s) {
                HStack {
                    Text("节点").font(.system(size: WgType.sub, weight: .medium))
                    Spacer()
                    Picker("", selection: $targetTab) {
                        Text("节点组").tag(0)
                        Text("节点").tag(1)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                PPSearchField(text: $targetSearch, placeholder: "搜索")
                List(selection: Binding(get: { target.isEmpty ? nil : target }, set: { target = $0 ?? "" })) {
                    ForEach(targetOptions, id: \.self) { name in
                        HStack {
                            Text(verbatim: name)
                            Spacer()
                            PPLatencyTag(name: name, group: nil, loading: store.isTesting("node:/\(name)")) {
                                Task { await store.testNode(name, group: nil) }
                            }
                        }
                        .tag(name)
                    }
                }
                .environmentObject(store)
                .frame(height: 180)
                .listStyle(.bordered)
            }

            if original == nil {
                Picker("写入位置", selection: $insertMode) {
                    Text("追加到 rules 末尾").tag(CustomRuleInput.InsertMode.append)
                    Text("插入到指定规则类型前").tag(CustomRuleInput.InsertMode.beforeTypes)
                }
                if insertMode == .beforeTypes {
                    TextField("指定规则类型", text: $beforeTypes).textFieldStyle(.roundedBorder)
                }
            }

            Text(original == nil ? "新增只会写入配置文件，点击右上角重启后生效" : "修改只会写入配置文件，点击右上角重启后生效")
                .font(.system(size: WgType.body)).foregroundStyle(.secondary)
            if let errorText { Text(verbatim: errorText).font(.system(size: WgType.body)).foregroundStyle(.red) }

            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(saving ? "正在写入…" : "确定") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving)
            }
        }
        .wgPadding(.m)
        .frame(width: 480)
        .onAppear(perform: prefill)
    }

    private var targetOptions: [String] {
        let pool: [String] = targetTab == 0
            ? store.proxyGroupList + ["DIRECT", "REJECT"]
            : store.proxyMap.keys.filter { !store.isGroup($0) }.sorted()
        let q = targetSearch.lowercased()
        return q.isEmpty ? pool : pool.filter { $0.lowercased().contains(q) }
    }

    private func prefill() {
        guard let original else { return }
        type = CustomRuleInput.allTypes.contains(original.type) ? original.type : "DOMAIN-SUFFIX"
        value = original.content
        target = original.params.components(separatedBy: ", ").last ?? ""
        targetTab = store.isGroup(target) || ["DIRECT", "REJECT"].contains(target) ? 0 : 1
    }

    private func save() {
        errorText = nil
        let input = CustomRuleInput(type: type, value: value, target: target, insertMode: insertMode,
                                    beforeTypes: beforeTypes.split(separator: ",").map { RuleEntry.normalizeType(String($0)) })
        do { _ = try input.normalizedRule() } catch { errorText = error.localizedDescription; return }
        saving = true
        Task {
            do {
                if let original {
                    try await RuleCacheStore.shared.updateCustomRule(mode: mode, original: original.raw, input: input)
                    store.post(PPNotice(id: "customrule", title: String(localized: "自定义规则已修改", bundle: .wgLocalized), detail: String(localized: "点击右上角重启后生效", bundle: .wgLocalized), kind: .success), autoDismiss: 4)
                } else {
                    try await RuleCacheStore.shared.addCustomRule(mode: mode, input: input)
                    store.post(PPNotice(id: "customrule", title: String(localized: "域名规则已写入", bundle: .wgLocalized), detail: String(localized: "重启代理后生效", bundle: .wgLocalized), kind: .success), autoDismiss: 4)
                }
                onDone()
                dismiss()
            } catch CustomRuleError.duplicated {
                errorText = CustomRuleError.duplicated.localizedDescription
            } catch {
                errorText = (original == nil ? String(localized: "新增域名规则失败：", bundle: .wgLocalized) : String(localized: "修改自定义规则失败：", bundle: .wgLocalized)) + error.localizedDescription
            }
            saving = false
        }
    }
}
