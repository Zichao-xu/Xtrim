import AppKit
import QuartzCore
import SwiftUI

// 无极滚动图表（O-G01…O-G05）。
//
// 横向：样本按时间戳定位，右边界 = 当前时间 − 延迟，曲线随时间连续左移，线头（记录笔）贴住右缘。
// 纵向：一台跟随笔头的“镜头”（ChartCamera）。取景只看笔头附近最近几秒的数据，
//      起伏大就拉远，起伏小就推近放大细节；比例尺只是镜头的读数，跟着镜头走。
//      （取景 2.5 秒：高峰一来，下沿在 1–2 秒内就离开 0 框住平台。）
//      更早的曲线不参与取景——被放大后冲出画面的旧尖峰在顶边截平，并标出峰值。
//      镜头移动有阻尼：扩大 0.35s，收小 0.7s，缓动先快后慢。
//
// 连续运动交给 Core Animation：纸带平移、曲线随镜头形变、笔头纵向运动都是系统动画，App 逐帧零开销。
// 只有纵轴读数在镜头移动期间以 20fps 重绘（几条刻度线 + 五个数字）。

// MARK: - 比例尺（镜头取景的数值区间）

struct PPChartScale: Hashable {
    var lo: Double
    var hi: Double

    func unit(_ v: Double) -> Double { (v - lo) / max(1e-9, hi - lo) }
    var span: Double { hi - lo }

    /// 三条刻度（底、中、顶）：够读数，又不把图表区画成格子纸。
    func ticks() -> [(value: Double, unit: Double)] {
        (0...2).map { i in (lo + Double(i) / 2 * span, Double(i) / 2) }
    }

    /// 读数用：按跨度的 1/20 取整（小幅变化时读数不变，不必每秒闪一次；也不会把 155–160 MB 全取成 160）。
    var rounded: PPChartScale {
        guard span > 0 else { return self }
        let q = pow(10, Foundation.floor(log10(span / 20)))
        return PPChartScale(lo: (lo / q).rounded() * q, hi: (hi / q).rounded() * q)
    }

    static func round2(_ v: Double) -> Double {
        guard v > 0 else { return 0 }
        var unit = 1.0
        while v / unit >= 1024 && unit < pow(1024, 4) { unit *= 1024 }
        let x = v / unit
        let mag = pow(10, Foundation.floor(log10(x)) - 1)
        return (x / mag).rounded() * mag * unit
    }

    static func lerp(_ a: PPChartScale, _ b: PPChartScale, _ t: Double) -> PPChartScale {
        PPChartScale(lo: a.lo + (b.lo - a.lo) * t, hi: a.hi + (b.hi - a.hi) * t)
    }
}

// MARK: - 镜头

/// 跟随笔头的纵向镜头：连续运动。
///
/// 每来一个样本记一个“目标取景点”，镜头的上下沿沿 Catmull-Rom 曲线穿过这些点连续移动（与曲线本身同一种平滑），
/// 不做“动一下—停—再动”的分段缓动（每秒一段会显得一抽一抽）。
/// 镜头整体滞后 lag 秒：目标取景用到了笔头尚未画到的最新样本，滞后正好让镜头与笔头同步——高峰滑到笔头时刚好被框住。
final class ChartCamera {
    private var points: [(t: TimeInterval, s: PPChartScale)] = []
    static let lag: TimeInterval = 1.2

    /// 最新目标（纵轴读数显示它：镜头正要去的位置）。
    var to: PPChartScale { points.last?.s ?? PPChartScale(lo: 0, hi: 1) }
    /// 镜头到达最新目标的时刻。
    var end: TimeInterval { (points.last?.t ?? 0) + Self.lag }
    func isMoving(at t: TimeInterval) -> Bool { t < end }

    func record(_ target: PPChartScale, now: TimeInterval) {
        if let last = points.last, now - last.t < 0.3 {
            points[points.count - 1] = (last.t, target)   // 同一次推送内重复求值：只更新，不新增点
        } else {
            points.append((now, target))
        }
        points.removeAll { now - $0.t > 12 }
    }

