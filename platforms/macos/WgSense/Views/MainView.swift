import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

// MARK: - 主题色（经典界面）

enum WgTheme {
    static let bg = adaptive(
        light: NSColor(calibratedRed: 0.94, green: 0.95, blue: 0.96, alpha: 1),
        dark: NSColor(calibratedRed: 0.08, green: 0.08, blue: 0.09, alpha: 1)
    )
    static let sidebarBg = adaptive(
        light: NSColor(calibratedRed: 0.88, green: 0.89, blue: 0.91, alpha: 1),
        dark: NSColor(calibratedRed: 0.06, green: 0.06, blue: 0.07, alpha: 1)
    )
    static let cardBg = adaptive(
        light: NSColor(calibratedWhite: 1, alpha: 0.72),
        dark: NSColor(calibratedWhite: 1, alpha: 0.05)
    )
    static let cardBorder = adaptive(
        light: NSColor(calibratedWhite: 0, alpha: 0.10),
        dark: NSColor(calibratedWhite: 1, alpha: 0.06)
    )
    static let tileBg = adaptive(
        light: NSColor(calibratedWhite: 1, alpha: 0.78),
        dark: NSColor(calibratedWhite: 0, alpha: 0.16)
    )
    static let tileNeutralTint = adaptive(
        light: NSColor(calibratedWhite: 0, alpha: 0.025),
        dark: NSColor(calibratedWhite: 1, alpha: 0.025)
    )
    static let tileBorder = adaptive(
        light: NSColor(calibratedWhite: 0, alpha: 0.12),
        dark: NSColor(calibratedWhite: 1, alpha: 0.09)
    )
    static let accent = Color(red: 0.2, green: 0.5, blue: 0.95)
    static var cardRadius: CGFloat { WgRadius.m }
    static var controlRadius: CGFloat { WgRadius.m }
    static var floatingRadius: CGFloat { WgRadius.m }
    static var spacing: CGFloat { WgSpace.m }
    static let pageGap: WgGap = .xl
    static var pagePadding: CGFloat { pageGap.value }
    /// 磁贴尺寸基准：小磁贴高=y, 宽=x; 中=高y宽2x; 大=2y×2x; 间距=y/10
    /// 设 y=80 → small: 80×(80/0.618)≈80×129, medium: 80×259, large: 160×259
    static let tileY: CGFloat = 80
    static let tileX: CGFloat = tileY / 0.618
    static let tileGap: CGFloat = tileY / 10

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}




extension View {
    func wgTileSurface(
        tint: Color? = nil,
        isSelected: Bool = false
    ) -> some View {
        modifier(WgTileSurfaceModifier(tint: tint, isSelected: isSelected))
    }

    func wgGlassSurface(
        cornerRadius: CGFloat = WgTheme.cardRadius,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        modifier(WgGlassSurfaceModifier(cornerRadius: cornerRadius, tint: tint, interactive: interactive))
    }

    func wgFloatingControlSurface(
        tint: Color? = nil,
        cornerRadius: CGFloat = WgTheme.controlRadius
    ) -> some View {
        modifier(WgFloatingControlSurfaceModifier(tint: tint, cornerRadius: cornerRadius))
    }

    func wgPageSurface() -> some View {
        modifier(WgPageSurfaceModifier())
    }

    func wgSidebarSurface() -> some View {
        modifier(WgSidebarSurfaceModifier())
    }

    func wgSettingsPanelSurface() -> some View {
        modifier(WgSettingsPanelSurfaceModifier())
    }

    func wgTimelineScroller() -> some View {
        self
    }
}

private struct WgTileSurfaceModifier: ViewModifier {
    let tint: Color?
    let isSelected: Bool
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("surfaceFill") private var surfaceFill = WgSurfaceTuning.standard.fill
    @AppStorage("surfaceBorder") private var surfaceBorder = WgSurfaceTuning.standard.border
    @AppStorage("surfaceTint") private var surfaceTint = WgSurfaceTuning.standard.tint

    private var tuning: WgSurfaceTuning {
        WgSurfaceTuning(fill: surfaceFill, border: surfaceBorder, tint: surfaceTint)
    }

    // 磁贴是浮在玻璃上的实体，不再叠材质。之前四层（底色 + ultraThinMaterial +
    // 深度 + 色调）互相抵消，调哪一层都会把另一层顶回去。
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: WgTheme.cardRadius, style: .continuous)
        content
            .background {
                shape
                    .fill(isSelected ? WgSurface.raised(colorScheme, tuning) : WgSurface.solid(colorScheme, tuning))
                    .overlay(shape.fill(tint?.opacity(WgSurface.tint(tuning, selected: isSelected)) ?? Color.clear))
                    .overlay(shape.strokeBorder(WgSurface.border(colorScheme, tuning), lineWidth: 1))
                    .allowsHitTesting(false)
            }
            .clipShape(shape)
            .contentShape(shape)
    }
}

private struct WgGlassSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color?
    let interactive: Bool

    // 旧卡片入口统一走新实体表面：中性底 + 顶缘高光 + 描边。状态色不再铺满整张卡，
    // 与控制中心/系统设置一致——颜色只留给徽章和状态点。
    func body(content: Content) -> some View {
        content.wgInteractiveSurface(cornerRadius: max(cornerRadius, WgDesign.cardRadius))
    }
}

private struct WgFloatingControlSurfaceModifier: ViewModifier {
    let tint: Color?
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("backdropMode") private var backdropModeRaw = WgBackdropMode.liquidRegular.rawValue
    @AppStorage("surfaceFill") private var surfaceFill = WgSurfaceTuning.standard.fill
    @AppStorage("surfaceBorder") private var surfaceBorder = WgSurfaceTuning.standard.border
    @AppStorage("surfaceTint") private var surfaceTint = WgSurfaceTuning.standard.tint

    private var tuning: WgSurfaceTuning {
        WgSurfaceTuning(fill: surfaceFill, border: surfaceBorder, tint: surfaceTint)
    }

    private var mode: WgBackdropMode {
        WgBackdropMode(rawValue: backdropModeRaw) ?? .liquidRegular
    }

    // 浮动小控件（菜单栏、侧栏顶部的圆形按钮）是 Liquid Glass 真正该去的地方：
    // 尺寸小、浮在内容之上，折射与镜面边缘都成立。毛玻璃档位下退回实色，
    // 以免出现背景是 vibrancy、控件却是 Liquid Glass 的混搭。
    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if mode == .vibrancy {
            content
                .background {
                    shape
                        .fill(WgSurface.raised(colorScheme, tuning))
                        .overlay(shape.fill(tint?.opacity(WgSurface.tint(tuning, selected: true)) ?? Color.clear))
                        .overlay(shape.strokeBorder(WgSurface.border(colorScheme, tuning), lineWidth: 1))
                        .allowsHitTesting(false)
                }
                .clipShape(shape)
                .contentShape(shape)
        } else {
            content
                .glassEffect(
                    .regular.tint(tint?.opacity(WgSurface.tint(tuning, selected: true))),
                    in: shape
                )
                .contentShape(shape)
        }
    }
}

private struct WgPageSurfaceModifier: ViewModifier {
    // 内容区不再自带底色。整窗一块玻璃铺在 MainView 的根视图上，这里保持透明，
    // 相邻两块背景板因此不可能对不齐。
    func body(content: Content) -> some View {
        content
    }
}

private struct WgSidebarSurfaceModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("surfaceFill") private var surfaceFill = WgSurfaceTuning.standard.fill
    @AppStorage("surfaceBorder") private var surfaceBorder = WgSurfaceTuning.standard.border
    @AppStorage("surfaceTint") private var surfaceTint = WgSurfaceTuning.standard.tint

    private var tuning: WgSurfaceTuning {
        WgSurfaceTuning(fill: surfaceFill, border: surfaceBorder, tint: surfaceTint)
    }

    // 侧栏与内容区共用同一块玻璃，只用右缘一条 hairline 分隔，不再靠明度差。
    func body(content: Content) -> some View {
        content
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(WgSurface.hairline(colorScheme, tuning))
                    .frame(width: 1)
            }
    }
}

private struct WgSettingsPanelSurfaceModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.wgInteractiveSurface(cornerRadius: WgDesign.cardRadius)
    }
}


struct MainView: View {
    @AppStorage("backdropMode") private var backdropModeRaw = WgBackdropMode.liquidRegular.rawValue
    @AppStorage("glassTintStrength") private var glassTintStrength = 0.55
    @EnvironmentObject var client: DaemonClient
    @AppStorage("appLanguage") private var appLanguageRaw = WgAppLanguage.system.rawValue
    @AppStorage("appAppearance") private var appAppearanceRaw = WgAppAppearance.system.rawValue
    /// 调试用：`open WgSense.app --args -WgSenseInitialTab settings` 直接停在指定页面（仅命令行参数域，不落盘）。
    @State private var selection: SidebarTab = SidebarTab(
        rawValue: UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["WgSenseInitialTab"] as? String ?? ""
    ) ?? .dashboard
    /// 侧栏宽度：一路拖到最窄（64）就是只剩图标的收起形态，中间无极过渡（见 SidebarView.compactness）。
    /// 调试用：`--args -WgSenseSidebarWidth 120` 指定启动宽度（看中间形态，仅命令行参数域）。
    @State private var sidebarWidth: CGFloat = (UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["WgSenseSidebarWidth"] as? String)
        .flatMap { Double($0) }.map { CGFloat($0) }
        ?? (UserDefaults.standard.bool(forKey: "sidebar.collapsed")
            ? SidebarView.railWidth : max(SidebarView.fullWidth, UserDefaults.standard.double(forKey: "sidebar.expandedWidth").nonZero ?? 300))
    /// 收起与否只用来记住状态、决定按钮箭头；收起 = 宽度在最窄处。
    @AppStorage("sidebar.collapsed") private var sidebarCollapsed = false
    /// 收起前的宽度：展开时回到这里。
    @AppStorage("sidebar.expandedWidth") private var expandedWidth = 300.0

    private let sidebarMaxWidth: CGFloat = 620

    /// 收起 / 展开：把宽度一帧帧推到最窄或拉回原宽，等于替你把分隔线拖过去——每一帧都按当时的宽度真实排版，
    /// 磁贴怎么变全交给宽窄逻辑。不用 withAnimation：那只在两端各排一次版、中间硬插值，磁贴会按终点宽度先跳过去（跳屏）。
    private func toggleSidebar() {
        if sidebarWidth > SidebarView.railWidth + 0.5 {
            expandedWidth = max(SidebarView.fullWidth, sidebarWidth)
            slideSidebar(to: SidebarView.railWidth)
        } else {
            slideSidebar(to: max(SidebarView.fullWidth, expandedWidth))
        }
    }

    /// 松手吸附：拖动时无极，松手滑到最近的「整列」宽度（或收起），磁贴不停在半截形态、网格右边不留零头。
    /// 带着松手的手速当初速度，用阻尼弹簧一帧帧收到吸附点：先顺着惯性走，再减速落位，不是从静止重新起步。
    private func snapSidebar(velocity: CGFloat) {
        // 按惯性预判落点再挑最近的吸附点：轻甩一下能跳到下一档
        let projected = sidebarWidth + velocity * 0.12
        let targets = SidebarView.snapWidths(upTo: sidebarMaxWidth)
        guard let target = targets.min(by: { abs($0 - projected) < abs($1 - projected) }) else { return }
        if target > SidebarView.railWidth { expandedWidth = target }
        guard abs(target - sidebarWidth) > 0.5 || abs(velocity) > 1 else { return }
        springSidebar(to: target, velocity: velocity)
    }

