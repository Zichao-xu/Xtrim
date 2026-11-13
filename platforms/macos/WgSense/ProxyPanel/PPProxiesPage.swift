import SwiftUI

// 代理页（AnGe「代理」一比一功能）：控制栏 + 策略/域名/节点/订阅 四个子视图。

struct PPProxiesPage: View {
    @ObservedObject private var store = ProxyPanelStore.shared
    @ObservedObject private var backends = MihomoBackendStore.shared

    var body: some View {
        VStack(spacing: 0) {
            PPToolbar()
                .wgPadding(.bottom, .l)
            content
        }
        .environmentObject(store)
        .overlay(alignment: .bottomTrailing) { PPNoticeStack().environmentObject(store) }
        .onAppear { store.activate() }
        .onDisappear { store.deactivate() }
        .onChange(of: backends.activeID) { _, _ in store.backendChanged() }
    }

    @ViewBuilder
    private var content: some View {
        if backends.active == nil {
            PPEmptyState(symbol: "server.rack", title: "还没有后端", detail: String(localized: "在代理设置中添加 Clash / Mihomo 控制器", bundle: .wgLocalized))
        } else if let error = store.lastError, store.proxyMap.isEmpty {
            PPEmptyState(symbol: "exclamationmark.triangle.fill", title: "无法连接后端", detail: error)
        } else if store.proxyMap.isEmpty {
            ProgressView().frame(maxWidth: .infinity, minHeight: 240)
        } else {
            switch store.tab {
            case .policy: PPGroupList(groups: store.policyGroups)
            // 与策略页共用表格容器（原先的分块 ScrollView 在展开时一次铺开上千张卡片）。
            case .node: PPGroupList(groups: store.nodeGroups)
            case .provider: PPProviderList()
            case .domain:
                PPDomainGroupView().wgPadding(.bottom, .m)
            }
        }
    }
}

// MARK: - 控制栏（P-C01…P-C07）

private struct PPToolbar: View {
    @EnvironmentObject private var store: ProxyPanelStore
    @State private var showSettings = false
    @Environment(\.colorScheme) private var colorScheme
    @Namespace private var tabIndicator

