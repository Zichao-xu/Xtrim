import AppKit
import Combine
import SwiftUI

/// Native scrolling keeps ordinary page hosts out of scroll-position layout updates.
struct WgScrollView: View {
    var content: AnyView
    @StateObject private var rail = WgScrollRailModel()
    var body: some View {
        WgNativeScrollView(content: content, rail: rail)
            .wgPublishesScrollRail(rail)
    }
}

struct WgNativeScrollView: NSViewRepresentable {
    @Environment(\.wgRegionColor) private var region
    var content: AnyView
    var rail: WgScrollRailModel
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.automaticallyAdjustsContentInsets = false
        let document = WgFlippedView()
        scroll.documentView = document
        let host = context.coordinator.controller
        host.view.translatesAutoresizingMaskIntoConstraints = true
        document.addSubview(host.view)
        context.coordinator.attach(scroll: scroll, document: document, rail: rail)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        context.coordinator.controller.rootView = AnyView(content.environment(\.wgRegionColor, region).fixedSize(horizontal: false, vertical: true)
            // 内容自身高度变化（异步数据到达、展开收起）时 preferredContentSize 的 KVO 并不可靠——
            // 实测概览页数据到达后内容 1091→1307 而通知从未触发，文档停在旧高度，顶部被居中裁掉。
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { _ in coordinator.contentHeightChanged() }
            .modifier(WgScrollHitGate()))
        context.coordinator.invalidate()
    }

    final class Coordinator: NSObject {
        let controller = NSHostingController(rootView: AnyView(EmptyView()))
        private weak var scroll: NSScrollView?
        private weak var document: NSView?
        private weak var rail: WgScrollRailModel?
        private var observers: [Any] = []
        private var pending = false
        private var layingOut = false
        private var dirty = true
        private var measuredWidth: CGFloat = -1
        private var railLink: Any?

        override init() {
            super.init()
            // Preserve intrinsic content changes (disclosures, async content), not just width changes.
            controller.sizingOptions = [.preferredContentSize]
            observers.append(controller.observe(\.preferredContentSize, options: [.old, .new]) { [weak self] _, change in
                guard let self, !self.layingOut else { return }
                if let old = change.oldValue, let new = change.newValue, abs(old.height - new.height) < 0.5 { return }
                self.dirty = true
                guard !self.pending else { return }
                self.pending = true
                DispatchQueue.main.async { [weak self] in
                    self?.pending = false
                    self?.relayout()
                }
            })
        }
        func attach(scroll: NSScrollView, document: NSView, rail: WgScrollRailModel) {
            self.scroll = scroll; self.document = document; self.rail = rail
            scroll.contentView.postsFrameChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in self?.relayout() })
            observers.append(contentsOf: MainActor.assumeIsolated { WgScrollActivity.track(scroll) })
            railLink = MainActor.assumeIsolated { rail.link(scroll) }
        }
        func invalidate() { dirty = true; relayout() }
        func contentHeightChanged() {
            dirty = true
            guard !pending else { return }
            pending = true
            DispatchQueue.main.async { [weak self] in
                self?.pending = false
                self?.relayout()
            }
        }
        func relayout() {
            guard !layingOut, let scroll, let document else { return }
            let width = scroll.contentView.bounds.width
            guard width > 1, dirty || measuredWidth != width else { return }
            layingOut = true
            defer { layingOut = false }
            dirty = false; measuredWidth = width
            let fitted = controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
            let size = CGSize(width: width, height: ceil(fitted.height))
            if document.frame.size != size { document.setFrameSize(size) }
            if controller.view.frame != document.bounds { controller.view.frame = document.bounds }
            let oldY = scroll.contentView.bounds.origin.y
            let maxY = max(0, size.height - scroll.contentView.bounds.height)
            scroll.contentView.setBoundsOrigin(CGPoint(x: 0, y: min(max(0, oldY), maxY)))
            scroll.reflectScrolledClipView(scroll.contentView)
            MainActor.assumeIsolated { rail?.refresh() }
        }
        deinit {
            for case let token as NSObjectProtocol in observers { NotificationCenter.default.removeObserver(token) }
            if let token = railLink { NotificationCenter.default.removeObserver(token) }
        }
    }
}
private final class WgFlippedView: NSView { override var isFlipped: Bool { true } }

/// 滚动期间“冻结”界面上的动态刷新：数据照常接收，但写入界面的动作先按 key 暂存（只留最新一次），
/// 滚动结束再一次性提交。滚动时 SwiftUI 不必重排整页，用户也察觉不到——停下的瞬间就是最新值。
@MainActor
enum WgScrollActivity {
    private(set) static var isScrolling = false
    private static var pending: [String: () -> Void] = [:]
    private static var active = 0

