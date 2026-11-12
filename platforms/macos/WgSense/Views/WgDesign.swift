import SwiftUI

// 设计基元：控制中心 + 系统设置的视觉语言。
//
//   圆形徽章    —— 侧栏模块（控制中心）。状态靠徽章上色，磁贴本体保持中性。
//   圆角方徽章  —— 概览里的分组列表（系统设置）。
//
// 颜色只表达状态：开启才上色，关闭一律回到中性灰，不给“未运行”的东西配彩色。

enum WgDesign {
    static var tileRadius: CGFloat { WgRadius.m }
    static var cardRadius: CGFloat { WgRadius.m }
    static var heroRadius: CGFloat { WgRadius.m }

    static let spring = Animation.spring(response: 0.32, dampingFraction: 0.82)
}

// MARK: - 徽章

/// 控制中心式圆形徽章：开启时实色渐变 + 白色图标，关闭时中性灰底。
struct WgCircleBadge: View {
    var symbol: String
    var tint: Color
    var isOn: Bool
    var size: CGFloat = 30
    var isBusy: Bool = false
    /// 设了就画出口标识（龙 / 猫 / 九点格）代替 SF 图标。
    var logo: WgExit? = nil

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.wgOnAccent) private var onAccent

    var body: some View {
        // 仪表语言：方块而非圆片。开启 = 实色块 + 反白图标；关闭 = 发丝框。
        // 开启 = 实墨块（颜色只留给警示/告警与“当前选中”，否则满屏蓝块就不再有焦点）。
        let normalized = WgInk.normalize(tint)
        let color: Color = (normalized == WgInk.warn || normalized == WgInk.alert) ? normalized : WgInk.ink
        let shape = RoundedRectangle(cornerRadius: WgRadius.s, style: .continuous)
        ZStack {
            if isOn {
                if color == WgInk.warn || color == WgInk.alert {
                    shape.fill(color)
                } else {
                    Color.clear.wgGlassAccent(shape)
                }
            } else {
                shape.fill(offFill)
                shape.strokeBorder(Color.primary.opacity(0.28), lineWidth: 1)
            }
            Group {
                if let logo {
                    WgExitLogo(exit: logo, size: size * 0.56)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: size * 0.46, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .foregroundStyle(isOn ? WgInk.ink : Color.primary.opacity(0.8))
            if isBusy {
                WgPerimeterRunner(shape: RoundedRectangle(cornerRadius: WgRadius.s + 3, style: .continuous),
                                  color: onAccent ? Color.white : color, lineWidth: 1.5, period: 1.2)
                    .wgInset(-3)
            }
        }
        .frame(width: size, height: size)
        .animation(WgDesign.spring, value: isOn)
    }

    private var offFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.05)
    }
}

// MARK: - 忙碌指示

/// 忙碌指示：一段亮线沿外框匀速绕行，始终贴在框上。
/// 不用「描边一段再整体旋转」：方框旋转时线段会甩出框外。
struct WgPerimeterRunner<S: Shape>: View {
    var shape: S
    var color: Color
    var lineWidth: CGFloat = 1.5
    /// 绕一圈的秒数。
    var period: Double = 1.2
    /// 亮线占周长的比例。
    var length: CGFloat = 0.22

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let phase = CGFloat(t.truncatingRemainder(dividingBy: period) / period)
            WgPerimeterSegment(shape: shape, phase: phase, length: length)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 外框上从 phase 起、长 length 的一段（越过终点时接回起点）。
struct WgPerimeterSegment<S: Shape>: Shape {
    var shape: S
    var phase: CGFloat
    var length: CGFloat

    func path(in rect: CGRect) -> Path {
        let full = shape.path(in: rect)
        let end = phase + length
        var p = full.trimmedPath(from: phase, to: min(end, 1))
        if end > 1 { p.addPath(full.trimmedPath(from: 0, to: end - 1)) }
        return p
    }
}

/// 行首方徽章：仪表语言下不再上彩色——中性底板 + 发丝描边 + 墨色图标。
/// `tint` 保留参数兼容，只在归一后属于警示/告警时才着色图标。
struct WgSquareBadge: View {
    var symbol: String
    var tint: Color
    var size: CGFloat = 24
    var dimmed: Bool = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
        // 行首图标纯装饰：一律墨色，彩色 tint 不再上色（否则会被读成“警示”）。
        let glyph: Color = dimmed ? WgInk.ink3 : WgInk.ink2
        shape
            .fill(WgInk.field)
            .overlay(shape.strokeBorder(WgInk.rule))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.46, weight: .medium))
                    .foregroundStyle(glyph)
            }
    }
}

// MARK: - 状态点