    /// 阻尼弹簧（响应约 0.48 秒、阻尼比 0.68：冲过头约 5% 再弹回，软而有弹性），按真实帧间隔积分，每帧普通赋值、真实排版。
    private func springSidebar(to target: CGFloat, velocity v0: CGFloat) {
        sidebarSlide?.cancel()
        let omega = 2 * Double.pi / (0.48 * Self.slowFactor)
        let zeta = 0.68
        sidebarSlide = Task { @MainActor in
            var x = Double(sidebarWidth), v = Double(v0)
            var last = CACurrentMediaTime()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(8))
                let now = CACurrentMediaTime()
                var dt = min(1.0 / 30, now - last); last = now
                // 小步积分，防大帧间隔发散
                while dt > 0 {
                    let h = min(dt, 1.0 / 240)
                    let a = -omega * omega * (x - Double(target)) - 2 * zeta * omega * v
                    v += a * h; x += v * h; dt -= h
                }
                if abs(x - Double(target)) < 0.3 && abs(v) < 5 { sidebarWidth = target; break }
                sidebarWidth = min(sidebarMaxWidth, max(SidebarView.railWidth, CGFloat(x)))
            }
        }
    }

    @State private var sidebarSlide: Task<Void, Never>?
    /// 调试用：`--args -WgSenseSlow 8` 让侧栏收放慢 8 倍，逐帧截图核对过渡（仅命令行参数域）。
    private static let slowFactor = max(1, UserDefaults.standard.double(forKey: "WgSenseSlow"))

    private func slideSidebar(to target: CGFloat, duration base: Double = 0.42) {
        sidebarSlide?.cancel()
        let from = sidebarWidth
        let duration = base * Self.slowFactor
        sidebarSlide = Task { @MainActor in
            let start = CACurrentMediaTime()
            while !Task.isCancelled {
                let t = min(1, (CACurrentMediaTime() - start) / duration)
                // 先快后慢再收住（ease-in-out 三次）
                let e = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
                // 普通赋值（不包动画）：和拖动一样每帧真实排版；列数变化时网格自带的重排动画照常生效，两列 → 一列不跳
                sidebarWidth = from + (target - from) * e
                if t >= 1 { break }
                try? await Task.sleep(for: .milliseconds(8))
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(selection: $selection)
                .frame(width: sidebarWidth, alignment: .leading)
                .clipped()
                // 全息模式：侧栏底下加一层模糊，越靠右缘越清晰
                .background { if selection == .trace { TraceSidebarBlur() } }
                .wgSidebarSurface()
                .wgSurfaceRegion(.sidebar)

            SidebarResizeHandle(
                width: $sidebarWidth,
                minimumWidth: SidebarView.railWidth,
                maximumWidth: sidebarMaxWidth,
                onBegin: { sidebarSlide?.cancel() },
                onEnd: { snapSidebar(velocity: $0) }
            )
            .frame(width: 7)
            // 收起 / 展开按钮骑在分隔线正中：两种状态都在同一个位置，不占侧栏底部的地方
            .overlay {
                SidebarCollapseButton(collapsed: sidebarWidth <= SidebarView.railWidth + 0.5, action: toggleSidebar)
            }
            .zIndex(1)

            // 页面区单独成一个子视图，输入只有当前页与语言：拖侧栏时 MainView 每帧重算（sidebarWidth 在变），
            // 子视图输入不变就整体跳过，不再每帧把整页内容重新塞进原生滚动容器（测速页曾因此拖动掉帧 70%+）。
            MainPageArea(selection: selection, language: selectedLanguage, client: client)
            .wgPageSurface()
            .wgSurfaceRegion(.content)
        }
        // 调试用：`--args -WgSenseSidebarSweep 6` 侧栏宽度在 64 ↔ 180 之间线性来回扫，单程 6 秒（模拟慢慢来回拖，逐帧截图核对）
        .task {
            let args = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            guard let leg = (args["WgSenseSidebarSweep"] as? String).flatMap(Double.init) else { return }
            try? await Task.sleep(for: .seconds(2))
            let start = CACurrentMediaTime()
            while !Task.isCancelled {
                let t = (CACurrentMediaTime() - start) / leg
                let phase = t.truncatingRemainder(dividingBy: 2)
                let k = phase < 1 ? phase : 2 - phase
                // 区间可用 -WgSenseSweepMin / -WgSenseSweepMax 改（默认 64 ↔ 180）
                let lo = UserDefaults.standard.double(forKey: "WgSenseSweepMin").nonZero ?? Double(SidebarView.railWidth)
                let hi = UserDefaults.standard.double(forKey: "WgSenseSweepMax").nonZero ?? 180
                sidebarWidth = CGFloat(hi - (hi - lo) * k)
                try? await Task.sleep(for: .milliseconds(8))
            }
        }
        // 调试用：`--args -WgSenseSidebarToggleAt 3` 启动 3 秒后自动点一次收起 / 展开（配合 -WgSenseSlow 逐帧截图）
        .task {
            let args = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            guard let at = (args["WgSenseSidebarToggleAt"] as? String).flatMap(Double.init) else { return }
            try? await Task.sleep(for: .seconds(at))
            toggleSidebar()
        }
        // 收起状态跟着宽度走（拖到最窄也算收起），重启后照样
        .onChange(of: sidebarWidth) { _, w in
            let collapsed = w <= SidebarView.railWidth + 0.5
            if sidebarCollapsed != collapsed { sidebarCollapsed = collapsed }
        }
        // 图表缓存：主窗口可见期间采样速度/内存，打开代理概览时曲线已有历史；窗口收起即停。
        .task { PPOverviewStore.shared.startSamplingWhileVisible() }
        // 调试用：`--args -WgSenseSwitchTab proxy:40` 启动 40 秒后切到指定页面（验证后台缓存，仅命令行参数域）。
        .task {
            let args = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            guard let spec = args["WgSenseSwitchTab"] as? String else { return }
            let parts = spec.split(separator: ":")
            guard parts.count == 2, let tab = SidebarTab(rawValue: String(parts[0])), let delay = Double(parts[1]) else { return }
            try? await Task.sleep(for: .seconds(delay))
            selection = tab
        }
        // 整窗一块玻璃：侧栏与内容区都坐在它上面，不再各自铺底色。
        .background {
            ZStack {
                WgBackdrop(
                    mode: WgBackdropMode(rawValue: backdropModeRaw) ?? .liquidRegular,
                    tintStrength: glassTintStrength
                )
                    .ignoresSafeArea()
                // 路由追踪页是全息模式：地球铺满整个窗口当背景，侧栏与页面浮在上面，地球中心对准内容区
                if selection == .trace {
                    TraceGlobeStage(leading: sidebarWidth + 7)
                        .environmentObject(client)
                }
            }
        }
        .background(WgTransparentWindow())
        .frame(minWidth: 780, minHeight: 500)
        .overlay(alignment: .bottom) {
            if let toast = client.actionToast {
                ActionToastView(toast: toast)
                    .wgInset(.bottom, 78)
                    .transition(
                        .scale(scale: 0.92, anchor: .bottom)
                            .combined(with: .opacity)
                    )
                    .zIndex(100)
            }
        }
        .modifier(WgLocaleOverride(language: selectedLanguage))
        .preferredColorScheme(selectedAppearance.colorScheme)
        .animation(.easeInOut(duration: 0.3), value: appAppearanceRaw)
        .id("content-\(appLanguageRaw)")
        .task {
            await client.refresh()
            Self.openMenuPreviewIfRequested(client)
            // 调试：`--args -WgSenseRuleSync YES` 启动即同步规则缓存（仅命令行参数域）。
            let args = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            if (args["WgSenseRuleSync"] as? String) == "YES" {
                RuleCacheStore.shared.loadIfNeeded()
                await RuleCacheStore.shared.sync()
            }
        }
    }

    private var selectedLanguage: WgAppLanguage {
        WgAppLanguage(rawValue: appLanguageRaw) ?? .system
    }

    private var selectedAppearance: WgAppAppearance {
        WgAppAppearance(rawValue: appAppearanceRaw) ?? .system
    }

    private static var menuPreviewWindow: NSWindow?

    /// 调试用：`--args -WgSenseMenuPreview YES` 把菜单栏面板放进独立窗口，便于截图（仅命令行参数域）。
    private static func openMenuPreviewIfRequested(_ client: DaemonClient) {
        let args = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        guard (args["WgSenseMenuPreview"] as? String) == "YES", menuPreviewWindow == nil else { return }
        let host = NSHostingView(rootView: MenuBarView().environmentObject(client))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 360),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "WgSense Menu Preview"
        window.titlebarAppearsTransparent = true
        let effect = NSVisualEffectView()
        effect.material = .menu
        effect.state = .active
        host.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            host.topAnchor.constraint(equalTo: effect.topAnchor, constant: 20),
            host.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        window.contentView = effect
        window.setContentSize(NSSize(width: 300, height: host.fittingSize.height + 20))
        window.center()
        window.makeKeyAndOrderFront(nil)
        menuPreviewWindow = window
    }
}

/// 主窗口右侧的页面区（见 MainView 里的说明）。
private struct MainPageArea: View {
    let selection: SidebarTab
    let language: WgAppLanguage
    let client: DaemonClient

    var body: some View {
        // 代理页自己管理滚动（内部是懒加载列表）；套在外层 ScrollView 里会让懒加载失效、
        // 屏幕外的卡片和图表也每次重绘。
        Group {
        if selection == .trace {
            // 全息模式：不套滚动容器，浮层铺满页面区，空白处让拖动 / 捏合穿透到背后的地球
            TraceView()
                .wgPadding(.xl)
                .environmentObject(client)
                .modifier(WgLocaleOverride(language: language))
                .tint(WgInk.control)
        } else if selection == .proxy {
            ProxyView()
                .wgPadding(.vertical, .xl)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else if selection == .speedtest {
            // Own the viewport: lazy drawers/sections stay lazy, including during live resize.
            ScrollView { SpeedLabView().wgPadding(.xl) }
                .environmentObject(client)
                .modifier(WgLocaleOverride(language: language))
                .tint(WgInk.control)
        } else if selection == .logs {
            // 日志页内部自带滚动区（跟随最新一行），保留 SwiftUI 容器。
            ScrollView { LogsView().wgPadding(.xl) }
        } else {
            // 普通页面统一用原生滚动容器（见 WgScrollView）：滚动时 SwiftUI 不再逐帧布局。
            // 内容是独立宿主根，环境需显式注入。
            WgScrollView(content: AnyView(
                Group {
                    switch selection {
                    case .dashboard, .wireguard: OverviewView()
                    case .profile: ProfileManagerView()
                    case .transferReceive: TransferReceiveView()
                    case .transferSend: TransferSendView()
                    case .settings: SettingsView()
                    case .about: AboutView()
                    case .speedtest: SpeedLabView()
                    case .trace: TraceView()
                    case .purity: PurityView()
                    case .vpn: VPNView()
                    case .proxy, .logs: EmptyView()
                    }
                }
                .wgPadding(.xl)
                .environmentObject(client)
                .modifier(WgLocaleOverride(language: language))
                .tint(WgInk.control)
            ))
            .id(selection)
        }
        }
    }
}

#if canImport(AppKit)
/// 侧栏收起 / 展开按钮：竖条形，骑在侧栏与页面的分隔线正中，箭头指向点了以后侧栏去的方向。
private struct SidebarCollapseButton: View {
    var collapsed: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: WgType.micro, weight: .bold))
                .rotationEffect(.degrees(collapsed ? 180 : 0))
                .foregroundStyle(hovering ? WgInk.ink : WgInk.ink3)
                .frame(width: 18, height: 44)
                .background(SLPlate(shape: ChamferShape(tr: 5, bl: 5), fill: WgInk.field,
                                    stroke: Color.primary.opacity(hovering ? 0.35 : 0.18)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(collapsed ? "展开侧栏" : "收起侧栏")
    }
}

private struct SidebarResizeHandle: NSViewRepresentable {
    @Binding var width: CGFloat
    let minimumWidth: CGFloat
    let maximumWidth: CGFloat
    var onBegin: () -> Void = {}
    /// 松手时的手速（点/秒），交给吸附当初速度
    var onEnd: (CGFloat) -> Void = { _ in }

    func makeNSView(context: Context) -> SidebarResizeHandleView {
        let view = SidebarResizeHandleView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: SidebarResizeHandleView, context: Context) {
        nsView.onDrag = resize(by:)
        nsView.onBegin = onBegin
        nsView.onEnd = onEnd
        nsView.currentWidth = { width }
    }

    private func resize(by delta: CGFloat) {
        width = min(maximumWidth, max(minimumWidth, width + delta))
    }
}

private final class SidebarResizeHandleView: NSView {
    var onDrag: ((CGFloat) -> Void)?
    var onBegin: (() -> Void)?
    var onEnd: ((CGFloat) -> Void)?
    var currentWidth: (() -> CGFloat)?

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        onBegin?()
        var last = event.locationInWindow.x
        var lastTime = event.timestamp
        var velocity: CGFloat = 0
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: NSEvent.foreverDuration, mode: .eventTracking) { e, stop in
            guard let e else { stop.pointee = true; return }
            if e.type == .leftMouseUp {
                // 停住超过 80ms 再松手 = 没有甩的意图
                if e.timestamp - lastTime > 0.08 { velocity = 0 }
                stop.pointee = true; return
            }
            let x = e.locationInWindow.x
            let dt = e.timestamp - lastTime
            if dt > 0 { velocity = velocity * 0.4 + (x - last) / CGFloat(dt) * 0.6 }
            onDrag?(x - last)
            last = x; lastTime = e.timestamp
        }
        onEnd?(velocity)
    }
}
#endif

// MARK: - Tab 枚举

enum SidebarTab: String, CaseIterable, Identifiable {
    case dashboard, wireguard, proxy, profile, transferReceive, transferSend, settings, logs, about, speedtest, trace, purity, vpn
    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .dashboard: return "概览"
        case .wireguard: return "WireGuard"
        case .proxy: return "面板"
        case .profile: return "配置"
        case .transferReceive: return "接收"
        case .transferSend: return "发送"
        case .settings: return "设置"
        case .logs: return "日志"
        case .about: return "关于"
        case .speedtest: return "测速"
        case .trace: return "路由追踪"
        case .purity: return "纯良"
        case .vpn: return "VPN"
        }
    }
}

// MARK: - 磁贴数据模型

enum TileKind: String, CaseIterable, Identifiable, Codable {
    case vpn, pause, stop, transferReceive, transferSend, proxy, profile, logs, about, connection, speedtest, trace, purity
    var id: String { rawValue }

    var isAddable: Bool {
        self != .pause && self != .stop
    }

    var title: LocalizedStringKey {
        switch self {
        case .vpn: return "VPN"
        case .pause: return "暂停"
        case .stop: return "停止"
        case .transferReceive: return "接收"
        case .transferSend: return "发送"
        case .proxy: return "面板"
        case .profile: return "配置"
        case .logs: return "日志"
        case .about: return "关于"
        case .connection: return "流量"
        case .speedtest: return "测速"
        case .trace: return "路由追踪"
        case .purity: return "纯良"
        }
    }

    var icon: String {
        switch self {
        case .vpn: return "lock.shield.fill"
        case .pause: return "pause.fill"
        case .stop: return "stop.fill"
        case .transferReceive: return "arrow.down"
        case .transferSend: return "arrow.up"
        case .proxy: return "rectangle.3.group"
        case .profile: return "doc.text.fill"
        case .logs: return "text.alignleft"
        case .about: return "info"
        case .connection: return "arrow.up.arrow.down"
        case .speedtest: return "gauge.with.dots.needle.67percent"
        case .trace: return "point.3.connected.trianglepath.dotted"
        case .purity: return "hand.raised.fill"
        }
    }

    /// 磁贴右上角的等宽代号。
    var code: String {
        switch self {
        case .vpn: return "VPN"
        case .pause: return "PS"
        case .stop: return "ST"
        case .transferReceive: return "RX"
        case .transferSend: return "TX"
        case .proxy: return "PNL"
        case .profile: return "CF"
        case .logs: return "LG"
        case .about: return "AB"
        case .connection: return "NET"
        case .speedtest: return "SPD"
        case .trace: return "TRC"
        case .purity: return "PUR"
        }
    }

    var activeColor: Color {
        switch self {
        // 仪表语言：“开启”统一克莱因蓝；只有暂停（警示）与停止（告警）保留状态色。
        case .pause: return .orange
        case .stop: return .red
        case .logs, .about: return .gray
        case .vpn, .transferReceive, .transferSend, .proxy, .profile, .connection, .speedtest, .trace, .purity: return WgInk.signal
        }
    }

    /// 默认尺寸（首次添加时使用，之后可切换）
    var defaultSize: TileSize {
        switch self {
        case .connection, .speedtest: return .medium
        default: return .small
        }
    }
}

enum TileSize: String, Codable, CaseIterable {
    case small   // 1 格子（半行）— 正方形
    case medium  // 2 格子（全宽一行）
    case large   // 4 格子（全宽两行）

    /// 固定高度倍数（以 small 高度为 1 单位）
    var heightUnits: Int {
        switch self {
        case .small: return 1
        case .medium: return 1   // 一行高
        case .large: return 2    // 两行高
        }
    }
}

struct TileData: Identifiable, Codable, Equatable {
    let id: UUID
    var kind: TileKind
    var size: TileSize

    init(id: UUID = UUID(), kind: TileKind, size: TileSize? = nil) {
        self.id = id
        self.kind = kind
        self.size = size ?? kind.defaultSize
    }
}

// MARK: - 侧边栏（iOS 桌面风格磁贴系统）

struct SidebarView: View {
    @Binding var selection: SidebarTab
    /// 侧栏宽窄的两端：fullWidth 以上磁贴是完整形态，railWidth 是只剩图标的收起形态；中间按宽度无极过渡。
    static let fullWidth: CGFloat = 176
    static let railWidth: CGFloat = 64