    static func begin() {
        active += 1
        isScrolling = true
        if !WgScrollState.shared.isScrolling { WgScrollState.shared.isScrolling = true }
    }

    static func end() {
        active = max(0, active - 1)
        guard active == 0 else { return }
        isScrolling = false
        WgScrollState.shared.isScrolling = false
        let work = pending
        pending.removeAll()
        work.values.forEach { $0() }
    }

    /// 不在滚动时立即执行；滚动中则暂存（同 key 只保留最新）。
    static func whenIdle(_ key: String, _ block: @escaping () -> Void) {
        if isScrolling { pending[key] = block } else { block() }
    }

    /// 把某个 NSScrollView 的实时滚动接入冻结机制。
    static func track(_ scroll: NSScrollView) -> [Any] {
        let center = NotificationCenter.default
        return [
            center.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: scroll, queue: .main) { _ in
                MainActor.assumeIsolated { begin() }
            },
            center.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: scroll, queue: .main) { _ in
                MainActor.assumeIsolated { end() }
            },
        ]
    }
}

/// 供 SwiftUI 订阅的滚动状态（只在滚动开始/结束时各变一次）。
@MainActor
final class WgScrollState: ObservableObject {
    static let shared = WgScrollState()
    @Published var isScrolling = false
}

/// 滚动期间关闭内容的点击/悬停判定：内容在静止的鼠标下移动，会被当成鼠标持续移动，
/// 每帧触发悬停更新（拓扑高亮重算、追踪区域重建）。停下后立即恢复。
struct WgScrollHitGate: ViewModifier {
    @ObservedObject private var state = WgScrollState.shared
    func body(content: Content) -> some View {
        content.allowsHitTesting(!state.isScrolling)
    }
}


// MARK: - 刻度条

/// 刻度条的数据：滚动位置（0–1）、视口占内容的比例、跳转回调。与某个 NSScrollView 绑定。
@MainActor
final class WgScrollRailModel: ObservableObject {
    @Published private(set) var fraction: CGFloat = 0
    @Published private(set) var scrollable = false
    private weak var scroll: NSScrollView?
    /// SwiftUI ScrollView 来源：没有 NSScrollView 可直接滚，跳转交给它的 ScrollPosition。
    private var seekHandler: ((CGFloat) -> Void)?
    private var swiftUIMaxY: CGFloat = 0

    /// SwiftUI ScrollView 上报滚动几何（见 wgTimelineScroller）。
    func update(offset: CGFloat, maxY: CGFloat, seek: @escaping (CGFloat) -> Void) {
        seekHandler = seek
        swiftUIMaxY = maxY
        let f = maxY > 0 ? min(1, max(0, offset / maxY)) : 0
        if abs(f - fraction) > 0.001 { fraction = f }
        let can = maxY > 4
        if can != scrollable { scrollable = can }
    }

    /// 绑定滚动框：监听剪裁区位置变化更新刻度；返回的观察者令牌需由调用方持有。
    func link(_ scroll: NSScrollView) -> Any {
        self.scroll = scroll
        scroll.contentView.postsBoundsChangedNotifications = true
        let token = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        DispatchQueue.main.async { [weak self] in self?.refresh() }
        return token
    }

    func refresh() {
        guard let scroll, let doc = scroll.documentView else { return }
        let maxY = max(0, doc.frame.height - scroll.contentView.bounds.height)
        let f = maxY > 0 ? min(1, max(0, scroll.contentView.bounds.origin.y / maxY)) : 0
        if abs(f - fraction) > 0.001 { fraction = f }
        let can = maxY > 4
        if can != scrollable { scrollable = can }
    }

    /// 拖动 / 点击：把 0–1 的位置直接映射成滚动位置。
    func seek(_ f: CGFloat) {
        guard let scroll, let doc = scroll.documentView else {
            seekHandler?(swiftUIMaxY * min(1, max(0, f)))
            return
        }
        let maxY = max(0, doc.frame.height - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: maxY * min(1, max(0, f))))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}

/// 左侧刻度条（ChatGPT 式）：一列细刻度，当前位置是加长的白色刻度；光标靠近时附近刻度按距离平滑拉长（吸附放大）；
/// 按住上下拖动实时滑动页面，单击跳到该处。整列画在一个画布里（避免非矩形区域的逐帧计算）。
struct WgScrollRail: View {
    /// nil = 当前页不滚动：照样画出刻度（每页同一位置都有），只是没有当前位置、不可拖。
    var model: WgScrollRailModel?