struct WgStatusDot: View {
    var color: Color
    var isOn: Bool
    var body: some View {
        Rectangle()
            .fill(isOn ? (color == .green ? WgInk.signal : WgInk.normalize(color)) : Color.secondary.opacity(0.35))
            .frame(width: 6, height: 6)
    }
}

// MARK: - 可点击表面（磁贴 / 卡片）

/// 统一的可点击表面：中性实体底、悬停抬高、选中描边。
///
/// 本体不是 Button，而是 onTapGesture —— 这样内部的 Button 能正常接收点击。
/// 嵌套 Button 时外层会吃掉内层点击，这是之前磁贴里按钮点不动的根因。
struct WgInteractiveSurface: ViewModifier {
    var cornerRadius: CGFloat = WgDesign.tileRadius
    var isSelected: Bool = false
    var isEnabled: Bool = true
    var action: (() -> Void)?

    @State private var hovering = false
    @Environment(\.colorScheme) private var colorScheme
    func body(content: Content) -> some View {
        // 磁贴 / 卡片：斜切（右上 + 左下）黑色弱玻璃；选中 = 白色弱玻璃；悬停抬亮一档。
        let shape = ChamferShape(cornerRadius >= 10 ? WgInk.cutPanel : WgInk.cutTile)
        let hot = hovering && action != nil && isEnabled
        return content
            .environment(\.wgOnAccent, isSelected)
            .modifier(SurfaceFill(shape: shape, selected: isSelected, raised: hot))
            // 斜切只画在背景（填充 + 描边）上，不用作遮罩/裁剪/点击区域：非矩形的裁剪与点击区域
            // 会让窗口在滚动的每一帧重新计算区域，实测是滚动掉帧 5% → 55% 的来源。溢出内容用矩形裁剪。
            .clipped()
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .modifier(SurfaceAction(action: isEnabled ? action : nil))
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.easeOut(duration: 0.18), value: isSelected)
    }

    // Passive panels must not install a competing gesture over native controls (e.g. color wells).
    private struct SurfaceAction: ViewModifier {
        var action: (() -> Void)?
        func body(content: Content) -> some View {
            if let action { content.onTapGesture(perform: action) } else { content }
        }
    }

    private struct SurfaceFill: ViewModifier {
        var shape: ChamferShape
        var selected: Bool
        var raised: Bool
        @Environment(\.wgRegionColor) private var region
        func body(content: Content) -> some View {
            if selected && region.color == nil {
                content.wgGlassAccent(shape)
            } else {
                content.wgGlassPanel(shape, raised: raised || selected)
                    .overlay { if selected { shape.strokeBorder(Color.primary.opacity(0.35), lineWidth: 1).allowsHitTesting(false) } }
            }
        }
    }
}

extension View {
    func wgInteractiveSurface(
        cornerRadius: CGFloat = WgDesign.tileRadius,
        isSelected: Bool = false,
        isEnabled: Bool = true,
        action: (() -> Void)? = nil
    ) -> some View {
        modifier(WgInteractiveSurface(cornerRadius: cornerRadius, isSelected: isSelected, isEnabled: isEnabled, action: action))
    }
}

// MARK: - 按钮样式

/// 模块里的次级操作：中性底，按下略缩；只有“激活”时图标上色。
struct WgActionButtonStyle: ButtonStyle {
    var isActive: Bool = false
    var tint: Color = WgInk.signal

    func makeBody(configuration: Configuration) -> some View {
        ActionBody(configuration: configuration, isActive: isActive, tint: tint)
    }

    private struct ActionBody: View {
        let configuration: Configuration
        let isActive: Bool
        let tint: Color
        @State private var hovering = false
        @Environment(\.colorScheme) private var colorScheme
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.wgOnAccent) private var onAccent

        var body: some View {
            // 斜切按钮：未激活 = 淡玻璃；激活 = 白色弱玻璃。异常（暂停 / 停止）只给图标着色。
            let shape = ChamferShape(WgInk.cutControl)
            let normalized = WgInk.normalize(tint)
            let semantic = normalized == WgInk.warn || normalized == WgInk.alert
            return configuration.label
                .foregroundStyle(isActive ? (semantic ? normalized : WgInk.ink) : Color.primary.opacity(0.78))
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .modifier(ButtonFill(shape: shape, active: isActive, hovering: hovering))
                .opacity(isEnabled ? 1 : 0.4)
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }

    private struct ButtonFill: ViewModifier {
        var shape: ChamferShape
        var active: Bool
        var hovering: Bool
        func body(content: Content) -> some View {
            if active {
                content.wgGlassAccent(shape)
            } else {
                content.background(WgShapePlate(shape: shape, fill: Color.primary.opacity(hovering ? 0.11 : 0.065), border: .clear, highlight: .clear))
            }
        }
    }
}

