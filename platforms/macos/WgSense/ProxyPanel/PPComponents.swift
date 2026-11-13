import AppKit
import SwiftUI

// 代理面板基础组件：延迟标签、延迟点/条预览、节点链、节点卡片、组图标、右键动作。

// MARK: - 延迟配色

extension ProxyPanelStore.LatencyLevel {
    // 仪表语言：正常不上色（墨色），只有“慢”和“很慢/不通”才用琥珀与朱红，眼睛自然落在异常上。
    var color: Color {
        switch self {
        case .none: return WgInk.ink3
        case .low: return WgInk.ink
        case .medium: return WgInk.warn
        case .high: return WgInk.alert
        }
    }
    /// 预览点的底色：未测为淡墨，正常为实墨。
    var dotColor: Color {
        switch self {
        case .none: return WgInk.ink4
        case .low: return Color.primary.opacity(0.72)
        case .medium: return WgInk.warn
        case .high: return WgInk.alert
        }
    }
}

// MARK: - 右键直接触发（原版右键卡片 = 测速，不弹菜单）

// 实现：全局只有一个本地事件监听，卡片在悬停进出时把自己的动作压栈/出栈，右键时触发栈顶（最内层）。
// 之前每张卡片挂一个 NSView 接右键，几百个 NSView 在滚动时每帧都要跟着重新布局。
@MainActor
final class PPRightClickRouter {
    static let shared = PPRightClickRouter()
    private var stack: [(id: UUID, action: () -> Void)] = []
    private var monitor: Any?

    func push(_ id: UUID, _ action: @escaping () -> Void) {
        stack.removeAll { $0.id == id }
        stack.append((id, action))
        installIfNeeded()
    }

    func pop(_ id: UUID) { stack.removeAll { $0.id == id } }

    private func installIfNeeded() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self, let top = self.stack.last else { return event }
            top.action()
            return nil
        }
    }
}

private struct RightClickTarget: ViewModifier {
    var action: () -> Void
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                if inside { PPRightClickRouter.shared.push(id, action) } else { PPRightClickRouter.shared.pop(id) }
            }
            .onDisappear { PPRightClickRouter.shared.pop(id) }
    }
}

/// 按需挂悬停监听。
struct PPOptionalHover: ViewModifier {
    var enabled: Bool
    @Binding var hovering: Bool
    func body(content: Content) -> some View {
        if enabled { content.onHover { hovering = $0 } } else { content }
    }
}

extension View {
    /// 只在悬停时挂提示：每个 `.help` 都会向 AppKit 注册一块光标/提示区域，滚动时逐帧重算，
    /// 几百张卡片常驻提示是滚动掉帧的主要来源之一。
    @ViewBuilder
    func ppHelp(_ text: @autoclosure () -> String, when active: Bool) -> some View {
        if active { help(text()) } else { self }
    }

    func onRightClick(_ action: @escaping () -> Void) -> some View {
        modifier(RightClickTarget(action: action))
    }
}

// MARK: - 延迟标签（P-G06 · P-G07 · P-N03）

struct PPLatencyTag: View {
    @EnvironmentObject private var store: ProxyPanelStore
    var name: String?
    var group: String?
    var loading: Bool
    var small = false
    /// 由外层卡片提供悬停状态时，标签自己不再挂悬停监听（几百张卡片 × 两个悬停区 = 滚动时的命中测试开销）。
    var externalHover: Bool? = nil
    var action: () -> Void

    @State private var ownHover = false
    private var hovering: Bool { externalHover ?? ownHover }

