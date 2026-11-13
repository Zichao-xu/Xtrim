import AppKit
import SwiftUI

// 连接拓扑（O-T01…O-T05）：自绘桑基图。
// 源 IP → 规则匹配 → 代理链入口 → 代理链出口；连线粗细按连接数对数压缩（与原版一致）。

struct PPSankeyModel: Equatable {
    struct Node: Equatable, Hashable {
        var key: String        // "层|名称"
        var name: String
        var layer: Int
    }
    struct Link: Equatable, Hashable {
        var source: String     // node key
        var target: String
        var count: Int
        var key: String { source + "→" + target }
        var weight: Double { log10(Double(count) + 1) * 10 }
    }
    var nodes: [Node]
    var links: [Link]

    static let layerTitles = [String(localized: "源IP地址", bundle: .wgLocalized), String(localized: "规则匹配", bundle: .wgLocalized), String(localized: "代理链入口", bundle: .wgLocalized), String(localized: "代理链出口", bundle: .wgLocalized)]

    static func build(from connections: [MihomoConnection], label: (String) -> String) -> PPSankeyModel {
        var nodes: [String: Node] = [:]
        var counts: [String: (String, String, Int)] = [:]
        func node(_ name: String, _ layer: Int) -> String {
            let key = "\(layer)|\(name)"
            if nodes[key] == nil { nodes[key] = Node(key: key, name: name, layer: layer) }
            return key
        }
        func link(_ a: String, _ b: String) {
            let k = a + "→" + b
            counts[k] = (a, b, (counts[k]?.2 ?? 0) + 1)
        }
        for conn in connections {
            guard let first = conn.chains.first, let last = conn.chains.last else { continue }
            let source = node(label(conn.metadata.sourceIP), 0)
            let ruleName = (conn.rulePayload ?? "").isEmpty ? (conn.rule ?? "-") : "\(conn.rule ?? ""): \(conn.rulePayload ?? "")"
            let rule = node(ruleName, 1)
            link(source, rule)
            if first == last {
                let exit = node(first, 3)
                link(rule, exit)
            } else {
                let entry = node(last, 2)
                let exit = node(first, 3)
                link(rule, entry)
                link(entry, exit)
            }
        }
        let sortedNodes = nodes.values.sorted { $0.layer != $1.layer ? $0.layer < $1.layer : $0.name.localizedCompare($1.name) == .orderedAscending }
        let links = counts.values.map { Link(source: $0.0, target: $0.1, count: $0.2) }.sorted { $0.key < $1.key }
        return PPSankeyModel(nodes: sortedNodes, links: links)
    }
}

/// 布局结果：节点矩形 + 连线两端区间。
struct PPSankeyLayout {
    struct NodeBox { var rect: CGRect; var node: PPSankeyModel.Node; var total: Int }
    struct Ribbon { var link: PPSankeyModel.Link; var y0: ClosedRange<CGFloat>; var y1: ClosedRange<CGFloat>; var x0: CGFloat; var x1: CGFloat }
    var nodes: [String: NodeBox] = [:]
    var ribbons: [String: Ribbon] = [:]

    static let nodeWidth: CGFloat = 4
    static let gap: CGFloat = 6