    var body: some View {
        HStack(spacing: WgSpace.m) {
            tabs
            if store.tab == .policy, let config = store.config {
                Picker("模式", selection: Binding(
                    get: { config.mode },
                    set: { mode in Task { await store.setMode(mode) } }
                )) {
                    ForEach(modes(config), id: \.self) { mode in
                        Text(modeTitle(mode)).tag(mode)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            searchField
            Spacer(minLength: 0)
            if store.tab == .provider {
                Button { Task { await store.updateAllProviders() } } label: {
                    Image(systemName: "arrow.clockwise")
                        .symbolEffect(.rotate, isActive: store.isTesting("updateAll"))
                }
                .buttonStyle(WgToolbarIconButtonStyle())
                .help("全部更新")
            }
            Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(WgToolbarIconButtonStyle())
                .help("代理设置")
                .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                    PPSettingsPopover().environmentObject(store)
                }
            Button { toggleCollapseAll() } label: {
                Image(systemName: hasExpanded ? "chevron.up.2" : "chevron.down.2")
            }
            .buttonStyle(WgToolbarIconButtonStyle())
            .help(hasExpanded ? "全部折叠" : "全部展开")
            Button { Task { await store.testAll() } } label: {
                if store.isTesting("all") {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "bolt.fill")
                }
            }
            .buttonStyle(WgToolbarIconButtonStyle())
            .help("全部测速")
        }
        .focusEffectDisabled()
    }

    private var tabs: some View {
        // 与代理页一级页签同一语言：平行四边形咬合，当前项白色弱玻璃。
        HStack(spacing: -6) {
            ForEach(PPTab.allCases) { tab in
                let on = store.tab == tab
                Button { withAnimation(WgDesign.spring) { store.tab = tab } } label: {
                    HStack(spacing: WgSpace.xs) {
                        Text(tab.title).font(.system(size: WgType.body, weight: on ? .bold : .semibold))
                            .foregroundStyle(on ? WgInk.ink : WgInk.ink2)
                        if tab != .domain {
                            Text("\(store.count(for: tab))").font(WgInk.mono(.caption)).foregroundStyle(on ? WgInk.ink2 : WgInk.ink4)
                        }
                    }
                    .wgPadding(.leading, .l).wgPadding(.trailing, .m)
                    .frame(height: 30)
                    .background {
                        if on {
                            Color.clear.wgGlassAccent(SlantShape(slant: 7))
                                .matchedGeometryEffect(id: "ppTab", in: tabIndicator)
                        } else {
                            WgShapePlate(shape: SlantShape(slant: 7), fill: Color.primary.opacity(0.05), border: .clear, highlight: .clear)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .fixedSize()
    }

    private var searchField: some View {
        HStack(spacing: WgSpace.s) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: WgType.body))
                .foregroundStyle(.secondary)
            TextField("搜索 · 多个关键词用空格分隔", text: $store.filter)
                .textFieldStyle(.plain)
                .font(.system(size: WgType.sub))
            if !store.filter.isEmpty {
                Button { store.filter = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .wgPadding(.horizontal, .m)
        .frame(height: 28)
        .frame(minWidth: 120, maxWidth: 280)
        .wgInteractiveSurface(cornerRadius: WgRadius.s)
    }

    private func modes(_ config: MihomoRuntimeConfig) -> [String] {
        let list = config.modeList ?? []
        return list.isEmpty ? ["rule", "global", "direct"] : list
    }

    private func modeTitle(_ mode: String) -> LocalizedStringKey {
        switch mode.lowercased() {
        case "rule": return "规则"
        case "global": return "全局"
        case "direct": return "直连"
        default: return LocalizedStringKey(mode)
        }
    }

    private var targets: [String] {
        switch store.tab {
        case .policy: return store.policyGroups
        case .node: return store.nodeGroups
        case .provider: return store.providers.map { "provider:" + $0.name }
        case .domain: return []
        }
    }

    private var hasExpanded: Bool { targets.contains { store.isExpanded($0) } }

    private func toggleCollapseAll() {
        let expand = !hasExpanded
        var map = store.collapseMap
        targets.forEach { map[$0] = expand }
        withAnimation(WgDesign.spring) { store.collapseMap = map }
    }
}

// MARK: - 策略组列表（P-G15 自动双列）

private struct PPGroupList: View {
    @EnvironmentObject private var store: ProxyPanelStore
    var groups: [String]
    @StateObject private var rail = WgScrollRailModel()

    var body: some View {
        GeometryReader { geo in
            // 自动双列只在全部折叠时启用：展开的组要整行宽度平铺节点，双列下每行只剩 2 张，反而难以点选。
            let anyExpanded = groups.contains { store.isExpanded($0) }
            let twoColumns = geo.size.width >= 760 && groups.count > 1 && !anyExpanded
            let items = listItems(twoColumns: twoColumns, width: geo.size.width)
            // AppKit 表格容器（见 PPGroupTable 顶部说明）：按行种类复用，节点行高度直接算出。
            PPGroupTable(items: items, rail: rail, width: geo.size.width, fixedHeight: { item in
                guard case .nodes(_, _, let names, _) = item.kind else { return nil }
                return (names.map { PPNodeCard.height(for: $0, store: store) }.max() ?? 0) + 8
            }, makeRow: { item in
                AnyView(
                    row(item, twoColumns: twoColumns)
                        .wgInset(.top, item.topInset)
                        .wgInset(.bottom, item.bottomInset)
                        .environmentObject(store)
                        .tint(WgInk.control)
                )
            })
            // 刻度条由页面区统一画在左侧页边距里，这里只上报滚动来源。
            .wgPublishesScrollRail(rail)
        }
    }
}

struct PPListItem: Identifiable, Hashable {
    enum Kind: Hashable { case cards([String]), header(String), nodes(String, Int, [String], Int), footer(String) }
    var kind: Kind
    var id: Kind { kind }
    var topInset: CGFloat {
        switch kind { case .cards, .header: return 6; default: return 0 }
    }
    var bottomInset: CGFloat {
        switch kind { case .cards, .footer: return 6; default: return 0 }
    }
}

extension PPGroupList {
    func listItems(twoColumns: Bool, width: CGFloat) -> [PPListItem] {
        if twoColumns {
            return stride(from: 0, to: groups.count, by: 2).map { PPListItem(kind: .cards(Array(groups[$0..<min($0 + 2, groups.count)]))) }
        }
        let inner = width - 32
        let cols = max(1, Int((inner + 8) / (store.minProxyCardWidth + 8)))
        var items: [PPListItem] = []
        for g in groups {
            guard store.isExpanded(g), !store.groupProxiesByProvider, store.proxyMap[g] != nil else {
                items.append(PPListItem(kind: .cards([g]))); continue
            }
            items.append(PPListItem(kind: .header(g)))
            let names = store.renderProxies(of: g)
            for (i, start) in stride(from: 0, to: names.count, by: cols).enumerated() {
                items.append(PPListItem(kind: .nodes(g, i, Array(names[start..<min(start + cols, names.count)]), cols)))
            }
            items.append(PPListItem(kind: .footer(g)))
        }
        return items
    }

    @ViewBuilder
    func row(_ item: PPListItem, twoColumns: Bool) -> some View {
        switch item.kind {
        case .cards(let names):
            HStack(alignment: .top, spacing: WgSpace.m) {
                ForEach(names, id: \.self) { PPGroupCard(name: $0) }
                if twoColumns && names.count == 1 { Color.clear.frame(maxWidth: .infinity) }
            }
        case .header(let g): PPGroupCard(name: g, part: .header)
        case .nodes(let g, _, let names, let cols):
            PPNodeRow(group: g, names: names, columns: cols)
        case .footer(let g): PPGroupCard(name: g, part: .footer)
        }
    }
}


// MARK: - 策略组卡片（P-G01…P-G16）

struct PPGroupCard: View {
    @EnvironmentObject private var store: ProxyPanelStore
    var name: String
    /// 内嵌在策略穿透里的层级卡片（没有外框、没有穿透区）。
    var embedded = false
    var level = 0
    var rootGroup: String?
    /// 在节点组块里时由外层提供外框。
    var chromeless = false
    /// 列表分段渲染：展开的组拆成 组头 / 节点行 / 组尾 多个列表行，滚动时一次只创建一小段。
    var part: PPGroupPart = .whole
    var onSelect: ((String, String) -> Void)?

    @State private var showPenetration = false

    private var collapseKey: String { embedded ? "penetration:\(rootGroup ?? ""):level-\(level)" : name }
    private var expanded: Bool { store.isExpanded(collapseKey, default: !embedded) }

    var body: some View {
        if let group = store.proxyMap[name] {
            switch part {
            case .whole: whole(group)
            case .header:
                header(group)
                    .wgPadding(.horizontal, .l).wgPadding(.top, .l).wgPadding(.bottom, .m)
                    .wgRegionContrast()
                    .background(PPSegmentChrome(top: true, bottom: false))
                    .contentShape(Rectangle())
                    .onRightClick { Task { await store.testGroup(name) } }
            case .footer:
                PPPenetrationSection(root: name)
                    .wgPadding(.horizontal, .l).wgPadding(.top, .zero).wgPadding(.bottom, .l)
                    .wgRegionContrast()
                    .background(PPSegmentChrome(top: false, bottom: true))
            }
        }
    }

    private func whole(_ group: MihomoProxy) -> some View {
        let rendered = store.renderProxies(of: name)
        return VStack(alignment: .leading, spacing: WgSpace.m) {
                header(group)
                if expanded {
                    Group {
                        if store.groupProxiesByProvider {
                            PPProviderSectionsView(group: name, names: rendered, previewOnly: false) { select($0) }
                        } else {
                            PPNodeGrid(group: name, names: rendered)
                        }
                    }
                    .transition(.opacity)
                    if !embedded { PPPenetrationSection(root: name) }
                } else if store.groupProxiesByProvider {
                    PPProviderSectionsView(group: name, names: rendered, previewOnly: true) { select($0) }
                } else {
                    PPPreview(nodes: rendered, now: group.now, group: name) { node in select(node) }
                }
            }
            .wgPadding(embedded ? .zero : .l)
            .wgPadding(.vertical, embedded ? .m : .zero)
            .modifier(CardChrome(enabled: !embedded && !chromeless))
            .contentShape(Rectangle())
            .onRightClick { Task { await store.testGroup(name) } }
            .animation(WgDesign.spring, value: expanded)
    }

    private func header(_ group: MihomoProxy) -> some View {
        let large = store.useLargeProxyGroupIcon && group.icon != nil
        return HStack(alignment: large ? .top : .center, spacing: WgSpace.m) {
            if large {
                PPGroupIcon(icon: group.icon, size: max(store.proxyGroupIconSize, 46))
            }
            VStack(alignment: .leading, spacing: WgSpace.xs) {
                HStack(spacing: WgSpace.s) {
                    if !large, group.icon != nil {
                        PPGroupIcon(icon: group.icon, size: store.proxyGroupIconSize)
                            .wgInset(.trailing, store.proxyGroupIconMargin - 6)
                    }
                    Text(verbatim: name)
                        .font(.system(size: embedded ? WgType.title : WgType.body, weight: .semibold))
                        .lineLimit(1)
                    if !embedded {
                        Button("域名穿透") { showPenetration = true }
                            .buttonStyle(WgPillButtonStyle())
                            .font(.system(size: WgType.body, weight: .medium))
                            .sheet(isPresented: $showPenetration) { PPRulePenetrationSheet(group: name) }
                    }
                    Text(verbatim: embedded ? "\(group.type) (\(store.availabilityText(of: name)))" : group.type)
                        .font(.system(size: WgType.body))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if store.manageHiddenGroup {
                        Button {
                            store.hiddenGroupMap[name] = !store.isHidden(name)
                        } label: {
                            Image(systemName: store.isHidden(name) ? "eye.slash" : "eye")
                                .font(.system(size: WgType.body))
                        }
                        .buttonStyle(WgToolbarIconButtonStyle())
                        .help(store.isHidden(name) ? "显示此组" : "隐藏此组")
                    }
                    Spacer(minLength: 6)
                    PPLatencyTag(name: group.now, group: name, loading: store.isTesting("group:\(name)")) {
                        Task { await store.testGroup(name) }
                    }
                }
                HStack(spacing: WgSpace.s) {
                    PPRouteView(group: name)
                    PPGroupSpeed(group: name)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(WgDesign.spring) { store.collapseMap[collapseKey] = !expanded }
        }
    }

    private func select(_ node: String) {
        onSelect?(name, node)
        Task { await store.select(group: name, node: node) }
    }
}

enum PPGroupPart: Hashable { case whole, header, footer }

/// 分段外框：同一张卡拆成多个列表行时，每段只画自己那部分边（顶段画顶边与上角标，底段画底边与下角标），
/// 上下拼接后与整卡 `wgInteractiveSurface` 的外观一致。
struct PPSegmentChrome: View {
    var top: Bool
    var bottom: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.wgRegionColor) private var region

    var body: some View {
        // 分段拼接的斜切面板：顶段切右上角，底段切左下角，中段只画两侧边；与整卡 WgGlassPanel 外观一致。
        let border = WgInk.panelBorder(colorScheme)
        let highlight = Color.white.opacity(colorScheme == .dark ? 0.10 : 0.5)
        let fill = region.fill(default: WgInk.panelFill(colorScheme))
        Canvas { ctx, size in
            let w = size.width, h = size.height, c = WgInk.cutPanel, i: CGFloat = 0.5
            var outline = Path()
            outline.move(to: CGPoint(x: i, y: top ? i : 0)); outline.addLine(to: CGPoint(x: i, y: bottom ? h - c : h))
            outline.move(to: CGPoint(x: w - i, y: top ? c : 0)); outline.addLine(to: CGPoint(x: w - i, y: bottom ? h - i : h))
            if top {
                outline.move(to: CGPoint(x: i, y: i)); outline.addLine(to: CGPoint(x: w - c, y: i)); outline.addLine(to: CGPoint(x: w - i, y: c))
            }
            if bottom {
                outline.move(to: CGPoint(x: i, y: h - c)); outline.addLine(to: CGPoint(x: c, y: h - i)); outline.addLine(to: CGPoint(x: w - i, y: h - i))
            }
            // 填充区域
            var area = Path()
            area.move(to: CGPoint(x: 0, y: 0))
            area.addLine(to: CGPoint(x: top ? w - c : w, y: 0))
            if top { area.addLine(to: CGPoint(x: w, y: c)) }
            area.addLine(to: CGPoint(x: w, y: h))
            area.addLine(to: CGPoint(x: bottom ? c : 0, y: h))
            if bottom { area.addLine(to: CGPoint(x: 0, y: h - c)) }
            area.closeSubpath()
            ctx.fill(area, with: .color(fill))
            ctx.stroke(outline, with: .color(border), lineWidth: 1)
            if top {
                var t = Path(); t.move(to: CGPoint(x: 0, y: 0.5)); t.addLine(to: CGPoint(x: w - c, y: 0.5))
                ctx.stroke(t, with: .color(highlight), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
    }
}

/// 展开组里的一行节点（固定列数，与同组其他行对齐）。
struct PPNodeRow: View {
    @EnvironmentObject private var store: ProxyPanelStore
    var group: String
    var names: [String]
    var columns: Int

    var body: some View {
        let now = store.proxyMap[group]?.now
        HStack(alignment: .top, spacing: WgSpace.s) {
            // 按列位置做身份（片段回收）：表格复用这一行显示别的节点时，卡片视图原地保留、只换数据重画，
            // 不必拆掉重建整棵子树。
            ForEach(Array(names.enumerated()), id: \.offset) { _, name in
                PPNodeCard(name: name, group: group, active: name == now)
            }
            ForEach(0..<max(0, columns - names.count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
        }
        .wgPadding(.horizontal, .l)
        .wgPadding(.bottom, .s)
        .wgRegionContrast()
        .background(PPSegmentChrome(top: false, bottom: false))
    }
}

private struct CardChrome: ViewModifier {
    var enabled: Bool
    func body(content: Content) -> some View {
        if enabled {
            content.wgInteractiveSurface(cornerRadius: WgDesign.cardRadius)
        } else {
            content
        }
    }
}

// MARK: - 策略穿透（P-P01…P-P04）

private struct PPPenetrationSection: View {
    @EnvironmentObject private var store: ProxyPanelStore
    var root: String

    @State private var isExpanded = false
    @State private var selectedMap: [String: String] = [:]
    @State private var lastSelectedGroup = ""
    @State private var stepwiseVisible = 1

    private var mode: PPPenetrationMode {
        PPPenetrationMode(rawValue: store.penetrationModeMap[root] ?? "") ?? .stepwise
    }

    /// 沿（用户在穿透层里的选择 ?? 当前实际选择）向下的组链，防环。
    private var penetrated: [String] {
        var names: [String] = []
        var visited: Set<String> = [root]
        var current = root
        while true {
            let selected: String? = {
                guard let s = selectedMap[current],
                      (store.proxyMap[current]?.all ?? []).contains(s),
                      store.isGroup(s) else { return nil }
                return s
            }()
            let actual = store.groupChain(current).dropFirst().first
            guard let next = selected ?? actual, !visited.contains(next) else { break }
            names.append(next)
            visited.insert(next)
            current = next
        }
        return names
    }

    var body: some View {
        let groups = penetrated
        let canPenetrate = !groups.isEmpty
        let canSwitch = groups.count > 1
        let rendered = !canPenetrate ? [] : (mode == .stepwise ? Array(groups.prefix(stepwiseVisible)) : groups)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button {
                    guard canPenetrate else { return }
                    withAnimation(WgDesign.spring) {
                        if !isExpanded, mode == .stepwise { stepwiseVisible = 1 }
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: WgSpace.xs) {
                        Text(isExpanded ? "收起穿透" : "策略穿透")
                        Image(systemName: "chevron.down")
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    }
                    .font(.system(size: WgType.sub, weight: .medium))
                }
                .buttonStyle(WgPillButtonStyle())
                .disabled(!canPenetrate)
                Spacer()
                // 自绘分段：系统分段控件是 AppKit 视图，每个组各建一个，滚动时创建与命中测试都偏重。
                PPSegmented(options: [(String(localized: "逐层穿透", bundle: .wgLocalized), PPPenetrationMode.stepwise), (String(localized: "穿透到底", bundle: .wgLocalized), PPPenetrationMode.full)],
                            selection: mode) { newMode in
                    store.penetrationModeMap[root] = newMode.rawValue
                    lastSelectedGroup = ""
                    if newMode == .stepwise { stepwiseVisible = 1 }
                }
                .disabled(!canPenetrate || !canSwitch)
            }
            if isExpanded && !rendered.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(rendered.enumerated()), id: \.element) { index, name in
                        Divider()
                        PPGroupCard(name: name, embedded: true, level: index + 1, rootGroup: root) { group, node in
                            handleSelection(group: group, node: node)
                        }
                    }
                }
                .wgPadding(.top, .s)
                .transition(.opacity)
            }
        }
        .wgPadding(.top, .xs)
        .onChange(of: canPenetrate) { _, value in
            if !value {
                isExpanded = false
                lastSelectedGroup = ""
                selectedMap = [:]
                stepwiseVisible = 1
            }
        }
        .onChange(of: canSwitch) { _, value in
            if !value { store.penetrationModeMap[root] = PPPenetrationMode.stepwise.rawValue }
        }
    }

    /// P-P04：某层改选后清掉下游已选，再按逐层模式推进可见层数。
    private func handleSelection(group: String, node: String) {
        lastSelectedGroup = group
        var map = selectedMap
        store.descendantGroups(group).forEach { map.removeValue(forKey: $0) }
        if (store.proxyMap[group]?.all ?? []).contains(node), store.isGroup(node) {
            map[group] = node
        } else {
            map.removeValue(forKey: group)
        }
        selectedMap = map
        if mode == .stepwise {
            let names = penetrated
            let index = names.firstIndex(of: lastSelectedGroup) ?? -1
            stepwiseVisible = index == -1 ? 1 : min(names.count, index + 2)
        }
    }
}

// MARK: - 订阅（P-V01…P-V05）

private struct PPProviderList: View {
    @EnvironmentObject private var store: ProxyPanelStore

    var body: some View {
        if store.providers.isEmpty {
            PPEmptyState(symbol: "tray", title: "没有订阅",
                         detail: String(localized: "当前配置里没有 http/file 类型的代理提供商（Compatible 与 default 不在此列出）", bundle: .wgLocalized))
        } else {
            ScrollView {
                LazyVStack(spacing: WgSpace.m) {
                    ForEach(store.providers) { PPProviderCard(provider: $0) }
                }
                .wgPadding(.bottom, .m)
            }
        }
    }
}

private struct PPProviderCard: View {
    @EnvironmentObject private var store: ProxyPanelStore
    var provider: MihomoProxyProvider

    private var key: String { "provider:" + provider.name }
    private var expanded: Bool { store.isExpanded(key) }

    var body: some View {
        let names = provider.proxies.map(\.name)
        let alive = names.filter { store.latency($0, group: provider.name) != mihomoNotConnected }.count
        VStack(alignment: .leading, spacing: WgSpace.m) {
            HStack(spacing: WgSpace.s) {
                Text(verbatim: provider.name).font(.system(size: WgType.title, weight: .semibold))
                Text(verbatim: "(\(alive)/\(names.count))").font(.system(size: WgType.body)).foregroundStyle(.secondary)
                Spacer()
                Button { Task { await store.healthCheckProvider(provider.name) } } label: {
                    if store.isTesting("health:\(provider.name)") { ProgressView().controlSize(.small) }
                    else { Image(systemName: "bolt.fill") }
                }
                .buttonStyle(WgToolbarIconButtonStyle())
                .help("健康检查")
                if provider.vehicleType != "Inline" {
                    Button { Task { await store.updateProvider(provider.name) } } label: {
                        Image(systemName: "arrow.clockwise")
                            .symbolEffect(.rotate, isActive: store.isTesting("update:\(provider.name)"))
                    }
                    .buttonStyle(WgToolbarIconButtonStyle())
                    .help("更新")
                }
            }
            HStack(spacing: WgSpace.l) {
                if let info = provider.subscriptionInfo {
                    Label(expireText(info), systemImage: "calendar")
                    Label(usageText(info), systemImage: "chart.bar.fill")
                }
                if let updated = provider.updatedAt.flatMap(PPPersist.parseDate) {
                    Label {
                        Text("更新于 ") + Text(updated, style: .relative)
                    } icon: { Image(systemName: "clock") }
                }
                Spacer()
                if store.categoryFeatureEnabled {
                    PPCategoryControls(provider: provider.name)
                }
            }
            .font(.system(size: WgType.body))
            .foregroundStyle(.secondary)
            if expanded {
                if store.categoryActive(provider: provider.name) {
                    PPCategorySections(provider: provider.name, names: names)
                } else {
                    PPNodeGrid(group: provider.name, names: names)
                }
            } else {
                PPPreview(nodes: names, now: nil, group: provider.name) { _ in }
            }
        }
        .wgPadding(.l)
        .wgInteractiveSurface(cornerRadius: WgDesign.cardRadius) {
            withAnimation(WgDesign.spring) { store.collapseMap[key] = !expanded }
        }
    }

    private func expireText(_ info: MihomoSubscriptionInfo) -> String {
        guard info.expire > 0 else { return String(localized: "不限时", bundle: .wgLocalized) }
        let date = Date(timeIntervalSince1970: TimeInterval(info.expire))
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return String(localized: "到期时间 \(f.string(from: date))", bundle: .wgLocalized)
    }

    private func usageText(_ info: MihomoSubscriptionInfo) -> String {
        let used = info.upload + info.download
        let fmt = ByteCountFormatter()
        guard info.total > 0 else { return String(localized: "已使用 \(fmt.string(fromByteCount: used))", bundle: .wgLocalized) }
        return "\(fmt.string(fromByteCount: used)) / \(fmt.string(fromByteCount: info.total))"
    }
}

// MARK: - 代理设置（P-C07）

private struct PPSettingsPopover: View {
    @EnvironmentObject private var store: ProxyPanelStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("代理设置")
                .font(.system(size: WgType.body, weight: .semibold))
                .wgPadding(.horizontal, .l)
                .wgPadding(.vertical, .m)
            Divider()
            VStack(spacing: 0) {
                row("排序方式") {
                    Picker("", selection: Binding(get: { store.sortType }, set: { store.sortType = $0 })) {
                        ForEach(PPSortType.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                if !store.smartWeights.isEmpty {
                    toggle("Smart 组根据使用频率排序", $store.useSmartGroupSort)
                }
                toggle("节点根据提供商分组", $store.groupProxiesByProvider)
                toggle("隐藏不可用节点", $store.hideUnavailableProxies)
                toggle("管理隐藏代理组", $store.manageHiddenGroup)
                toggle("切换节点时自动断开连接", $store.automaticDisconnection)
                toggle("显示完整路由节点", $store.displayFinalOutbound)
                row("节点卡片最小宽度") {
                    HStack(spacing: WgSpace.s) {
                        TextField("", value: $store.minProxyCardWidth, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                        Button("重置") { store.minProxyCardWidth = store.smallCard ? 140 : 180 }
                            .buttonStyle(WgPillButtonStyle())
                    }
                }
            }
            .wgPadding(.vertical, .xs)
        }
        .frame(width: 320)
        .focusEffectDisabled()
    }

    private func toggle(_ title: LocalizedStringKey, _ binding: Binding<Bool>) -> some View {
        row(title) {
            Toggle("", isOn: binding).toggleStyle(.switch).controlSize(.small).labelsHidden()
        }
    }

    private func row<A: View>(_ title: LocalizedStringKey, @ViewBuilder _ accessory: () -> A) -> some View {
        HStack {
            Text(title).font(.system(size: WgType.sub))
            Spacer()
            accessory()
        }
        .wgPadding(.horizontal, .l)
        .frame(minHeight: 34)
    }
}

// MARK: - 通知（P-T01…P-T03）

private struct PPNoticeStack: View {
    @EnvironmentObject private var store: ProxyPanelStore

    var body: some View {
        VStack(alignment: .trailing, spacing: WgSpace.s) {
            ForEach(store.notices) { notice in
                HStack(alignment: .top, spacing: WgSpace.m) {
                    Image(systemName: symbol(notice.kind))
                        .foregroundStyle(tint(notice.kind))
                        .font(.system(size: WgType.title))
                    VStack(alignment: .leading, spacing: WgSpace.zero) {
                        Text(verbatim: notice.title)
                            .font(.system(size: WgType.sub, weight: .semibold))
                            .lineLimit(2)
                        Text(verbatim: notice.detail)
                            .font(.system(size: WgType.body).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Button { store.dismiss(notice.id) } label: {
                        Image(systemName: "xmark").font(.system(size: WgType.micro, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                }
                .wgPadding(.m)
                .frame(width: 260, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: WgRadius.s, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .wgPadding(.l)
        .animation(WgDesign.spring, value: store.notices)
    }

    private func symbol(_ kind: PPNotice.Kind) -> String {
        switch kind {
        case .info: return "bolt.horizontal.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private func tint(_ kind: PPNotice.Kind) -> Color {
        switch kind {
        case .info: return WgInk.signal
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}

private struct PPEmptyState: View {
    var symbol: String
    var title: LocalizedStringKey
    var detail: String

    var body: some View {
        VStack(spacing: WgSpace.m) {
            WgSquareBadge(symbol: symbol, tint: .gray, size: 40, dimmed: true)
            Text(title).font(.system(size: WgType.title, weight: .semibold))
            Text(verbatim: detail)
                .font(.system(size: WgType.sub))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .wgInset(40)
        .wgInteractiveSurface(cornerRadius: WgDesign.cardRadius)
    }
}

/// 仪表风分段按钮：发丝框，选中项克莱因蓝实底。
struct PPSegmented<Value: Hashable>: View {
    var options: [(String, Value)]
    var selection: Value
    var onChange: (Value) -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let selected = option.1 == selection
                Text(LocalizedStringKey(option.0))
                    .font(.system(size: WgType.sub, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.white : WgInk.ink2)
                    .wgPadding(.horizontal, .m)
                    .frame(height: 24)
                    .background(selected ? WgInk.signal : Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { if !selected { onChange(option.1) } }
            }
        }
        .wgInset(1)
        .overlay(Rectangle().strokeBorder(Color.primary.opacity(0.16), lineWidth: 1))
        .opacity(isEnabled ? 1 : 0.4)
    }
}
