import SwiftUI

// 测速台 HUD（定稿 docs/speedlab/design-final.webp，规格 docs/speedtest-spec.md §8）。
//
// 每个元素对应测量里的一个真实部件；动作只在它的事件发生时触发：
//   两翼     下行 / 上行通道。刻度 0–协商速率，两翼一致：中间低、外角高，亮部从中间往外长
//   读数     稳态吞吐（测速中为平滑实时值，逐帧连续变化），不做翻转动画
//   RTT      空载 / 负载延迟与真实 ping 采样直方图
//   SOURCE   候选源试跑结果 keep / drop
//   PIPELINE RUNNER → NIC → STREAMS ×n → EXIT → SRC，重连只在对应那一根上轻标
//   VERDICT  每个方向的瓶颈（LINK / UPSTREAM）与余量
//
// 设计坐标 1280×720。缩放有上限（WgLayout.speedHudScale）：窄时整体等比缩小，宽到上限后高度与字号不再变，
// 多出的宽度横向展开（两翼外伸、右侧面板贴右、管线拉长）。动作以 SLMotion 帧为单位、三次缓出，按屏幕刷新率（垂直同步）逐帧连续绘制。

// MARK: - 数据快照

struct SLHUDData {
    var runner = "—"
    var path = "—"
    var target = "—"
    var running = false
    var startedAt: Date?
    var finishedAt: Date?
    var phaseDates: [SLPhase: Date] = [:]
    var infoDates: [String: Date] = [:]
    var info: [String: String] = [:]
    var link: Int?
    var down: [SLTimedSample] = []
    var up: [SLTimedSample] = []
    var idle: [SLTimedSample] = []
    var sources: [SLSourceResult] = []
    var reconnects: [SLConnEvent] = []
    /// 没有可用源、被跳过的方向（dl / ul）。
    var skipped: Set<String> = []
    var downThreads = 12
    var upThreads = 4
    var isPublic = true
    var unit: SLUnit = .mbps
    var tick: Double = 0.1
    /// 上行的区间与数据来源（接收端的区间由服务端决定）。
    var upTick: Double = 0.1
    var upSide: SLRateSide?
    /// 本次测量用的测法（结果算法跟着它走）。
    var method = SLParams()
    /// 样本到达时算好的统计轨迹（Store 增量维护；离线渲染可用 replayTrails() 从样本回放）。
    var trails = SLTrails()
    var error: String?

    init() {}

    var scale: Double { Double(link ?? 1000) }
    var done: Bool { finishedAt != nil && error == nil }

    func stat(left: Bool) -> SLStat? { left ? trails.downStat : trails.upStat }

    /// 按到达时间回放样本重建轨迹（Store 实时增量维护，这里给离线渲染用）。
    mutating func replayTrails() {
        trails = .replay(idle: idle, down: down, up: up, tick: tick, upTick: upTick, method: method)
    }
}

// MARK: - 动作（参数单位：帧，按 24fps 标定；取值连续，垂直同步下平滑插值）

enum SLMotion {
    /// 动作时间单位：每秒 10 个"帧"。原先按 24fps 走，2–3 帧就完，太急。
    static let fps = 10.0
    static func frames(_ now: Date, since t0: Date?) -> Double {
        guard let t0 else { return -1_000 }
        return now.timeIntervalSince(t0) * fps
    }
    /// 关键帧表在 k = from, from+1, … 处取值，中间线性插值，两端外延取端值。
    static func lerp(_ t: [Double], _ k: Double, from: Double = 0) -> Double {
        let x = k - from
        guard x > 0 else { return t[0] }
        let i = Int(x)
        guard i < t.count - 1 else { return t[t.count - 1] }
        return t[i] + (t[i + 1] - t[i]) * (x - Double(i))
    }
    /// 三次缓出：起步快、收尾慢，到位不回弹。x 为 0–1 进度。
    static func ease(_ x: Double) -> Double { x <= 0 ? 0 : (x >= 1 ? 1 : 1 - pow(1 - x, 3)) }
    /// 标签渐显：3 帧。
    static func flick(_ k: Double) -> Double { ease(k / 3) }
    /// 减速到位：2 帧。
    static func settle(_ k: Double) -> Double { ease(k / 2) }
    /// 射出：3 帧。
    static func shoot(_ k: Double) -> Double { ease(k / 3) }
    /// 预兆：正式出现前 2 帧的虚影。
    static func ghost(_ k: Double) -> Double { lerp([0, 0.5, 0.22, 0], k, from: -3) }
}

// MARK: - 视图

struct SLHUD: View {
    @Environment(\.wgRegionColor) private var region
    var data: SLHUDData
    var now: Date

    static let size = CGSize(width: 1280, height: 720)

    /// 给定页面宽度时的缩放：不超过上限。
    static func scale(forWidth width: CGFloat) -> CGFloat { min(WgLayout.speedHudScale, width / size.width) }

    var body: some View {
        Canvas { ctx, size in
            let s = Self.scale(forWidth: size.width)
            ctx.scaleBy(x: s, y: s)
            SLHUDPainter(ctx: ctx, d: data, now: now, region: region, W: max(Self.size.width, size.width / s)).paint()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility)
    }

    private var accessibility: String {
        let dl = data.trails.downStat.map { SLFormat.compact($0.stable, unit: data.unit) } ?? "—"
        let ul = data.trails.upStat.map { SLFormat.compact($0.stable, unit: data.unit) } ?? "—"
        return String(localized: "测速 下行 \(dl) 上行 \(ul) \(data.unit.title)", bundle: .wgLocalized)
    }
}