    static func compute(_ model: PPSankeyModel, size: CGSize) -> PPSankeyLayout {
        var layout = PPSankeyLayout()
        guard !model.nodes.isEmpty, size.width > 40, size.height > 40 else { return layout }
        let columns = 4
        let usable = size.width - nodeWidth
        let colX = (0..<columns).map { CGFloat($0) * usable / CGFloat(columns - 1) }

        var inWeight: [String: Double] = [:], outWeight: [String: Double] = [:]
        var inCount: [String: Int] = [:], outCount: [String: Int] = [:]
        for l in model.links {
            outWeight[l.source, default: 0] += l.weight
            inWeight[l.target, default: 0] += l.weight
            outCount[l.source, default: 0] += l.count
            inCount[l.target, default: 0] += l.count
        }
        func value(_ key: String) -> Double { max(inWeight[key] ?? 0, outWeight[key] ?? 0, 1) }

        let byLayer = Dictionary(grouping: model.nodes, by: \.layer)
        // 统一缩放：取最拥挤一列决定每单位权重的像素数。
        var k = CGFloat.greatestFiniteMagnitude
        for (_, list) in byLayer {
            let total = list.reduce(0) { $0 + value($1.key) }
            let room = size.height - gap * CGFloat(max(0, list.count - 1))
            k = min(k, room / CGFloat(total))
        }
        k = max(k, 0.1)
        for (layer, list) in byLayer {
            let heights = list.map { max(2, CGFloat(value($0.key)) * k) }
            let used = heights.reduce(0, +) + gap * CGFloat(max(0, list.count - 1))
            var y = max(0, (size.height - used) / 2)
            for (node, h) in zip(list, heights) {
                layout.nodes[node.key] = NodeBox(rect: CGRect(x: colX[min(layer, columns - 1)], y: y, width: nodeWidth, height: h),
                                                 node: node, total: max(inCount[node.key] ?? 0, outCount[node.key] ?? 0))
                y += h + gap
            }
        }
        // 连线两端：源侧按目标 y 排序、目标侧按源 y 排序，减少交叉。
        var outOffset: [String: CGFloat] = [:], inOffset: [String: CGFloat] = [:]
        let bySource = model.links.sorted { (layout.nodes[$0.target]?.rect.minY ?? 0) < (layout.nodes[$1.target]?.rect.minY ?? 0) }
        var sourceSpan: [String: ClosedRange<CGFloat>] = [:]
        for l in bySource {
            guard let s = layout.nodes[l.source] else { continue }
            let h = CGFloat(l.weight) * k * (s.rect.height / max(2, CGFloat(value(l.source)) * k))
            let y0 = s.rect.minY + (outOffset[l.source] ?? 0)
            outOffset[l.source] = (outOffset[l.source] ?? 0) + h
            sourceSpan[l.key] = y0...(y0 + h)
        }
        let byTarget = model.links.sorted { (layout.nodes[$0.source]?.rect.minY ?? 0) < (layout.nodes[$1.source]?.rect.minY ?? 0) }
        for l in byTarget {
            guard let s = layout.nodes[l.source], let t = layout.nodes[l.target], let span = sourceSpan[l.key] else { continue }
            let h = span.upperBound - span.lowerBound
            let y1 = t.rect.minY + (inOffset[l.target] ?? 0)
            inOffset[l.target] = (inOffset[l.target] ?? 0) + h
            layout.ribbons[l.key] = Ribbon(link: l, y0: span, y1: y1...(y1 + h), x0: s.rect.maxX, x1: t.rect.minX)
        }
        return layout
    }