    func scale(at t: TimeInterval) -> PPChartScale {
        guard let first = points.first, let last = points.last else { return PPChartScale(lo: 0, hi: 1) }
        let q = t - Self.lag
        if q <= first.t { return first.s }
        if q >= last.t { return last.s }
        var i = 0
        while i < points.count - 2 && points[i + 1].t <= q { i += 1 }
        let p0 = points[max(0, i - 1)].s, p1 = points[i].s, p2 = points[i + 1].s, p3 = points[min(points.count - 1, i + 2)].s
        let u = (q - points[i].t) / max(0.001, points[i + 1].t - points[i].t)
        func cr(_ a: Double, _ b: Double, _ c: Double, _ d: Double) -> Double {
            let v = 0.5 * ((2 * b) + (-a + c) * u + (2 * a - 5 * b + 4 * c - d) * u * u + (-a + 3 * b - 3 * c + d) * u * u * u)
            return min(max(b, c), max(min(b, c), v))   // 夹在相邻两点之间，不过冲
        }
        return PPChartScale(lo: cr(p0.lo, p1.lo, p2.lo, p3.lo), hi: cr(p0.hi, p1.hi, p2.hi, p3.hi))
    }
}

// MARK: - 图表

struct PPStreamChart: View {
    struct Series {
        var name: LocalizedStringKey
        var color: Color
        /// 是否铺面积（主系列铺，次系列只描线，避免两层叠成一团）。
        var fill = true
        /// 虚线描边：单色体系里区分次系列的方式。
        var dashed = false
    }

    let title: LocalizedStringKey
    /// 图表代号（A1 / A2 …），显示在白色细框标签里。
    var code: String = ""
    @ObservedObject var buffer: PPSampleBuffer
    let series: [Series]
    let format: (Double) -> String
    var window: TimeInterval = 60
    /// 显示延迟：≥ 推送间隔（1s），保证右端总有样本可衔接。
    var delay: TimeInterval = 1.2
    /// 镜头最小取景跨度：再平静也不会推近到比这更细（避免把噪声放大成满屏起伏）。
    var floor: Double = 1

    @State private var paused = false
    @State private var camera = ChartCamera()
    @State private var hoverX: CGFloat?
    @State private var frozenAt: TimeInterval?

    static let gutter: CGFloat = 68     // 左侧纵轴刻度
    static let ruler: CGFloat = 16      // 底部时间尺
    /// 纸带比视窗多出的时长：左侧留出渐隐余量。
    static let tail: TimeInterval = 4
    /// 镜头取景：只盯笔头附近此刻的数据（往回 2.5 秒 ≈ 最近 2–3 个样本；推送是 1Hz，这是反应下限）。
    /// 更早的爬坡、旧尖峰冲出画面被裁掉。
    static let focus: TimeInterval = 2.5

    init(title: LocalizedStringKey, code: String = "", buffer: PPSampleBuffer, series: [Series], format: @escaping (Double) -> String,
         window: TimeInterval = 60, floor: Double = 1) {
        self.title = title
        self.code = code
        self.buffer = buffer
        self.series = series
        self.format = format
        self.window = window
        self.floor = floor
    }

    var body: some View {
        let samples = buffer.samples
        let now = frozenAt ?? Date().timeIntervalSince1970
        if frozenAt == nil, let latest = samples.last?.time { camera.record(focusScale(samples, now: now), now: latest) }
        return VStack(alignment: .leading, spacing: WgSpace.s) {
            header(values: samples.last?.values ?? [])
            GeometryReader { geo in
                let plot = CGRect(x: Self.gutter, y: 4, width: max(1, geo.size.width - Self.gutter - 2),
                                  height: max(1, geo.size.height - Self.ruler - 6))
                ZStack(alignment: .topLeading) {
                    // 纵轴读数标出镜头的目标取景：换取景时 0.25s 淡入淡出（最多每秒一次），曲线自己平滑形变过去。
                    // 不逐帧滚动数字：四张图 × 20fps 的文字排版比曲线动画还贵。
                    ZStack {
                        PPChartAxis(scale: camera.to.rounded, format: format, window: window, size: geo.size, plot: plot)
                            .equatable()
                            .id(camera.to.rounded)
                            .transition(.opacity)
                    }
                    .animation(.easeInOut(duration: 0.4), value: camera.to.rounded)
                    PPChartTape(samples: samples, version: buffer.version, camera: camera, cameraEnd: camera.end,
                                series: series, format: format, plot: plot, window: window, delay: delay, frozenAt: frozenAt)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .allowsHitTesting(false)
                    if let hx = hoverX, hx >= plot.minX, let at = frozenAt {
                        hoverLayer(hx: hx, now: at, scale: camera.scale(at: at), plot: plot, samples: samples)
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        if hoverX == nil && !paused { frozenAt = Date().timeIntervalSince1970 }
                        hoverX = location.x
                    case .ended:
                        hoverX = nil
                        if !paused { frozenAt = nil }
                    }
                }
            }
            // 绘图区高度走档位；标题行按内容自然撑开，总高 = 两者之和，外面不再套固定高度。
            .frame(height: WgLayout.chartPlot)
        }
    }