/// 主操作胶囊（连接 / 断开）。
struct WgCapsuleButtonStyle: ButtonStyle {
    var tint: Color
    var prominent: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        CapsuleBody(configuration: configuration, tint: tint, prominent: prominent)
    }

    private struct CapsuleBody: View {
        let configuration: Configuration
        let tint: Color
        let prominent: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.colorScheme) private var colorScheme

        var body: some View {
            // 主操作：斜切白色弱玻璃（prominent）或淡玻璃；异常色（红/琥珀）只给文字。
            let shape = ChamferShape(WgInk.cutControl)
            let normalized = WgInk.normalize(tint)
            let semantic = normalized == WgInk.warn || normalized == WgInk.alert
            return configuration.label
                .font(.system(size: WgType.body, weight: .semibold))
                .foregroundStyle(semantic ? normalized : WgInk.ink)
                .wgPadding(.horizontal, .m)
                .frame(height: 32)
                .modifier(CapsuleFill(shape: shape, prominent: prominent, hovering: hovering))
                .opacity(isEnabled ? 1 : 0.45)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }

    private struct CapsuleFill: ViewModifier {
        var shape: ChamferShape
        var prominent: Bool
        var hovering: Bool
        func body(content: Content) -> some View {
            if prominent { content.wgGlassAccent(shape) } else { content.background(WgShapePlate(shape: shape, fill: Color.primary.opacity(hovering ? 0.11 : 0.065), border: .clear, highlight: .clear)) }
        }
    }
}

/// 头部的无边框图标按钮：平时透明，悬停出现圆形底。
struct WgToolbarIconButtonStyle: ButtonStyle {
    var isActive: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        IconBody(configuration: configuration, isActive: isActive)
    }

    private struct IconBody: View {
        let configuration: Configuration
        let isActive: Bool
        @State private var hovering = false
        @Environment(\.colorScheme) private var colorScheme

        var body: some View {
            configuration.label
                .font(.system(size: WgType.title, weight: .medium))
                .foregroundStyle(isActive ? WgInk.signal : Color.secondary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: WgRadius.s, style: .continuous)
                        .strokeBorder(Color.primary.opacity(hovering || isActive ? 0.25 : 0), lineWidth: 1)
                )
                .scaleEffect(configuration.isPressed ? 0.92 : 1)
                .contentShape(Rectangle())
                .focusEffectDisabled()
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

// MARK: - 文本格式

enum WgFormat {
    static func speed(_ bytesPerSec: Double) -> String {
        let bps = max(0, bytesPerSec)
        if bps < 1024 { return String(format: "%.0f B/s", bps) }
        if bps < 1024 * 1024 { return String(format: "%.1f KB/s", bps / 1024) }
        if bps < 1024 * 1024 * 1024 { return String(format: "%.1f MB/s", bps / (1024 * 1024)) }
        return String(format: "%.1f GB/s", bps / (1024 * 1024 * 1024))
    }

    static func size(_ bytes: UInt64) -> String {
        let b = Double(bytes)
        if b < 1024 { return String(format: "%.0f B", b) }
        if b < 1024 * 1024 { return String(format: "%.1f KB", b / 1024) }
        if b < 1024 * 1024 * 1024 { return String(format: "%.1f MB", b / (1024 * 1024)) }
        return String(format: "%.2f GB", b / (1024 * 1024 * 1024))
    }

    static func age(_ seconds: Int) -> String {
        if seconds < 5 { return "刚刚" }
        if seconds < 60 { return "\(seconds) 秒前" }
        if seconds < 3600 { return "\(seconds / 60) 分钟前" }
        return "\(seconds / 3600) 小时前"
    }
}

// MARK: - 页面框架

/// 所有页面共用：同一种标题排版、同一内容宽度、同一纵向节奏。
struct WgPage<Accessory: View, Content: View>: View {
    var title: LocalizedStringKey
    var subtitle: LocalizedStringKey? = nil
    var word: String? = nil
    var maxWidth: CGFloat = WgLayout.pageMaxWidth
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: WgSpace.m) {
            WgPageHeader(title: title, subtitle: subtitle, word: word, accessory: accessory)
            content()
        }
        .frame(maxWidth: maxWidth, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

extension WgPage where Accessory == EmptyView {
    init(title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil, word: String? = nil, maxWidth: CGFloat = WgLayout.pageMaxWidth,
         @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, subtitle: subtitle, word: word, maxWidth: maxWidth, accessory: { EmptyView() }, content: content)
    }
}

/// 页面标题：签名方块 + 大标题 + 副标题，下方刻度尺线。所有页面（含代理页）共用。
struct WgPageHeader<Accessory: View>: View {
    var title: LocalizedStringKey
    var subtitle: LocalizedStringKey? = nil
    var subtitleText: String? = nil
    /// 标题背后放大淡出的英文词（如 PROXY / SETTINGS）：只做辨识度。
    var word: String? = nil
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: WgSpace.l) {
            Text(title)
                .font(.system(size: WgInk.sizePage, weight: .heavy))
                .tracking(1)
            Group {
                if let subtitle { Text(subtitle) } else if let subtitleText { Text(verbatim: subtitleText) }
            }
            .font(WgInk.mono(.footnote))
            .tracking(1.2)
            .foregroundStyle(WgInk.ink3)
            .lineLimit(1)
            Spacer(minLength: 12)
            accessory()
        }
        .background(alignment: .topLeading) {
            if let word {
                Text(verbatim: word)
                    .font(.system(size: 118, weight: .black))
                    .tracking(-1)
                    .foregroundStyle(Color.primary.opacity(0.055))
                    .fixedSize()
                    .offset(x: -6, y: -44)
                    .mask(LinearGradient(colors: [.black, .black, .clear], startPoint: .leading, endPoint: .trailing))
                    .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - 分组

/// 系统设置式分组：小标题 + 一块圆角实体 + 可选脚注。
struct WgSection<Content: View>: View {
    var title: LocalizedStringKey?
    var footer: LocalizedStringKey? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: WgSpace.s) {
            if let title {
                WgSectionMark(title: title).wgPadding(.top, .m).wgPadding(.bottom, .xs)
            }
            VStack(spacing: 0) {
                content()
            }
            .wgInteractiveSurface(cornerRadius: WgDesign.cardRadius)
            if let footer {
                Text(footer)
                    .font(.system(size: WgType.body))
                    .foregroundStyle(.secondary)
                    .wgPadding(.horizontal, .xs)
            }
        }
    }
}

/// 分组内的一行：方形徽章 + 标题/副标题 + 右侧控件。
struct WgRow<Accessory: View>: View {
    var symbol: String?
    var tint: Color = .gray
    var title: LocalizedStringKey
    var subtitle: Text? = nil
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: WgSpace.m) {
            if let symbol {
                WgSquareBadge(symbol: symbol, tint: tint, size: 24)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: WgType.body))
                if let subtitle {
                    subtitle
                        .font(.system(size: WgType.body))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            accessory()
        }
        .wgPadding(.horizontal, .l)
        .wgPadding(.vertical, .s)
        .frame(minHeight: 46)
    }
}