    var body: some View {
        let latency = name.map { store.latency($0, group: group) } ?? mihomoNotConnected
        let level = store.level(latency)
        Button(action: action) {
            ZStack {
                if loading {
                    ProgressView().controlSize(.mini)
                } else if latency == mihomoNotConnected {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: WgType.micro, weight: .semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(latency)")
                        .font(.system(size: WgType.body, weight: .semibold).monospacedDigit())
                        .foregroundStyle(level.color)
                        .contentTransition(.numericText(value: Double(latency)))
                }
            }
            .frame(width: small ? 32 : 40, height: small ? 16 : 20)
            .background(RoundedRectangle(cornerRadius: WgRadius.s, style: .continuous).fill(Color.primary.opacity(hovering ? 0.12 : 0.055)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(PPOptionalHover(enabled: externalHover == nil, hovering: $ownHover))
        .animation(.easeOut(duration: 0.6), value: latency)
        // 提示文本只在悬停时生成：几百张卡每次渲染都查历史、格式化时间是白花的开销。
        .ppHelp(historyTip, when: hovering)
    }

    private static let tipFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return fmt
    }()

    /// 悬停显示测速历史（时间 + 延迟）。
    private var historyTip: String {
        guard let name else { return "" }
        let items = store.history(name, group: group)
        guard !items.isEmpty else { return String(localized: "测速", bundle: .wgLocalized) }
        let fmt = Self.tipFormatter
        return items.suffix(10).map { item in
            let time = PPPersist.parseDate(item.time).map { fmt.string(from: $0) } ?? item.time
            return String(localized: "\(time)  \(item.delay == 0 ? String(localized: "超时", bundle: .wgLocalized) : "\(item.delay)ms")", bundle: .wgLocalized)
        }.joined(separator: "\n")
    }
}

// MARK: - 预览（P-G09）

struct PPPreview: View {
    @EnvironmentObject private var store: ProxyPanelStore
    var nodes: [String]
    var now: String?
    var group: String?
    var onSelect: (String) -> Void

    @State private var width: CGFloat = 0

    var body: some View {
        let showDots: Bool = {
            switch store.previewType {
            case .dots: return true
            case .bar: return false
            case .auto: return width == 0 || width > CGFloat(20 * nodes.count)
            }
        }()
        Group {
            if showDots {
                PPFlowLayout(spacing: WgSpace.xs) {
                    ForEach(nodes, id: \.self) { node in
                        let latency = store.latency(node, group: group)
                        PPDot(color: store.level(latency).dotColor, isCurrent: node == now,
                              tip: latency == 0 ? node : "\(node)  \(latency)ms") { onSelect(node) }
                    }
                }
            } else {
                barView
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GeometryReader { geo in
            Color.clear.onAppear { width = geo.size.width }
                .onChange(of: geo.size.width) { _, w in width = w }
        })
    }

    private var barView: some View {
        let levels = nodes.map { store.level(store.latency($0, group: group)) }
        let total = max(levels.count, 1)
        let counts: [(ProxyPanelStore.LatencyLevel, Int)] = [
            (.low, levels.filter { $0 == .low }.count),
            (.medium, levels.filter { $0 == .medium }.count),
            (.high, levels.filter { $0 == .high }.count),
            (.none, levels.filter { $0 == .none }.count),
        ]
        return GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(counts, id: \.0) { level, count in
                    level.dotColor.frame(width: geo.size.width * CGFloat(count) / CGFloat(total))
                }
            }
        }
        .frame(height: 6)
        .clipShape(RoundedRectangle(cornerRadius: WgRadius.s, style: .continuous))
    }
}

/// 延迟点：纯值输入，不订阅数据源（上层算好颜色传入），避免任何数据变化都让几百个点一起重算。
private struct PPDot: View, Equatable {
    var color: Color
    var isCurrent: Bool
    var tip: String
    var action: () -> Void
    @State private var hovering = false

    static func == (a: PPDot, b: PPDot) -> Bool {
        a.color == b.color && a.isCurrent == b.isCurrent && a.tip == b.tip
    }

    var body: some View {
        // 方点：像示波器/矩阵屏的像素。当前节点 = 克莱因蓝实块。
        Rectangle()
            .fill(isCurrent ? WgInk.signal : color)
            .frame(width: 9, height: 9)
            .wgPadding(.zero)
            .overlay {
                if isCurrent { Rectangle().strokeBorder(WgInk.signal, lineWidth: 1) }
            }
            .scaleEffect(hovering ? 1.15 : 1)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(perform: action)
            .ppHelp(tip, when: hovering)
    }
}

/// 组下载速度：唯一订阅每秒变化统计的视图。
struct PPGroupSpeed: View {
    @ObservedObject private var live = PPLiveStats.shared
    var group: String
    var body: some View {
        Text(verbatim: WgFormat.speed(Double(live.groupDownloadSpeed[group] ?? 0)))
            .font(.system(size: WgType.body).monospacedDigit())
            .foregroundStyle(.secondary)
            .fixedSize()
    }
}

/// 自动换行布局（预览点、节点链等）。
struct PPFlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - 节点链（P-G03 · P-G04 · P-G05）

struct PPRouteView: View {
    @EnvironmentObject private var store: ProxyPanelStore
    var group: String
    var forceFull = false

