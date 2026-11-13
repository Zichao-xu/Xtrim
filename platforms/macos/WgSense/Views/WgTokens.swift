import AppKit
import Observation
import SwiftUI

// 设计档位：界面里的间距、字号、圆角只准从这里取值，不再写死数字。
//
//   数值存在同目录的 WgTokens.json（随 App 打包）。
//   Debug 版有「布局调节」面板（⌥⌘T）：拖滑块整页实时变化，「保存到工程」写回 WgTokens.json，
//   下次构建 / 发版即生效。scripts/check-tokens.py 拦截新写死的数字。

struct WgTokenSpec: Identifiable {
    let key: String
    let label: String
    let fallback: CGFloat
    let range: ClosedRange<CGFloat>
    var id: String { key }
}

enum WgTokenGroup: String, CaseIterable, Identifiable {
    case space, type, radius, layout
    var id: String { rawValue }
    var title: String {
        switch self {
        case .space: return String(localized: "间距", bundle: .wgLocalized)
        case .type: return String(localized: "字号", bundle: .wgLocalized)
        case .radius: return String(localized: "圆角", bundle: .wgLocalized)
        case .layout: return String(localized: "版面", bundle: .wgLocalized)
        }
    }
    var step: CGFloat { self == .space ? 4 : 1 }
    var specs: [WgTokenSpec] {
        switch self {
        case .space:
            // 8pt 网格：滑块按 4 吸附，且不能越过相邻档位。
            return [
                .init(key: "space.xs", label: "xs", fallback: 4, range: 0...8),
                .init(key: "space.s", label: "s", fallback: 8, range: 4...12),
                .init(key: "space.m", label: "m", fallback: 12, range: 8...16),
                .init(key: "space.l", label: "l", fallback: 16, range: 12...20),
                .init(key: "space.xl", label: "xl", fallback: 20, range: 16...24),
                .init(key: "space.xxl", label: "xxl", fallback: 24, range: 20...32),
                .init(key: "space.xxxl", label: "xxxl", fallback: 32, range: 24...48),
            ]
        case .type:
            // 13 / 15 / 17 = macOS 正文 / 标题 3 / 标题 2。
            return [
                .init(key: "type.micro", label: String(localized: "micro · 刻度", bundle: .wgLocalized), fallback: 9, range: 7...10),
                .init(key: "type.caption", label: String(localized: "caption · 注释", bundle: .wgLocalized), fallback: 10, range: 9...11),
                .init(key: "type.footnote", label: String(localized: "footnote · 次要", bundle: .wgLocalized), fallback: 11, range: 10...13),
                .init(key: "type.body", label: String(localized: "body · 正文", bundle: .wgLocalized), fallback: 13, range: 11...15),
                .init(key: "type.sub", label: String(localized: "sub · 小标题", bundle: .wgLocalized), fallback: 15, range: 13...17),
                .init(key: "type.title", label: String(localized: "title · 标题", bundle: .wgLocalized), fallback: 17, range: 15...22),
                .init(key: "type.large", label: String(localized: "large · 大字", bundle: .wgLocalized), fallback: 24, range: 18...30),
                .init(key: "type.readout", label: String(localized: "readout · 读数", bundle: .wgLocalized), fallback: 30, range: 24...40),
                .init(key: "type.display", label: String(localized: "display · 展示", bundle: .wgLocalized), fallback: 48, range: 32...64),
            ]
        case .radius:
            return [
                .init(key: "radius.s", label: String(localized: "s · 小件", bundle: .wgLocalized), fallback: 6, range: 0...8),
                .init(key: "radius.m", label: String(localized: "m · 卡片", bundle: .wgLocalized), fallback: 8, range: 6...16),
            ]
        case .layout:
            // 不归档的具体版面尺寸，每个滑块只管一处。
            return [
                .init(key: "layout.sidebarTop", label: String(localized: "侧栏顶部留白（让红绿灯）", bundle: .wgLocalized), fallback: 40, range: 0...80),
                .init(key: "layout.pageMaxWidth", label: String(localized: "页面最大宽度（拉满=贴边）", bundle: .wgLocalized), fallback: 820, range: 600...2400),
                .init(key: "layout.speedHudScale", label: String(localized: "测速仪表缩放上限（%）", bundle: .wgLocalized), fallback: 70, range: 40...120),
                .init(key: "layout.chartPlot", label: String(localized: "实时图表绘图区高度", bundle: .wgLocalized), fallback: 110, range: 80...220),
            ]
        }
    }
}

@Observable
final class WgTokens {
    static let shared = WgTokens()