    /// 两个布局之间插值；新出现的从零高度长出，消失的收缩到零。
    static func interpolate(from a: PPSankeyLayout, to b: PPSankeyLayout, t: CGFloat) -> PPSankeyLayout {
        func lerp(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * t }
        func lerpRect(_ r0: CGRect, _ r1: CGRect) -> CGRect {
            CGRect(x: lerp(r0.minX, r1.minX), y: lerp(r0.minY, r1.minY), width: lerp(r0.width, r1.width), height: lerp(r0.height, r1.height))
        }
        func lerpRange(_ r0: ClosedRange<CGFloat>, _ r1: ClosedRange<CGFloat>) -> ClosedRange<CGFloat> {
            let lo = lerp(r0.lowerBound, r1.lowerBound)
            return lo...max(lo, lerp(r0.upperBound, r1.upperBound))
        }
        func collapsed(_ r: ClosedRange<CGFloat>) -> ClosedRange<CGFloat> { let m = (r.lowerBound + r.upperBound) / 2; return m...m }
        var out = PPSankeyLayout()
        for key in Set(a.nodes.keys).union(b.nodes.keys) {
            switch (a.nodes[key], b.nodes[key]) {
            case let (x?, y?): out.nodes[key] = NodeBox(rect: lerpRect(x.rect, y.rect), node: y.node, total: y.total)
            case let (nil, y?): out.nodes[key] = NodeBox(rect: lerpRect(CGRect(x: y.rect.minX, y: y.rect.midY, width: y.rect.width, height: 0), y.rect), node: y.node, total: y.total)
            case let (x?, nil): out.nodes[key] = NodeBox(rect: lerpRect(x.rect, CGRect(x: x.rect.minX, y: x.rect.midY, width: x.rect.width, height: 0)), node: x.node, total: x.total)
            default: break
            }
        }
        for key in Set(a.ribbons.keys).union(b.ribbons.keys) {
            switch (a.ribbons[key], b.ribbons[key]) {
            case let (x?, y?):
                out.ribbons[key] = Ribbon(link: y.link, y0: lerpRange(x.y0, y.y0), y1: lerpRange(x.y1, y.y1), x0: lerp(x.x0, y.x0), x1: lerp(x.x1, y.x1))
            case let (nil, y?):
                out.ribbons[key] = Ribbon(link: y.link, y0: lerpRange(collapsed(y.y0), y.y0), y1: lerpRange(collapsed(y.y1), y.y1), x0: y.x0, x1: y.x1)
            case let (x?, nil):
                out.ribbons[key] = Ribbon(link: x.link, y0: lerpRange(x.y0, collapsed(x.y0)), y1: lerpRange(x.y1, collapsed(x.y1)), x0: x.x0, x1: x.x1)
            default: break
            }
        }
        return out
    }
}

private final class SankeyAnimation {
    var from = PPSankeyLayout()
    var to = PPSankeyLayout()
    var start: TimeInterval = 0
    var size: CGSize = .zero
    var model = PPSankeyModel(nodes: [], links: [])
    static let duration: TimeInterval = 0.6

    func progress(at now: TimeInterval) -> CGFloat {
        let t = min(1, max(0, (now - start) / Self.duration))
        return CGFloat(1 - pow(1 - t, 3))   // cubic ease-out
    }

    func current(at now: TimeInterval) -> PPSankeyLayout {
        PPSankeyLayout.interpolate(from: from, to: to, t: progress(at: now))
    }
}

struct PPSankeyView: View, Equatable {
    var model: PPSankeyModel
    /// 悬停时通知外部暂停数据更新（O-T03）。
    var onHoverChange: (Bool) -> Void = { _ in }
    var labelLimit = 28

    @State private var anim = SankeyAnimation()
    @State private var animating = false
    @State private var hover: CGPoint?
    @State private var focus: Set<String>?     // 高亮的节点/连线 key
    @State private var tip: String?

    /// 只有模型或标签长度变了才重画（外层卡片订阅了整个概览数据，任何一项更新都会走到这里）。
    static func == (a: PPSankeyView, b: PPSankeyView) -> Bool { a.model == b.model && a.labelLimit == b.labelLimit }

    /// 顶部列标题区高度（A 源IP地址 · B 规则匹配 …）。
    static let headerHeight: CGFloat = 28
    static let layerMarks = ["A", "B", "C", "D"]

    /// 按实际标签宽度决定左右边距：左边放第一列标签，右边放最后一列标签。
    private func margins(width: CGFloat) -> (left: CGFloat, right: CGFloat) {
        func widest(_ layer: Int) -> CGFloat {
            model.nodes.filter { $0.layer == layer }.map { Self.textWidth(truncate($0.name, limit: labelLimit)) }.max() ?? 0
        }
        let left = min(max(widest(0) + 22, 70), width * 0.2)
        let right = min(max(widest(3) + 40, 96), width * 0.3)   // 出口标签块：左距 10 + 内边距 16 + 余量
        return (left, right)
    }

