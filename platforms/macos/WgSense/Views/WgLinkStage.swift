import SwiftUI
import QuartzCore

// Continuous, display-synchronised motion; event and pointer driven, idle clock paused.
enum WgHUDFocus: String, CaseIterable { case all, receive, send
    var title: String { switch self { case .all: return String(localized: "全部", bundle: .wgLocalized); case .receive: return String(localized: "接收", bundle: .wgLocalized); case .send: return String(localized: "发送", bundle: .wgLocalized) } }
}

struct WgLinkStage: View {
    var phase: WgLinkPhase
    @ObservedObject var monitor: WgLinkMonitor
    var frozenAt: Date?
    var frozenEntrance: Date?
    var frozenReduceMotion: Bool?
    var frozenPointer: CGPoint?
    var frozenSelection: WgHUDFocus?
    var frozenInteraction: Date?
    var onFrame: ((Date, Double) -> Void)?

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { frozenReduceMotion ?? systemReduceMotion }
    @StateObject private var displayClock = WgHUDDisplayClock()
    @State private var entrance: Date?
    @State private var pointer: CGPoint?
    @State private var pointerOrigin = CGPoint.zero
    @State private var pointerTarget = CGPoint.zero
    @State private var pointerAt: Date?
    @State private var focus = WgHUDFocus.all
    @State private var priorFocus = WgHUDFocus.all
    @State private var focusAt: Date?
    @State private var previousLevels: CGPoint?
    @State private var pinnedSample: Date?
    private var displayedFocus: WgHUDFocus { frozenSelection ?? focus }