    var body: some View {
        let proxy = store.proxyMap[group]
        HStack(spacing: WgSpace.xs) {
            if let proxy, proxy.now != nil {
                if store.isFixed(group) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: WgType.body))
                        .foregroundStyle(.secondary)
                        .help("当前策略组被固定在了当前节点，点击测速来恢复 \(proxy.type) 行为")
                }
                let names = (store.displayFinalOutbound || forceFull) ? store.routeChain(group) : [proxy.now!]
                ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                    if index > 0 {
                        Image(systemName: "arrow.right")
                            .font(.system(size: WgType.micro, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    Text(verbatim: name)
                        .font(.system(size: WgType.sub))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else if proxy?.type.lowercased() == "loadbalance" {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: WgType.body))
                    .foregroundStyle(.secondary)
                Text("负载均衡")
                    .font(.system(size: WgType.sub))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }
}

// MARK: - 组图标

struct PPGroupIcon: View {
    var icon: String?
    var size: CGFloat

    var body: some View {
        if let icon, let url = URL(string: icon), url.scheme?.hasPrefix("http") == true {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                Color.clear
            }
            .frame(width: size, height: size)
        } else if let icon, icon.hasPrefix("data:image"),
                  let data = Data(base64Encoded: String(icon.split(separator: ",").last ?? "")),
                  let image = NSImage(data: data) {
            Image(nsImage: image).resizable().scaledToFit().frame(width: size, height: size)
        }
    }
}

// MARK: - 节点卡片（P-N01…P-N08）

struct PPNodeCard: View {
    @EnvironmentObject private var store: ProxyPanelStore
    var name: String
    var group: String
    var active: Bool

    @State private var hovering = false
    @State private var flash = false
    @State private var clickID = UUID()

    // 整张卡用一个 Canvas 画完（背景、边框、名称、协议、延迟标签），不再由十几层视图拼装。
    // 滚动换向时列表要批量创建行，单卡的视图层数直接决定那几帧会不会掉。
    var body: some View {
        let node = store.proxyMap[name]
        let small = store.smallCard
        let pad: CGFloat = small ? 7 : 10
        let tagSize = CGSize(width: small ? 32 : 40, height: small ? 16 : 20)
        let latency = store.latency(name, group: group)
        let loading = store.isTesting("node:\(group)/\(name)")
        let type = typeDescription(node)
        let nameFont = NSFont.systemFont(ofSize: small ? WgType.sub : WgType.body, weight: active ? .semibold : .regular)
        let lines = Self.lines(name, store: store)
        let lineHeight: CGFloat = small ? 15 : 17
        let height = Self.height(for: name, store: store)
        let hasIcon = node?.icon != nil
        let levelColor = active ? Color.white : store.level(latency).color
        Canvas { ctx, size in
            let rect = CGRect(origin: .zero, size: size)
            // 斜切节点卡（右上 + 左下）；选中 = 白色弱玻璃（半透明白 + 亮边），不再是实色块。
            let shape = ChamferShape(WgInk.cutControl).path(in: rect.insetBy(dx: 0.5, dy: 0.5))
            ctx.fill(shape, with: .color(active ? Color.white.opacity(0.17) : Color.primary.opacity(hovering ? 0.075 : 0.035)))
            if flash {
                ctx.stroke(ChamferShape(WgInk.cutControl).path(in: rect.insetBy(dx: 1, dy: 1)), with: .color(WgInk.ink), lineWidth: 2)
            } else {
                ctx.stroke(shape, with: .color(active ? Color.white.opacity(0.4) : Color.primary.opacity(hovering ? 0.14 : 0.07)), lineWidth: 1)
            }
            // 名称
            let nameX = pad + (hasIcon ? 18 : 0)
            let nameWidth = size.width - nameX - pad
            let shown = lines == 1 ? Self.truncate(name, font: nameFont, width: nameWidth) : name
            let title = Text(verbatim: shown)
                .font(Font(nameFont))
                .foregroundColor(active ? .white : .primary)
            ctx.draw(title, in: CGRect(x: nameX, y: pad - 1, width: nameWidth, height: lineHeight * CGFloat(lines) + 2))
            // 协议 / udp
            let baseline = size.height - pad - tagSize.height / 2
            let typeText = Text(verbatim: Self.truncate(type, font: .systemFont(ofSize: WgType.body), width: size.width - pad * 2 - tagSize.width - 6))
                .font(.system(size: WgType.body))
                .foregroundColor(active ? Color.white.opacity(0.8) : Color.secondary)
            ctx.draw(typeText, at: CGPoint(x: pad, y: baseline), anchor: .leading)
            // 延迟标签
            let tag = CGRect(x: size.width - pad - tagSize.width, y: size.height - pad - tagSize.height, width: tagSize.width, height: tagSize.height)
            ctx.fill(Path(roundedRect: tag, cornerRadius: WgRadius.s), with: .color(Color.primary.opacity(active ? 0.0 : 0.055)))
            if active { ctx.fill(Path(roundedRect: tag, cornerRadius: WgRadius.s), with: .color(Color.white.opacity(0.14))) }
            let center = CGPoint(x: tag.midX, y: tag.midY)
            if loading {
                ctx.draw(Text(verbatim: "···").font(.system(size: WgType.body, weight: .bold)).foregroundColor(levelColor), at: center)
            } else if latency == mihomoNotConnected {
                ctx.draw(Text(Image(systemName: "bolt.fill")).font(.system(size: WgType.micro, weight: .semibold))
                    .foregroundColor(active ? Color.white.opacity(0.8) : Color.secondary), at: center)
            } else {
                ctx.draw(Text(verbatim: "\(latency)").font(.system(size: WgType.body, weight: .semibold).monospacedDigit()).foregroundColor(levelColor), at: center)
            }
        }
        .frame(height: height)
        .frame(minWidth: store.minProxyCardWidth, maxWidth: .infinity)
        .overlay(alignment: .topLeading) {
            if hasIcon { PPGroupIcon(icon: node?.icon, size: 14).wgInset(.leading, pad).wgInset(.top, pad + 1).allowsHitTesting(false) }
        }
        // 延迟标签的点击区（测速）。
        .overlay(alignment: .bottomTrailing) {
            Color.clear
                .frame(width: tagSize.width, height: tagSize.height)
                .contentShape(Rectangle())
                .onTapGesture { test() }
                .wgInset(pad)
        }
        .contentShape(Rectangle())
        // 唯一的悬停监听：同时负责高亮、提示与右键测速的路由。
        .onHover { inside in
            hovering = inside
            if inside { PPRightClickRouter.shared.push(clickID) { test() } } else { PPRightClickRouter.shared.pop(clickID) }
        }
        .onDisappear { PPRightClickRouter.shared.pop(clickID) }
        .onTapGesture { Task { await store.select(group: group, node: name) } }
        .ppHelp(tooltip, when: hovering)
    }