    /// 收缩程度：0 = 完整磁贴，1 = 只剩图标。拖动分隔线、点收起按钮都只是改宽度，磁贴形态全由它决定。
    static func compactness(_ width: CGFloat) -> CGFloat {
        min(1, max(0, (fullWidth - width) / (fullWidth - railWidth)))
    }

    /// 吸附点：收起，以及网格恰好排满 n 列（每列最小宽、无零头）的侧栏宽度；一列时不低于完整磁贴的宽度。
    static func snapWidths(upTo maxWidth: CGFloat) -> [CGFloat] {
        let padding = WgGap.m.value * 2
        var result = [railWidth]
        var n = 1
        while true {
            let width = CGFloat(n) * GridGeometry.minimum + CGFloat(n - 1) * GridGeometry.gap + padding
            guard width <= maxWidth else { break }
            result.append(max(fullWidth, width))
            n += 1
        }
        return result
    }
    @EnvironmentObject var client: DaemonClient
    /// 路由追踪磁贴的状态行跟着追踪进度走。只订阅这一行字：订阅整个追踪状态的话，每来一跳（定位、代理查询……）
    /// 整个侧栏都要重算，压测里是追踪中地图每秒一次 60–80ms 的卡顿。
    @ObservedObject private var traceTile = TraceTileSummary.shared
    @State private var tiles: [TileData] = []
    @State private var isEditMode = false
    @State private var draggedItem: TileData?
    @State private var showDeleteConfirm = false
    @State private var showAddSheet = false
    @State private var showProfileDeleteConfirm = false
    @State private var contextMenuTile: TileData? = nil  // 长按/右键磁贴时弹菜单
    @State private var contextMenuAnchor: CGPoint = .zero
    @State private var vpnPauseTask: Task<Void, Never>?

    // VPN 状态快捷访问
    private var isConnected: Bool { client.isVPNOn }
    private var isTunnelUp: Bool { client.isTunnelUp }
    /// 服务离线时不沿用本地缓存的守护意图，否则会显示“运行中”而实际没人在守护。
    private var guardRunning: Bool { client.status != nil && client.isGuardOn }

    init(selection: Binding<SidebarTab>) {
        self._selection = selection
        var tiles = Self.loadTiles() ?? Self.defaultTiles()
        // 新磁贴给已有布局补一次；用户之后删掉就不再加回来
        if !UserDefaults.standard.bool(forKey: "tileLayout.seeded.trace") {
            if !tiles.contains(where: { $0.kind == .trace }) { tiles.append(TileData(kind: .trace)) }
            UserDefaults.standard.set(true, forKey: "tileLayout.seeded.trace")
        }
        if !UserDefaults.standard.bool(forKey: "tileLayout.seeded.purity") {
            if !tiles.contains(where: { $0.kind == .purity }) { tiles.append(TileData(kind: .purity)) }
            UserDefaults.standard.set(true, forKey: "tileLayout.seeded.purity")
        }
        _tiles = State(initialValue: tiles)
    }

    // MARK: 磁贴布局持久化

    private static let tileLayoutKey = "tileLayout"

    /// 逐条解码，跳过无法识别的条目。
    ///
    /// 直接 decode 整个数组的话，只要有一条认不出来（比如某个磁贴类型在新版本里
    /// 被移除了）整个布局就会回退成默认，用户排好的顺序全丢。
    private struct LenientTile: Decodable {
        let value: TileData?
        init(from decoder: Decoder) throws {
            value = try? TileData(from: decoder)
        }
    }

    static func loadTiles() -> [TileData]? {
        guard
            let raw = UserDefaults.standard.string(forKey: tileLayoutKey),
            let data = raw.data(using: .utf8),
            let decoded = try? JSONDecoder().decode([LenientTile].self, from: data)
        else { return nil }
        let tiles = decoded.compactMap(\.value)
        return tiles.isEmpty ? nil : tiles
    }

    func saveTiles() {
        guard
            let data = try? JSONEncoder().encode(tiles),
            let raw = String(data: data, encoding: .utf8)
        else { return }
        UserDefaults.standard.set(raw, forKey: Self.tileLayoutKey)
    }

    static func defaultTiles() -> [TileData] {
        [
            TileData(kind: .vpn),
            TileData(kind: .transferReceive),
            TileData(kind: .transferSend),
            TileData(kind: .proxy),
            TileData(kind: .profile),
            TileData(kind: .logs),
            TileData(kind: .about),
            TileData(kind: .connection),
            TileData(kind: .speedtest),
            TileData(kind: .trace),
            TileData(kind: .purity),
        ]
    }

    var body: some View {
        GeometryReader { geometry in
            let c = Self.compactness(geometry.size.width)
            VStack(spacing: 0) {
                // 顶部只留出红绿灯的位置；品牌与工具按钮移到底部。
                Color.clear.frame(height: WgLayout.sidebarTop)

                // 磁贴网格区域
                ScrollView(showsIndicators: c == 0) {
                    tileGridContent(availableWidth: geometry.size.width, compact: c)
                }

                foot(c)
            }
            // 底栏、编辑栏有固定的最小宽度：不卡住的话会把整列撑宽并居中，窄的时候图标被挤到侧栏外面
            .frame(width: geometry.size.width, alignment: .leading)
        }
        // 排序、增删、改大小都会走到这里，落盘一次。
        .onChange(of: tiles) { _, _ in saveTiles() }
        .sheet(isPresented: $showAddSheet) { AddTileSheet(existingKinds: tiles.map(\.kind)) { kind in
            tiles.append(TileData(kind: kind))
            showAddSheet = false
        }}
        .confirmationDialog("确认删除配置？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let name = client.status?.service {
                    Task {
                        await client.postAndWait("pause")
                        await client.postAndWait("disconnect")
                        await client.deleteProfile(name: name)
                        await client.fetchProfiles()
                        await client.fetchStatus()
                    }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将断开 WG 并删除当前 profile「\(client.status?.service ?? "")」，此操作不可撤销。")
        }
    }

    // MARK: - 底部品牌栏