    private var events: [Date?] { let s = monitor.snapshot; return [s.handshakeEvent, s.rebindEvent, s.alarmEvent, s.activityEvent, s.recoveryEvent, s.linkEvent, s.dataEvent] }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            interactiveStage.frame(minWidth: 600).frame(height: 340)
            interactiveStage.frame(minWidth: 340).frame(height: 440)
            narrowSummary
        }
        .clipped()
        .background { if frozenAt == nil { WgHUDClockBridge(clock: displayClock).allowsHitTesting(false) } }
        .transaction { $0.animation = nil }
        .accessibilityElement(children: .contain)
        .task(id: phase) {
            guard frozenAt == nil else { return }
            entrance = Date()
            if !reduceMotion && frozenAt == nil { displayClock.play() }
        }
        .onChange(of: events) { _, _ in if !reduceMotion && frozenAt == nil { displayClock.play() } }
        .onChange(of: CGPoint(x: monitor.snapshot.rxLevel, y: monitor.snapshot.txLevel)) { old, _ in previousLevels = old }
        .onChange(of: monitor.snapshot.history) { _, history in
            if let pinnedSample, !history.contains(where: { $0.at == pinnedSample }) { self.pinnedSample = nil }
        }
        .onChange(of: frozenPointer) { _, _ in if !reduceMotion && frozenAt == nil { displayClock.play() } }
        .onChange(of: reduceMotion) { _, value in
            if value { displayClock.stop() } else if frozenAt == nil { displayClock.play() }
        }
        .onDisappear { displayClock.stop() }
    }

    private var interactiveStage: some View {
        GeometryReader { geometry in
            stage(at: frozenAt ?? displayClock.now)
                .contentShape(Rectangle())
                .onContinuousHover { hover in
                    let now = Date()
                    pointerOrigin = pointerOffset(at: now)
                    switch hover {
                    case .active(let point):
                        pointer = point
                        pointerTarget = CGPoint(x: max(-1, min(1, (point.x / geometry.size.width - 0.5) * 2)),
                                                y: max(-1, min(1, (point.y / geometry.size.height - 0.5) * 2)))
                    case .ended: pointer = nil; pointerTarget = .zero
                    }
                    pointerAt = now
                    if !reduceMotion { displayClock.play(for: 0.65) }
                }
                .onTapGesture(coordinateSpace: .local) { point in
                    let compact = geometry.size.width < 600
                    if point.y >= (compact ? 357 : 260), point.y < (compact ? 406 : 306) {
                        if pinnedSample != nil { pinnedSample = nil }
                        else { pinnedSample = nearestSample(at: point, width: geometry.size.width)?.at }
                    } else if point.y > 62 && point.y < 237 {
                        let rail = compact ? geometry.size.width : geometry.size.width - 218
                        if point.x >= rail {
                            if point.y >= 90 && point.y <= 145 { select(.receive) }
                            if point.y >= 155 && point.y <= 212 { select(.send) }
                        } else {
                            let c = CGPoint(x: 22 + (rail - 32) * (compact ? 0.43 : 0.51), y: 151)
                            let scale = min(1, (rail - 32) / (compact ? 500 : 420))
                            let rxLength = (82 + 195 * CGFloat(monitor.snapshot.rxLevel) / 8) * scale
                            let txLength = (66 + 157 * CGFloat(monitor.snapshot.txLevel) / 8) * scale
                            func hit(_ offset: CGPoint, _ angle: Double, _ length: CGFloat, _ thickness: CGFloat) -> CGFloat? {
                                let dx = point.x - c.x - offset.x, dy = point.y - c.y - offset.y
                                let along = cos(angle) * dx + sin(angle) * dy
                                let across = abs(-sin(angle) * dx + cos(angle) * dy)
                                return abs(along) <= length / 2 + 8 && across <= thickness ? across : nil
                            }
                            let rx = hit(CGPoint(x: -7, y: -7), -0.31, rxLength, 23)
                            let tx = hit(CGPoint(x: 17, y: 8), 0.72, txLength, 16)
                            if rx != nil || tx != nil { select((rx ?? .infinity) <= (tx ?? .infinity) ? .receive : .send) }
                        }
                    } else if compact && point.y >= 267 && point.y <= 325 {
                        select(point.x < geometry.size.width / 2 ? .receive : .send)
                    }
                }
                .accessibilityLabel("链路舞台")
                .accessibilityValue(accessibilitySummary)
                .accessibilityAction(named: "查看全部") { select(.all) }
                .accessibilityAction(named: "聚焦接收") { select(.receive) }
                .accessibilityAction(named: "聚焦发送") { select(.send) }
                .help("移动指针感应构成，点击斜面聚焦收发；移到流量轨迹查看采样，点击可固定，再点解除。")
                .overlay(alignment: .bottomLeading) {
                    HStack(spacing: WgSpace.zero) {
                        ForEach(WgHUDFocus.allCases, id: \.rawValue) { item in
                            Button { select(item) } label: {
                                Text(item.title).font(.system(size: WgType.body, weight: displayedFocus == item ? .semibold : .regular))
                                    .wgPadding(.horizontal, .s).frame(height: 23)
                                    .background(displayedFocus == item ? Color.primary.opacity(0.12) : Color.clear)
                            }.buttonStyle(.plain).accessibilityAddTraits(displayedFocus == item ? .isSelected : [])
                                .help(item == .all ? String(localized: "显示完整收发构成", bundle: .wgLocalized) : String(localized: "聚焦", bundle: .wgLocalized) + item.title + String(localized: "，再次点击恢复全部", bundle: .wgLocalized))
                        }
                    }.wgPadding(.leading, .m).wgPadding(.bottom, .s)
                }
        }
    }

    private func select(_ next: WgHUDFocus) {
        priorFocus = focus
        focus = next == focus ? .all : next
        focusAt = Date()
        if !reduceMotion { displayClock.play(for: 0.85) }
    }

    private func pointerOffset(at date: Date) -> CGPoint {
        guard !reduceMotion else { return .zero }
        let p = WgHUDMotion.easeOutQuint(WgHUDMotion.progress(time: date, since: pointerAt, duration: 0.38))
        return CGPoint(x: pointerOrigin.x + (pointerTarget.x - pointerOrigin.x) * p,
                       y: pointerOrigin.y + (pointerTarget.y - pointerOrigin.y) * p)
    }

    private func nearestSample(at point: CGPoint, width: CGFloat) -> WgLinkSample? {
        guard let end = monitor.snapshot.history.last?.at else { return nil }
        let age = (1 - max(0, min(1, (point.x - 89) / max(1, width - 111)))) * 30
        return monitor.snapshot.history.min { abs(end.timeIntervalSince($0.at) - age) < abs(end.timeIntervalSince($1.at) - age) }
    }

    private var narrowSummary: some View {
        VStack(alignment: .leading, spacing: WgSpace.m) {
            Text("链路舞台").font(.system(size: WgType.body, weight: .semibold))
            Text(WgLinkComposition.status(phase: phase, snapshot: monitor.snapshot))
                .font(.system(size: WgType.body)).foregroundStyle(.secondary)
            if phase == .linked && monitor.snapshot.trafficAvailable {
                Text("接收 \(WgFormat.speed(monitor.snapshot.rxRate))")
                Text("发送 \(WgFormat.speed(monitor.snapshot.txRate))")
            }
            Text("加宽窗口可查看完整舞台").font(.system(size: WgType.body)).foregroundStyle(.secondary)
        }
        .font(.system(size: WgType.body, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
        .wgPadding(.l)
    }

    private func stage(at now: Date) -> some View {
        GeometryReader { geometry in
            let size = geometry.size
            let hover = frozenPointer ?? pointer
            let historyStart: CGFloat = size.width < 600 ? 357 : 260
            let historyEnd: CGFloat = size.width < 600 ? 406 : 306
            let hoveredSample = hover.flatMap { $0.y >= historyStart && $0.y < historyEnd ? nearestSample(at: $0, width: size.width) : nil }
            let inspection = pinnedSample.flatMap { stamp in monitor.snapshot.history.first { $0.at == stamp } } ?? hoveredSample
            let offset = frozenPointer.map { CGPoint(x: max(-1, min(1, ($0.x / size.width - 0.5) * 2)), y: max(-1, min(1, ($0.y / size.height - 0.5) * 2))) } ?? pointerOffset(at: now)
            ZStack {
                // Equatable boundary retains text, grid and historical data across animation ticks.
                WgHUDStaticLayer(phase: phase, snapshot: monitor.snapshot, dark: scheme == .dark,
                                 inspection: inspection, pinned: pinnedSample != nil,
                                 ground: .clear).equatable()
                Canvas { context, canvasSize in
                    let start = CACurrentMediaTime()
                    WgLinkComposition(size: canvasSize, phase: phase, now: now, s: monitor.snapshot,
                                      dark: scheme == .dark, reduceMotion: reduceMotion,
                                      entrance: frozenEntrance ?? entrance,
                                      pointer: reduceMotion ? .zero : offset,
                                      focus: frozenSelection ?? focus, priorFocus: priorFocus,
                                      focusAt: frozenInteraction ?? focusAt, previousLevels: previousLevels,
                                      inspection: inspection, pinned: pinnedSample != nil).drawMotion(in: &context)
                    onFrame?(Date(), CACurrentMediaTime() - start)
                }
                WgHUDStaticLayer(phase: phase, snapshot: monitor.snapshot, dark: scheme == .dark,
                                 inspection: nil, pinned: false, labelsOnly: true).equatable()
            }
        }
    }

    private var accessibilitySummary: String {
        let s = monitor.snapshot
        let title = WgLinkComposition.status(phase: phase, snapshot: s)
        guard phase == .linked else { return title }
        let rates = s.trafficAvailable
            ? String(localized: "，最近 30 秒平均接收 \(WgFormat.speed(s.rxRate))，发送 \(WgFormat.speed(s.txRate))", bundle: .wgLocalized)
            : String(localized: "，等待流量采样", bundle: .wgLocalized)
        return title + rates + String(localized: "，距上次握手 \(s.handshakeAge.map { String(localized: "\($0) 秒", bundle: .wgLocalized) } ?? String(localized: "未知", bundle: .wgLocalized))，本次观测最近一小时重绑 \(s.rebindsLastHour) 次", bundle: .wgLocalized)
    }
}

private struct WgHUDStaticLayer: View, Equatable {
    var phase: WgLinkPhase
    var snapshot: WgLinkSnapshot
    var dark: Bool
    var inspection: WgLinkSample?
    var pinned: Bool
    var labelsOnly = false
    /// 舞台底色。App 内传 .clear：外层已是与其他卡片相同的面板（wgInteractiveSurface），
    /// 画布再铺一层会叠成双倍不透明度。nil = 不透明原色（离线渲染用）。
    var ground: Color? = nil

    var body: some View {
        Canvas { context, size in
            let composition = WgLinkComposition(size: size, phase: phase, now: snapshot.lastDataAt ?? .distantPast,
                              s: snapshot, dark: dark, reduceMotion: true, entrance: nil,
                              inspection: inspection, pinned: pinned, groundFill: ground)
            if labelsOnly { composition.fixedAnnotations(&context) }
            else { composition.drawStatic(in: &context) }
        }.allowsHitTesting(false)
    }
}

/// 所有位置、颜色、帧函数均由快照决定，同一帧可离线复现。
private struct WgLinkComposition {
    var size: CGSize
    var phase: WgLinkPhase
    var now: Date
    var s: WgLinkSnapshot
    var dark: Bool
    var reduceMotion: Bool
    var entrance: Date?
    var pointer: CGPoint = .zero
    var focus: WgHUDFocus = .all
    var priorFocus: WgHUDFocus = .all
    var focusAt: Date?
    var previousLevels: CGPoint?
    var inspection: WgLinkSample?
    var pinned = false
    var groundFill: Color? = nil

    private var ink: Color { dark ? Color(white: 0.91) : Color(white: 0.12) }
    private var ground: Color { groundFill ?? opaqueGround }
    private var opaqueGround: Color { dark ? Color(red: 0.055, green: 0.061, blue: 0.07) : Color(red: 0.95, green: 0.955, blue: 0.96) }
    private var red: Color { dark ? Color(red: 1, green: 0.25, blue: 0.22) : Color(red: 0.77, green: 0.12, blue: 0.10) }
    private var amber: Color { dark ? Color(red: 0.95, green: 0.67, blue: 0.26) : Color(red: 0.56, green: 0.34, blue: 0.07) }
    private var linked: Bool { phase == .linked }
    private var alarm: WgLinkAlarm? { linked ? s.alarm : nil }
    private var accent: Color { alarm == .transmitStall ? red : (alarm == .unstable ? amber : ink) }
    private var rebindCount: String { s.rebindsLastHour > 99 ? "99+" : "\(s.rebindsLastHour)" }
    private var compact: Bool { size.width < 600 }
    private var railX: CGFloat { compact ? size.width : size.width - 218 }
    private var fieldWidth: CGFloat { railX - 32 }
    private var center: CGPoint { CGPoint(x: 22 + fieldWidth * (compact ? 0.43 : 0.51) + pointer.x * 6, y: 151 + pointer.y * 4) }
    private var radius: CGFloat { min(75, fieldWidth * 0.22) }
    private var scale: CGFloat { min(1, fieldWidth / (compact ? 500 : 420)) }
    private var entryFrame: Double { elapsed(entrance) * 24 }
    private var alarmFrame: Double { elapsed(s.alarmEvent) * 24 }
    private var alarmLanded: Bool { alarm != nil && (reduceMotion || alarmFrame >= 2) }

    static func status(phase: WgLinkPhase, snapshot s: WgLinkSnapshot) -> String {
        switch phase {
        case .home: return String(localized: "受信任网络 · 已自动断开", bundle: .wgLocalized)
        case .offline: return String(localized: "等待后台服务", bundle: .wgLocalized)
        case .idle: return String(localized: "隧道待命", bundle: .wgLocalized)
        case .connecting: return String(localized: "正在建立链路", bundle: .wgLocalized)
        case .linked:
            if s.alarm == .transmitStall { return String(localized: "发送疑似停滞", bundle: .wgLocalized) }
            if s.alarm == .unstable { return String(localized: "链路反复重绑", bundle: .wgLocalized) }
            return s.trafficAvailable ? String(localized: "链路遥测中", bundle: .wgLocalized) : String(localized: "等待遥测数据", bundle: .wgLocalized)
        }
    }

    func drawStatic(in g: inout GraphicsContext) {
        g.fill(Path(CGRect(origin: .zero, size: size)), with: .color(ground))
        framework(&g)
        header(&g)
        readings(&g)
        history(&g)
        footer(&g)
    }

    func drawMotion(in g: inout GraphicsContext) {
        var scene = g
        scene.opacity = reveal(after: 1, frames: 4)
        composition(&scene)
    }

    private func framework(_ g: inout GraphicsContext) {
        // 图纸坐标只提供尺度，不增加无意义的伪读数。
        for x in stride(from: CGFloat(24), through: railX - 10, by: 28) {
            for y in stride(from: CGFloat(70), through: 244, by: 28) {
                g.fill(Path(CGRect(x: x, y: y, width: 1, height: 1)), with: .color(ink.opacity(0.13)))
            }
        }
        stroke(&g, [(20, 48), (size.width - 20, 48)], ink.opacity(0.17))
        if !compact { stroke(&g, [(railX, 68), (railX, 241)], ink.opacity(0.15)) }
        stroke(&g, [(20, 257), (size.width - 20, 257)], ink.opacity(0.16))
        for (x, y, dx, dy) in [(CGFloat(20), CGFloat(66), CGFloat(1), CGFloat(1)),
                               (railX - 18, CGFloat(66), CGFloat(-1), CGFloat(1)),
                               (CGFloat(20), CGFloat(240), CGFloat(1), CGFloat(-1)),
                               (railX - 18, CGFloat(240), CGFloat(-1), CGFloat(-1))] {
            stroke(&g, [(x, y + dy * 9), (x, y), (x + dx * 9, y)], ink.opacity(0.4))
        }
    }

    private func header(_ g: inout GraphicsContext) {
        polygon(&g, [CGPoint(x: 20, y: 20), CGPoint(x: 28, y: 20), CGPoint(x: 32, y: 28), CGPoint(x: 24, y: 28)], ink)
        text(&g, String(localized: "链路舞台", bundle: .wgLocalized), 42, 24, 13, ink, weight: .semibold)
        if size.width >= 680 { text(&g, "W G S E N S E   /   T E L E M E T R Y", 116, 24, 8, ink.opacity(0.42), mono: true) }
        let title = Self.status(phase: phase, snapshot: s)
        text(&g, title, size.width - 20, 24, 11, accent.opacity(linked ? 1 : 0.68), anchor: .trailing)
    }

    private func composition(_ g: inout GraphicsContext) {
        let c = center, r = radius
        let interpolation = reduceMotion ? 1 : WgHUDMotion.spring(WgHUDMotion.progress(time: now, since: s.activityEvent, duration: 0.68))
        let rx = (previousLevels?.x ?? CGFloat(s.rxLevel)) + (CGFloat(s.rxLevel) - (previousLevels?.x ?? CGFloat(s.rxLevel))) * interpolation
        let tx = (previousLevels?.y ?? CGFloat(s.txLevel)) + (CGFloat(s.txLevel) - (previousLevels?.y ?? CGFloat(s.txLevel))) * interpolation
        let rxLength = (82 + 195 * rx / 8) * scale
        let txLength = (66 + 157 * tx / 8) * scale
        let liveData = linked && s.trafficAvailable
        let fade = linked ? 1.0 : 0.38
        var base = g
        // Every moving shape shares the record gutter exclusion, including high traffic,
        // pointer overshoot, rings and event arcs. Records are painted separately last.
        var geometryRegion = Path(CGRect(origin: .zero, size: size))
        geometryRegion.addRect(CGRect(x: railX - 107, y: 62, width: 88, height: 58))
        base.clip(to: geometryRegion, style: FillStyle(eoFill: true))
        // Brief anticipation before the warning plane springs into place.
        if alarmLanded {
            let settle = reduceMotion ? 0 : 9 * (1 - WgHUDMotion.spring(WgHUDMotion.progress(time: now, since: s.alarmEvent, duration: 0.72, delay: 2 / 24)))
            var warningPlane = base
            warningPlane.clip(to: Path(CGRect(x: 22, y: 62, width: railX - 134, height: 170)))
            let warningRight = railX - 112
            plane(&warningPlane, center: CGPoint(x: (22 + warningRight) / 2 + settle, y: c.y + 2), length: (warningRight - 46) * 0.94,
                  width: 106, angle: -0.28, color: accent.opacity(alarm == .transmitStall ? 0.94 : 0.20))
            for i in 0..<6 {
                let x = c.x + CGFloat(i * 9) - 18
                stroke(&base, [(x, 94), (x + 24, 71)], accent.opacity(0.7), 1)
            }
        }
        // 握手龄以环形 24 刻度表达；每档 4 刻度，不伪装网络拓扑。
        for i in 0..<24 {
            let a = Double(i) / 24 * .pi * 2 - .pi / 2
            let inner = r + (i % 3 == 0 ? 7.0 : 11.0)
            let outer = r + 15
            let arrival = reduceMotion ? 1 : WgHUDMotion.easeOutQuint(WgHUDMotion.progress(time: now, since: entrance, duration: 0.5, delay: Double(i) * 0.012))
            let filled = linked && i < max(0, min(24, s.freshness * 4))
            stroke(&base, [polar(c, inner, a), polar(c, outer, a)], ink.opacity((filled ? 0.7 : 0.15) * arrival), filled ? 1.6 : 0.8)
        }
        arc(&base, c, r, -192, -33, ink.opacity(0.27 * fade), 0.75)
        arc(&base, c, r + 22, 5, 92, ink.opacity(0.22 * fade), 0.75)
        arc(&base, c, r - 12, 84, 190, ink.opacity(0.14 * fade), 0.75)
        stroke(&base, [(c.x - r - 27, c.y), (c.x + r + 28, c.y)], ink.opacity(0.10))
        stroke(&base, [(c.x, c.y - r - 23), (c.x, c.y + r + 24)], ink.opacity(0.10))

        // 收发档位以连续弹簧插值衔接，浅色告警保留深色前景。
        let shapeInk = alarmLanded && alarm == .transmitStall && dark ? Color(white: 0.96) : ink
        blade(&base, center: CGPoint(x: c.x - 7, y: c.y - 7), length: (liveData ? rxLength : 122 * scale) * CGFloat(0.7 + 0.3 * reveal(after: 2, frames: 4)),
              width: 30 * scale, angle: -0.31 + pointer.y * 0.022, color: shapeInk.opacity((liveData ? 0.92 : fade) * emphasis(.receive)),
              filled: liveData, split: false)
        blade(&base, center: CGPoint(x: c.x + 17, y: c.y + 8), length: (liveData ? txLength : 95 * scale) * CGFloat(0.7 + 0.3 * reveal(after: 4, frames: 4)),
              width: 11 * scale, angle: 0.72 - pointer.x * 0.035, color: shapeInk.opacity((liveData ? 0.72 : fade) * emphasis(.send)),
              filled: liveData, split: alarmLanded && alarm == .transmitStall)
        // 平行细导轨与偏置短划，维持抽象构成的方向感。
        var parallel = base
        parallel.translateBy(x: c.x - 7, y: c.y - 7)
        parallel.rotate(by: .radians(-0.31))
        stroke(&parallel, [(-rxLength / 2, 23), (rxLength / 2, 23)], shapeInk.opacity(0.30 * fade))
        for i in 0..<8 {
            let x = -rxLength / 2 + CGFloat(i) * rxLength / 8
            stroke(&parallel, [(x, 23), (x, 27)], shapeInk.opacity(0.34 * fade))
        }
        polygon(&base, [CGPoint(x: c.x + r + 15, y: c.y - 9), CGPoint(x: c.x + r + 23, y: c.y - 9),
                       CGPoint(x: c.x + r + 15, y: c.y - 1)], accent.opacity(0.72 * fade))
        if (alarm == nil || alarmLanded) && (reduceMotion || entryFrame >= 5) {
            annotation(&base, String(localized: "接收", bundle: .wgLocalized), at: CGPoint(x: 34, y: 90), to: CGPoint(x: c.x - rxLength * 0.25, y: c.y - 33), trailing: false)
            annotation(&base, String(localized: "发送", bundle: .wgLocalized), at: CGPoint(x: railX - 35, y: 221), to: CGPoint(x: c.x + txLength * 0.26, y: c.y + 34), trailing: true)
        }
        if alarm != nil && alarmFrame >= 1 && alarmFrame < 2 && !reduceMotion {
            stroke(&base, [(c.x - 32, c.y + 64), (c.x + 35, c.y - 64)], accent, 3)
        }
        events(&base)
        rebindMarks(&g)
    }

    func fixedAnnotations(_ g: inout GraphicsContext) {
        text(&g, String(localized: "接收", bundle: .wgLocalized), 34, 90, 10, ink.opacity(0.66))
        text(&g, String(localized: "发送", bundle: .wgLocalized), railX - 35, 221, 10, ink.opacity(0.66), anchor: .trailing)
        let x = railX - 95, y: CGFloat = 84
        stroke(&g, [(x - 7, y - 18), (x - 7, y + 31), (x + 64, y + 31)], ink.opacity(0.18))
        text(&g, String(localized: "自愈记录", bundle: .wgLocalized), x + 59, y - 11, 8, ink.opacity(0.62), anchor: .trailing)
        // 相位说明位于安全的固定区域，永远不压住数据图例。
        let note: String
        switch phase {
        case .home: note = String(localized: "守护已接管 · 无需连接", bundle: .wgLocalized)
        case .offline: note = String(localized: "数据暂不可用", bundle: .wgLocalized)
        case .idle: note = String(localized: "等待下一次连接", bundle: .wgLocalized)
        case .connecting: note = String(localized: "等待握手确认", bundle: .wgLocalized)
        case .linked: note = alarmLanded ? (alarm == .transmitStall ? String(localized: "接收有增长 · 发送超过 35 秒未增长", bundle: .wgLocalized) : String(localized: "60 秒内至少 3 次重绑", bundle: .wgLocalized)) : String(localized: "长度 / 收发强度     刻度 / 握手新鲜度", bundle: .wgLocalized)
        }
        text(&g, note, 34, 244, 9, alarmLanded ? accent : ink.opacity(0.46))
    }

    private func rebindMarks(_ g: inout GraphicsContext) {
        guard entryFrame >= 8 || reduceMotion else { return }
        let x = railX - 95, y: CGFloat = 84
        // Animated marks only; their label and rule stay on the retained text layer.
        for i in 0..<12 {
            let origin = CGPoint(x: x + CGFloat(i % 6) * 10, y: y + CGFloat(i / 6) * 18)
            let isFilled = i < min(s.rebindsLastHour, 12)
            var alpha = isFilled ? 0.9 : 0.28
            if isFilled { alpha *= reduceMotion ? 1 : WgHUDMotion.easeOutQuint(WgHUDMotion.progress(time: now, since: s.rebindEvent, duration: 0.52, delay: Double(i % 6) * 0.045)) }
            stroke(&g, [(origin.x, origin.y + 10), (origin.x + 4, origin.y)], accent.opacity(alpha), isFilled ? 2.6 : 1)
        }
    }

    private func events(_ g: inout GraphicsContext) {
        guard !reduceMotion else { return }
        let c = center
        let handshake = WgHUDMotion.progress(time: now, since: s.handshakeEvent, duration: 1.10)
        if linked && handshake < 1 {
            let p = WgHUDMotion.easeOutQuint(handshake)
            arc(&g, c, radius + 7, -140 + p * 280, -106 + p * 280, ink.opacity(WgHUDMotion.pulse(handshake)), 1.8)
            let x = c.x - radius + 2 * radius * p
            stroke(&g, [(x, c.y - radius * 0.60), (x, c.y + radius * 0.60)], ink.opacity(0.36 * WgHUDMotion.pulse(handshake)), 0.8)
        }
        let activity = WgHUDMotion.progress(time: now, since: s.activityEvent, duration: 0.9)
        if linked && alarm == nil && activity < 1 {
            let p = WgHUDMotion.easeOutQuint(activity)
            arc(&g, c, radius - 5 + 16 * p, -50 + 18 * p, 55 + 35 * p, ink.opacity(WgHUDMotion.pulse(activity) * 0.48), 1)
        }
        let recovery = WgHUDMotion.progress(time: now, since: s.recoveryEvent, duration: 1.15)
        if linked && recovery < 1 {
            let p = WgHUDMotion.spring(recovery)
            let d = radius + 37 - 23 * p
            for sign in [CGFloat(-1), 1] {
                stroke(&g, [(c.x + sign * d, c.y - 12), (c.x + sign * (d - 8), c.y), (c.x + sign * d, c.y + 12)], ink.opacity(WgHUDMotion.pulse(recovery)), 1.5)
            }
        }
        let selection = WgHUDMotion.progress(time: now, since: focusAt, duration: 0.8)
        if selection < 1 {
            let p = WgHUDMotion.easeOutQuint(selection)
            arc(&g, c, radius - 15 + p * 18, -205 + p * 30, -45 + p * 100, ink.opacity(0.65 * WgHUDMotion.pulse(selection)), 1.2)
        }
        let entry = WgHUDMotion.progress(time: now, since: entrance, duration: 1.1)
        if phase == .connecting && entry < 1 {
            let p = WgHUDMotion.easeOutQuint(entry)
            arc(&g, c, radius - 6, -140 + p * 280, -98 + p * 280, ink.opacity(0.65 * WgHUDMotion.pulse(entry)), 1.7)
        }
    }

    private func emphasis(_ item: WgHUDFocus) -> Double {
        let old = priorFocus == .all || priorFocus == item ? 1.0 : 0.2
        let next = focus == .all || focus == item ? 1.0 : 0.2
        let p = reduceMotion ? 1 : WgHUDMotion.smoothstep(WgHUDMotion.progress(time: now, since: focusAt, duration: 0.42))
        return old + (next - old) * p
    }

    private func readings(_ g: inout GraphicsContext) {
        let available = linked && s.trafficAvailable
        if compact {
            let left: CGFloat = 22, right = size.width / 2 + 14
            text(&g, String(localized: "接收 · 30 秒平均", bundle: .wgLocalized), left, 274, 10, ink.opacity(0.55))
            text(&g, String(localized: "发送 · 30 秒平均", bundle: .wgLocalized), right, 274, 10, ink.opacity(0.55))
            readout(&g, available ? WgFormat.speed(s.rxRate) : "—", left, 297, emphasized: true, end: size.width / 2 - 18)
            readout(&g, available ? WgFormat.speed(s.txRate) : "—", right, 297, emphasized: false, end: size.width - 22)
            meter(&g, left, 319, level: available ? s.rxLevel : 0, color: ink.opacity(0.8), end: size.width / 2 - 18)
            meter(&g, right, 319, level: available ? s.txLevel : 0, color: alarm == .transmitStall ? red : ink.opacity(0.55), end: size.width - 22)
            text(&g, String(localized: "握手", bundle: .wgLocalized), left, 340, 10, ink.opacity(0.55))
            text(&g, linked ? (s.handshakeAge.map { $0 >= 86400 ? String(localized: "超过一天", bundle: .wgLocalized) : WgFormat.age($0) } ?? String(localized: "未采集", bundle: .wgLocalized)) : "—", left + 38, 340, 11, ink, mono: true)
            text(&g, String(localized: "重绑 \(rebindCount) 次 · 本次观测近 1 小时", bundle: .wgLocalized), size.width - 22, 340, 9, ink.opacity(0.55), anchor: .trailing)
            stroke(&g, [(22, 354), (size.width - 22, 354)], ink.opacity(0.13))
        } else {
            let x = railX + 22
            text(&g, String(localized: "30 秒平均", bundle: .wgLocalized), x, 72, 10, ink.opacity(0.5))
            text(&g, String(localized: "接收", bundle: .wgLocalized), x, 96, 10, ink.opacity(0.65))
            readout(&g, available ? WgFormat.speed(s.rxRate) : "—", x, 118, emphasized: true)
            meter(&g, x, 140, level: available ? s.rxLevel : 0, color: ink.opacity(0.8))
            text(&g, String(localized: "发送", bundle: .wgLocalized), x, 161, 10, ink.opacity(0.65))
            readout(&g, available ? WgFormat.speed(s.txRate) : "—", x, 182, emphasized: false)
            meter(&g, x, 204, level: available ? s.txLevel : 0, color: alarm == .transmitStall ? red : ink.opacity(0.55))
            stroke(&g, [(x, 218), (size.width - 22, 218)], ink.opacity(0.13))
            text(&g, String(localized: "握手", bundle: .wgLocalized), x, 237, 10, ink.opacity(0.55))
            text(&g, linked ? (s.handshakeAge.map { $0 >= 86400 ? String(localized: "超过一天", bundle: .wgLocalized) : WgFormat.age($0) } ?? String(localized: "未采集", bundle: .wgLocalized)) : "—", x + 37, 237, 11, ink, mono: true)
            text(&g, String(localized: "\(rebindCount) 次重绑", bundle: .wgLocalized), size.width - 22, 237, 10, s.rebindsLastHour > 0 ? accent : ink.opacity(0.55), anchor: .trailing)
        }
    }

    private func history(_ g: inout GraphicsContext) {
        let left: CGFloat = 22, right = size.width - 22, top: CGFloat = compact ? 371 : 275, mid: CGFloat = compact ? 385 : 289
        if let inspection, linked {
            let age = max(0, Int((s.history.last?.at ?? now).timeIntervalSince(inspection.at)))
            let detail = inspection.available ? String(localized: "\(age) 秒前  接收 \(WgFormat.speed(inspection.rxRate))  /  发送 \(WgFormat.speed(inspection.txRate))", bundle: .wgLocalized) : String(localized: "\(age) 秒前 · 此处没有有效采样", bundle: .wgLocalized)
            text(&g, detail, left, top - 6, 9, ink.opacity(0.84))
        } else {
            text(&g, String(localized: "流量轨迹", bundle: .wgLocalized), left, top - 6, 9, ink.opacity(0.52))
            text(&g, String(localized: "30 秒前", bundle: .wgLocalized), left + 65, top - 6, 8, ink.opacity(0.36), mono: true)
            text(&g, linked && s.trafficAvailable ? String(localized: "现在", bundle: .wgLocalized) : String(localized: "暂无采样", bundle: .wgLocalized), right, top - 6, 8, ink.opacity(0.50), anchor: .trailing)
        }
        let start = left + 67, width = right - start
        stroke(&g, [(start, mid), (right, mid)], ink.opacity(0.18))
        // 每秒一个位置；缺测留空，不拼接跨断线曲线。
        let end = s.history.last?.at ?? now
        for sample in s.history where sample.available && linked {
            let age = end.timeIntervalSince(sample.at)
            guard age >= 0, age <= 30 else { continue }
            let x = start + width * CGFloat(1 - age / 30)
            let barWidth = max(2, min(5, width / 80))
            let up = sample.rxRate > 0 ? 2 + CGFloat(sample.rxLevel) * 1.4 : 0
            let down = sample.txRate > 0 ? 1 + CGFloat(sample.txLevel) * 0.85 : 0
            if up == 0 && down == 0 {
                g.fill(Path(CGRect(x: x - 1, y: mid - 0.5, width: 1, height: 1)), with: .color(ink.opacity(0.45)))
            }
            g.fill(Path(CGRect(x: x - barWidth, y: mid - up, width: barWidth, height: up)), with: .color(ink.opacity(0.66)))
            g.fill(Path(CGRect(x: x - barWidth, y: mid + 2, width: barWidth, height: down)), with: .color(ink.opacity(0.29)))
        }
        if let inspection, linked {
            let age = end.timeIntervalSince(inspection.at)
            let x = start + width * CGFloat(1 - age / 30)
            stroke(&g, [(x, mid - 15), (x, mid + 13)], ink.opacity(0.8), 0.8)
            g.fill(Path(ellipseIn: CGRect(x: x - 2, y: mid - 2, width: 4, height: 4)), with: .color(ink))
        }
        for i in 0...6 {
            let x = start + width * CGFloat(i) / 6
            stroke(&g, [(x, top + 27), (x, top + 30)], ink.opacity(0.26))
        }
        text(&g, String(localized: "收 / 发", bundle: .wgLocalized), left, mid + 2, 8, ink.opacity(0.4))
    }

    private func footer(_ g: inout GraphicsContext) {
        let textValue: String
        if phase == .home { textValue = String(localized: "受信任网络中保持安静", bundle: .wgLocalized) }
        else if phase == .connecting { textValue = String(localized: "连接确认后开始记录", bundle: .wgLocalized) }
        else if phase != .linked { textValue = String(localized: "建立链路后恢复观测", bundle: .wgLocalized) }
        else if !s.trafficAvailable { textValue = String(localized: "等待新的有效采样", bundle: .wgLocalized) }
        else if alarm == .transmitStall { textValue = String(localized: "依据字节计数判断，正在等待发送恢复", bundle: .wgLocalized) }
        else if alarm == .unstable { textValue = String(localized: "检测到频繁自愈，继续观察链路", bundle: .wgLocalized) }
        else if let recovered = s.recoveryEvent, let sampled = s.lastDataAt,
                sampled.timeIntervalSince(recovered) >= 0 && sampled.timeIntervalSince(recovered) < 3 { textValue = String(localized: "遥测已恢复", bundle: .wgLocalized) }
        else { textValue = String(localized: "真实采样 · 事件触发", bundle: .wgLocalized) }
        let hint = pinned ? String(localized: "已固定采样 · 再点解除", bundle: .wgLocalized) : (compact ? String(localized: "移动感应 · 轨迹可探查", bundle: .wgLocalized) : textValue + String(localized: " · 移动感应 / 点击聚焦 / 探查轨迹", bundle: .wgLocalized))
        text(&g, hint, size.width - 22, compact ? 421 : 321, compact ? 8 : 9, alarm != nil ? accent : ink.opacity(0.51), anchor: .trailing)
    }

    // MARK: - 确定性绘图基元

    private func elapsed(_ event: Date?) -> Double {
        guard !reduceMotion, let event else { return 100 }
        return max(0, now.timeIntervalSince(event))
    }

    private func frame(_ event: Date?) -> Int? {
        guard !reduceMotion else { return nil }
        return WgLinkMonitor.frame(since: event, at: now)
    }

    private func reveal(after delay: Int, frames: Int) -> Double {
        guard !reduceMotion else { return 1 }
        return WgHUDMotion.easeOutQuint(WgHUDMotion.progress(time: now, since: entrance, duration: Double(frames) / 12 + 0.18, delay: Double(delay) / 30))
    }

    private func text(_ g: inout GraphicsContext, _ value: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat,
                      _ color: Color, weight: Font.Weight = .regular, mono: Bool = false, anchor: UnitPoint = .leading) {
        let label = Text(verbatim: value).font(.system(size: size, weight: weight, design: mono ? .monospaced : .default)).foregroundColor(color)
        g.draw(label, at: CGPoint(x: x, y: y), anchor: anchor)
    }

    private func readout(_ g: inout GraphicsContext, _ value: String, _ x: CGFloat, _ y: CGFloat, emphasized: Bool, end: CGFloat? = nil) {
        let parts = value.split(separator: " ", maxSplits: 1).map(String.init)
        text(&g, parts[0], x, y, emphasized ? 27 : 23, ink.opacity(emphasized ? 0.96 : 0.8), weight: .light, mono: true)
        if parts.count > 1 {
            text(&g, parts[1], end ?? size.width - 22, y + 4, 10, ink.opacity(0.47), mono: true, anchor: .trailing)
        }
    }

    private func meter(_ g: inout GraphicsContext, _ x: CGFloat, _ y: CGFloat, level: Int, color: Color, end: CGFloat? = nil) {
        let width = ((end ?? size.width - 22) - x - 7 * 4) / 8
        for i in 0..<8 {
            g.fill(Path(CGRect(x: x + CGFloat(i) * (width + 4), y: y, width: width, height: 3)),
                   with: .color(i < level ? color : ink.opacity(0.1)))
        }
    }

    private func annotation(_ g: inout GraphicsContext, _ label: String, at p: CGPoint, to end: CGPoint, trailing: Bool) {
        let direction: CGFloat = trailing ? -1 : 1
        stroke(&g, [(p.x, p.y + 10), (p.x + direction * 30, p.y + 10), (end.x, end.y)], ink.opacity(0.32))
        g.fill(Path(CGRect(x: end.x - 1, y: end.y - 1, width: 2, height: 2)), with: .color(ink.opacity(0.8)))
    }

    private func blade(_ g: inout GraphicsContext, center: CGPoint, length: CGFloat, width: CGFloat,
                       angle: Double, color: Color, filled: Bool, split: Bool) {
        var local = g
        local.translateBy(x: center.x, y: center.y)
        local.rotate(by: .radians(angle))
        let cuts: [(CGFloat, CGFloat, CGFloat)] = split ? [(-length / 2, length / 2 - 9, -5), (9, length / 2 - 9, 6)] : [(-length / 2, length, 0)]
        for (x, span, y) in cuts {
            let points = [CGPoint(x: x, y: y - width / 2), CGPoint(x: x + span - 8, y: y - width / 2),
                          CGPoint(x: x + span, y: y + width / 2), CGPoint(x: x + 8, y: y + width / 2)]
            let path = path(points)
            if filled { local.fill(path, with: .color(color)) }
            else { local.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 0.9, dash: phase == .connecting ? [4, 4] : [])) }
        }
    }

    private func plane(_ g: inout GraphicsContext, center: CGPoint, length: CGFloat, width: CGFloat, angle: Double, color: Color) {
        var local = g
        local.translateBy(x: center.x, y: center.y)
        local.rotate(by: .radians(angle))
        local.fill(Path(CGRect(x: -length / 2, y: -width / 2, width: length, height: width)), with: .color(color))
    }

    private func stroke(_ g: inout GraphicsContext, _ points: [(CGFloat, CGFloat)], _ color: Color, _ width: CGFloat = 0.7) {
        var path = Path()
        for (i, point) in points.enumerated() {
            if i == 0 { path.move(to: CGPoint(x: point.0, y: point.1)) }
            else { path.addLine(to: CGPoint(x: point.0, y: point.1)) }
        }
        g.stroke(path, with: .color(color), lineWidth: width)
    }

    private func polar(_ c: CGPoint, _ r: CGFloat, _ a: Double) -> (CGFloat, CGFloat) {
        (c.x + r * cos(a), c.y + r * sin(a))
    }

    private func arc(_ g: inout GraphicsContext, _ c: CGPoint, _ r: CGFloat, _ a: Double, _ b: Double, _ color: Color, _ width: CGFloat) {
        var p = Path()
        p.addArc(center: c, radius: r, startAngle: .degrees(a), endAngle: .degrees(b), clockwise: false)
        g.stroke(p, with: .color(color), lineWidth: width)
    }

    private func path(_ points: [CGPoint]) -> Path {
        var p = Path()
        for (i, point) in points.enumerated() { if i == 0 { p.move(to: point) } else { p.addLine(to: point) } }
        p.closeSubpath()
        return p
    }

    private func polygon(_ g: inout GraphicsContext, _ points: [CGPoint], _ color: Color) {
        g.fill(path(points), with: .color(color))
    }
}