    private var tooltip: String {
        let items = store.history(name, group: group)
        guard !items.isEmpty else { return name }
        let fmt = PPNodeCard.tipFormatter
        return ([name] + items.suffix(10).map { item in
            let time = PPPersist.parseDate(item.time).map { fmt.string(from: $0) } ?? item.time
            return String(localized: "\(time)  \(item.delay == 0 ? String(localized: "超时", bundle: .wgLocalized) : "\(item.delay)ms")", bundle: .wgLocalized)
        }).joined(separator: "\n")
    }

    private static let tipFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return fmt
    }()

    private static var widthCache: [String: CGFloat] = [:]

    private static func width(_ text: String, font: NSFont) -> CGFloat {
        let key = "\(font.pointSize)|\(font.fontName)|\(text)"
        if let w = widthCache[key] { return w }
        let w = (text as NSString).size(withAttributes: [.font: font]).width
        if widthCache.count > 4000 { widthCache.removeAll() }
        widthCache[key] = w
        return w
    }

    /// 单行截断（尾部省略号）。
    static func truncate(_ text: String, font: NSFont, width: CGFloat) -> String {
        guard width > 0, Self.width(text, font: font) > width else { return text }
        var chars = Array(text)
        while !chars.isEmpty && Self.width(String(chars) + "…", font: font) > width { chars.removeLast() }
        return String(chars) + "…"
    }

    static func lines(_ name: String, store: ProxyPanelStore) -> Int {
        guard !store.truncateProxyName else { return 1 }
        let small = store.smallCard
        let font = NSFont.systemFont(ofSize: small ? WgType.sub : WgType.body, weight: .semibold)
        return lineCount(name, font: font, width: store.minProxyCardWidth - (small ? 14 : 20) - 18)
    }

    /// 卡片高度可直接算出（不依赖布局测量），列表据此给出节点行的精确行高。
    static func height(for name: String, store: ProxyPanelStore) -> CGFloat {
        let small = store.smallCard
        let pad: CGFloat = small ? 7 : 10
        let lineHeight: CGFloat = small ? 15 : 17
        return pad * 2 + lineHeight * CGFloat(lines(name, store: store)) + (small ? 3 : 6) + (small ? 16 : 20)
    }