    /// 底栏随侧栏收缩：完整品牌栏淡出，只剩品牌标与设置的窄版淡入。
    private func foot(_ c: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            if c < 0.5 {
                // minWidth 0 + 裁切：品牌栏自身约 208 宽，不卡住会把整列撑宽，网格在里面居中、右移被切
                brandFoot
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .clipped()
                    .opacity(Double(1 - c * 2))
            }
            VStack(spacing: WgSpace.s) {
                WgBrandIcon().frame(width: 28, height: 28)
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { selection = .settings }
                } label: { Image(systemName: "gearshape") }
                    .buttonStyle(WgToolbarIconButtonStyle(isActive: selection == .settings))
                    .help("设置")
            }
            .frame(maxWidth: .infinity)
            .wgPadding(.bottom, .l)
            .opacity(Double(max(0, (c - 0.4) / 0.6)))
            .allowsHitTesting(c >= 0.5)
        }
        .transaction { $0.animation = nil }
    }

    /// 品牌栏：细分隔线 + 几何标 + 名称 / 版本，右侧是添加、编辑、设置。
    private var brandFoot: some View {
        // 按宽度降级，永不撑出侧栏：完整 → 去掉名字 → 只留标志和设置
        ViewThatFits(in: .horizontal) {
            brandFootRow(name: true, tools: true)
            brandFootRow(name: false, tools: true)
            brandFootRow(name: false, tools: false)
        }
        .wgPadding(.horizontal, .l)
        .wgPadding(.top, .m)
        .wgPadding(.bottom, .l)
        .overlay(alignment: .top) { Rectangle().fill(WgInk.rule).frame(height: 1).wgPadding(.horizontal, .l) }
        .focusEffectDisabled()
        .wgRegionBackground()
        .wgSurfaceRegion(.toolbar)
    }

    private func brandFootRow(name: Bool, tools: Bool) -> some View {
        HStack(spacing: WgSpace.m) {
            WgBrandIcon()
                .frame(width: 28, height: 28)
            if name {
                VStack(alignment: .leading, spacing: WgSpace.zero) {
                    Text(verbatim: "WgSense").font(.system(size: WgType.title, weight: .heavy)).tracking(0.6).fixedSize()
                    // 版本行不计入理想宽度：名字放得下就显示这一档，版本行放不下就截断
                    Text(verbatim: "V\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0") · WIREGUARD / MIHOMO")
                        .font(WgInk.mono(.micro)).tracking(1).foregroundStyle(WgInk.ink3).lineLimit(1)
                        .frame(idealWidth: 0, maxWidth: .infinity, alignment: .leading)
                }
            }
            Spacer(minLength: 4)

            if tools {
                Button { showAddSheet = true } label: { Image(systemName: "plus") }
                    .buttonStyle(WgToolbarIconButtonStyle())
                    .help("添加磁贴")

                Button {
                    withAnimation(WgDesign.spring) { isEditMode.toggle() }
                } label: {
                    Image(systemName: isEditMode ? "checkmark" : "square.grid.2x2")
                }
                .buttonStyle(WgToolbarIconButtonStyle(isActive: isEditMode))
                .help(isEditMode ? "完成编辑" : "编辑磁贴")
            }

            Button {
                withAnimation(.easeInOut(duration: 0.15)) { selection = .settings }
            } label: { Image(systemName: "gearshape") }
                .buttonStyle(WgToolbarIconButtonStyle(isActive: selection == .settings))
                .help("设置")
        }
    }

    // MARK: - 收缩形态的图标

    /// 磁贴缩到最窄时的样子：40 × 40 的图标方块。页面磁贴点了切页，暂停 / 停止点了直接执行；
    /// 选中的页面垫一块底板，开着的模块右上角一个小点。
    private func compactIcon(_ tile: TileData) -> some View {
        let kind = tile.kind
        let selected = isSelected(kind)
        let on: Bool = switch kind {
        case .vpn: isConnected
        case .connection: isTunnelUp
        case .speedtest: false
        default: moduleInfo(kind).isOn
        }
        return Button {
            switch kind {
            case .pause: if !client.isPauseOn { toggleVPNPause() }
            default: handleSmallTileTap(tile)
            }
        } label: {
            Image(systemName: kind.icon)
                .font(.system(size: WgType.title, weight: .medium))
                .foregroundStyle(selected ? WgInk.ink : WgInk.ink3)
                .frame(width: 40, height: 40)
                .background {
                    if selected {
                        SLPlate(shape: ChamferShape(tr: 8), fill: Color.primary.opacity(0.1), stroke: Color.primary.opacity(0.3))
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if on { Circle().fill(WgInk.ink).frame(width: 5, height: 5).offset(x: -5, y: 5) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(kind.title))
    }

    // MARK: - 磁贴内容

    @ViewBuilder
    private func tileContent(_ tile: TileData) -> some View {
        Group {
            switch tile.kind {
            case .vpn:
                vpnModule(tile)
            case .connection:
                trafficModule(tile)
            case .speedtest:
                SLSpeedTile(size: tile.size, isSelected: isSelected(tile.kind), isEditMode: isEditMode) {
                    handleSmallTileTap(tile)
                }
            case .logs where tile.size != .small:
                logContentTile(tile)
            case .pause where tile.size != .small:
                pauseTile(tile)
            case .stop where tile.size != .small:
                stopTile(tile)
            default:
                standardModule(tile)
            }
        }
        .modifier(EditShakeModifier(isShaking: isEditMode && draggedItem?.id != tile.id))
        .overlay(alignment: .topTrailing) {
            if isEditMode { editOverlay(tile) }
        }
    }

    private func tab(for kind: TileKind) -> SidebarTab? {
        switch kind {
        case .vpn: return .vpn
        case .connection: return .dashboard
        case .transferReceive: return .transferReceive
        case .transferSend: return .transferSend
        case .proxy: return .proxy
        case .profile: return .profile
        case .logs: return .logs
        case .about: return .about
        case .speedtest: return .speedtest
        case .trace: return .trace
        case .purity: return .purity
        case .pause, .stop: return nil
        }
    }

    private func isSelected(_ kind: TileKind) -> Bool {
        guard let tab = tab(for: kind) else { return false }
        return selection == tab
    }

    // MARK: 通用模块（控制中心样式：圆形徽章 + 标题 + 一行状态）

    private struct ModuleInfo {
        var symbol: String
        var tint: Color
        var isOn: Bool
        var status: Text
        var highlight: Bool = false
    }

    private func moduleInfo(_ kind: TileKind) -> ModuleInfo {
        switch kind {
        case .transferReceive:
            guard let state = client.transferState else {
                return ModuleInfo(symbol: kind.icon, tint: kind.activeColor, isOn: false, status: Text("未启动"))
            }
            if !state.pending.isEmpty {
                return ModuleInfo(symbol: kind.icon, tint: .orange, isOn: true,
                                  status: Text("\(state.pending.count) 个待确认"), highlight: true)
            }
            return ModuleInfo(symbol: kind.icon, tint: kind.activeColor, isOn: state.running,
                              status: Text(state.running ? "可接收" : "已停止"))
        case .transferSend:
            let count = client.transferDevices.count
            return ModuleInfo(symbol: kind.icon, tint: kind.activeColor, isOn: count > 0,
                              status: count > 0 ? Text("\(count) 台设备") : Text("无设备"))
        case .proxy:
            let status: Text
            if client.proxyRunning {
                status = Text(client.mihomoVersion?.version ?? "运行中")
            } else {
                status = Text(client.proxyServiceRunning ? "等待认证" : "未连接")
            }
            return ModuleInfo(symbol: kind.icon, tint: kind.activeColor, isOn: client.proxyRunning, status: status)
        case .profile:
            let name = client.status?.service ?? client.profiles.first
            return ModuleInfo(symbol: kind.icon, tint: kind.activeColor, isOn: name != nil,
                              status: name.map { Text(verbatim: $0) } ?? Text("无配置"))
        case .logs:
            return ModuleInfo(symbol: kind.icon, tint: kind.activeColor, isOn: false, status: Text("运行记录"))
        case .about:
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            return ModuleInfo(symbol: kind.icon, tint: kind.activeColor, isOn: false, status: Text(verbatim: "v\(version)"))
        case .pause:
            return ModuleInfo(symbol: kind.icon, tint: kind.activeColor, isOn: client.isPauseOn,
                              status: client.isPauseOn ? Text("已暂停") : Text("\(client.pauseMinutes) 分钟"))
        case .stop:
            return ModuleInfo(symbol: kind.icon, tint: kind.activeColor, isOn: false, status: Text("全部停止"))
        case .trace:
            let tile = traceTile
            return ModuleInfo(symbol: kind.icon, tint: kind.activeColor, isOn: tile.running,
                              status: tile.text.map { Text(verbatim: $0) } ?? Text("世界航线"))
        case .purity:
            // 状态行只给结论（成立 / N 项不成立），与页面第一层同源；不成立时着警示色
            let purity = PurityPresentation(status: client.status, tunnelUp: client.isTunnelUp)
            return ModuleInfo(symbol: kind.icon, tint: WgInk.warn, isOn: purity.mode == .on || purity.mode == .domestic,
                              status: Text(purity.verdict), highlight: purity.needsAttention)
        case .vpn, .connection, .speedtest:
            return ModuleInfo(symbol: kind.icon, tint: kind.activeColor, isOn: false, status: Text(""))
        }
    }

    private func standardModule(_ tile: TileData) -> some View {
        // 磁贴：左上白色短竖条 + 右上等宽代号 + 标题 / 状态 + 右下放大淡出的图标（只做辨识度）。
        let info = moduleInfo(tile.kind)
        let compact = tile.size == .small
        // 中号磁贴只有一行高：详情排在标题右侧；排在下方放不下，会把标题顶出磁贴。
        let wide = tile.size == .medium
        let heading = VStack(alignment: .leading, spacing: WgSpace.xs) {
            Text(tile.kind.title)
                .font(.system(size: WgType.title, weight: .bold))
                .lineLimit(1)
            info.status
                .font(.system(size: WgType.body, weight: .medium))
                .foregroundStyle(info.highlight ? info.tint : WgInk.ink3)
                .lineLimit(1)
        }
        return Group {
            if wide {
                // 侧栏宽窄不定：宽时详情列让出水印图标的位置；窄一档贴右排；再窄只留标题与结论，不显示截断的半截字。
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: WgSpace.l) {
                        heading.fixedSize()
                        Spacer(minLength: 0)
                        VStack(alignment: .leading, spacing: WgSpace.xs) { moduleDetail(tile) }
                            .frame(width: 120)
                            .wgInset(.trailing, 52)
                    }
                    HStack(alignment: .center, spacing: WgSpace.l) {
                        heading.fixedSize()
                        Spacer(minLength: 0)
                        VStack(alignment: .leading, spacing: WgSpace.xs) { moduleDetail(tile) }
                            .frame(width: 88)
                    }
                    heading
                }
            } else {
                VStack(alignment: .leading, spacing: WgSpace.m) {
                    heading
                    if !compact {
                        moduleDetail(tile)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
            }
        }
        .wgPadding(.leading, .l).wgPadding(.trailing, wide ? .l : .m).wgPadding(.vertical, compact || wide ? .m : .l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: compact || wide ? .leading : .topLeading)
        .background(alignment: .bottomTrailing) {
            WgGhostSymbol(symbol: info.symbol, size: compact ? 58 : 72, opacity: info.isOn ? 0.2 : 0.12)
                .offset(x: 12, y: 16)
        }
        .overlay(alignment: .topLeading) {
            Rectangle().fill(WgInk.ink.opacity(info.isOn ? 0.9 : 0.45)).frame(width: 3, height: 20)
        }
        .overlay(alignment: .topTrailing) {
            Text(verbatim: tile.kind.code).font(WgInk.mono(.micro)).tracking(1).foregroundStyle(WgInk.ink4).wgPadding(.s)
        }
        .wgInteractiveSurface(isSelected: isSelected(tile.kind), isEnabled: !isEditMode) {
            handleSmallTileTap(tile)
        }
    }

    @ViewBuilder
    private func moduleDetail(_ tile: TileData) -> some View {
        switch tile.kind {
        case .transferReceive:
            if let state = client.transferState {
                detailLine("设备名", state.alias)
                if tile.size == .large { detailLine("端口", ":\(state.port)") }
            }
        case .transferSend:
            if tile.size == .large {
                ForEach(client.transferDevices.prefix(3)) { device in
                    detailLine(device.alias, device.ip ?? "")
                }
            }
        case .proxy:
            if !client.proxyAddress.isEmpty { detailLine("控制器", client.proxyAddress) }
        case .profile:
            if tile.size == .large {
                ForEach(client.profiles.prefix(3), id: \.self) { name in
                    detailLine(name, name == client.status?.service ? "当前" : "")
                }
            }
        case .purity:
            let purity = PurityPresentation(status: client.status, tunnelUp: client.isTunnelUp)
            detailLine("处境", purity.code)
            detailLine("已拒绝", "\(purity.blocked) 包")
            if tile.size == .large {
                detailLine("网卡", client.status?.firewall?.interfaces?.joined(separator: " ") ?? "—")
            }
        default:
            EmptyView()
        }
    }

    private func detailLine(_ label: String, _ value: String) -> some View {
        HStack {
            Text(verbatim: label).foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Text(verbatim: value).foregroundStyle(.tertiary).monospacedDigit()
        }
        .font(.system(size: WgType.body))
        .lineLimit(1)
    }

    // MARK: VPN 模块

    private func vpnModule(_ tile: TileData) -> some View {
        let vpn = client.vpnPresentation
        // 代号与状态跟随点击立即变化；切换进行中显示「切换中」
        let exit = client.displayedExit
        let switching = client.switchingExit != nil
        let mh = MihomoPresentation(status: client.mihomo, error: client.mihomoError)
        let compact = tile.size == .small
        // 出口不是 WireGuard 时，徽标与状态跟随当前出口；守护 / 暂停只属于 WireGuard
        let isOn = exit == .mihomo ? mh.phase == .running : vpn.isConnected
        let statusText: Text = switching ? Text("切换中") : (exit == .mihomo ? Text(mh.title) : Text(vpn.title))
        let statusTint: Color = exit == .mihomo ? (mh.phase == .crashed ? WgInk.warn : (isOn ? vpn.tint : .secondary)) : (vpn.isConnected ? vpn.tint : .secondary)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: WgSpace.m) {
                Button(action: toggleVPN) {
                    WgCircleBadge(
                        symbol: exit == .mihomo ? "globe" : vpn.symbol,
                        tint: exit == .mihomo ? .green : vpn.tint,
                        isOn: isOn,
                        size: compact ? 36 : 46,
                        isBusy: switching || (exit == .wireguard && vpn.isBusy)
                    )
                }
                .buttonStyle(.plain)
                .disabled(isEditMode)
                .help(vpnToggleHelp(vpn))

                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: WgSpace.s) {
                        Text("VPN")
                            .font(.system(size: compact ? WgType.body : WgType.title, weight: .semibold))
                        WgExitLogo(exit: exit, size: compact ? 11 : 13)
                            .foregroundStyle(WgInk.ink3)
                    }
                    statusText
                        .font(.system(size: compact ? WgType.body : WgType.sub, weight: isOn ? .medium : .regular))
                        .foregroundStyle(statusTint)
                        .contentTransition(.opacity)
                }
                .fixedSize()
                Spacer(minLength: 0)

                if tile.size == .medium {
                    // 一行高：出口切换放得下就放切换，放不下退回守护 / 暂停两个图标
                    ViewThatFits(in: .horizontal) {
                        WgExitSwitch(compact: true, isEnabled: !isEditMode).frame(width: 132)
                        wgGuardPauseIcons.disabled(exit != .wireguard)
                    }
                    .disabled(isEditMode)
                }
            }

            if tile.size == .large {
                WgExitSwitch(compact: true, isEnabled: !isEditMode)
                    .wgPadding(.top, .m)
                (exit == .mihomo ? Text(verbatim: mihomoTileDetail(mh)) : Text(vpn.detail))
                    .font(.system(size: WgType.body))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .wgPadding(.top, .m)
                Spacer(minLength: 8)
                vpnActions
                    .disabled(exit != .wireguard)
                    .opacity(exit == .wireguard ? 1 : 0.4)
            }
        }
        .wgPadding(compact ? .m : .l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: compact ? .leading : .topLeading)
        .wgInteractiveSurface(isSelected: selection == .vpn, isEnabled: !isEditMode) {
            withAnimation(.easeInOut(duration: 0.15)) { selection = .vpn }
        }
    }

    private var wgGuardPauseIcons: some View {
        HStack(spacing: WgSpace.zero) {
            Button { Task { await client.setGuardEnabled(!guardRunning) } } label: {
                Image(systemName: guardRunning ? "shield.fill" : "shield.slash")
            }
            .buttonStyle(WgToolbarIconButtonStyle(isActive: guardRunning))
            .help(guardRunning ? "关闭守护" : "开启守护")
            Button(action: toggleVPNPause) {
                Image(systemName: client.isPauseOn ? "play.fill" : "pause.fill")
            }
            .buttonStyle(WgToolbarIconButtonStyle(isActive: client.isPauseOn))
            .help(client.isPauseOn ? "继续并重新连接" : "暂停 \(client.pauseMinutes) 分钟")
        }
    }

    private func mihomoTileDetail(_ mh: MihomoPresentation) -> String {
        switch mh.phase {
        case .running: return "内核运行中 · 只监听本机端口，尚未接管流量"
        case .crashed: return mh.status?.last_exit ?? "内核意外退出"
        case .stopped: return "内核已停止"
        case .notBundled, .unsupported: return "内核不可用"
        }
    }

    private func toggleVPN() {
        if client.currentExit == .mihomo {
            let running = client.mihomo?.running == true
            Task { _ = await client.setMihomo(running: !running) }
            return
        }
        let vpn = client.vpnPresentation
        if vpn.phase == .setupFailed {
            Task { await client.retryServiceInstall() }
            return
        }
        Task { await client.post(vpn.canDisconnect ? "disconnect" : "connect") }
    }

    private func vpnToggleHelp(_ vpn: WgVPNPresentation) -> LocalizedStringKey {
        if client.currentExit == .mihomo { return client.mihomo?.running == true ? "停止 mihomo 内核" : "启动 mihomo 内核" }
        if vpn.canDisconnect { return "断开 VPN" }
        if vpn.phase == .setupFailed { return "重试安装后台服务（会弹一次密码框）" }
        if vpn.phase == .home { return "在家由守护保持断开；关闭守护后可手动连接" }
        return "连接 VPN"
    }

    private var vpnActions: some View {
        HStack(spacing: WgSpace.s) {
            vpnActionButton(
                client.isPauseOn ? "继续" : "暂停",
                symbol: client.isPauseOn ? "play.fill" : "pause.fill",
                isActive: client.isPauseOn, tint: .orange,
                help: client.isPauseOn ? "继续并重新连接" : "暂停 \(client.pauseMinutes) 分钟",
                action: toggleVPNPause
            )
            vpnActionButton(
                "守护",
                symbol: guardRunning ? "shield.fill" : "shield.slash",
                isActive: guardRunning, tint: .blue,
                help: guardRunning ? "关闭守护" : "开启守护"
            ) {
                Task { await client.setGuardEnabled(!guardRunning) }
            }
            vpnActionButton("重启", symbol: "arrow.clockwise", isActive: false, tint: .purple, help: "重启守护") {
                vpnPauseTask?.cancel()
                vpnPauseTask = nil
                Task { await client.restartGuardFlow() }
            }
            vpnActionButton("停止", symbol: "stop.fill", isActive: false, tint: .red, help: "关闭守护并断开 VPN",
                            destructive: true, action: stopAllServices)
        }
        .disabled(isEditMode)
    }

    private func vpnActionButton(
        _ title: LocalizedStringKey,
        symbol: String,
        isActive: Bool,
        tint: Color,
        help: LocalizedStringKey,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: WgSpace.xs) {
                Image(systemName: symbol)
                    .font(.system(size: WgType.sub, weight: .semibold))
                    .foregroundStyle(destructive ? AnyShapeStyle(Color.red.opacity(0.9)) : AnyShapeStyle(.foreground))
                    .contentTransition(.symbolEffect(.replace))
                Text(title)
                    .font(.system(size: WgType.body, weight: .medium))
            }
        }
        .buttonStyle(WgActionButtonStyle(isActive: isActive, tint: tint))
        .help(help)
    }

    // MARK: 流量模块

    private func trafficModule(_ tile: TileData) -> some View {
        let up = client.isTunnelUp
        let tx = client.traffic?.tx_speed ?? 0
        let rx = client.traffic?.rx_speed ?? 0
        let compact = tile.size == .small
        return VStack(alignment: .leading, spacing: WgSpace.m) {
            HStack(spacing: WgSpace.m) {
                WgCircleBadge(symbol: TileKind.connection.icon, tint: .cyan, isOn: up, size: compact ? 36 : 38)
                VStack(alignment: .leading, spacing: 1) {
                    Text(TileKind.connection.title)
                        .font(.system(size: WgType.title, weight: .semibold))
                    Group {
                        if compact && up {
                            Text(verbatim: "↓ \(WgFormat.speed(rx))")
                        } else {
                            Text(up ? "经由隧道" : "未连接")
                        }
                    }
                    .font(.system(size: WgType.body))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }
                Spacer(minLength: 0)
                if !compact {
                    VStack(alignment: .trailing, spacing: WgSpace.zero) {
                        speedLabel("arrow.down", up ? WgFormat.speed(rx) : "—")
                        speedLabel("arrow.up", up ? WgFormat.speed(tx) : "—")
                    }
                }
            }
            if tile.size == .large {
                VStack(spacing: WgSpace.xs) {
                    detailLine("累计下载", WgFormat.size(client.traffic?.rx_bytes ?? 0))
                    detailLine("累计上传", WgFormat.size(client.traffic?.tx_bytes ?? 0))
                    if let s = client.status {
                        detailLine("配置", s.service.isEmpty ? "—" : s.service)
                        if let age = s.last_handshake_age_seconds, up {
                            detailLine("最近握手", WgFormat.age(age))
                        }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .wgPadding(compact ? .m : .l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: tile.size == .large ? .topLeading : .leading)
        .wgInteractiveSurface(isSelected: false, isEnabled: !isEditMode) {
            withAnimation(.easeInOut(duration: 0.15)) { selection = .dashboard }
        }
    }

    private func speedLabel(_ symbol: String, _ value: String) -> some View {
        HStack(spacing: WgSpace.xs) {
            Image(systemName: symbol)
                .font(.system(size: WgType.micro, weight: .bold))
                .foregroundStyle(.tertiary)
            Text(verbatim: value)
                .font(.system(size: WgType.sub, weight: .medium).monospacedDigit())
                .foregroundStyle(.primary.opacity(0.85))
        }
    }

    // MARK: - Tab 行

    private var tabRow: some View {
        let topTabs: [SidebarTab] = [.dashboard, .profile, .settings]  // 概览 + 配置 + 设置
        return HStack(spacing: WgSpace.s) {
            ForEach(topTabs) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { selection = tab }
                } label: {
                    Text(tab.label)
                        .font(.subheadline)
                        .fontWeight(selection == tab ? .semibold : .regular)
                        .foregroundStyle(selection == tab ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .wgPadding(.vertical, .s)
                        .background(RoundedRectangle(cornerRadius: WgRadius.s)
                            .fill(selection == tab ? WgTheme.accent : Color.clear))
                }
                .buttonStyle(.plain)
            }
        }
        .wgPadding(.horizontal, .m)
        .wgPadding(.bottom, .m)
    }

    // MARK: - 磁贴内容视图

    /// 小磁贴点击处理
    private func handleSmallTileTap(_ tile: TileData) {
        withAnimation(.easeInOut(duration: 0.15)) {
            switch tile.kind {
            case .vpn: selection = .vpn
            case .connection: selection = .dashboard
            case .proxy: selection = .proxy
            case .profile: selection = .profile
            case .transferReceive: selection = .transferReceive
            case .transferSend: selection = .transferSend
            case .logs: selection = .logs
            case .about: selection = .about
            case .speedtest: selection = .speedtest
            case .trace: selection = .trace
            case .purity: selection = .purity
            case .stop: stopAllServices()
            case .pause: break
            }
        }
    }

    private func stopAllServices() {
        vpnPauseTask?.cancel()
        vpnPauseTask = nil
        Task {
            await client.post("pause")
            try? await Task.sleep(for: .milliseconds(300))
            await client.post("disconnect")
        }
    }

    private func toggleVPNPause() {
        if client.isPauseOn {
            vpnPauseTask?.cancel()
            vpnPauseTask = nil
            Task {
                await client.post("resume")
                await client.post("connect")
            }
            return
        }

        vpnPauseTask?.cancel()
        let duration = Duration.seconds(client.pauseMinutes * 60)
        vpnPauseTask = Task {
            await client.post("pause")
            await client.post("disconnect")
            do {
                try await Task.sleep(for: duration)
                guard !Task.isCancelled else { return }
                await client.post("resume")
                await client.post("connect")
            } catch {
                // Manual resume or stop cancels the scheduled reconnect.
            }
            vpnPauseTask = nil
        }
    }

    // MARK: 各类型磁贴

    // --- 暂停磁贴 ---
    private func pauseTile(_ tile: TileData) -> some View {
        actionTile(
            tile: tile,
            icon: tile.kind.icon,
            color: tile.kind.activeColor,
            subtitle: "\(client.pauseMinutes)分钟",
            actionLabel: "执行"
        ) {
            // 与 VPN 磁贴的暂停按钮共用可取消的计时，手动继续/停止会取消到点重连。
            if !client.isPauseOn { toggleVPNPause() }
        }
    }

    // --- 停止磁贴（紧急停止：关闭守护 + 断开 WG）---
    private func stopTile(_ tile: TileData) -> some View {
        controlTile(
            tile: tile,
            icon: "stop.circle.fill",
            color: .red,
            subtitle: "全部关闭",
            isOn: false,
            toggleAction: stopAllServices,
            onTap: stopAllServices
        )
    }

    private func statItem(_ label: LocalizedStringKey, _ value: String, _ color: Color) -> some View {
        VStack(spacing: WgSpace.zero) {
            Text(label).font(.caption2).foregroundStyle(color)
            Text(value).font(.caption).fontWeight(.medium).monospacedDigit()
        }
    }

    private func formatSpeed(_ bytesPerSec: Int64?) -> String {
        guard let bps = bytesPerSec, bps > 0 else { return "0 B/s" }
        if bps < 1024 { return "\(bps) B/s" }
        if bps < 1024 * 1024 { return "\(bps / 1024) KB/s" }
        return String(format: "%.1f MB/s", Double(bps) / 1024.0 / 1024.0)
    }

    /// 中/大尺寸日志磁贴：显示滚动日志内容
    private func logContentTile(_ tile: TileData) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题栏
            HStack(spacing: WgSpace.s) {
                Image(systemName: "scroll")
                    .font(.system(size: tileSizeIcon(tile.size) - 4))
                    .foregroundStyle(.secondary)
                Text("日志")
                    .font(tile.size == .medium ? .body : .title3)
                    .fontWeight(.semibold)
                    .foregroundColor(.white.opacity(0.9))
                Spacer()

                // 条目数
                Text("\(client.logLines.count)条")
                    .font(.caption2).monospacedDigit()
                    .foregroundColor(Color(.tertiaryLabelColor))
            }
            .wgPadding(.bottom, .s)

            Divider().opacity(0.15)

            // 滚动日志区域
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: tile.size == .large) {
                    VStack(alignment: .leading, spacing: tile.size == .large ? WgSpace.xs : WgSpace.zero) {
                        ForEach(client.logLines) { line in
                            HStack(spacing: WgSpace.s) {
                                Circle()
                                    .fill(Color.gray.opacity(0.25))
                                    .frame(width: 4, height: 4)
                                    .wgPadding(.top, .xs)
                                Text(line.text)
                                    .font(.system(size: tile.size == .medium ? WgType.body : WgType.body))
                                    .foregroundColor(.white.opacity(0.55))
                                    .lineLimit(tile.size == .large ? 2 : 1)
                                    .id(line.id)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .wgPadding(.top, .s)
                    .wgPadding(.horizontal, .xs)
                }
                .onChange(of: client.logLines.count) { _, _ in
                    if let last = client.logLines.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .wgPadding(tilePadding(tile.size))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .wgTileSurface(isSelected: selection == .logs)
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) { selection = .logs }
        }
        .task {
            await client.fetchLogs(n: 30)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                await client.fetchLogs(n: 30)
            }
        }
        .modifier(EditShakeModifier(isShaking: isEditMode && draggedItem?.id != tile.id))
    }

    // MARK: - 通用控制卡片组件（带 Toggle）

    private func controlTile(
        tile: TileData, icon: String, color: Color,
        subtitle: LocalizedStringKey, isOn: Bool,
        toggleAction: @escaping () -> Void,
        onTap: @escaping () -> Void
    ) -> some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    Image(systemName: icon)
                        .font(.system(size: tileSizeIcon(tile.size), weight: .light))
                        .foregroundStyle(isOn ? color : .secondary.opacity(0.5))
                    Spacer()
                    if !isEditMode {
                        Toggle("", isOn: Binding.constant(isOn))
                            .labelsHidden()
                            .toggleStyle(PillToggleStyle(activeColor: color))
                            .fixedSize()
                            .allowsHitTesting(true)
                            .simultaneousGesture(TapGesture().onEnded { _ in toggleAction() })
                    }
                }
                if tile.size != .small { Divider().opacity(0.15) }
                VStack(alignment: .leading, spacing: WgSpace.zero) {
                    Text(tile.kind.title)
                        .font(tile.size == .small ? .subheadline : .body)
                        .fontWeight(.semibold)
                    Text(subtitle)
                        .font(tile.size == .small ? .caption2 : .caption)
                        .foregroundStyle(isOn ? color : .secondary)

                    // 中尺寸：显示状态摘要行
                    if tile.size == .medium {
                        HStack(spacing: WgSpace.s) {
                            Circle().fill(isOn ? color : Color.gray.opacity(0.3))
                                .frame(width: 6, height: 6)
                            Text(isOn ? "运行中" : "已停止")
                                .font(.system(size: WgType.body)).foregroundStyle(.secondary)
                            Spacer()
                        }
                    }

                    // 大尺寸留出底部空间给 VPN 磁贴叠加的动作按钮。
                    if tile.size == .large { Spacer().frame(height: 30) }
                }
            }
            .wgPadding(tilePadding(tile.size))
            .frame(maxWidth: .infinity, minHeight: tileMinHeight(tile.size), maxHeight: .infinity)
            .contentShape(RoundedRectangle(cornerRadius: WgTheme.cardRadius, style: .continuous))
            .wgTileSurface(tint: isOn ? color : nil)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 动作卡片组件（带执行按钮）

    private func actionTile(
        tile: TileData, icon: String, color: Color,
        subtitle: LocalizedStringKey, actionLabel: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Image(systemName: icon)
                    .font(.system(size: tileSizeIcon(tile.size), weight: .light))
                    .foregroundStyle(color)
                Spacer()
                if !isEditMode {
                    Button(action: action) {
                        Text(actionLabel)
                            .font(.caption2).fontWeight(.semibold)
                            .foregroundStyle(.white)
                            .wgPadding(.horizontal, .m).wgPadding(.vertical, .xs)
                            .background(color).clipShape(RoundedRectangle(cornerRadius: WgRadius.s, style: .continuous))
                    }.buttonStyle(.plain)
                }
            }
            if tile.size != .small { Divider().opacity(0.15) }
            VStack(alignment: .leading, spacing: WgSpace.zero) {
                Text(tile.kind.title)
                    .font(tile.size == .small ? .subheadline : .body)
                    .fontWeight(.semibold)
                Text(subtitle)
                    .font(tile.size == .small ? .caption2 : .caption)
                    .foregroundStyle(.secondary)

                // 中尺寸：显示快捷操作
                if tile.size == .medium {
                    HStack(spacing: WgSpace.s) {
                        Image(systemName: "clock").font(.system(size: WgType.body)).foregroundStyle(.tertiary)
                        Text("\(client.pauseMinutes)分钟")
                            .font(.system(size: WgType.body)).foregroundStyle(.secondary)
                        Spacer()
                    }
                }

                // 大尺寸：时长选择器
                if tile.size == .large {
                    HStack(spacing: WgSpace.s) {
                        Text("暂停时长:")
                            .font(.caption2).foregroundStyle(.tertiary)
                        Picker("", selection: $client.pauseMinutes) {
                            ForEach([1, 5, 10, 30, 60], id: \.self) { m in
                                Text("\(m) 分钟").tag(m)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 100)
                    }
                }
            }
        }
        .wgPadding(tilePadding(tile.size))
        .frame(maxWidth: .infinity, minHeight: actionTileMinHeight(tile.size), maxHeight: .infinity)
        .contentShape(RoundedRectangle(cornerRadius: WgTheme.cardRadius, style: .continuous))
        .background {
            if !isEditMode {
                Button(action: action) {
                    Color.clear
                        .contentShape(RoundedRectangle(cornerRadius: WgTheme.cardRadius, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .wgTileSurface(tint: color)
    }

    // MARK: - 尺寸辅助函数

    /// 图标大小
    private func tileSizeIcon(_ size: TileSize) -> CGFloat {
        switch size {
        case .small: return 20
        case .medium: return 26
        case .large: return 32
        }
    }

    /// 内边距
    private func tilePadding(_ size: TileSize) -> WgGap {
        switch size {
        case .small: return .m
        case .medium: return .m
        case .large: return .l
        }
    }

    /// 最小高度（control/action 磁贴）
    private func tileMinHeight(_ size: TileSize) -> CGFloat {
        switch size {
        case .small: return 0   // 由外层 tileCell 控制 (88)
        case .medium: return 0  // 由外层 tileCell 控制 (112)
        case .large: return 140
        }
    }

    /// 格式化网速（bytes/s → 可读字符串）
    private func formatSpeed(_ bytesPerSec: Double) -> String {
        let bps = bytesPerSec
        if bps < 1024 { return String(format: "%.0f B/s", bps) }
        if bps < 1024 * 1024 { return String(format: "%.1f KB/s", bps / 1024) }
        if bps < 1024 * 1024 * 1024 { return String(format: "%.1f MB/s", bps / (1024*1024)) }
        return String(format: "%.1f GB/s", bps / (1024*1024*1024))
    }

    private func formatSize(_ bytes: UInt64) -> String {
        let b = Double(bytes)
        if b < 1024 { return String(format: "%.0f B", b) }
        if b < 1024 * 1024 { return String(format: "%.1f KB", b / 1024) }
        if b < 1024 * 1024 * 1024 { return String(format: "%.1f MB", b / (1024*1024)) }
        return String(format: "%.2f GB", b / (1024*1024*1024))
    }

    /// actionTile 的最小高度
    private func actionTileMinHeight(_ size: TileSize) -> CGFloat {
        switch size {
        case .small: return 0
        case .medium: return 0
        case .large: return 130
        }
    }

    // MARK: - 编辑模式覆盖层

    @ViewBuilder
    private func editOverlay(_ tile: TileData) -> some View {
        HStack(spacing: WgSpace.xs) {
            // 删除按钮
            Button {
                withAnimation(.spring(response: 0.3)) {
                    tiles.removeAll { $0.id == tile.id }
                }
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: WgType.title))
                    .foregroundStyle(.red.opacity(0.75))
                    .background(Circle().fill(Color.black.opacity(0.4)))
            }.buttonStyle(.plain)

            // 尺寸切换按钮
            Button {
                withAnimation(.spring(response: 0.3)) {
                    let next: TileSize
                    switch tile.size {
                    case .small: next = .medium
                    case .medium: next = .large
                    case .large: next = .small
                    }
                    if let idx = tiles.firstIndex(where: { $0.id == tile.id }) {
                        tiles[idx].size = next
                    }
                }
            } label: {
                Image(systemName: tile.size == .large ? "arrow.down.left.and.arrow.up.right" : "arrow.up.right.and.arrow.down.left")
                    .font(.system(size: WgType.sub))
                    .foregroundStyle(.white.opacity(0.7))
                    .wgPadding(.xs)
                    .background(RoundedRectangle(cornerRadius: WgRadius.m).fill(.black.opacity(0.4)))
            }.buttonStyle(.plain)
        }
        .transition(.opacity.combined(with: .scale))
        .wgPadding(.s)
    }

    // MARK: - 磁贴网格（稳定身份、按实际宽度实时排版）

    private func tileGridContent(availableWidth: CGFloat, compact c: CGFloat) -> some View {
        let outerGap: WgGap = .m
        let outerPadding = outerGap.value
        let usableWidth = max(1, availableWidth - outerPadding * 2)
        let columnCount = GridGeometry.columns(usableWidth)
        let specs = tiles.map {
            GridItemSpec(span: $0.size == .small ? 1 : 2, height: Self.tileHeight($0.size, compact: c))
        }
        return VStack(spacing: 0) {
            RetainedGrid(specs: specs) {
                // One stable parent: moving to a different row preserves controls and tasks.
                ForEach(tiles) { tile in tileCell(tile, compact: c) }
            }
            .overlay { if UserDefaults.standard.bool(forKey: "WgSenseDebugBorders") { Rectangle().stroke(Color.green, lineWidth: 1) } }
            // 编辑栏只在完整形态出现（收缩时没有编辑这回事，也免得它的最小宽度把整列撑宽）
            if c == 0 {
                editFooter
                    .wgInset(.top, WgTheme.tileGap)
            }
        }
        .wgPadding(.horizontal, outerGap)
        .wgInset(.vertical, WgTheme.tileGap)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: tiles.map { $0.kind })
        .animation(.smooth(duration: 0.3), value: columnCount)
        // 空白处点击退出编辑
        .onTapGesture {
            if isEditMode {
                withAnimation(.spring(response: 0.35)) { isEditMode = false }
            }
        }
        // 磁贴 Popover 菜单
        .popover(item: $contextMenuTile) { tile in
            tileMenuPopover(tile)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: tiles.map(\.size))
    }

    @ViewBuilder
    private var editFooter: some View {
        // 非编辑态不放任何提示：编辑入口在头部，底部保持干净。
        if isEditMode {
            HStack(spacing: WgSpace.s) {
                Button { showAddSheet = true } label: {
                    Label("添加磁贴", systemImage: "plus")
                }
                .buttonStyle(WgCapsuleButtonStyle(tint: WgInk.signal, prominent: false))

                Spacer(minLength: 8)

                Button("完成") {
                    withAnimation(WgDesign.spring) { isEditMode = false }
                }
                .buttonStyle(WgCapsuleButtonStyle(tint: WgInk.signal))
            }
            .wgPadding(.top, .xs)
        }
    }

    /// 单个磁贴单元格（三种尺寸模式各自固定物理尺寸）
    @ViewBuilder
    /// 磁贴高度：完整形态按尺寸，收缩时连续降到图标方块的 40。
    static func tileHeight(_ size: TileSize, compact c: CGFloat) -> CGFloat {
        let full = size == .large ? WgTheme.tileY * 2 + WgTheme.tileGap : WgTheme.tileY
        return full + (40 - full) * c
    }

    /// 一块磁贴：完整内容随收缩程度淡出（大约收到一半就看不见，窄到装不下之前已经淡掉），
    /// 图标方块从中浮现，最窄时只剩它。两层同在一格里，所以拖动分隔线时是连续变化。
    private func tileCell(_ tile: TileData, compact c: CGFloat) -> some View {
        ZStack {
            if c < 0.5 {
                cellBody(tile)
                    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .opacity(Double(1 - c * 2))
            }
            if c > 0.3 {
                compactIcon(tile)
                    .opacity(Double(min(1, (c - 0.3) / 0.4)))
            }
        }
        // minWidth 0：磁贴内容比列宽还宽时不许撑开格子，否则图标跟着居中右移、被分隔线切掉
        .frame(minWidth: 0, maxWidth: .infinity).frame(height: Self.tileHeight(tile.size, compact: c))
        .overlay { if UserDefaults.standard.bool(forKey: "WgSenseDebugBorders") { Rectangle().stroke(Color.red, lineWidth: 1) } }
        .clipShape(RoundedRectangle(cornerRadius: WgTheme.cardRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: WgTheme.cardRadius, style: .continuous))
        .contextMenu { tileContextMenu(tile) }
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 1.5).onEnded { _ in
                    contextMenuTile = tile
                    contextMenuAnchor = CGPoint(x: 100, y: 50)
                }
            )
    }

    /// 单元格内部内容（编辑/正常双模式）
    @ViewBuilder
    private func cellBody(_ tile: TileData) -> some View {
        if isEditMode {
            TileDragContainer(
                tile: tile,
                isEditMode: true,
                isBeingDragged: draggedItem?.id == tile.id
            ) {
                tileContent(tile)
            }
            .contentShape(Rectangle())
            .onDrag {
                draggedItem = tile
                return NSItemProvider(object: "\(tileIndex(tile))" as NSString)
            }
            .dropDestination(for: String.self) { _, _ in
                guard let dropped = draggedItem,
                      let srcIdx = tiles.firstIndex(where: { $0.id == dropped.id }),
                      let dstIdx = tiles.firstIndex(where: { $0.id == tile.id }),
                      srcIdx != dstIdx else {
                    draggedItem = nil
                    return false
                }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                    tiles.move(fromOffsets: IndexSet(integer: srcIdx),
                               toOffset: dstIdx > srcIdx ? dstIdx + 1 : dstIdx)
                }
                draggedItem = nil
                return true
            }
        } else {
            // 正常模式：纯 SwiftUI 视图，不用 NSViewRepresentable 包裹（避免破坏 HStack 均分）
            TileDragContainer(
                tile: tile,
                isEditMode: false,
                isBeingDragged: false
            ) {
                tileContent(tile)
            }
        }
    }

    /// 磁贴右键菜单内容（三档尺寸）
    @ViewBuilder
    private func tileContextMenu(_ tile: TileData) -> some View {
        if tile.size != .small {
            Button { resizeTile(tile, to: .small) }
            label: { Label("小 (1 格)", systemImage: "square") }
        }
        if tile.size != .medium {
            Button { resizeTile(tile, to: .medium) }
            label: { Label("中 (2 格)", systemImage: "rectangle") }
        }
        if tile.size != .large {
            Button { resizeTile(tile, to: .large) }
            label: { Label("大 (4 格)", systemImage: "rectangle.3.groupfill") }
        }

        Divider()

        Button(role: .destructive) {
            withAnimation(.spring(response: 0.3)) {
                tiles.removeAll { $0.id == tile.id }
            }
        } label: { Label("移除磁贴", systemImage: "trash") }
    }

    /// 调整磁贴尺寸（带弹性动画）
    private func resizeTile(_ tile: TileData, to newSize: TileSize) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
            if let idx = tiles.firstIndex(where: { $0.id == tile.id }) {
                tiles[idx].size = newSize
            }
        }
    }

    /// 磁贴 Popover 菜单
    @ViewBuilder
    private func tileMenuPopover(_ tile: TileData) -> some View {
        VStack(spacing: 0) {
            if tile.size != .small {
                menuRow("小 (1 格)", icon: "square") { resizeTile(tile, to: .small); contextMenuTile = nil }
            }
            if tile.size != .medium {
                menuRow("中 (2 格)", icon: "rectangle") { resizeTile(tile, to: .medium); contextMenuTile = nil }
            }
            if tile.size != .large {
                menuRow("大 (4 格)", icon: "rectangle.3.groupfill") { resizeTile(tile, to: .large); contextMenuTile = nil }
            }
            Divider().wgPadding(.horizontal, .m)
            menuRow("移除磁贴", icon: "trash", destructive: true) {
                withAnimation(.spring(response: 0.3)) {
                    tiles.removeAll { $0.id == tile.id }
                }
                contextMenuTile = nil
            }
        }
        .wgPadding(.vertical, .xs)
        .frame(width: 170)
    }

    private func menuRow(_ title: LocalizedStringKey, icon: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: WgSpace.m) {
                Image(systemName: icon).font(.system(size: WgType.body))
                    .foregroundStyle(destructive ? .red : .primary)
                Text(title).font(.subheadline)
                    .foregroundStyle(destructive ? .red : .primary)
                Spacer()
            }
            .wgPadding(.horizontal, .m)
            .wgPadding(.vertical, .s)
            .background(destructive ? Color.red.opacity(0.08) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: WgRadius.s))
        }
        .buttonStyle(.plain)
    }

    func tileIndex(_ t: TileData) -> Int {
        tiles.firstIndex(where: { $0.id == t.id }) ?? 0
    }


}