    /// 镜头目标取景：笔头往回 2.5 秒（含即将滑入的最新样本，镜头会提前一点拉远，尖峰不会冲出画面）。
    /// 上下各留 12% 余量；跨度小于 floor 时以当前值为中心展开 floor。底部不固定在 0。
    private func focusScale(_ samples: [PPSampleBuffer.Sample], now: TimeInterval) -> PPChartScale {
        let edge = now - delay
        var values: [Double] = []
        for sample in samples.reversed() {
            if sample.time < edge - Self.focus { break }
            values.append(contentsOf: sample.values)
        }
        // 取景左端恰好落在两个样本之间：补上该时刻的插值，避免边界样本滑出时取景跳一下。
        for i in series.indices {
            if let v = Self.value(at: edge - Self.focus, series: i, in: samples) { values.append(v) }
        }
        guard !values.isEmpty else { return PPChartScale(lo: 0, hi: floor) }
        // 取景 = 笔头附近这几秒的最低到最高：平台在 30–47 MB/s，画面就是 30–47 MB/s。
        let lo = values.min()!
        let hi = values.max()!
        if hi - lo < floor {
            let mid = (lo + hi) / 2
            let base = max(0, mid - floor / 2)
            return PPChartScale(lo: base, hi: base + floor)
        }
        let pad = (hi - lo) * 0.12
        return PPChartScale(lo: max(0, lo - pad), hi: hi + pad)
    }

    // MARK: 标题行：图例 + 当前读数

    private func header(values: [Double]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: WgSpace.l) {
            WgTagBox(code: code, title: title)
            ForEach(Array(series.enumerated()), id: \.offset) { index, s in
                HStack(alignment: .firstTextBaseline, spacing: WgSpace.xs) {
                    Path { p in p.move(to: CGPoint(x: 0, y: 1)); p.addLine(to: CGPoint(x: 12, y: 1)) }
                        .stroke(s.color, style: StrokeStyle(lineWidth: 1.5, dash: s.dashed ? [3, 2] : []))
                        .frame(width: 12, height: 2)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 3 }
                    if series.count > 1 {
                        Text(s.name).font(.system(size: WgType.body)).foregroundStyle(WgInk.ink3)
                    }
                    WgReadout(text: values[safe: index].map(format) ?? "—", size: .title, weight: .regular)
                }
            }
            Spacer()
            Button { togglePause() } label: {
                Image(systemName: paused ? "play.fill" : "pause.fill").font(.system(size: WgType.micro, weight: .bold))
            }
            .buttonStyle(WgToolbarIconButtonStyle(isActive: paused))
            .help(paused ? "继续" : "暂停")
        }
    }

    private func togglePause() {
        paused.toggle()
        frozenAt = paused ? Date().timeIntervalSince1970 : nil
    }

    // MARK: 悬停

    private func hoverLayer(hx: CGFloat, now: TimeInterval, scale: PPChartScale, plot: CGRect, samples: [PPSampleBuffer.Sample]) -> some View {
        let end = now - delay
        let t = end - window + Double((hx - plot.minX) / plot.width) * window
        let values: [(Int, Double)] = series.indices.compactMap { i in Self.value(at: t, series: i, in: samples).map { (i, $0) } }
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(WgInk.ink3).frame(width: 1, height: plot.height)
                .position(x: hx, y: plot.midY)
            ForEach(values, id: \.0) { i, v in
                Circle().fill(series[i].color).frame(width: 6, height: 6)
                    .position(x: hx, y: plot.maxY - CGFloat(min(1, max(0, scale.unit(v)))) * plot.height)
            }
            VStack(alignment: .leading, spacing: WgSpace.xs) {
                Text(verbatim: Date(timeIntervalSince1970: t).formatted(date: .omitted, time: .standard))
                    .font(WgInk.mono(.micro)).foregroundStyle(WgInk.ink3)
                ForEach(values, id: \.0) { i, v in
                    HStack(spacing: WgSpace.s) {
                        Rectangle().fill(series[i].color).frame(width: 8, height: 2)
                        Text(series[i].name).font(.system(size: WgType.body)).foregroundStyle(WgInk.ink2)
                        Spacer(minLength: 8)
                        Text(verbatim: format(v)).font(WgInk.figure(.caption))
                    }
                }
            }
            .wgPadding(.horizontal, .s).wgPadding(.vertical, .s)
            .frame(width: 168)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: WgRadius.s, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: WgRadius.s, style: .continuous).strokeBorder(WgInk.rule))
            .offset(x: hx + 176 > plot.maxX ? hx - 176 : hx + 8, y: plot.minY + 2)
        }
        .allowsHitTesting(false)
    }

    /// 某时刻的线性插值值。
    static func value(at t: TimeInterval, series index: Int, in samples: [PPSampleBuffer.Sample]) -> Double? {
        guard let first = samples.first, let last = samples.last else { return nil }
        if t <= first.time { return first.values[safe: index] }
        if t >= last.time { return last.values[safe: index] }
        var lo = 0, hi = samples.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if samples[mid].time < t { lo = mid } else { hi = mid }
        }
        let a = samples[lo], b = samples[hi]
        let f = (t - a.time) / max(0.001, b.time - a.time)
        return (a.values[safe: index] ?? 0) * (1 - f) + (b.values[safe: index] ?? 0) * f
    }
}