extension WgRow where Accessory == EmptyView {
    init(symbol: String?, tint: Color = .gray, title: LocalizedStringKey, subtitle: Text? = nil) {
        self.init(symbol: symbol, tint: tint, title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// 行内右侧的只读值。
struct WgValue: View {
    var text: String
    var monospaced = false
    init(_ text: String, monospaced: Bool = false) {
        self.text = text
        self.monospaced = monospaced
    }
    var body: some View {
        Text(verbatim: text)
            .font(monospaced ? .system(size: WgType.sub, design: .monospaced) : .system(size: WgType.body))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
    }
}

/// 行间分隔：从徽章之后开始，与系统设置一致。
struct WgRowDivider: View {
    var inset: CGFloat = 50
    var body: some View {
        Divider().opacity(0.5).wgInset(.leading, inset)
    }
}

/// 小号次级按钮：中性底胶囊，文字可带语义色（红=卸载，橙=清理）。
struct WgPillButtonStyle: ButtonStyle {
    var tint: Color = .primary

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, tint: tint)
    }

    private struct PillBody: View {
        let configuration: Configuration
        let tint: Color
        @State private var hovering = false
        @Environment(\.colorScheme) private var colorScheme
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .foregroundStyle(tint == .primary ? AnyShapeStyle(Color.primary.opacity(0.85)) : AnyShapeStyle(tint))
                .wgPadding(.horizontal, .m)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: WgRadius.s, style: .continuous).fill((colorScheme == .dark ? Color.white : Color.black).opacity(hovering ? 0.11 : 0.065))
                )
                .opacity(isEnabled ? 1 : 0.45)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .contentShape(RoundedRectangle(cornerRadius: WgRadius.s, style: .continuous))
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

// MARK: - 语言

/// 仅在确有必要时注入 locale（见 WgAppLanguage.needsLocaleOverride）。
struct WgLocaleOverride: ViewModifier {
    var language: WgAppLanguage
    func body(content: Content) -> some View {
        if language.needsLocaleOverride {
            content.environment(\.locale, language.locale)
        } else {
            content
        }
    }
}