// MARK: - 原生风格 Toggle 开关

/// iOS UISwitch 风格的开关组件（纯展示，点击由外层 Button 处理）
struct ToggleSwitch: View {
    let isOn: Bool
    var tintColor: Color = .green

    private let trackWidth: CGFloat = 44
    private let trackHeight: CGFloat = 26
    private let thumbSize: CGFloat = 22
    private let padding: CGFloat = 2

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            // 轨道背景
            RoundedRectangle(cornerRadius: WgRadius.s, style: .continuous)
                .fill(isOn ? tintColor.opacity(0.3) : Color.gray.opacity(0.25))
                .frame(width: trackWidth, height: trackHeight)

            // 圆形滑块（thumb）
            Circle()
                .fill(.white)
                .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
                .frame(width: thumbSize, height: thumbSize)
                .wgInset(padding)
        }
        .animation(.easeInOut(duration: 0.22), value: isOn)
    }
}

// MARK: - 全局 Liquid Glass 动作播报

struct ActionToastView: View {
    let toast: DaemonClient.ActionToast

    var body: some View {
        toastContent
            .frame(width: 360)
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
    }

    private var toastContent: some View {
        HStack(spacing: WgSpace.m) {
            Image(systemName: toast.symbol)
                .font(.system(size: WgType.body, weight: .semibold))
                .foregroundStyle(toast.tint)
                .frame(width: 30, height: 30)
                .background(Circle().fill(toast.tint.opacity(0.16)))

            VStack(alignment: .leading, spacing: WgSpace.zero) {
                Text(toast.title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(toast.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .wgPadding(.horizontal, .l)
        .wgPadding(.vertical, .m)
        .modifier(LiquidGlassToastSurface(tint: toast.tint))
    }
}

private struct LiquidGlassToastSurface: ViewModifier {
    let tint: Color

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: WgSpace.m) {
                content
                    .glassEffect(.regular.tint(tint.opacity(0.16)).interactive(), in: .rect(cornerRadius: WgRadius.s))
                    .glassEffectTransition(.materialize)
                    .shadow(color: .black.opacity(0.20), radius: 22, y: 12)
            }
        } else {
            content
                .background {
                    RoundedRectangle(cornerRadius: WgRadius.s, style: .continuous)
                        .fill(.regularMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: WgRadius.s, style: .continuous)
                                .fill(tint.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: WgRadius.s, style: .continuous)
                                .stroke(.white.opacity(0.22), lineWidth: 0.75)
                        )
                        .shadow(color: .black.opacity(0.20), radius: 22, y: 12)
                }
        }
    }
}