// MARK: - 坐标层：横向刻度线 + 纵轴读数 + 底部时间尺

private struct PPChartAxis: View, Equatable {
    let scale: PPChartScale
    let format: (Double) -> String
    let window: TimeInterval
    let size: CGSize
    let plot: CGRect

    static func == (a: Self, b: Self) -> Bool { a.scale == b.scale && a.size == b.size && a.window == b.window }

    var body: some View {
        Canvas { context, _ in
            let rule = Color.primary.opacity(0.07)
            for tick in scale.ticks() {
                let y = plot.maxY - plot.height * CGFloat(tick.unit)
                var line = Path()
                line.move(to: CGPoint(x: plot.minX, y: y))
                line.addLine(to: CGPoint(x: plot.maxX, y: y))
                context.stroke(line, with: .color(tick.unit == 0 ? Color.primary.opacity(0.3) : Color.primary.opacity(0.14)),
                               style: StrokeStyle(lineWidth: 1, dash: tick.unit == 0 ? [] : [1, 4]))
                // 左端短刻度，像直尺的刻痕。
                var mark = Path()
                mark.move(to: CGPoint(x: plot.minX - 4, y: y))
                mark.addLine(to: CGPoint(x: plot.minX, y: y))
                context.stroke(mark, with: .color(Color.primary.opacity(0.28)), lineWidth: 1)
                context.draw(Text(verbatim: format(tick.value)).font(WgInk.mono(.micro)).foregroundStyle(Color.primary.opacity(0.42)),
                             at: CGPoint(x: plot.minX - 8, y: y), anchor: .trailing)
            }
            // 时间尺：每 5s 一个细刻痕，每 15s 一个长刻痕 + 读数（相对“现在”）。
            let base = plot.maxY
            for s in stride(from: 0, through: Int(window), by: 5) {
                let x = plot.maxX - CGFloat(Double(s) / window) * plot.width
                let major = s % 15 == 0
                var tick = Path()
                tick.move(to: CGPoint(x: x, y: base))
                tick.addLine(to: CGPoint(x: x, y: base + (major ? 5 : 3)))
                context.stroke(tick, with: .color(Color.primary.opacity(major ? 0.32 : 0.18)), lineWidth: 1)
                if major {
                    let label = s == 0 ? "NOW" : "−\(s)s"
                    context.draw(Text(verbatim: label).font(WgInk.mono(.micro)).foregroundStyle(Color.primary.opacity(0.4)),
                                 at: CGPoint(x: x, y: base + 7),
                                 // 两端标签向内对齐：最左的 −60s 若居中会伸进纵轴刻度区，压住最底一格读数。
                                 anchor: s == 0 ? .topTrailing : (s == Int(window) ? .topLeading : .top))
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }
}

// MARK: - 纸带（Core Animation）

private struct PPChartTape: NSViewRepresentable {
    let samples: [PPSampleBuffer.Sample]
    let version: TimeInterval
    let camera: ChartCamera
    /// 镜头过渡的结束时刻：镜头重新取景时它会变，驱动纸带重建。
    let cameraEnd: TimeInterval
    let series: [PPStreamChart.Series]
    let format: (Double) -> String
    let plot: CGRect
    let window: TimeInterval
    let delay: TimeInterval
    let frozenAt: TimeInterval?

    func makeNSView(context: Context) -> TapeView { TapeView() }

    func updateNSView(_ view: TapeView, context: Context) {
        view.update(TapeView.Input(samples: samples, version: version, camera: camera, cameraEnd: cameraEnd,
                                   series: series.map { .init(color: NSColor($0.color), fill: $0.fill, dashed: $0.dashed) },
                                   format: format, plot: plot, window: window, delay: delay, frozenAt: frozenAt))
    }
}

final class TapeView: NSView {
    struct SeriesStyle { var color: NSColor; var fill: Bool; var dashed: Bool }
    struct Input {
        var samples: [PPSampleBuffer.Sample]
        var version: TimeInterval
        var camera: ChartCamera
        var cameraEnd: TimeInterval
        var series: [SeriesStyle]
        var format: (Double) -> String
        var plot: CGRect
        var window: TimeInterval
        var delay: TimeInterval
        var frozenAt: TimeInterval?
    }

    private let clip = CALayer()        // 视窗：裁剪 + 左缘渐隐
    private let fade = CAGradientLayer()
    private let tape = CALayer()        // 平移的纸带
    private let markers = CALayer()     // 超量程标记（随纸带平移，不受裁剪）
    private var fills: [CAGradientLayer] = []
    private var fillMasks: [CAShapeLayer] = []
    private var strokes: [CAShapeLayer] = []
    private var pens: [CAShapeLayer] = []
    private var last: Input?


    override init(frame: NSRect) {
        super.init(frame: frame)
        // 图层宿主视图：图层树完全自己管理，坐标原点在左上。
        layer = CALayer()
        wantsLayer = true
        layer?.isGeometryFlipped = true
        clip.masksToBounds = true
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        fade.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor]
        fade.locations = [0, 0.1, 1]
        clip.mask = fade
        tape.anchorPoint = .zero
        markers.anchorPoint = .zero
        layer?.addSublayer(clip)
        clip.addSublayer(tape)
        tape.addSublayer(markers)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func ensureFlipped() {
        if layer?.isGeometryFlipped != true { layer?.isGeometryFlipped = true }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if let last { self.last = nil; update(last) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // 离开窗口时动画会被移除；回到窗口重新挂上。
        if window != nil, let last { self.last = nil; update(last) }
    }

    func update(_ input: Input) {
        let previous = last
        last = input
        guard let latest = input.samples.last?.time, input.plot.width > 1 else {
            last = nil   // 尚未布局：下一次有数据时按“首次”完整布局
            CATransaction.begin(); CATransaction.setDisableActions(true)
            strokes.forEach { $0.path = nil }; fillMasks.forEach { $0.path = nil }; pens.forEach { $0.isHidden = true }
            CATransaction.commit()
            return
        }
        let plot = input.plot
        let pps = plot.width / input.window
        let span = input.window + PPStreamChart.tail
        let geometryChanged = previous?.plot != plot || previous?.window != input.window
        let dataChanged = geometryChanged || previous?.version != input.version || previous?.cameraEnd != input.cameraEnd
            || previous?.series.count != input.series.count
        let freezeChanged = previous?.frozenAt != input.frozenAt
        guard dataChanged || freezeChanged || previous == nil else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ensureFlipped()
        ensureLayers(count: input.series.count)

        if geometryChanged {
            clip.frame = plot
            fade.frame = CGRect(origin: .zero, size: plot.size)
        }

        let now = input.frozenAt ?? Date().timeIntervalSince1970
        if dataChanged {
            tape.bounds = CGRect(x: 0, y: 0, width: CGFloat(span) * pps, height: plot.height)
            markers.frame = tape.bounds
            buildPaths(input, latest: latest, span: span, pps: pps, now: now)
        }

        // 平移：x(t) = (latest − t + delay − tail) × pps，匀速。
        func x(_ t: TimeInterval) -> CGFloat { CGFloat(latest - t + input.delay - PPStreamChart.tail) * pps }
        tape.removeAnimation(forKey: "scroll")
        if input.frozenAt == nil {
            let duration: TimeInterval = 30
            tape.position = CGPoint(x: x(now + duration), y: 0)
            let scroll = CABasicAnimation(keyPath: "position.x")
            scroll.fromValue = x(now)
            scroll.toValue = x(now + duration)
            scroll.duration = duration
            scroll.timingFunction = CAMediaTimingFunction(name: .linear)
            tape.add(scroll, forKey: "scroll")
        } else {
            tape.position = CGPoint(x: x(now), y: 0)
        }

        updatePens(input, now: now)
        CATransaction.commit()
    }

    private func ensureLayers(count: Int) {
        while strokes.count < count {
            let fill = CAGradientLayer()
            let mask = CAShapeLayer()
            fill.anchorPoint = .zero
            fill.mask = mask
            let stroke = CAShapeLayer()
            stroke.fillColor = nil
            stroke.lineCap = .round
            stroke.lineJoin = .round
            let pen = CAShapeLayer()
            pen.path = CGPath(ellipseIn: CGRect(x: -2.5, y: -2.5, width: 5, height: 5), transform: nil)
            pen.lineWidth = 1.5
            // 次系列先画、主系列在上：后创建的是主系列，放在最上层。
            tape.insertSublayer(fill, below: markers)
            tape.insertSublayer(stroke, below: markers)
            layer?.addSublayer(pen)
            fills.append(fill); fillMasks.append(mask); strokes.append(stroke); pens.append(pen)
        }
    }

    private func resolved(_ color: NSColor, alpha: CGFloat = 1) -> CGColor {
        var cg: CGColor = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let base = color.usingColorSpace(.sRGB) ?? color
            cg = base.withAlphaComponent(base.alphaComponent * alpha).cgColor
        }
        return cg
    }

    /// 45° 剖面线图案（6pt 间距），颜色按当前外观解析。
    private func hatchColor(_ color: NSColor) -> CGColor {
        let tile = NSImage(size: NSSize(width: 6, height: 6), flipped: false) { [weak self] _ in
            guard let self else { return false }
            var c = color
            self.effectiveAppearance.performAsCurrentDrawingAppearance { c = (color.usingColorSpace(.sRGB) ?? color).withAlphaComponent(0.34) }
            c.setStroke()
            let path = NSBezierPath()
            path.lineWidth = 1
            path.move(to: NSPoint(x: -1, y: -1)); path.line(to: NSPoint(x: 7, y: 7))
            path.move(to: NSPoint(x: -1, y: 5)); path.line(to: NSPoint(x: 1, y: 7))
            path.move(to: NSPoint(x: 5, y: -1)); path.line(to: NSPoint(x: 7, y: 1))
            path.stroke()
            return true
        }
        return NSColor(patternImage: tile).cgColor
    }

    /// 点阵图案：14pt 方块里散布几粒小点（固定伪随机，拼接无缝），颜色按当前外观解析。
    private func stippleColor(_ color: NSColor) -> CGColor {
        let tile = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { [weak self] _ in
            guard let self else { return false }
            var c = color
            self.effectiveAppearance.performAsCurrentDrawingAppearance { c = (color.usingColorSpace(.sRGB) ?? color).withAlphaComponent(0.42) }
            c.setFill()
            let dots: [(CGFloat, CGFloat)] = [(1.5, 2), (8, 1), (4.5, 6), (11.5, 5.5), (2, 10.5), (7.5, 9), (12, 12), (5, 13)]
            for (x, y) in dots { NSBezierPath(ovalIn: NSRect(x: x - 0.8, y: y - 0.8, width: 1.6, height: 1.6)).fill() }
            return true
        }
        return NSColor(patternImage: tile).cgColor
    }

    /// 曲线路径：按“此刻镜头”画出起点形状，按“镜头目标”画出终点形状，
    /// 镜头仍在移动时从起点形变到终点（剩余时长 + 同一条缓动），镜头的推拉就是曲线的伸缩。
    /// 超出取景的部分交给裁剪层截掉。
    private func buildPaths(_ input: Input, latest: TimeInterval, span: TimeInterval, pps: CGFloat, now: TimeInterval) {
        let h = input.plot.height
        let start = latest - span
        let visible = input.samples.filter { $0.time >= start - 2 }
        let camera = input.camera
        let target = camera.to
        let frozen = input.frozenAt != nil
        // 镜头运动的关键帧：从此刻到镜头到达最新目标，每 0.1s 一帧，交给 Core Animation 线性播放。
        let horizon = frozen ? 0 : min(2.0, max(0, camera.end - now))
        let steps = horizon > 0.05 ? max(1, Int((horizon / 0.1).rounded(.up))) : 0
        let frameTimes = (0...steps).map { now + (steps == 0 ? 0 : horizon * Double($0) / Double(steps)) }
        let frameScales = frameTimes.map { camera.scale(at: $0) }
        let background = resolved(NSColor.windowBackgroundColor)

        func paths(_ i: Int, _ scale: PPChartScale) -> (curve: CGPath, area: CGPath)? {
            let points = visible.map { CGPoint(x: CGFloat($0.time - start) * pps, y: h - CGFloat(scale.unit($0.values[safe: i] ?? 0)) * h) }
            guard points.count >= 2 else { return nil }
            let curve = Self.smoothPath(points)
            let area = curve.mutableCopy()!
            // 面积底边放在远低于取景框处：曲线被镜头推到框外时，填充仍连续。
            area.addLine(to: CGPoint(x: points.last!.x, y: h * 4))
            area.addLine(to: CGPoint(x: points.first!.x, y: h * 4))
            area.closeSubpath()
            return (curve, area)
        }
        func play(_ layer: CAShapeLayer, _ frames: [CGPath]) {
            layer.removeAnimation(forKey: "camera")
            layer.path = frames.last
            guard frames.count >= 2 else { return }
            let anim = CAKeyframeAnimation(keyPath: "path")
            anim.values = frames
            anim.keyTimes = (0..<frames.count).map { NSNumber(value: Double($0) / Double(frames.count - 1)) }
            anim.duration = horizon
            anim.calculationMode = .linear
            layer.add(anim, forKey: "camera")
        }
        for (i, style) in input.series.enumerated() {
            let stroke = strokes[i], fill = fills[i], mask = fillMasks[i]
            stroke.strokeColor = resolved(style.color)
            // 原版画法：实线曲线 + 斜线剖面填充（对照点阵版保留在 stippleColor）。
            stroke.lineWidth = style.fill ? 1.5 : 1.2
            stroke.lineCap = .round
            stroke.lineDashPattern = style.dashed ? [3, 2.5] : nil
            pens[i].fillColor = resolved(style.color)
            pens[i].strokeColor = background
            let frames = frameScales.compactMap { paths(i, $0) }
            guard !frames.isEmpty else { stroke.path = nil; mask.path = nil; continue }
            play(stroke, frames.map(\.curve))
            fill.isHidden = !style.fill
            if style.fill {
                fill.frame = CGRect(x: 0, y: -h * 3, width: tape.bounds.width, height: h * 8)
                fill.colors = nil
                fill.backgroundColor = hatchColor(style.color)
                // 面罩坐标相对 fill 层：fill 向上扩了 3h，路径整体下移 3h 对齐。
                play(mask, frames.map { f -> CGPath in var shift = CGAffineTransform(translationX: 0, y: h * 3); return f.area.copy(using: &shift)! })
            }
        }
        buildMarkers(input, visible: visible, start: start, pps: pps, target: target)
    }

    /// 超量程标记：取景之上的曲线段，在顶边标一个小三角 + 该段峰值读数。每段只标一次。
    private func buildMarkers(_ input: Input, visible: [PPSampleBuffer.Sample], start: TimeInterval, pps: CGFloat, target: PPChartScale) {
        markers.sublayers?.forEach { $0.removeFromSuperlayer() }
        let scale = window?.backingScaleFactor ?? 2
        // 只标整张图里最高的一个超量程峰：满屏标记是噪声。
        var best: (time: TimeInterval, value: Double, color: NSColor)?
        for (i, style) in input.series.enumerated() where style.fill {
            for sample in visible {
                let v = sample.values[safe: i] ?? 0
                if v > target.hi, v > (best?.value ?? -1) { best = (sample.time, v, style.color) }
            }
        }
        guard let peak = best else { return }
        let x = CGFloat(peak.time - start) * pps
        let tri = CAShapeLayer()
        let path = CGMutablePath()
        path.move(to: CGPoint(x: x - 4, y: 7)); path.addLine(to: CGPoint(x: x + 4, y: 7)); path.addLine(to: CGPoint(x: x, y: 1))
        path.closeSubpath()
        tri.path = path
        tri.fillColor = resolved(peak.color)
        markers.addSublayer(tri)
        let text = CATextLayer()
        text.string = "PEAK " + input.format(peak.value)
        text.font = NSFont.monospacedSystemFont(ofSize: WgType.micro, weight: .medium)
        text.fontSize = 9
        text.foregroundColor = resolved(NSColor.labelColor, alpha: 0.7)
        text.contentsScale = scale
        text.alignmentMode = .left
        text.frame = CGRect(x: x + 7, y: 0, width: 140, height: 13)
        markers.addSublayer(text)
    }

    /// 记录笔：右缘时刻 te = t − delay 处的插值值，按每个关键帧时刻的镜头取景换算高度，
    /// 所以笔头与曲线一起随镜头推拉。关键帧覆盖到已知的最新样本为止。
    private func updatePens(_ input: Input, now: TimeInterval) {
        let plot = input.plot
        let camera = input.camera
        func y(_ v: Double, at t: TimeInterval) -> CGFloat {
            let u = CGFloat(min(1, max(0, camera.scale(at: input.frozenAt ?? t).unit(v))))
            return plot.maxY - u * plot.height
        }
        let edgeNow = now - input.delay
        let latest = input.samples.last?.time ?? edgeNow
        let horizon = input.frozenAt == nil ? max(latest - edgeNow, camera.end - now, 0) : 0
        // 关键帧：每 0.1s 一个（覆盖镜头过渡与样本间插值）。
        let steps = max(1, Int((horizon / 0.1).rounded(.up)))
        for (i, pen) in pens.enumerated() {
            pen.removeAnimation(forKey: "pen")
            guard i < input.series.count, let v0 = PPStreamChart.value(at: edgeNow, series: i, in: input.samples) else {
                pen.isHidden = true; continue
            }
            pen.isHidden = false
            var values: [CGFloat] = [y(v0, at: now)]
            var times: [Double] = [0]
            if horizon > 0.02 {
                for k in 1...steps {
                    let dt = min(horizon, Double(k) * 0.1)
                    let v = PPStreamChart.value(at: edgeNow + dt, series: i, in: input.samples) ?? v0
                    values.append(y(v, at: now + dt))
                    times.append(dt / horizon)
                }
            }
            pen.position = CGPoint(x: plot.maxX, y: values.last!)
            guard values.count >= 2 else { continue }
            let anim = CAKeyframeAnimation(keyPath: "position.y")
            anim.values = values
            anim.keyTimes = times.map { NSNumber(value: $0) }
            anim.duration = horizon
            anim.calculationMode = .linear
            pen.add(anim, forKey: "pen")
        }
    }

    /// Catmull-Rom → 三次贝塞尔，控制点纵向夹在相邻点之间，避免过冲。
    static func smoothPath(_ p: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        path.move(to: p[0])
        for i in 0..<(p.count - 1) {
            let p0 = p[max(0, i - 1)], p1 = p[i], p2 = p[i + 1], p3 = p[min(p.count - 1, i + 2)]
            let lo = min(p1.y, p2.y), hi = max(p1.y, p2.y)
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: min(hi, max(lo, p1.y + (p2.y - p0.y) / 6)))
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: min(hi, max(lo, p2.y - (p3.y - p1.y) / 6)))
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