// MARK: - 绘制

private struct SLHUDPainter {
    var ctx: GraphicsContext
    let d: SLHUDData
    let now: Date
    var region = WgRegionColor()
    /// 设计坐标下的实际宽度（≥1280）。左侧元素按左边定位，右侧元素按右边定位，居中元素按 cx。
    var W: CGFloat = 1280
    var cx: CGFloat { W / 2 }
    /// 比设计宽度多出来的宽度：右侧元素整体右移这么多。
    var dx: CGFloat { W - 1280 }

    // 灰阶色板（深色主场；颜色只给异常）。
    // 白色（ink）只给高光：START、正在跑的读数与表盘亮部。其余信息一律灰阶，层级靠灰阶之间的距离拉开：
    //   g0 值 · g1 标题/次要值 · g2 键名/刻度 · g3 未启用 · g4 线 · g5 底
    private func gray(_ value: Double) -> Color { Color(white: region.scheme == .light ? 1 - value : value) }
    var ink: Color { gray(0.95) }
    var g0: Color { gray(0.84) }
    var g1: Color { gray(0.7) }
    var g2: Color { gray(0.56) }
    var g3: Color { gray(0.32) }
    var g4: Color { gray(0.17) }
    var g5: Color { gray(0.11) }
    var bg: Color { region.fill(default: Color(red: 0.06, green: 0.063, blue: 0.07)) }
    let alert = Color(red: 1, green: 0.36, blue: 0.3)

    func k(_ t: Date?) -> Double { SLMotion.frames(now, since: t) }

    func paint() {
        var c = ctx
        // 外框斜切直接画在 Canvas 里：页面上对非矩形做 clipShape，窗口每帧都要把它栅格化，滚动掉帧
        let w = W, h = SLHUD.size.height, cut: CGFloat = 28
        c.fill(poly([CGPoint(x: 0, y: 0), CGPoint(x: w - cut, y: 0), CGPoint(x: w, y: cut),
                     CGPoint(x: w, y: h), CGPoint(x: cut, y: h), CGPoint(x: 0, y: h - cut)], close: true), with: .color(bg))
        wings()
        readouts()
        modeBlock()
        rttPanel()
        sourcePanel()
        interfacePanel()
        pipeline()
        verdictPanel()
        progress()
    }

    // MARK: 原语

    func poly(_ p: [CGPoint], close: Bool = false) -> Path {
        var path = Path()
        guard let f = p.first else { return path }
        path.move(to: f)
        p.dropFirst().forEach { path.addLine(to: $0) }
        if close { path.closeSubpath() }
        return path
    }

    func fill(_ p: [CGPoint], _ c: Color, _ a: Double = 1) {
        var g = ctx; g.opacity = a; g.fill(poly(p, close: true), with: .color(c))
    }

    func stroke(_ p: [CGPoint], _ c: Color, _ w: CGFloat = 1, close: Bool = false, dash: [CGFloat] = [], a: Double = 1) {
        var g = ctx; g.opacity = a
        g.stroke(poly(p, close: close), with: .color(c), style: StrokeStyle(lineWidth: w, lineJoin: .miter, dash: dash))
    }