// MARK: - iOS 抖动动画修饰器

struct EditShakeModifier: ViewModifier {
    let isShaking: Bool
    @State private var rotation: Double = 0
    @State private var shakeTimer: Timer?

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(rotation))
            .onChange(of: isShaking) { _, newValue in
                if newValue {
                    startShaking()
                } else {
                    stopShaking()
                }
            }
            .onAppear {
                // 关键修复：如果初始就是 shaking 状态（编辑模式直接进入），onAppear 补充启动
                if isShaking && shakeTimer == nil {
                    startShaking()
                }
            }
            .onDisappear { stopShaking() }
    }

    func startShaking() {
        stopShaking()
        shakeTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [self] _ in
            withAnimation(.easeInOut(duration: 0.08)) {
                rotation = Double.random(in: -2...2)
            }
        }
    }

    func stopShaking() {
        shakeTimer?.invalidate()
        shakeTimer = nil
        withAnimation(.linear(duration: 0.15)) { rotation = 0 }
    }
}

// MARK: - macOS 触控板重按（Force Press）容器
/// 将 ForcePressNSView 作为底层容器接收压力事件，SwiftUI 内容作为 NSHostingView 子视图
/// 解决 background/overlay 方式 NSView 无法正确接收触控板压力事件的问题
struct ForcePressContainer<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        ForcePressNSViewRepresentable(action: action, content: content())
    }
}

private struct ForcePressNSViewRepresentable<Content: View>: NSViewRepresentable {
    let action: () -> Void
    let content: Content

    func makeNSView(context: Context) -> NSView {
        let containerView = ForcePressContainerNSView()
        containerView.action = action

        let hostingView = NSHostingView(rootView: content)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(hostingView)

        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: containerView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
        ])

        return containerView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let container = nsView as? ForcePressContainerNSView,
              let hosting = container.subviews.first as? NSHostingView<Content> else { return }
        hosting.rootView = content
    }
}

/// 轻量版 ForcePress NSView（无 Content 泛参，用于 overlay 层，不干扰布局）
private struct ForcePressOverlayNSView: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> ForcePressContainerNSView {
        let view = ForcePressContainerNSView()
        view.action = action
        return view
    }

    func updateNSView(_ nsView: ForcePressContainerNSView, context: Context) {
        nsView.action = action
    }
}

/// 底层 NSView：接收触控板压力事件（深按/二段按），SwiftUI 内容在其上方正常交互
private class ForcePressContainerNSView: NSView {
    var action: () -> Void = {}
    private var hasFired = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // 配置深按（二段按）压力行为
        pressureConfiguration = .init(pressureBehavior: .primaryDeepClick)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func pressureChange(with event: NSEvent) {
        guard !hasFired else { return }
        if event.stage == 2 {
            // stage == 2 = 二段按压（用力深按）
            hasFired = true
            action()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.hasFired = false
            }
        }
    }
}

// MARK: - 药丸开关样式

struct PillToggleStyle: ToggleStyle {
    let activeColor: Color

    func makeBody(configuration: Configuration) -> some View {
        RoundedRectangle(cornerRadius: WgRadius.s, style: .continuous)
            .fill(configuration.isOn ? activeColor : Color.secondary.opacity(0.35))
            .frame(width: 44, height: 24)
            .overlay(
                Circle()
                    .fill(.white).frame(width: 19, height: 19)
                    .shadow(color: .black.opacity(0.15), radius: 1, x: 0, y: 0.5)
                    .offset(x: configuration.isOn ? 11.5 : -11.5)
            )
            .animation(.spring(response: 0.25, dampingFraction: 0.85), value: configuration.isOn)
            .onTapGesture {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) { configuration.isOn.toggle() }
            }
    }
}

// MARK: - 添加磁贴 Sheet

struct AddTileSheet: View {
    let existingKinds: [TileKind]
    let onSelect: (TileKind) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("添加磁贴").font(.headline).fontWeight(.semibold)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }
            .padding()

            Divider().opacity(0.3)

            let available = TileKind.allCases.filter { $0.isAddable && !existingKinds.contains($0) }
            if available.isEmpty {
                Text("所有磁贴已添加").foregroundColor(.secondary).padding()
            } else {
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: WgSpace.m) {
                    ForEach(available) { kind in
                        Button { onSelect(kind) } label: {
                            VStack(spacing: WgSpace.s) {
                                Image(systemName: kind.icon)
                                    .font(.system(size: WgType.large))
                                    .foregroundStyle(kind.activeColor)
                                Text(kind.title).font(.subheadline).fontWeight(.medium)
                            }
                            .frame(maxWidth: .infinity)
                            .wgPadding(.l)
                            .wgGlassSurface(cornerRadius: WgTheme.controlRadius, tint: kind.activeColor, interactive: true)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
        }
        .frame(width: 320, height: availableKinds.isEmpty ? 200 : nil)
        .wgPadding(.bottom, .s)
        .background {
            RoundedRectangle(cornerRadius: WgTheme.floatingRadius, style: .continuous)
                .fill(.regularMaterial)
                .ignoresSafeArea()
        }
    }

    private var availableKinds: [TileKind] {
        TileKind.allCases.filter { $0.isAddable && !existingKinds.contains($0) }
    }
}

// MARK: - 关于页