    /// 当前生效的数值；界面读这里，调节面板写这里。
    private(set) var values: [String: CGFloat]
    /// 上次保存（或打包自带）的数值，用于「还原」和判断有无改动。
    private(set) var saved: [String: CGFloat]
    /// 参考线：给每处 wgPadding 画出内边距区域和档位标注（仅 Debug）。
    var guides = false

    private init() {
        var loaded: [String: CGFloat] = [:]
        if let url = Bundle.main.url(forResource: "WgTokens", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let raw = try? JSONDecoder().decode([String: Double].self, from: data) {
            loaded = raw.mapValues { CGFloat($0) }
        }
        values = loaded
        saved = loaded
        #if DEBUG
        guides = UserDefaults.standard.bool(forKey: "WgTuneGuides")
        // 脚本 / 自测入口：发分布式通知 com.wgsense.tune.set，userInfo {key, value} 等同拖滑块。
        DistributedNotificationCenter.default().addObserver(forName: .init("com.wgsense.tune.set"), object: nil, queue: .main) { note in
            guard let key = note.userInfo?["key"] as? String, let raw = note.userInfo?["value"] as? String,
                  let v = Double(raw) else { return }
            if key == "guides" { WgTokens.shared.guides = v != 0 } else { WgTokens.shared.set(key, CGFloat(v)) }
        }
        #endif
    }

    static let allSpecs = WgTokenGroup.allCases.flatMap(\.specs)

    subscript(_ key: String) -> CGFloat {
        if let v = values[key] { return v }
        return Self.allSpecs.first { $0.key == key }?.fallback ?? 0
    }

    /// 档位值只能落在相邻两档之间，保证 s < m < l… 的顺序永远不反。
    func set(_ key: String, _ value: CGFloat) {
        var v = value
        if let group = WgTokenGroup.allCases.first(where: { $0 != .layout && $0.specs.contains { $0.key == key } }),
           let i = group.specs.firstIndex(where: { $0.key == key }) {
            if i > 0 { v = max(v, self[group.specs[i - 1].key] + group.step) }
            if i < group.specs.count - 1 { v = min(v, self[group.specs[i + 1].key] - group.step) }
        }
        values[key] = v
    }

    var isDirty: Bool { Self.allSpecs.contains { self[$0.key] != (saved[$0.key] ?? $0.fallback) } }

    func revert() { values = saved }

    func resetToFallback() { values = Dictionary(uniqueKeysWithValues: Self.allSpecs.map { ($0.key, $0.fallback) }) }

    /// 给参考线用：数值 → 档位名（多个档位同值时取第一个）。
    func spaceTier(for value: CGFloat) -> (name: String, index: Int)? {
        let specs = WgTokenGroup.space.specs
        guard let i = specs.firstIndex(where: { self[$0.key] == value }) else { return nil }
        return (String(specs[i].key.dropFirst("space.".count)), i)
    }

    #if DEBUG
    /// 源码里的 WgTokens.json（Debug 构建知道自己的源码位置）。
    static let sourceFile = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("WgTokens.json")

    /// 写回工程里的 WgTokens.json，同时更新运行中 App 的 Resources 副本。
    @discardableResult
    func saveToProject() -> String? {
        let snapshot = Dictionary(uniqueKeysWithValues: Self.allSpecs.map { ($0.key, Double(self[$0.key])) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(snapshot)
            try data.write(to: Self.sourceFile, options: .atomic)
            if let bundled = Bundle.main.url(forResource: "WgTokens", withExtension: "json") {
                try? data.write(to: bundled, options: .atomic)
            }
            saved = snapshot.mapValues { CGFloat($0) }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
    #endif
}

// MARK: - 档位

enum WgSpace {
    static let zero: CGFloat = 0
    static var xs: CGFloat { WgTokens.shared["space.xs"] }
    static var s: CGFloat { WgTokens.shared["space.s"] }
    static var m: CGFloat { WgTokens.shared["space.m"] }
    static var l: CGFloat { WgTokens.shared["space.l"] }
    static var xl: CGFloat { WgTokens.shared["space.xl"] }
    static var xxl: CGFloat { WgTokens.shared["space.xxl"] }
    static var xxxl: CGFloat { WgTokens.shared["space.xxxl"] }
}

enum WgType {
    static var micro: CGFloat { WgTokens.shared["type.micro"] }
    static var caption: CGFloat { WgTokens.shared["type.caption"] }
    static var footnote: CGFloat { WgTokens.shared["type.footnote"] }
    static var body: CGFloat { WgTokens.shared["type.body"] }
    static var sub: CGFloat { WgTokens.shared["type.sub"] }
    static var title: CGFloat { WgTokens.shared["type.title"] }
    static var large: CGFloat { WgTokens.shared["type.large"] }
    static var readout: CGFloat { WgTokens.shared["type.readout"] }
    static var display: CGFloat { WgTokens.shared["type.display"] }
}

enum WgLayout {
    static var sidebarTop: CGFloat { WgTokens.shared["layout.sidebarTop"] }
    /// 测速仪表最多放大到设计尺寸的多少倍；再宽就横向展开，不再变大。
    static var speedHudScale: CGFloat { WgTokens.shared["layout.speedHudScale"] / 100 }
    /// 实时图表（面板 · 概览）绘图区高度：含底部时间尺，不含标题行。图表总高 = 标题行 + 它。
    static var chartPlot: CGFloat { WgTokens.shared["layout.chartPlot"] }
    /// 内容页最大宽度，超出部分居中留白；拉到上限即铺满窗口。
    static var pageMaxWidth: CGFloat {
        let v = WgTokens.shared["layout.pageMaxWidth"]
        return v >= 2400 ? .infinity : v
    }
}

/// 间距档位。`wgPadding` 只收这个类型，写数字编译不过。
enum WgGap: CaseIterable {
    case zero, xs, s, m, l, xl, xxl, xxxl
    var value: CGFloat {
        switch self {
        case .zero: return WgSpace.zero
        case .xs: return WgSpace.xs
        case .s: return WgSpace.s
        case .m: return WgSpace.m
        case .l: return WgSpace.l
        case .xl: return WgSpace.xl
        case .xxl: return WgSpace.xxl
        case .xxxl: return WgSpace.xxxl
        }
    }
}

/// 字号档位。`WgInk.mono` / `WgInk.figure` 只收这个类型，写数字编译不过。
enum WgTextSize: CaseIterable {
    case micro, caption, footnote, body, sub, title, large, readout, display
    /// 按比例推出来的字号（如读数的单位）落到最近的档位。
    static func nearest(_ size: CGFloat) -> WgTextSize {
        allCases.min { abs($0.value - size) < abs($1.value - size) } ?? .caption
    }
    var value: CGFloat {
        switch self {
        case .micro: return WgType.micro
        case .caption: return WgType.caption
        case .footnote: return WgType.footnote
        case .body: return WgType.body
        case .sub: return WgType.sub
        case .title: return WgType.title
        case .large: return WgType.large
        case .readout: return WgType.readout
        case .display: return WgType.display
        }
    }
}

enum WgRadius {
    static var s: CGFloat { WgTokens.shared["radius.s"] }
    static var m: CGFloat { WgTokens.shared["radius.m"] }
}

// MARK: - 带参考线的内边距

extension View {
    /// 等同 `.padding`，但只收档位；Debug 版打开参考线时会标出这块内边距属于哪一档。
    func wgPadding(_ gap: WgGap) -> some View { modifier(WgPaddingGuide(edges: .all, length: gap.value)) }
    func wgPadding(_ edges: Edge.Set = .all, _ gap: WgGap) -> some View {
        modifier(WgPaddingGuide(edges: edges, length: gap.value))
    }
}

extension View {
    /// 不属于间距档位的版面尺寸：对齐某一列、由别的尺寸推算、负值微调等。
    /// 只在它确实不是「间距」时用；每处都应该能说出它跟谁对齐。
    func wgInset(_ length: CGFloat) -> some View { padding(length) }
    func wgInset(_ edges: Edge.Set = .all, _ length: CGFloat) -> some View { padding(edges, length) }
}

struct WgPaddingGuide: ViewModifier {
    let edges: Edge.Set
    let length: CGFloat

    func body(content: Content) -> some View {
        #if DEBUG
        // 结构保持不变（只在闭包里开关），切换参考线不会重建视图、不丢滚动位置。
        let tokens = WgTokens.shared
        let on = tokens.guides && length > 0
        let tier = on ? tokens.spaceTier(for: length) : nil
        let color = tier.map { Self.palette[$0.index % Self.palette.count] } ?? .red
        content
            .overlay { if on { Rectangle().strokeBorder(color.opacity(0.7), style: StrokeStyle(lineWidth: 0.5, dash: [2, 2])) } }
            .padding(edges, length)
            .background { if on { color.opacity(0.14) } }
            .overlay(alignment: .topLeading) {
                if on {
                    Text(tier.map { "\($0.name) \(Int(length))" } ?? "✕ \(Int(length))")
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 2)
                        .background(color.opacity(0.85))
                        .allowsHitTesting(false)
                }
            }
        #else
        content.padding(edges, length)
        #endif
    }

    static let palette: [Color] = [.gray, .teal, .blue, .indigo, .purple, .pink, .orange, .red]
}