    static func lineCount(_ text: String, font: NSFont, width: CGFloat) -> Int {
        min(3, max(1, Int(ceil(Self.width(text, font: font) / max(40, width)))))
    }

    private func test() {
        Task {
            await store.testNode(name, group: group)
            // P-N07：按延迟排序时，测完闪烁提示位置。
            if store.sortType == .latencyasc || store.sortType == .latencydesc {
                flash = true
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                flash = false
            }
        }
    }

    /// P-N02：协议简写 / udp|xudp / Smart 使用频率 / IPv6。
    private func typeDescription(_ node: MihomoProxy?) -> String {
        guard let node else { return "" }
        var type = node.type.lowercased()
        type = type.replacingOccurrences(of: "shadowsocks", with: "ss")
            .replacingOccurrences(of: "hysteria", with: "hy")
            .replacingOccurrences(of: "wireguard", with: "wg")
        let udp = node.udp ? (node.xudp ? "xudp" : "udp") : ""
        let smart: String = {
            switch store.smartWeights[group]?[name] {
            case "MostUsed": return String(localized: "经常使用", bundle: .wgLocalized)
            case "OccasionalUsed": return String(localized: "偶尔使用", bundle: .wgLocalized)
            case "RarelyUsed": return String(localized: "很少使用", bundle: .wgLocalized)
            default: return ""
            }
        }()
        let v6 = store.ipv6Test && (store.ipv6Map[name] ?? false) ? "IPv6" : ""
        return [type, udp, smart, v6].filter { !$0.isEmpty }.joined(separator: store.smallCard ? "/" : " / ")
    }
}

/// 节点卡片网格：按最小宽度自适应列数。
struct PPNodeGrid: View {
    @EnvironmentObject private var store: ProxyPanelStore
    var group: String
    var names: [String]

    var body: some View {
        let now = store.proxyMap[group]?.now
        // 非懒加载网格：外层 LazyVStack 已按组懒加载；组内再套 LazyVGrid 会让每一帧滚动都重算可见区与摆放。
        PPAdaptiveGrid(minWidth: store.minProxyCardWidth, spacing: WgSpace.s) {
            ForEach(names, id: \.self) { name in
                PPNodeCard(name: name, group: group, active: name == now)
            }
        }
    }
}

/// 自适应列宽网格（等价于 GridItem(.adaptive(minimum:))，但不懒加载；行高按宽度缓存）。
struct PPAdaptiveGrid: Layout {
    var minWidth: CGFloat
    var spacing: CGFloat

    struct Cache { var width: CGFloat = -1; var rows: [CGFloat] = [] }
    func makeCache(subviews: Subviews) -> Cache { Cache() }
    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache = Cache() }

    private func columns(for width: CGFloat) -> Int { max(1, Int((width + spacing) / (minWidth + spacing))) }

    private func rows(_ width: CGFloat, _ subviews: Subviews, _ cache: inout Cache) -> [CGFloat] {
        if cache.width == width { return cache.rows }
        let cols = columns(for: width)
        let cellWidth = (width - spacing * CGFloat(cols - 1)) / CGFloat(cols)
        var rows: [CGFloat] = []
        var index = 0
        while index < subviews.count {
            let slice = subviews[index..<min(index + cols, subviews.count)]
            rows.append(slice.map { $0.sizeThatFits(ProposedViewSize(width: cellWidth, height: nil)).height }.max() ?? 0)
            index += cols
        }
        cache = Cache(width: width, rows: rows)
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = proposal.width ?? minWidth
        let r = rows(width, subviews, &cache)
        return CGSize(width: width, height: r.reduce(0, +) + spacing * CGFloat(max(0, r.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let cols = columns(for: bounds.width)
        let cellWidth = (bounds.width - spacing * CGFloat(cols - 1)) / CGFloat(cols)
        let r = rows(bounds.width, subviews, &cache)
        var y = bounds.minY
        for (rowIndex, rowHeight) in r.enumerated() {
            for col in 0..<cols {
                let i = rowIndex * cols + col
                guard i < subviews.count else { break }
                subviews[i].place(at: CGPoint(x: bounds.minX + CGFloat(col) * (cellWidth + spacing), y: y),
                                  proposal: ProposedViewSize(width: cellWidth, height: rowHeight))
            }
            y += rowHeight + spacing
        }
    }
}