struct AboutView: View {
    @EnvironmentObject var client: DaemonClient

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    var body: some View {
        WgPage(title: "关于", word: "ABOUT") {
            VStack(spacing: WgSpace.m) {
                WgBrandIcon()
                    .frame(width: 88, height: 88)
                Text("WgSense")
                    .font(.system(size: WgType.readout, weight: .bold))
                Text(verbatim: "版本 \(version)（\(build)）")
                    .font(.system(size: WgType.sub))
                    .foregroundStyle(.secondary)
                Text("在家自动断开，出门自动连上的 WireGuard 客户端")
                    .font(.system(size: WgType.body))
                    .foregroundStyle(.secondary)
                    .wgPadding(.top, .zero)
            }
            .frame(maxWidth: .infinity)
            .wgPadding(.vertical, .xl)
            .wgInteractiveSurface(cornerRadius: WgDesign.heroRadius)

            WgSection(title: "运行") {
                WgRow(symbol: "server.rack", tint: client.status != nil ? .green : .gray, title: "后台服务") {
                    HStack(spacing: WgSpace.s) {
                        WgStatusDot(color: .green, isOn: client.status != nil)
                        WgValue(client.status == nil ? "未运行" : (client.status?.app_owned == true ? "临时服务" : "系统服务"))
                    }
                }
                WgRowDivider()
                WgRow(symbol: "lock.shield.fill", tint: client.isTunnelUp ? .green : .gray, title: "隧道") {
                    WgValue(client.isTunnelUp ? "已连接" : "未连接")
                }
                WgRowDivider()
                WgRow(symbol: "doc.text.fill", tint: .orange, title: "当前配置") {
                    WgValue(client.status.map { $0.service.isEmpty ? "—" : $0.service } ?? "—")
                }
            }

            WgSection(title: "项目") {
                WgRow(symbol: "square.stack.3d.up.fill", tint: .indigo, title: "平台") {
                    WgValue("macOS · Windows · Linux · iOS · Android")
                }
                WgRowDivider()
                WgRow(symbol: "checkmark.seal.fill", tint: .green, title: "开源协议") {
                    WgValue("Apache-2.0")
                }
                WgRowDivider()
                WgRow(symbol: "chevron.left.forwardslash.chevron.right", tint: .gray, title: "源代码") {
                    Button {
                        if let url = URL(string: "https://github.com/Zichao-xu/WgSense") { NSWorkspace.shared.open(url) }
                    } label: { Label("GitHub", systemImage: "arrow.up.forward") }
                        .buttonStyle(WgPillButtonStyle())
                }
            }
        }
    }
}

// MARK: - 磁贴拖拽容器（编辑模式简化版，无内部按钮冲突）

struct TileDragContainer<Content: View>: View {
    let tile: TileData
    let isEditMode: Bool
    let isBeingDragged: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        if isEditMode {
            // 编辑模式：简化卡片（无内部 Button），确保拖拽不冲突
            simplifiedTile
                .opacity(isBeingDragged ? 0.35 : 1.0)
                .animation(.spring(response: 0.3), value: isBeingDragged)
                .modifier(EditShakeModifier(isShaking: true))
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: WgType.body, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .wgPadding(.m)
                }
        } else {
            // 正常模式：完整交互内容
            content()
        }
    }

    // 编辑模式下的简化卡片：与正常态同一套徽章，右上角是拖拽手柄。
    private var simplifiedTile: some View {
        HStack(spacing: WgSpace.m) {
            WgCircleBadge(symbol: tile.kind.icon, tint: tile.kind.activeColor, isOn: true, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(tile.kind.title)
                    .font(.system(size: WgType.body, weight: .semibold))
                Text(sizeLabel(tile.size))
                    .font(.system(size: WgType.body))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .wgPadding(.m)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: tile.size == .large ? .topLeading : .leading)
        .wgInteractiveSurface()
    }

    private func sizeLabel(_ size: TileSize) -> String {
        switch size {
        case .small: return "小"
        case .medium: return "中"
        case .large: return "大"
        }
    }
}

extension Notification.Name {
    static let wgsenseDeleteProfile = Notification.Name("wgsenseDeleteProfile")
}

// MARK: - 接收页（独立视图）
struct TransferReceiveView: View {
    @EnvironmentObject var client: DaemonClient
    @State private var togglingReceive = false
    @State private var resolvingRequestID: String?
    @State private var startingDaemon = false