    static func textWidth(_ text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: WgType.body)]).width
    }

    private func truncate(_ name: String, limit: Int) -> String {
        name.count > limit ? String(name.prefix(limit)) + "…" : name
    }

    var body: some View {
        GeometryReader { geo in
            let m = margins(width: geo.size.width)
            let plotSize = CGSize(width: max(1, geo.size.width - m.left - m.right), height: max(1, geo.size.height - Self.headerHeight))
            TimelineView(.animation(minimumInterval: 1.0 / 45, paused: !animating)) { timeline in
                Canvas { context, size in
                    let now = timeline.date.timeIntervalSince1970
                    let layout = anim.current(at: now)
                    drawHeader(&context, offsetX: m.left, plotWidth: plotSize.width)
                    var body = context
                    body.translateBy(x: 0, y: Self.headerHeight)
                    draw(&body, layout: layout, offsetX: m.left, columnGap: plotSize.width / 3)
                    if anim.progress(at: now) >= 1 { DispatchQueue.main.async { if animating { animating = false } } }
                }
            }
            .onAppear { retarget(size: plotSize, animated: false) }
            .onChange(of: model) { _, _ in retarget(size: plotSize, animated: true) }
            .onChange(of: geo.size) { _, _ in retarget(size: plotSize, animated: false) }
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    hover = p
                    updateFocus(at: CGPoint(x: p.x - m.left, y: p.y - Self.headerHeight))
                    onHoverChange(true)
                case .ended:
                    hover = nil; focus = nil; tip = nil
                    onHoverChange(false)
                }
            }
            .overlay(alignment: .topLeading) {
                if let tip, let hover {
                    Text(verbatim: tip)
                        .font(.system(size: WgType.body, weight: .medium))
                        .wgPadding(.horizontal, .s).wgPadding(.vertical, .xs)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: WgRadius.s, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: WgRadius.s, style: .continuous).strokeBorder(WgInk.rule))
                        .offset(x: min(hover.x + 12, geo.size.width - 260), y: max(0, hover.y - 38))
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private func retarget(size: CGSize, animated: Bool) {
        let target = PPSankeyLayout.compute(model, size: size)
        let now = Date().timeIntervalSince1970
        anim.from = animated ? anim.current(at: now) : target
        anim.to = target
        anim.start = now
        anim.size = size
        anim.model = model
        if animated { animating = true } else { animating.toggle(); animating = false }
    }

    // MARK: 绘制

    private func ribbonPath(_ r: PPSankeyLayout.Ribbon, dx: CGFloat) -> Path {
        var p = Path()
        let mid = (r.x0 + r.x1) / 2
        p.move(to: CGPoint(x: r.x0 + dx, y: r.y0.lowerBound))
        p.addCurve(to: CGPoint(x: r.x1 + dx, y: r.y1.lowerBound), control1: CGPoint(x: mid + dx, y: r.y0.lowerBound), control2: CGPoint(x: mid + dx, y: r.y1.lowerBound))
        p.addLine(to: CGPoint(x: r.x1 + dx, y: r.y1.upperBound))
        p.addCurve(to: CGPoint(x: r.x0 + dx, y: r.y0.upperBound), control1: CGPoint(x: mid + dx, y: r.y1.upperBound), control2: CGPoint(x: mid + dx, y: r.y0.upperBound))
        p.closeSubpath()
        return p
    }

    private func layer(of key: String) -> Int { Int(key.prefix { $0 != "|" }) ?? 0 }

    /// 列标题：字母编号 + 名称，下方一条发丝线与节点列对齐的刻痕，像图纸的分区标注。
    private func drawHeader(_ context: inout GraphicsContext, offsetX dx: CGFloat, plotWidth: CGFloat) {
        // 列头：等宽「A · 源IP地址」… 对齐到各列节点。
        let usable = plotWidth - PPSankeyLayout.nodeWidth
        let baseY = Self.headerHeight - 10
        for i in 0..<4 {
            let x = dx + CGFloat(i) * usable / 3 + PPSankeyLayout.nodeWidth / 2
            let label = Text(verbatim: "\(Self.layerMarks[i]) · \(PPSankeyModel.layerTitles[i])")
                .font(WgInk.mono(.caption, .medium)).foregroundStyle(Color.primary.opacity(0.45))
            context.draw(label, at: CGPoint(x: i == 0 ? x + 4 : x - 4, y: baseY), anchor: i == 0 ? .trailing : .leading)
        }
    }

    /// 稳定的伪随机（按字符串 + 序号），让同一条轨迹每次重画的弯曲一致。
    private static func jitter(_ key: String, _ k: Int) -> CGFloat {
        var h: UInt64 = 1469598103934665603
        for b in key.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        h = (h ^ UInt64(k + 1)) &* 1099511628211
        return CGFloat(h % 1000) / 1000 - 0.5
    }

    /// 粒子轨迹：每条连接画成若干根虚点曲线（连接越多越密），节点是实心点 + 淡竖线表示体量，
    /// 出口节点用细框标签块。悬停追踪的整条路径变亮白、变粗，其余压暗。
    private func draw(_ context: inout GraphicsContext, layout: PPSankeyLayout, offsetX dx: CGFloat, columnGap: CGFloat) {
        let middleMax = max(40, columnGap - PPSankeyLayout.nodeWidth - 18)
        let dotted = StrokeStyle(lineWidth: 1.25, lineCap: .round, dash: [0.1, 3])
        let dottedHot = StrokeStyle(lineWidth: 2.2, lineCap: .round, dash: [0.1, 2.6])
        for ribbon in layout.ribbons.values.sorted(by: { $0.link.key < $1.link.key }) {
            let active = focus.map { $0.contains(ribbon.link.key) } ?? true
            let strands = min(6, max(1, Int((Double(ribbon.link.count)).squareRoot().rounded(.up))))
            let opacity: Double = focus == nil ? 0.42 : (active ? 0.95 : 0.07)
            for k in 0..<strands {
                let f = (CGFloat(k) + 0.5) / CGFloat(strands)
                let y0 = ribbon.y0.lowerBound + (ribbon.y0.upperBound - ribbon.y0.lowerBound) * f
                let y1 = ribbon.y1.lowerBound + (ribbon.y1.upperBound - ribbon.y1.lowerBound) * f
                let x0 = ribbon.x0 + dx - PPSankeyLayout.nodeWidth / 2, x1 = ribbon.x1 + dx + PPSankeyLayout.nodeWidth / 2
                let span = x1 - x0
                let j = Self.jitter(ribbon.link.key, k) * span * 0.25
                var p = Path()
                p.move(to: CGPoint(x: x0, y: y0))
                p.addCurve(to: CGPoint(x: x1, y: y1),
                           control1: CGPoint(x: x0 + span * 0.5 + j, y: y0),
                           control2: CGPoint(x: x0 + span * 0.5 - j, y: y1))
                context.stroke(p, with: .color(Color.primary.opacity(opacity)), style: focus != nil && active ? dottedHot : dotted)
            }
        }
        for box in layout.nodes.values {
            let active = focus.map { $0.contains(box.node.key) } ?? true
            let hot = focus != nil && active
            let rect = box.rect.offsetBy(dx: dx, dy: 0)
            let cx = rect.midX
            // 体量竖线
            var bar = Path()
            bar.move(to: CGPoint(x: cx, y: rect.minY)); bar.addLine(to: CGPoint(x: cx, y: rect.maxY))
            context.stroke(bar, with: .color(Color.primary.opacity(active ? 0.28 : 0.08)), lineWidth: 1)
            let r: CGFloat = hot ? 4.5 : 3.5
            context.fill(Path(ellipseIn: CGRect(x: cx - r, y: rect.midY - r, width: r * 2, height: r * 2)),
                         with: .color(Color.primary.opacity(active ? 1 : 0.25)))
            var name = truncate(box.node.name, limit: labelLimit)
            if box.node.layer == 1 || box.node.layer == 2 {
                while name.count > 2 && Self.textWidth(name) > middleMax { name = String(name.dropLast(2)) + "…" }
            }
            switch box.node.layer {
            case 0:
                context.draw(Text(verbatim: name).font(WgInk.mono(.caption)).foregroundStyle(Color.primary.opacity(active ? 0.8 : 0.25)),
                             at: CGPoint(x: cx - 10, y: rect.midY), anchor: .trailing)
            case 3:
                // 出口：细框标签块；被追踪时为白色弱玻璃。
                let resolved = context.resolve(Text(verbatim: name).font(.system(size: WgType.sub, weight: hot ? .bold : .medium))
                    .foregroundStyle(Color.primary.opacity(active ? 0.95 : 0.3)))
                let size = resolved.measure(in: CGSize(width: 400, height: 40))
                let chip = CGRect(x: cx + 10, y: rect.midY - 10, width: size.width + 16, height: 20)
                let chipPath = Path(chip)
                context.fill(chipPath, with: .color(hot ? Color.white.opacity(0.18) : Color.black.opacity(0.35)))
                context.stroke(chipPath, with: .color(Color.primary.opacity(hot ? 0.8 : (active ? 0.45 : 0.15))), lineWidth: 1)
                if hot { context.stroke(Path(chip.offsetBy(dx: 3, dy: 3)), with: .color(Color.primary.opacity(0.3)), lineWidth: 1) }
                context.draw(resolved, at: CGPoint(x: chip.minX + 8, y: chip.midY), anchor: .leading)
            default:
                context.draw(Text(verbatim: name).font(WgInk.mono(.caption)).foregroundStyle(Color.primary.opacity(hot ? 0.95 : (active ? 0.55 : 0.2))),
                             at: CGPoint(x: cx + 8, y: rect.midY - 9), anchor: .leading)
            }
        }
    }

    // MARK: 悬停：节点优先，其次连线；高亮整条上下游路径

    private func updateFocus(at p: CGPoint) {
        let layout = anim.to
        if let box = layout.nodes.values.first(where: { $0.rect.insetBy(dx: -4, dy: -1).contains(p) }) {
            focus = trajectory(fromNode: box.node.key, layout: layout)
            tip = String(localized: "\(box.node.name)\n节点类型：\(PPSankeyModel.layerTitles[box.node.layer]) · 连接数：\(box.total)", bundle: .wgLocalized)
            return
        }
        if let ribbon = layout.ribbons.values.first(where: { ribbonPath($0, dx: 0).contains(p) }) {
            var set = trajectory(fromNode: ribbon.link.source, layout: layout, direction: -1)
            set.formUnion(trajectory(fromNode: ribbon.link.target, layout: layout, direction: 1))
            set.insert(ribbon.link.key)
            focus = set
            let s = layout.nodes[ribbon.link.source]?.node.name ?? ""
            let t = layout.nodes[ribbon.link.target]?.node.name ?? ""
            tip = String(localized: "\(s) → \(t)\n连接数：\(ribbon.link.count)", bundle: .wgLocalized)
            return
        }
        focus = nil
        tip = nil
    }

    /// direction: -1 上游、1 下游、0 双向。
    private func trajectory(fromNode key: String, layout: PPSankeyLayout, direction: Int = 0) -> Set<String> {
        var result: Set<String> = [key]
        let links = layout.ribbons.values.map(\.link)
        func walk(_ node: String, down: Bool) {
            for l in links where (down ? l.source : l.target) == node {
                let next = down ? l.target : l.source
                if result.insert(l.key).inserted { result.insert(next); walk(next, down: down) }
            }
        }
        if direction >= 0 { walk(key, down: true) }
        if direction <= 0 { walk(key, down: false) }
        return result
    }
}