    func chamfer(_ r: CGRect, _ cut: CGFloat) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX - cut, y: r.minY), CGPoint(x: r.maxX, y: r.minY + cut),
         CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX + cut, y: r.maxY), CGPoint(x: r.minX, y: r.maxY - cut)]
    }

    func text(_ s: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ c: Color,
              anchor: UnitPoint = .leading, weight: Font.Weight = .regular, track: CGFloat = 0, a: Double = 1, floor: Bool = true) {
        guard a > 0 else { return }
        var g = ctx; g.opacity = a
        // 页面里 HUD 常只有设计宽度的 0.7 倍：注记类小字统一抬到 14，缩放后仍约 10pt，老花眼也认得出
        // （装在定宽小框里的注记可免下限，如链路节点里的 IP）
        let size = size <= 12 ? (floor ? max(14, size * 1.15) : size * 1.15) : size
        g.draw(Text(verbatim: s).font(.system(size: size, weight: weight, design: .monospaced)).tracking(track).foregroundColor(c),
               at: CGPoint(x: x, y: y), anchor: anchor)
    }

    /// [key] value 行：键淡、值亮。
    func row(_ key: String, _ value: String, _ x: CGFloat, _ y: CGFloat, keyWidth: CGFloat = 78, size: CGFloat = 12,
             valueColor: Color? = nil, a: Double = 1) {
        text("[\(key)]", x, y, size, g2, a: a)
        text(value, x + keyWidth, y, size, valueColor ?? g0, weight: .medium, a: a)
    }

    func node(_ p: CGPoint, _ r: CGFloat = 4, _ c: Color? = nil, a: Double = 1) {
        var g = ctx; g.opacity = a
        g.fill(Path(CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)), with: .color(c ?? g1))
        g.stroke(Path(CGRect(x: p.x - r - 4, y: p.y - r - 4, width: 2 * r + 8, height: 2 * r + 8)), with: .color(g3), lineWidth: 1)
    }

    /// 面板：只有标题 + 标题下一条发丝线，不画封闭框——封闭的斜切框是按钮的样子，全屏只有 START 是按钮。
    /// 进场 = 发丝线从左往右划出 → 标题 0→⅓→⅔→1。返回内容透明度（未进场为 0）。
    @discardableResult
    func panel(_ r: CGRect, _ title: String, enter: Date?) -> Double {
        let f = k(enter), ruleY = r.minY + 34
        func rule(_ len: CGFloat, _ c: Color) { stroke([CGPoint(x: r.minX, y: ruleY), CGPoint(x: r.minX + len, y: ruleY)], c, 1) }
        rule(r.width, g4)
        guard f >= 0 else {
            text(title, r.minX, r.minY + 20, 12, g3, weight: .bold, track: 1)
            return 0
        }
        rule(r.width * SLMotion.settle(f), g2)
        text(title, r.minX, r.minY + 20, 12, g1, weight: .bold, track: 1, a: SLMotion.flick(f))
        return SLMotion.flick(f - 3)
    }

    // MARK: 平滑：面板里的统计量也连续变化，不随新样本跳

    /// 把一条统计轨迹在最近 0.5 秒上取平均：新样本带来的变化摊成连续过渡。每帧只做 8 次二分查找。
    func glide(_ trail: SLTrail) -> Double? {
        var sum = 0.0, n = 0.0
        for i in 0..<8 { if let v = trail.value(at: now.addingTimeInterval(-Double(i) * 0.07)) { sum += v; n += 1 } }
        return n > 0 ? sum / n : nil
    }

    // MARK: 两翼

    func wings() {
        wing(left: true, samples: d.down, enter: d.phaseDates[.dl], label: "DL")
        wing(left: false, samples: d.up, enter: d.phaseDates[.ul], label: "UL")
    }

    /// 一条通道。几何：外角（源一侧）→ 折点 → 内端（执行端一侧）。
    func wing(left: Bool, samples: [SLTimedSample], enter: Date?, label: String) {
        let sx: CGFloat = left ? -1 : 1
        let outer = cx - 40, foldAt = 168 + (outer - 168) * (410 - 168) / (600 - 168)
        let corner = CGPoint(x: cx + sx * outer, y: 66), fold = CGPoint(x: cx + sx * foldAt, y: 114), tip = CGPoint(x: cx + sx * 168, y: 172)
        let blade = [corner, fold, tip, CGPoint(x: tip.x - sx * 34, y: tip.y + 12), CGPoint(x: fold.x - sx * 6, y: fold.y + 44),
                     CGPoint(x: corner.x + sx * 22, y: corner.y + 16)]
        let f = k(enter)
        // 未启用：只留最淡的轮廓（底座的一部分）
        guard f >= 0 else {
            stroke(blade, g4, 1, close: true)
            node(corner, 3.5, g3)
            // 心跳：开测前（连执行端 / 测空载延迟 / 试测源）在还没开跑的通道上来回扫一道暗亮带，
            // 表示正在准备、不是卡住。只用 g3 灰，不抢读数和 START 的白。
            if waiting != nil, let st = d.startedAt {
                let period = 1.6, t = now.timeIntervalSince(st).truncatingRemainder(dividingBy: period) / period
                let p = CGFloat(t * t * (3 - 2 * t))
                let x = tip.x + (corner.x - tip.x) * p
                var band = ctx
                band.clip(to: Path(CGRect(x: x - 36, y: 0, width: 72, height: 260)))
                band.opacity = sin(Double.pi * t)
                band.fill(poly(blade, close: true), with: .color(g3))
            }
            return
        }
        // 3 帧从内端射向外角：轮廓沿 x 方向展开
        let open = SLMotion.shoot(f)
        var g = ctx
        let reveal = left ? CGRect(x: tip.x - (tip.x - corner.x + 30) * open, y: 0, width: (tip.x - corner.x + 30) * open + 40, height: 260)
                          : CGRect(x: tip.x - 40, y: 0, width: (corner.x - tip.x + 30) * open + 40, height: 260)
        g.clip(to: Path(reveal))
        g.fill(poly(blade, close: true), with: .color(g5))
        g.stroke(poly(blade, close: true), with: .color(g3), lineWidth: 1)
        // 下方投影折面：通道的厚度
        g.fill(poly([CGPoint(x: fold.x + sx * 10, y: fold.y + 58), CGPoint(x: tip.x - sx * 20, y: tip.y + 26),
                     CGPoint(x: tip.x - sx * 70, y: tip.y + 34), CGPoint(x: fold.x - sx * 30, y: fold.y + 70)], close: true), with: .color(g4))
        // 亮部：吞吐 / 协商速率；两翼都从中间（内端）往外角长
        let value = displayValue(samples, left: left)
        let frac = min(1, value / d.scale)
        if frac > 0 {
            var lit = g
            let span = abs(corner.x - tip.x)
            let rect: CGRect = left
                ? CGRect(x: tip.x - span * frac, y: 0, width: 40 + span * frac, height: 260)
                : CGRect(x: tip.x - 40, y: 0, width: 40 + span * frac, height: 260)
            lit.clip(to: Path(rect))
            lit.fill(poly(blade, close: true), with: .color(g2))
            // 读数才是高光；翼是它的图形复述，只在测速中给推进的前沿一条白线（笔尖）
            if d.running {
                let edge = left ? rect.minX : rect.maxX
                var pen = g
                pen.clip(to: Path(CGRect(x: edge - 1, y: 0, width: 2, height: 260)))
                pen.fill(poly(blade, close: true), with: .color(ink))
            }
        }
        // 刻度：0（中间）/ ¼ / ½ / ¾ / 满（外角，协商速率），沿上沿平行
        for i in 0...4 {
            let r = CGFloat(i) / 4
            let x = tip.x + (corner.x - tip.x) * r
            let yTop = y(onTopEdgeAt: x, corner, fold, tip) - 14
            g.stroke(poly([CGPoint(x: x, y: yTop), CGPoint(x: x, y: yTop - 7)]), with: .color(g2), lineWidth: 1)
            // 外角那一格不标数字：会撞上通道标题
            guard abs(x - corner.x) > 40 else { continue }
            g.draw(Text(verbatim: SLFormat.tick(d.scale * Double(r))).font(.system(size: WgType.body, design: .monospaced)).foregroundColor(g2),
                   at: CGPoint(x: x, y: yTop - 16), anchor: .center)
        }
        // 通道标签 + 百分比（亮部占协商速率）
        let a = SLMotion.flick(f - 3)
        let lx = left ? corner.x - 12 : corner.x + 12
        text("\(label) CHANNEL", lx, 18, 13, g1, anchor: left ? .leading : .trailing, weight: .bold, track: 1, a: a)
        text("0 – \(SLFormat.tick(d.scale)) \(d.unit.title)", lx, 36, 11, g2, anchor: left ? .leading : .trailing, a: a)
        if value > 0 {
            // 放在翼尖下方的暗处：压在亮部上会白字白底看不见
            text("\(Int((frac * 100).rounded()))%", tip.x - sx * 6, tip.y + 34, 15, g1, anchor: left ? .trailing : .leading, weight: .bold, a: a)
        }
        node(corner, 4)
    }

    /// 上沿折线在 x 处的 y。
    func y(onTopEdgeAt x: CGFloat, _ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
        let (p, q) = (min(a.x, b.x)...max(a.x, b.x)).contains(x) ? (a, b) : (b, c)
        let t = (x - p.x) / (q.x - p.x == 0 ? 1 : q.x - p.x)
        return p.y + (q.y - p.y) * t
    }

    /// 采样连成的折线在 t 时刻的值。首条之前 0.1 秒从 0 升上来，末条之后保持。
    func curve(_ s: [SLTimedSample], at t: Date) -> Double {
        guard let first = s.first, let last = s.last else { return 0 }
        if t >= last.at { return last.v }
        if t <= first.at { return first.v * max(0, 1 - first.at.timeIntervalSince(t) / 0.1) }
        var lo = 0, hi = s.count - 1                     // 找 s[lo].at <= t < s[hi].at
        while hi - lo > 1 { let m = (lo + hi) / 2; if s[m].at <= t { lo = m } else { hi = m } }
        let span = s[hi].at.timeIntervalSince(s[lo].at)
        return span > 0 ? s[lo].v + (s[hi].v - s[lo].v) * t.timeIntervalSince(s[lo].at) / span : s[hi].v
    }

    /// 测速中的读数：折线滞后 0.15 秒（等下一条采样到）、再取 0.5 秒滑动均值。每帧重算，数值连续变化，不跳。
    func live(_ s: [SLTimedSample], at t: Date) -> Double {
        let n = 11, lag = 0.15, w = 0.5
        var sum = 0.0
        for j in 0..<n { sum += curve(s, at: t.addingTimeInterval(-lag - w * Double(j) / Double(n - 1))) }
        return sum / Double(n)
    }

    /// 这一方向测完的时刻：下行 = 上行开始时；否则 = 整轮结束。
    func finishedAt(_ left: Bool) -> Date? { left ? (d.phaseDates[.ul] ?? d.finishedAt) : d.finishedAt }

    /// 当前显示值（读数和两翼共用）：测速中 = 平滑实时值；这一方向测完后 0.6 秒内缓到稳态中位数并定格，不跟着收尾的 0 走。
    func displayValue(_ s: [SLTimedSample], left: Bool) -> Double {
        if let t0 = finishedAt(left), let st = d.stat(left: left) {
            let e = SLMotion.ease(now.timeIntervalSince(t0) / 0.6)
            return e >= 1 ? st.stable : live(s, at: t0) + (st.stable - live(s, at: t0)) * e
        }
        return live(s, at: now)
    }

    // MARK: 读数

    func readouts() {
        readout(left: true, samples: d.down, enter: d.phaseDates[.dl], label: "↓ DL")
        readout(left: false, samples: d.up, enter: d.phaseDates[.ul], label: "↑ UL")
        stroke([CGPoint(x: cx, y: 214), CGPoint(x: cx, y: 330)], g3, 1)
        node(CGPoint(x: cx, y: 272), 3, g2)
    }

    func readout(left: Bool, samples: [SLTimedSample], enter: Date?, label: String) {
        let x: CGFloat = left ? cx - 134 : cx + 134, y: CGFloat = 300
        var v: Double?
        if !samples.isEmpty { v = displayValue(samples, left: left) }
        digits(v.map { d.unit.value($0) }, x, y, 100)
        // 无读数时单位和发丝线一起退到底色，不跟 START 抢
        text("\(label) · \(d.unit.title)", x, y + 30, 18, v == nil ? g3 : g1, anchor: .center)
        // 标签行：上沿一道发丝线
        stroke([CGPoint(x: x - 150, y: y + 52), CGPoint(x: x + 150, y: y + 52)], v == nil ? g4 : g3, 1)
        guard let st = d.stat(left: left) else { return }
        var items: [(String, String)] = [("peak", SLFormat.compact(st.peak, unit: d.unit))]
        let body = Array(samples.map(\.v).dropFirst(Int(2 / max(left ? d.tick : d.upTick, 0.05))))
        if body.count > 3 { items.append(("cv", String(format: "%.1f%%", cv(body)))) }
        let a = d.done ? SLMotion.flick(k(d.finishedAt)) : 1
        var line = ""
        for (kk, vv) in items { line += "[\(kk)] \(vv)   " }
        text(String(line.dropLast(3)), x, y + 72, 12, g1, anchor: .center, a: a)
        // 数据来源单独一行：并进上一行会撞到另一侧的读数
        if !left, let side = d.upSide { text("[src] \(side.key)", x, y + 90, 12, g2, anchor: .center, a: a) }
        _ = enter
    }

    func cv(_ a: [Double]) -> Double {
        let m = a.reduce(0, +) / Double(a.count)
        guard m > 0 else { return 0 }
        return sqrt(a.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(a.count)) / m * 100
    }

    /// 读数：新值到了直接换，不做动画。待机为最淡的 000。
    /// 字体 SF Pro Expanded Ultralight：宽而细，笔画只占很少的白——读数是高光，但白要克制。
    func digits(_ v: Double?, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat) {
        let str = v.map { $0 >= 100 ? String(format: "%.0f", $0) : String(format: "%.1f", $0) } ?? "000"
        // 半边最多 240 宽（中线 640 两侧留白）：四位数（局域网 iperf3 常见）按比例缩小，不压中线
        let size = min(size, 240 / (0.7 * CGFloat(str.count)))
        let cw = size * 0.7
        let x0 = x - cw * CGFloat(str.count) / 2
        // 文本框底边比基线低一个下伸部（约 0.24 字号）
        let bottom = y + size * 0.24
        for (i, ch) in str.enumerated() {
            ctx.draw(Text(String(ch)).font(.system(size: size, weight: .ultraLight).width(.expanded).monospacedDigit()).foregroundColor(v == nil ? g3 : ink),
                     at: CGPoint(x: x0 + cw * (CGFloat(i) + 0.5), y: bottom), anchor: .bottom)
        }
    }

    // MARK: 等待说明

    /// 码表还没动的时候在做什么（nil = 不在等待）。给状态行和两翼心跳用，让等待看得见、不像卡死。
    var waiting: String? {
        guard d.running, d.error == nil else { return nil }
        if d.phaseDates[.dl] != nil || d.phaseDates[.ul] != nil {
            // 下行测完、上行开跑前要试测上行源（约 2 秒）
            return d.phaseDates[.ul] == nil && d.info["stage"] == "probe_ul" ? String(localized: "试测上行测速源", bundle: .wgLocalized) : nil
        }
        if d.phaseDates[.pick] != nil { return String(localized: "试测下行测速源", bundle: .wgLocalized) }
        if d.phaseDates[.idle] != nil { return String(localized: "测空载延迟", bundle: .wgLocalized) }
        return String(localized: "连接执行端 \(d.runner)", bundle: .wgLocalized)
    }

    // MARK: 模式块

    func modeBlock() {
        let modes: [(SLPhase, String)] = [(.prepare, "PREPARE"), (.idle, "LATENCY"), (.pick, "SOURCE"), (.dl, "DOWNLINK"), (.ul, "UPLINK"), (.done, "THROUGHPUT")]
        var cur: (SLPhase, String, Date?) = (.prepare, "STANDBY", nil)
        for (p, name) in modes { if let t = d.phaseDates[p], cur.2 == nil || t >= cur.2! { cur = (p, name, t) } }
        if d.startedAt == nil { cur = (.prepare, d.done ? "THROUGHPUT" : "STANDBY", nil) }
        // 版面（1280×720，四周留白 28，块间距 20）：
        //   顶栏 17–55   DL CHANNEL ……【模式条】…… UL CHANNEL，三者同一行
        //   两翼 66–206  | 上排 200–496：RTT ｜ 读数 220–378 · START 396–448 · [runner] 474 ｜ SOURCE
        //   下排 516–692：INTERFACE ｜ PIPELINE 516–624 · 进度 644–680 ｜ VERDICT
        let f = k(cur.2), y: CGFloat = 17, h: CGFloat = 38
        let state = d.error != nil ? "FAIL" : (d.running ? "RUN" : (d.done ? "DONE" : "IDLE"))
        // 待机：模式条退成最淡的空框，把主次让给 START
        if cur.1 == "STANDBY" && d.error == nil {
            let box = chamfer(CGRect(x: cx - 140, y: y, width: 280, height: h), 12)
            stroke(box, g4, 1, close: true)
            text("STANDBY", cx, y + h / 2, 22, g3, anchor: .center, weight: .bold, track: 5)
            text(state, cx - 160, y + h / 2, 14, g3, anchor: .trailing, weight: .bold, track: 2)
            text("[runner] \(d.runner)   [path] \(d.path)   [target] \(d.target)", cx, 474, 12, g2, anchor: .center)
            return
        }
        // 模式条是状态牌，不是按钮：只描边、不填白；切换阶段时边框从两侧收拢到位
        let col = d.error != nil ? alert : g2
        if f >= 0 && f < 3 && cur.2 != nil {
            let half = CGFloat(560 - 420 * SLMotion.ease(f / 3)), open = CGFloat(SLMotion.ease(f))
            stroke(chamfer(CGRect(x: cx - half, y: y + 12 * (1 - open), width: half * 2, height: 14 + (h - 14) * open), 12), col, 1, close: true)
        } else {
            stroke(chamfer(CGRect(x: cx - 140, y: y, width: 280, height: h), 12), col, 1, close: true)
        }
        let ta = cur.2 == nil ? 1 : SLMotion.flick(f - 2)
        text(d.error != nil ? "ERROR" : cur.1, cx, y + h / 2, 22, d.error != nil ? alert : g0, anchor: .center, weight: .bold, track: 5, a: ta)
        let sa = cur.2 == nil ? 1 : SLMotion.flick(f)
        text(state, cx - 160, y + h / 2, 14, d.error != nil ? alert : g1, anchor: .trailing, weight: .bold, track: 2, a: sa)
        let stamp: String
        if let fin = d.finishedAt { stamp = fin.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted)).minute().second()) }
        else if let st = d.startedAt { stamp = String(format: "T+%05.2f s", now.timeIntervalSince(st)) }
        else { stamp = "—" }
        text(stamp, cx + 160, y + h / 2, 13, g1, a: sa)
        var line = d.error ?? "[runner] \(d.runner)   [path] \(d.path)   [target] \(d.target)"
        if d.error == nil, let w = waiting {
            // 当前步骤 + 本步已用时 + 跳动的点：每帧都在变，一眼看出没卡住
            let since = [d.phaseDates[.prepare], d.phaseDates[.idle], d.phaseDates[.pick], d.infoDates["stage"]].compactMap { $0 }.max() ?? d.startedAt ?? now
            let dots = String(repeating: "·", count: Int(now.timeIntervalSince(since) * 3) % 4)
            line = String(format: "%@  %.1f s ", w, now.timeIntervalSince(since)) + dots
        }
        text(line, cx, 474, 12, d.error != nil ? alert : g1, anchor: .center)
    }

    // MARK: 左上：RTT

    func rttPanel() {
        let r = CGRect(x: 28, y: 200, width: 290, height: 296)
        let a = panel(r, "RTT", enter: d.phaseDates[.idle])
        guard a > 0 else { return }
        let idleV = glide(d.trails.idleMedian), loadV = glide(d.trails.loadMedian)
        row("idle", idleV.map { String(format: "%.1f ms", $0) } ?? "—", r.minX + 2, r.minY + 58, a: a)
        row("load", loadV.map { String(format: "%.1f ms", $0) } ?? "—", r.minX + 2, r.minY + 80, a: a)
        if let i = idleV, let l = loadV {
            let delta = l - i
            row("delta", String(format: "%+.1f ms", delta), r.minX + 2, r.minY + 102, a: a)
            // 负载下延迟涨超过 30 ms 视为队列膨胀（bufferbloat），这是异常，才上色
            row("state", delta > 30 ? "BLOAT" : "STABLE", r.minX + 2, r.minY + 124, valueColor: delta > 30 ? alert : g0, a: a)
        }
        // 直方图：空载淡、负载亮。一帧只用一套分格：量程取平滑后的值，
        // 每个样本到达后 0.5 秒内从 0 长到 1 格高——柱子是长出来的，不是整体跳或叠影
        let bins = 12
        let all = d.idle.map { ($0.v, false, $0.at) } + (d.down + d.up).compactMap { s in s.rtt.map { ($0, true, s.at) } }
        guard let rLo = glide(d.trails.rttLo), let rHi = glide(d.trails.rttHi) else { return }
        let lo = max(0, rLo - 0.5), span = rHi + 0.5 - lo
        guard span > 0 else { return }
        let hi = lo + span
        var cnt = [Double](repeating: 0, count: bins), hot = [Bool](repeating: false, count: bins)
        for (v, l, at) in all where at <= now {
            let grow = SLMotion.ease(now.timeIntervalSince(at) / 0.5)
            let b = min(bins - 1, max(0, Int((v - lo) / span * Double(bins))))
            cnt[b] += grow; if l { hot[b] = true }
        }
        let mx = max(1, cnt.max() ?? 1)
        cnt = cnt.map { $0 / mx }
        let n = 1.0
        let base = r.maxY - 30, bw: CGFloat = 16
        stroke([CGPoint(x: r.minX + 2, y: base), CGPoint(x: r.maxX - 24, y: base)], g3, 1, a: a)
        for i in 0..<bins where cnt[i] > 0 {
            let h = CGFloat(cnt[i] / n) * 76, x = r.minX + 6 + CGFloat(i) * (bw + 5)
            fill([CGPoint(x: x, y: base - h), CGPoint(x: x + bw, y: base - h), CGPoint(x: x + bw, y: base), CGPoint(x: x, y: base)], hot[i] ? g1 : g3, a)
        }
        text(String(format: "%.1f", lo), r.minX + 2, base + 16, 10, g2, a: a)
        text(String(format: "%.1f ms", hi), r.maxX - 24, base + 16, 10, g2, anchor: .trailing, a: a)
    }

    // MARK: 右上：选源

    func sourcePanel() {
        let r = CGRect(x: 962 + dx, y: 200, width: 290, height: 296)
        let a = panel(r, "SOURCE", enter: d.isPublic ? d.phaseDates[.pick] : d.phaseDates[.idle])
        guard a > 0 else { return }
        if !d.isPublic {
            row("target", d.target, r.minX + 2, r.minY + 58, a: a)
            row("addr", d.info["target"] ?? "—", r.minX + 2, r.minY + 80, a: a)
            row("engine", "iperf3", r.minX + 2, r.minY + 102, a: a)
            return
        }
        // 候选源：每个结果到达那一刻 0→⅓→⅔→1 进场；淘汰的变暗并划线
        var y = r.minY + 58
        for dir in ["dl", "ul"] {
            let list = d.sources.filter { $0.dir == dir }
            guard !list.isEmpty else { continue }
            text(dir == "dl" ? "↓ DL" : "↑ UL", r.minX + 2, y, 11, g2, weight: .bold, a: a)
            y += 20
            for s in list {
                let fa = a * SLMotion.flick(k(s.at))
                let col = s.keep ? g0 : g3
                text(s.shortName, r.minX + 14, y, 12, col, weight: .medium, a: fa)
                text("\(Int(s.mbps)) Mbps", r.minX + 196, y, 12, s.keep ? g1 : g3, anchor: .trailing, a: fa)
                text(s.keep ? "KEEP" : "DROP", r.maxX - 4, y, 11, s.keep ? g1 : g3, anchor: .trailing, weight: .bold, a: fa)
                if !s.keep { stroke([CGPoint(x: r.minX + 12, y: y), CGPoint(x: r.minX + 198, y: y)], g3, 1, a: fa) }
                y += 20
            }
            y += 6
        }
        // 入选源的地址
        if let ip = d.info["src_ip"] {
            stroke([CGPoint(x: r.minX, y: r.maxY - 40), CGPoint(x: r.maxX, y: r.maxY - 40)], g4, 1, a: a)
            row("ip", ip, r.minX + 2, r.maxY - 22, keyWidth: 44, a: a * SLMotion.flick(k(d.infoDates["src_ip"])))
        }
    }

    // MARK: 左下：本机网口

    func interfacePanel() {
        let r = CGRect(x: 28, y: 516, width: 252, height: 176)
        let a = panel(r, "INTERFACE", enter: d.infoDates["link"] ?? d.infoDates["iface"])
        guard a > 0 else { return }
        let degraded = (d.link ?? 1000) <= 100 && !(d.info["link"] ?? "").contains("Wi-Fi")
        row("if", d.info["phy"] ?? d.info["iface"] ?? "—", r.minX + 2, r.minY + 58, keyWidth: 66, a: a)
        row("link", linkText, r.minX + 2, r.minY + 80, keyWidth: 66, valueColor: degraded ? alert : nil, a: a)
        row("mtu", d.info["mtu"].flatMap { $0.isEmpty ? nil : $0 } ?? "—", r.minX + 2, r.minY + 102, keyWidth: 66, a: a)
        let dl = glide(d.trails.downStable).map { "\(Int(($0 / d.scale * 100).rounded()))%" } ?? "—"
        let ul = glide(d.trails.upStable).map { "\(Int(($0 / d.scale * 100).rounded()))%" } ?? "—"
        row("util", "DL \(dl) · UL \(ul)", r.minX + 2, r.minY + 124, keyWidth: 66, a: a)
    }

    var linkText: String {
        let raw = d.info["link"] ?? ""
        let parts = raw.split(separator: " ")
        guard let v = parts.first.flatMap({ Int($0) }) else { return raw.isEmpty ? "—" : raw }
        let speed = v >= 1000 ? "\(v)BASE-T" : "\(v)BASE-TX"
        let rest = parts.dropFirst().joined(separator: " ")
        if rest.contains("Wi-Fi") { return "Wi-Fi \(v) Mbps" }
        return speed + (rest == "full" ? " FD" : (rest == "half" ? " HD" : ""))
    }

    // MARK: 中下：测量链路

    func pipeline() {
        let r = CGRect(x: 300, y: 516, width: 680 + dx, height: 108)
        let a = panel(r, "PIPELINE", enter: d.startedAt)
        guard a > 0 else { return }
        let y = r.minY + 78
        let srcName = d.isPublic ? (d.sources.first { $0.keep && $0.dir == "dl" }?.shortName ?? "—") : d.target
        let exitIP = (d.info["exit"] ?? "").replacingOccurrences(of: "当前 IP：", with: "").split(separator: " ").first.map(String.init)
        let nodes: [(String, String, Date?)] = [
            ("RUNNER", d.runner, d.startedAt),
            ("NIC", d.info["phy"] ?? d.info["iface"] ?? "—", d.infoDates["iface"]),
            ("STREAMS", "", d.phaseDates[.dl] ?? d.phaseDates[.ul]),
            (d.isPublic ? "EXIT" : "PATH", d.isPublic ? (exitIP ?? "—") : (d.info["iface"] ?? "—"), d.infoDates["exit"] ?? d.infoDates["iface"]),
            (d.isPublic ? "SRC" : "TARGET", srcName, d.sources.first?.at ?? d.phaseDates[.dl]),
        ]
        // 节点按设计宽度 680 的相对位置随管线拉长
        let xs: [CGFloat] = [64, 186, 340, 494, 616].map { r.minX + $0 * r.width / 680 }
        for (i, (title, sub, t)) in nodes.enumerated() {
            let f = k(t), x = xs[i]
            if i > 0 {
                let on = f >= 0
                stroke([CGPoint(x: xs[i - 1] + (i - 1 == 2 ? 74 : 54), y: y), CGPoint(x: x - (i == 2 ? 74 : 54), y: y)], on ? g1 : g4, 1.5, a: a)
                if on { node(CGPoint(x: (xs[i - 1] + x) / 2 + (i == 3 ? 37 : (i == 2 ? -37 : 0)), y: y), 3, g1, a: a) }
            }
            if i == 2 { streams(x, y, f, a); continue }
            let box = CGRect(x: x - 54, y: y - 22, width: 108, height: 44)
            if f < 0 {
                stroke(chamfer(box, 10), g4, 1, close: true, a: a)
                text(title, x, y - 6, 12, g3, anchor: .center, weight: .bold, a: a)
                continue
            }
            stroke(chamfer(box, 10), g3, 1, close: true, a: a)
            text(title, x, y - 7, 12, g1, anchor: .center, weight: .bold, track: 1, a: a * SLMotion.flick(f))
            text(sub, x, y + 10, 10.5, g1, anchor: .center, a: a * SLMotion.flick(f - 2), floor: false)
        }
    }

    /// STREAMS：一根线一条连接；当前方向的连接数；重连那一根变暗 12 帧，再闪回。
    func streams(_ x: CGFloat, _ y: CGFloat, _ f: Double, _ a: Double) {
        let ulActive = d.phaseDates[.ul] != nil && !(d.done)
        let n = max(1, ulActive ? d.upThreads : d.downThreads), dir = ulActive ? "ul" : "dl"
        let w: CGFloat = 148, h: CGFloat = min(44, CGFloat(n) * 4 + 4)
        let label = f >= 0 ? "STREAMS ×\(n)" : "STREAMS"
        text(label, x, y - 30, 12, f >= 0 ? g1 : g3, anchor: .center, weight: .bold, track: 1, a: a)
        guard f >= 0 else {
            stroke([CGPoint(x: x - w / 2, y: y), CGPoint(x: x + w / 2, y: y)], g4, 1, a: a)
            return
        }
        for i in 0..<n {
            let yy = y - h / 2 + (n == 1 ? h / 2 : h * CGFloat(i) / CGFloat(n - 1))
            var col = g1, ea = a
            if let ev = d.reconnects.last(where: { $0.dir == dir && $0.n == i }) {
                let kk = k(ev.at)
                if kk >= 0 && kk < 12 { col = g3 } else if kk >= 12 && kk < 14 { col = ink; ea = a * SLMotion.ghost(kk - 14) * 2 }
            }
            stroke([CGPoint(x: x - w / 2, y: yy), CGPoint(x: x + w / 2, y: yy)], col, 1.2, a: ea * SLMotion.flick(f - Double(i / 3)))
        }
        // 两端夹具
        for e in [x - w / 2 - 6, x + w / 2 + 6] {
            stroke([CGPoint(x: e, y: y - h / 2 - 6), CGPoint(x: e, y: y + h / 2 + 6)], g2, 2, a: a)
        }
        let rc = d.reconnects.filter { $0.dir == dir }.count
        if rc > 0 { text("reconn \(rc)", x, y + h / 2 + 16, 10, g2, anchor: .center, a: a) }
    }

    // MARK: 右下：判断

    func verdictPanel() {
        let r = CGRect(x: 1000 + dx, y: 516, width: 252, height: 176)
        let a = panel(r, "VERDICT", enter: d.phaseDates[.dl] ?? d.phaseDates[.ul])
        guard a > 0 else { return }
        func judge(_ st: SLStat?, _ trail: SLTrail) -> (String, String, Bool) {
            guard let st, let stable = glide(trail) else { return ("—", "—", false) }
            let head = max(0, 1 - stable / d.scale)
            let b = !st.flat ? (d.done ? "—" : "…") : (st.stable >= d.scale * 0.9 ? "LINK" : "UPSTREAM")
            return (b, "\(Int((head * 100).rounded()))%", false)
        }
        var dl = judge(d.trails.downStat, d.trails.downStable), ul = judge(d.trails.upStat, d.trails.upStable)
        if d.skipped.contains("dl") { dl = ("NO SRC", "—", false) }
        if d.skipped.contains("ul") { ul = ("NO SRC", "—", false) }
        let fa = d.done ? a * SLMotion.flick(k(d.finishedAt)) : a
        row("DL", dl.0, r.minX + 2, r.minY + 58, keyWidth: 50, a: fa)
        row("UL", ul.0, r.minX + 2, r.minY + 80, keyWidth: 50, a: fa)
        row("headroom", "DL \(dl.1) · UL \(ul.1)", r.minX + 2, r.minY + 110, keyWidth: 104, a: fa)
    }

    // MARK: 阶段条 + START 位置（按钮本身由页面叠一个真按钮）

    func progress() {
        let cells: [(String, SLPhase, SLPhase)] = [("RTT", .idle, .pick), ("SRC", .pick, .dl), ("DL", .dl, .ul), ("UL", .ul, .done)]
        let y: CGFloat = 644, w: CGFloat = 118
        for (i, (lab, a0, a1)) in cells.enumerated() {
            let x0: CGFloat = cx - 2 * (w + 8) + CGFloat(i) * (w + 8)
            let box = [CGPoint(x: x0 + 8, y: y), CGPoint(x: x0 + w, y: y), CGPoint(x: x0 + w - 8, y: y + 22), CGPoint(x: x0, y: y + 22)]
            // 整轮已结束时，开始过的阶段都算完成（收尾事件可能先于 done 阶段到达）
            let started = d.phaseDates[a0], ended = d.phaseDates[a1] ?? (d.done && started != nil ? d.finishedAt : nil)
            // 进度格也不是按钮：正在跑的那格描亮边，跑完的退回灰，都不填白
            let running = started != nil && ended == nil
            if running { fill(box, g4, SLMotion.flick(k(started))) }
            stroke(box, running ? g1 : (ended != nil ? g3 : g4), 1, close: true)
            let col = running ? g0 : (ended != nil ? g1 : g3)
            text(lab, x0 + w / 2 + 3, y + 11, 12, col, anchor: .center, weight: .bold, track: 1)
            let skip = (lab == "DL" && d.skipped.contains("dl")) || (lab == "UL" && d.skipped.contains("ul"))
            let st = skip ? "SKIP" : (ended != nil ? "DONE" : (started != nil ? "RUN" : "—"))
            if started != nil || skip { text(st, x0 + w / 2, y + 38, 10, running ? g1 : g2, anchor: .center) }
        }
    }
}