    var body: some View {
        WgPage(title: "接收", subtitle: "兼容 LocalSend，隧道内的设备可以直接把文件发到这台 Mac", word: "RECEIVE") {
            if let state = client.transferState {
                HStack(spacing: WgSpace.s) {
                    if togglingReceive { ProgressView().controlSize(.small) }
                    Text(state.running ? "接收已开启" : "接收已关闭")
                        .font(.system(size: WgType.sub))
                        .foregroundStyle(.secondary)
                    Toggle("", isOn: Binding(
                        get: { client.transferState?.running ?? false },
                        set: { enabled in
                            Task {
                                togglingReceive = true
                                let ok = await client.setTransferReceiveEnabled(enabled)
                                if !ok { await client.fetchTransferState() }
                                togglingReceive = false
                            }
                        }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(togglingReceive)
                }
            }
        } content: {
            if let state = client.transferState {
                WgSection(title: "本机") {
                    WgRow(symbol: "desktopcomputer", tint: .blue, title: "设备名",
                          subtitle: Text("对方在 LocalSend 里看到的名字")) {
                        WgValue(state.alias)
                    }
                    WgRowDivider()
                    WgRow(symbol: "number", tint: .gray, title: "端口") {
                        WgValue("\(state.port)", monospaced: true)
                    }
                    WgRowDivider()
                    WgRow(symbol: "folder.fill", tint: .blue, title: "保存到") {
                        HStack(spacing: WgSpace.s) {
                            WgValue(state.downloads)
                            Button {
                                NSWorkspace.shared.open(URL(fileURLWithPath: state.downloads))
                            } label: { Image(systemName: "arrow.up.forward.square") }
                                .buttonStyle(WgToolbarIconButtonStyle())
                                .help("在访达中打开")
                        }
                    }
                }
            } else {
                WgSection(title: nil) {
                    WgRow(symbol: client.transferError == nil ? "hourglass" : "exclamationmark.triangle.fill",
                          tint: client.transferError == nil ? .gray : .orange,
                          title: LocalizedStringKey(client.transferError ?? "正在连接后台服务…")) {
                        if client.transferError != nil {
                            Button {
                                Task {
                                    startingDaemon = true
                                    _ = await client.startDaemonForTransfer()
                                    startingDaemon = false
                                }
                            } label: {
                                Text(LocalizedStringKey(startingDaemon ? "正在启动…" : "启动后台服务"))
                            }
                            .buttonStyle(WgCapsuleButtonStyle(tint: WgInk.signal))
                            .disabled(startingDaemon)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: WgSpace.s) {
                HStack(spacing: WgSpace.s) {
                    Text("待确认")
                        .font(.system(size: WgType.sub, weight: .semibold))
                        .foregroundStyle(.secondary)
                    if let count = client.transferState?.pending.count, count > 0 {
                        Text("\(count)")
                            .font(.system(size: WgType.body, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .wgPadding(.horizontal, .s).wgInset(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: WgRadius.s, style: .continuous).fill(Color.orange))
                    }
                }
                .wgPadding(.leading, .xs)
                if let pending = client.transferState?.pending, !pending.isEmpty {
                    ForEach(pending) { pendingRequestRow($0) }
                } else {
                    HStack(spacing: WgSpace.m) {
                        Image(systemName: "tray")
                            .font(.system(size: WgType.title))
                            .foregroundStyle(.tertiary)
                        Text("暂无待确认的传输")
                            .font(.system(size: WgType.body))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .wgPadding(.horizontal, .l)
                    .frame(height: 52)
                    .wgInteractiveSurface(cornerRadius: WgDesign.cardRadius)
                }
            }

            if let active = client.transferState?.active, !active.isEmpty {
                VStack(alignment: .leading, spacing: WgSpace.s) {
                    sectionLabel("接收中")
                    ForEach(active) { activeTransferRow($0) }
                }
            }

            if let history = client.transferState?.history, !history.isEmpty {
                VStack(alignment: .leading, spacing: WgSpace.s) {
                    sectionLabel("最近接收")
                    ForEach(Array(history.prefix(5))) { historyTransferRow($0) }
                }
            }
        }
        .task {
            while !Task.isCancelled {
                await client.fetchTransferState()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func sectionLabel(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.system(size: WgType.sub, weight: .semibold))
            .foregroundStyle(.secondary)
            .wgPadding(.leading, .xs)
    }

    private func receiveInfoRow(_ label: LocalizedStringKey, value: String) -> some View {
        VStack(alignment: .leading, spacing: WgSpace.xs) {
            Text(label).font(.caption).foregroundStyle(.tertiary)
            Text(value).font(.body.weight(.medium)).foregroundStyle(.primary)
        }
    }

    private func pendingRequestRow(_ request: DaemonClient.TransferPendingRequest) -> some View {
        HStack(spacing: WgSpace.l) {
            Image(systemName: "desktopcomputer.and.arrow.down")
                .font(.system(size: WgType.readout)).foregroundStyle(WgTheme.accent)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: WgSpace.xs) {
                Text(request.alias).font(.body.weight(.semibold))
                Text("\(request.files.count) 个文件 · \(formattedBytes(request.totalSize)) · \(request.ip)")
                    .font(.caption).foregroundStyle(.secondary)
                Text(request.files.prefix(3).map(\.name).joined(separator: "、"))
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer()
            if resolvingRequestID == request.id {
                ProgressView().controlSize(.small).frame(width: 72)
            } else {
                Button { resolve(request, accepted: false) } label: { Text("拒绝") }
                    .buttonStyle(WgCapsuleButtonStyle(tint: .red, prominent: false))
                Button { resolve(request, accepted: true) } label: { Text("接受") }
                    .buttonStyle(WgCapsuleButtonStyle(tint: WgInk.signal))
            }
        }
        .wgPadding(.l)
        .wgGlassSurface(tint: WgTheme.accent, interactive: true)
    }

    private func resolve(_ request: DaemonClient.TransferPendingRequest, accepted: Bool) {
        resolvingRequestID = request.id
        Task {
            _ = await client.resolveTransferRequest(request.id, accepted: accepted)
            resolvingRequestID = nil
        }
    }

    private func activeTransferRow(_ progress: DaemonClient.TransferFileProgress) -> some View {
        let total = max(progress.totalBytes, 1)
        let fraction = min(max(Double(progress.doneBytes) / Double(total), 0), 1)
        return VStack(alignment: .leading, spacing: WgSpace.s) {
            HStack {
                Image(systemName: "arrow.down.doc.fill").foregroundStyle(WgTheme.accent)
                VStack(alignment: .leading, spacing: WgSpace.zero) {
                    Text(progress.fileName).font(.body.weight(.medium)).lineLimit(1)
                    Text("来自 \(progress.sender) · \(progress.senderIP)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(Int(fraction * 100))%")
                    .font(.caption.monospacedDigit().weight(.medium)).foregroundStyle(.secondary)
            }
            ProgressView(value: fraction).animation(.easeOut(duration: 0.18), value: progress.doneBytes)
            HStack { Text(formattedBytes(progress.doneBytes)); Spacer(); Text(formattedBytes(progress.totalBytes)) }
                .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
        }
        .wgPadding(.l)
        .wgGlassSurface(tint: WgTheme.accent)
    }

    private func historyTransferRow(_ progress: DaemonClient.TransferFileProgress) -> some View {
        HStack(spacing: WgSpace.m) {
            Image(systemName: progress.status == "completed" ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(progress.status == "completed" ? .green : .orange)
            VStack(alignment: .leading, spacing: WgSpace.zero) {
                Text(progress.fileName).font(.callout.weight(.medium)).lineLimit(1)
                Text(progress.status == "completed"
                     ? "\(progress.sender) · \(formattedBytes(progress.doneBytes))"
                     : "\(progress.sender) · \(progress.error ?? "传输失败")")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(progress.status == "completed" ? "已完成" : "失败")
                .font(.caption.weight(.medium)).foregroundStyle(progress.status == "completed" ? .green : .orange)
        }
        .wgPadding(.horizontal, .l).wgPadding(.vertical, .m)
        .wgGlassSurface()
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - 发送页（独立视图）
struct TransferSendView: View {
    @EnvironmentObject var client: DaemonClient

    enum SendType: String, CaseIterable {
        case file, folder, text, clipboard
        static var supportedCases: [SendType] { [.file, .folder] }
        var icon: String {
            switch self { case .file: return "doc"; case .folder: return "folder"; case .text: return "text.bubble"; case .clipboard: return "clipboard" }
        }
        var label: LocalizedStringKey {
            switch self { case .file: return "文件"; case .folder: return "文件夹"; case .text: return "文本"; case .clipboard: return "剪贴板" }
        }
    }

    @State private var sendType: SendType? = nil
    @State private var showFilePicker = false
    @State private var showFolderPicker = false
    @State private var selectedDevice: DaemonClient.TransferDevice?
    @State private var isStartingSend = false
    @State private var lastSendResult: String?
    @State private var isScanning = false
    @State private var showAddDeviceSheet = false
    @State private var addDeviceAddr = ""
    @State private var startingDaemon = false

    var body: some View {
        WgPage(title: "发送", subtitle: "把文件发给隧道内运行 LocalSend 或 WgSense 的设备", word: "SEND") {
            HStack(spacing: WgSpace.zero) {
                if isScanning { ProgressView().controlSize(.small).wgPadding(.trailing, .s) }
                Button { Task { await refreshDevices() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(WgToolbarIconButtonStyle()).disabled(isScanning).help("刷新设备")
                Button { Task { await scanSubnetDevices() } } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(WgToolbarIconButtonStyle()).disabled(isScanning).help("扫描局域网设备")
                Button { showAddDeviceSheet = true } label: { Image(systemName: "plus") }
                    .buttonStyle(WgToolbarIconButtonStyle()).help("手动添加设备")
            }
        } content: {
            VStack(alignment: .leading, spacing: WgSpace.s) {
                sendSectionLabel("选择设备")
                if client.transferDevices.isEmpty && !isScanning {
                    deviceEmptyCard
                } else {
                    WgSection(title: nil) {
                        ForEach(client.transferDevices) { device in
                            sendDeviceRow(device)
                            if device.id != client.transferDevices.last?.id { WgRowDivider() }
                        }
                    }
                }
            }

            if let device = selectedDevice { selectedDeviceActions(device) }

            if let result = lastSendResult {
                Label(LocalizedStringKey(result),
                      systemImage: result.contains("失败") || result.contains("未") ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: WgType.sub))
                    .foregroundStyle(result.contains("失败") || result.contains("未") ? .orange : .green)
                    .wgPadding(.leading, .xs)
                    .transition(.opacity)
            }

            if let active = client.transferSendTasks?.active, !active.isEmpty {
                VStack(alignment: .leading, spacing: WgSpace.s) {
                    sendSectionLabel("发送中")
                    ForEach(active) { activeSendTaskRow($0) }
                }
            }
            if let history = client.transferSendTasks?.history, !history.isEmpty {
                VStack(alignment: .leading, spacing: WgSpace.s) {
                    sendSectionLabel("最近发送")
                    ForEach(Array(history.prefix(5))) { sendHistoryRow($0) }
                }
            }
        }
        .task {
            await loadInitialData()
            while !Task.isCancelled {
                await client.fetchTransferTasks()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.data, .image, .movie, .audio], allowsMultipleSelection: true) { handleFileSelection($0) }
        .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder], allowsMultipleSelection: false) { handleFileSelection($0) }
        .sheet(isPresented: $showAddDeviceSheet) { addDeviceSheet }
    }

    private func sendSectionLabel(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.system(size: WgType.sub, weight: .semibold))
            .foregroundStyle(.secondary)
            .wgPadding(.leading, .xs)
    }

    private var deviceEmptyCard: some View {
        VStack(spacing: WgSpace.m) {
            WgSquareBadge(symbol: "antenna.radiowaves.left.and.right", tint: .indigo, size: 44, dimmed: true)
            Text(LocalizedStringKey(client.transferError ?? "还没有发现设备"))
                .font(.system(size: WgType.title, weight: .semibold))
            Text(LocalizedStringKey(client.transferError == nil ? "点右上角的放大镜扫描，或用 + 手动添加隧道内设备的 IP" : "传输功能需要后台服务"))
                .font(.system(size: WgType.sub))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: WgSpace.s) {
                if client.transferError != nil {
                    Button {
                        Task {
                            startingDaemon = true
                            _ = await client.startDaemonForTransfer()
                            startingDaemon = false
                        }
                    } label: { Text(LocalizedStringKey(startingDaemon ? "正在启动…" : "启动后台服务")) }
                        .buttonStyle(WgCapsuleButtonStyle(tint: WgInk.signal))
                        .disabled(startingDaemon)
                } else {
                    Button { Task { await scanSubnetDevices() } } label: { Label("扫描", systemImage: "magnifyingglass") }
                        .buttonStyle(WgCapsuleButtonStyle(tint: WgInk.signal))
                        .disabled(isScanning)
                    Button { showAddDeviceSheet = true } label: { Label("手动添加", systemImage: "plus") }
                        .buttonStyle(WgPillButtonStyle())
                }
            }
            .wgPadding(.top, .s)
        }
        .frame(maxWidth: .infinity)
        .wgPadding(.xl)
        .wgInteractiveSurface(cornerRadius: WgDesign.cardRadius)
    }

    /// 选中设备后直接给出两个动作，省掉“先选类型再点发送”这一步。
    private func selectedDeviceActions(_ device: DaemonClient.TransferDevice) -> some View {
        HStack(spacing: WgSpace.m) {
            WgCircleBadge(symbol: "paperplane.fill", tint: WgInk.signal, isOn: true, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text("发送到 \(device.alias)")
                    .font(.system(size: WgType.body, weight: .semibold))
                if let ip = device.ip {
                    Text(verbatim: ip).font(.system(size: WgType.body)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                sendType = .folder
                triggerSend(target: device)
            } label: { Label("文件夹…", systemImage: "folder") }
                .buttonStyle(WgPillButtonStyle())
                .disabled(isStartingSend)
            Button {
                sendType = .file
                triggerSend(target: device)
            } label: { Label(isStartingSend ? "正在创建…" : "文件…", systemImage: "doc") }
                .buttonStyle(WgCapsuleButtonStyle(tint: WgInk.signal))
                .disabled(isStartingSend)
        }
        .wgPadding(.l)
        .wgInteractiveSurface(cornerRadius: WgDesign.cardRadius, isSelected: true)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: - 添加设备 Sheet
    private var addDeviceSheet: some View {
        VStack(spacing: WgSpace.m) {
            Text("添加设备").font(.headline.weight(.bold))
            Text("输入设备的 IP 地址（或 IP:端口）").font(.subheadline).foregroundStyle(.secondary)
            TextField("例如：192.168.200.5 或 192.168.200.5:53317", text: $addDeviceAddr).textFieldStyle(.roundedBorder).font(.body.monospaced()).autocorrectionDisabled()
            HStack(spacing: WgSpace.m) {
                Button("取消") { showAddDeviceSheet = false; addDeviceAddr = "" }.keyboardShortcut(.escape, modifiers: []).buttonStyle(.bordered)
                Button {
                    let addr = addDeviceAddr.trimmingCharacters(in: .whitespacesAndNewlines); guard !addr.isEmpty else { return }
                    Task {
                        if let _ = await client.addManualDevice(addr: addr) {
                            await MainActor.run { showAddDeviceSheet = false; addDeviceAddr = ""; lastSendResult = "设备已添加"; DispatchQueue.main.asyncAfter(deadline: .now() + 3) { lastSendResult = nil } }
                        } else { await MainActor.run { lastSendResult = "连接失败，检查地址后重试"; DispatchQueue.main.asyncAfter(deadline: .now() + 4) { lastSendResult = nil } } }
                    }
                } label: { Text("添加") }.buttonStyle(.borderedProminent).disabled(addDeviceAddr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("提示：确保目标设备已运行 LocalSend 或 WgSense").font(.caption2).foregroundStyle(.tertiary)
            Spacer()
        }.wgPadding(.xl).frame(width: 420, height: 280)
    }

    // MARK: - Actions
    private func loadInitialData() async {
        await client.fetchTransferState()
        await client.fetchTransferDevices(timeoutSec: 3)
        await client.fetchTransferTasks()
    }
    private func refreshDevices() async { isScanning = true; await client.fetchTransferDevices(timeoutSec: 5); try? await Task.sleep(for: .seconds(1)); isScanning = false }
    private func scanSubnetDevices() async { isScanning = true; let found = await client.scanSubnet(timeoutSec: 10); try? await Task.sleep(for: .seconds(1)); isScanning = false; if found.isEmpty { lastSendResult = "扫描完成，未发现 LocalSend 设备"; DispatchQueue.main.asyncAfter(deadline: .now() + 4) { lastSendResult = nil } } else { lastSendResult = "扫描发现 \(found.count) 个设备"; DispatchQueue.main.asyncAfter(deadline: .now() + 4) { lastSendResult = nil } } }
    private func selectSendType(_ type: SendType) { withAnimation(.easeInOut(duration: 0.15)) { sendType = type } }
    private func triggerSend(target: DaemonClient.TransferDevice) {
        guard sendType != nil else { return }
        if sendType == .file || sendType == .folder {
            if sendType == .file { showFilePicker = true } else { showFolderPicker = true }
            return
        }
        lastSendResult = "当前版本仅支持发送文件和文件夹"
    }

    private func handleFileSelection(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else {
            lastSendResult = "选择文件失败"
            return
        }
        guard let target = selectedDevice else { return }
        let paths = urls.map(\.path)
        guard !paths.isEmpty else {
            lastSendResult = "无法获取文件路径"
            return
        }

        isStartingSend = true
        lastSendResult = nil
        Task {
            let success = await client.startFileSend(to: target.id, paths: paths) != nil
            await MainActor.run {
                isStartingSend = false
                lastSendResult = success ? "等待对方确认" : "发送任务创建失败"
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { lastSendResult = nil }
            }
        }
    }

    private func activeSendTaskRow(_ task: DaemonClient.TransferSendTask) -> some View {
        let total = max(task.totalBytes, 1)
        let fraction = min(max(Double(task.doneBytes) / Double(total), 0), 1)
        return VStack(alignment: .leading, spacing: WgSpace.m) {
            HStack(spacing: WgSpace.m) {
                Image(systemName: task.status == "waiting" ? "person.crop.circle.badge.clock" : "paperplane.fill")
                    .font(.system(size: WgType.readout)).foregroundStyle(WgTheme.accent).frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: WgSpace.zero) {
                    Text(task.deviceAlias).font(.body.weight(.semibold))
                    Text(sendStatusLabel(task.status)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if task.status == "sending" {
                    Text("\(Int(fraction * 100))%").font(.caption.monospacedDigit().weight(.medium)).foregroundStyle(.secondary)
                }
                Button { Task { _ = await client.cancelTransfer(taskID: task.id) } } label: {
                    Image(systemName: "xmark.circle").frame(width: 24, height: 24)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).disabled(task.status == "cancelling").help("取消发送")
            }
            ProgressView(value: fraction).animation(.easeInOut(duration: 0.18), value: task.doneBytes)
            HStack {
                Text(task.files.prefix(3).map(\.name).joined(separator: "、")).lineLimit(1)
                Spacer()
                Text("\(formattedSendBytes(task.doneBytes)) / \(formattedSendBytes(task.totalBytes))").monospacedDigit()
            }
            .font(.caption2).foregroundStyle(.tertiary)
        }
        .wgPadding(.l)
        .wgGlassSurface(tint: WgTheme.accent, interactive: true)
    }

    private func sendHistoryRow(_ task: DaemonClient.TransferSendTask) -> some View {
        HStack(spacing: WgSpace.m) {
            Image(systemName: task.status == "completed" ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(task.status == "completed" ? .green : .orange)
            VStack(alignment: .leading, spacing: WgSpace.zero) {
                Text(task.deviceAlias).font(.callout.weight(.medium)).lineLimit(1)
                Text(task.status == "completed"
                     ? "\(task.completedFiles) 个文件 · \(formattedSendBytes(task.doneBytes))"
                     : task.error ?? sendStatusLabel(task.status))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(sendStatusLabel(task.status)).font(.caption.weight(.medium))
                .foregroundStyle(task.status == "completed" ? .green : .orange)
        }
        .wgPadding(.horizontal, .l).wgPadding(.vertical, .m)
        .wgGlassSurface()
    }

    private func sendStatusLabel(_ status: String) -> String {
        switch status {
        case "preparing": return "正在整理文件"
        case "waiting": return "等待对方确认"
        case "sending": return "发送中"
        case "cancelling": return "正在取消"
        case "completed": return "已完成"
        case "cancelled": return "已取消"
        case "failed": return "失败"
        default: return status
        }
    }

    private func formattedSendBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - 设备行
    private func sendDeviceRow(_ device: DaemonClient.TransferDevice) -> some View {
        let selected = selectedDevice?.id == device.id
        return HStack(spacing: WgSpace.m) {
            WgSquareBadge(symbol: iconForOS(device.deviceType ?? ""), tint: colorForOS(device.deviceType ?? ""), size: 28)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: WgSpace.s) {
                    Text(verbatim: device.alias).font(.system(size: WgType.body, weight: .medium))
                    Text(sourceBadgeLabel(device.source ?? "multicast"))
                        .font(.system(size: WgType.body, weight: .medium))
                        .foregroundStyle(.secondary)
                        .wgPadding(.horizontal, .xs).wgInset(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: WgRadius.s, style: .continuous).fill(Color.secondary.opacity(0.14)))
                }
                if let ip = device.ip {
                    Text(verbatim: ip).font(.system(size: WgType.body)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if device.source == "manual" {
                Button {
                    Task {
                        let ok = await client.removeManualDevice(deviceID: device.id)
                        if selectedDevice?.id == device.id { selectedDevice = nil }
                        lastSendResult = ok ? "设备已移除" : "只能移除手动添加的设备"
                    }
                } label: { Image(systemName: "trash") }
                    .buttonStyle(WgToolbarIconButtonStyle())
                    .help("移除此手动设备")
            }
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: WgType.title))
                .foregroundStyle(selected ? WgInk.signal : Color.secondary.opacity(0.4))
        }
        .wgPadding(.horizontal, .l)
        .wgPadding(.vertical, .s)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(WgDesign.spring) { selectedDevice = device } }
    }

    private func sourceBadgeLabel(_ source: String) -> String { switch source { case "manual": return "手动"; case "scan": return "扫描"; default: return "多播" } }
    private func colorForDeviceSource(_ source: String) -> Color { switch source { case "manual": return .orange; case "scan": return .blue; default: return .green } }
    private func iconForOS(_ dt: String) -> String { let d = dt.lowercased(); if d.contains("mac") || d.contains("ios") { return "desktopcomputer" }; if d.contains("android") { return "smartphone" }; if d.contains("windows") { return "pc" }; return "laptopcomputer" }
    private func colorForOS(_ dt: String) -> Color { let d = dt.lowercased(); if d.contains("mac") || d.contains("ios") { return .blue }; if d.contains("android") { return .green }; if d.contains("windows") { return .cyan }; return .purple }
}

// MARK: - 设置行组件
private struct SettingsToggleRow: View {
    let label: LocalizedStringKey
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Text(label).font(.body).foregroundStyle(.primary)
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(WgTheme.accent)
        }
        .wgPadding(.horizontal, .l).wgPadding(.vertical, .m)
        .overlay(alignment: .bottom) {
            Rectangle().fill(WgTheme.cardBorder.opacity(0.3)).frame(height: 0.5).wgPadding(.leading, .l)
        }
    }
}

private struct SettingsButtonRow: View {
    let label: LocalizedStringKey
    let value: String

    var body: some View {
        HStack {
            Text(label).font(.body).foregroundStyle(.primary)
            Spacer()
            Text(value).font(.body).foregroundStyle(.secondary)
        }
        .wgPadding(.horizontal, .l).wgPadding(.vertical, .m)
        .overlay(alignment: .bottom) {
            Rectangle().fill(WgTheme.cardBorder.opacity(0.3)).frame(height: 0.5).wgPadding(.leading, .l)
        }
    }
}

private struct SettingsNavRow: View {
    let label: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(label).font(.body).foregroundStyle(.primary)
                Spacer()
                Text("打开").font(.body).foregroundStyle(.secondary)
            }
            .wgPadding(.horizontal, .l).wgPadding(.vertical, .m)
            .overlay(alignment: .bottom) {
                Rectangle().fill(WgTheme.cardBorder.opacity(0.3)).frame(height: 0.5).wgPadding(.leading, .l)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Environment Key for DaemonClient

private struct DaemonClientKey: EnvironmentKey {
    @MainActor static let defaultValue = DaemonClient()
}

extension EnvironmentValues {
    var daemonClient: DaemonClient {
        get { self[DaemonClientKey.self] }
        set { self[DaemonClientKey.self] = newValue }
    }
}

// MARK: - Xcode Preview
#Preview("概览页") {
    MainView()
}

private extension Double {
    /// 0（从未存过的 UserDefaults 读回来的默认值）当作没有。
    var nonZero: Double? { self == 0 ? nil : self }
}