    static let spacing: CGFloat = 5
    /// 刻度条占据页面左侧页边距，与内容之间空一档 s。宽度跟着页边距档位走，不写死。
    static var width: CGFloat { max(4, WgTheme.pagePadding - WgSpace.s) }

    var body: some View {
        if let model { Live(model: model) } else { Ticks(fraction: nil, hoverY: nil) }
    }

    private struct Live: View {
        @ObservedObject var model: WgScrollRailModel
        @State private var hoverY: CGFloat?

        var body: some View {
            GeometryReader { geo in
                Ticks(fraction: model.scrollable ? model.fraction : nil, hoverY: model.scrollable ? hoverY : nil)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p): hoverY = p.y
                        case .ended: hoverY = nil
                        }
                    }
                    .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                        hoverY = v.location.y
                        model.seek(v.location.y / max(1, geo.size.height))
                    })
            }
            .frame(width: WgScrollRail.width)
            .allowsHitTesting(model.scrollable)
        }
    }

    /// 刻度长度按刻度条宽度比例：普通 ½、每十格 ¾、当前位置与吸附放大到满宽。
    private struct Ticks: View {
        var fraction: CGFloat?
        var hoverY: CGFloat?

        var body: some View {
            Canvas { ctx, size in
                let full = size.width
                let count = max(2, Int(size.height / WgScrollRail.spacing))
                let step = size.height / CGFloat(count - 1)
                let active = fraction.map { Int(($0 * CGFloat(count - 1)).rounded()) }
                for i in 0..<count {
                    let y = CGFloat(i) * step
                    var w = full * (i % 10 == 0 ? 0.75 : 0.5)
                    if let hy = hoverY {
                        let d = abs(y - hy)
                        w += full * exp(-(d * d) / (2 * 20 * 20))
                    }
                    let isActive = i == active
                    if isActive { w = full }
                    w = min(full, w)
                    var p = Path()
                    p.move(to: CGPoint(x: 0, y: y))
                    p.addLine(to: CGPoint(x: w, y: y))
                    ctx.stroke(p, with: .color(Color.primary.opacity(isActive ? 1 : (i % 10 == 0 ? 0.42 : 0.24))),
                               lineWidth: isActive ? 2 : 1)
                }
            }
            .frame(width: WgScrollRail.width)
        }
    }
}

// MARK: - 刻度条挂载：滚动来源上报，页面区统一画

/// 当前页的滚动来源。页面里任何滚动容器（原生 WgScrollView、SwiftUI ScrollView、AppKit 表格）都只上报，
/// 由页面区（MainPageArea）在左侧页边距的同一位置画一条——不再各页自己摆、各自写偏移。
struct WgScrollRailKey: PreferenceKey {
    static let defaultValue: WgScrollRailRef? = nil
    static func reduce(value: inout WgScrollRailRef?, nextValue: () -> WgScrollRailRef?) {
        if let next = nextValue() { value = next }
    }
}

struct WgScrollRailRef: Equatable {
    let model: WgScrollRailModel
    static func == (a: Self, b: Self) -> Bool { a.model === b.model }
}

extension View {
    /// 把这个滚动来源登记为当前页的刻度条数据。
    func wgPublishesScrollRail(_ model: WgScrollRailModel) -> some View {
        preference(key: WgScrollRailKey.self, value: WgScrollRailRef(model: model))
    }

    /// 页面区：左侧页边距里画刻度条，每个页面都有、位置一致。
    func wgPageScrollRail() -> some View {
        overlayPreferenceValue(WgScrollRailKey.self, alignment: .leading) { ref in
            WgScrollRail(model: ref?.model).wgPadding(.vertical, .m)
        }
    }
}

/// SwiftUI ScrollView 接入刻度条：隐藏系统滚动条，上报滚动位置，接收跳转。
struct WgTimelineScrollerModifier: ViewModifier {
    @StateObject private var rail = WgScrollRailModel()
    @State private var position = ScrollPosition(edge: .top)

    func body(content: Content) -> some View {
        let binding = $position
        content
            .scrollIndicators(.hidden)
            .scrollPosition(binding)
            .onScrollGeometryChange(for: CGPoint.self) { g in
                CGPoint(x: g.contentOffset.y + g.contentInsets.top,
                        y: max(0, g.contentSize.height + g.contentInsets.top + g.contentInsets.bottom - g.containerSize.height))
            } action: { _, v in
                rail.update(offset: v.x, maxY: v.y) { y in binding.wrappedValue.scrollTo(y: y) }
            }
            .wgPublishesScrollRail(rail)
    }
}
