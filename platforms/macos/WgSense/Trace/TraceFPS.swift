import AppKit
import QuartzCore
import SwiftUI

// 帧率诊断：地图各层每画一帧打一次点，左下角每半秒报一次实际帧率与这段时间里最长的一帧间隔。
//   地图 Metal 地图（地球与平面同一套 GPU 网格，含光环、星空、国名）
//   航线 航线 / 脉冲 / 标注层（Canvas）
// 只数真正画出来的帧：静止时为 0 是正常的（不动不画）。

enum TraceFPS {
    enum Layer: Int, CaseIterable {
        case globe, route
        var name: String { [String(localized: "地图", bundle: .wgLocalized), String(localized: "航线", bundle: .wgLocalized)][rawValue] }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var counts = [Int](repeating: 0, count: Layer.allCases.count)
    nonisolated(unsafe) private static var last = [CFTimeInterval](repeating: 0, count: Layer.allCases.count)
    nonisolated(unsafe) private static var prevGap = [CFTimeInterval](repeating: 1, count: Layer.allCases.count)
    nonisolated(unsafe) private static var maxGap = [CFTimeInterval](repeating: 0, count: Layer.allCases.count)
    nonisolated(unsafe) private static var windowStart = CACurrentMediaTime()
    /// 压测在取数时，角标不再取（免得两边各分走一半帧数）。
    nonisolated(unsafe) static var benchOwnsStats = false

    /// 任意线程调用（Canvas 异步绘制线程等）。
    static func tick(_ layer: Layer) {
        let t = CACurrentMediaTime()
        lock.lock(); defer { lock.unlock() }
        let i = layer.rawValue
        // 只在连续出帧时记间隔：上一个间隔也不长（< 50ms）才算，静止后重新动起来的那一下不算卡顿
        let gap = t - last[i]
        if last[i] > 0, prevGap[i] < 0.05, gap < 0.25 { maxGap[i] = max(maxGap[i], gap) }
        prevGap[i] = last[i] > 0 ? gap : 1
        last[i] = t
        counts[i] += 1
    }

    nonisolated(unsafe) private static var costs: [String: (sum: Double, n: Int, max: Double)] = [:]

    /// 记一段绘制耗时（毫秒），压测日志里按名字给出平均与最大值。
    static func cost(_ name: String, since t0: CFTimeInterval) {
        let ms = (CACurrentMediaTime() - t0) * 1000
        lock.lock(); defer { lock.unlock() }
        var c = costs[name] ?? (0, 0, 0)
        c.sum += ms; c.n += 1; c.max = max(c.max, ms)
        costs[name] = c
    }

    static func drainCosts() -> String {
        lock.lock(); defer { lock.unlock() }
        let s = costs.keys.sorted().map { k in let c = costs[k]!; return String(format: "%@=%.1f/%.1fms×%d", k, c.sum / Double(c.n), c.max, c.n) }
        costs = [:]
        return s.joined(separator: " ")
    }

    /// 取走上一段的统计并清零：每层（帧率，最长间隔毫秒）。
    static func drain() -> [(Layer, fps: Int, gapMs: Int)] {
        let t = CACurrentMediaTime()
        lock.lock(); defer { lock.unlock() }
        let span = max(0.001, t - windowStart)
        let out = Layer.allCases.map { l in (l, Int((Double(counts[l.rawValue]) / span).rounded()), Int((maxGap[l.rawValue] * 1000).rounded())) }
        counts = counts.map { _ in 0 }
        maxGap = maxGap.map { _ in 0 }
        windowStart = t
        return out
    }
}

/// 左下角的帧率读数：每半秒刷新一次，只重画自己。
struct TraceFPSLabel: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let stats = TraceFPS.benchOwnsStats ? [] : TraceFPS.drain()
            let hz = NSScreen.main?.maximumFramesPerSecond ?? 60
            let parts = stats.map { s in s.fps == 0 ? "\(s.0.name) –" : "\(s.0.name) \(s.fps)·\(s.gapMs)ms" }
            Text(verbatim: "FPS  " + parts.joined(separator: "  ") + "  /\(hz)Hz")
                .font(WgInk.mono(.micro, .medium)).tracking(1).foregroundStyle(WgInk.ink3).monospacedDigit()
                .help("各层每秒实际画出的帧数 · 这半秒里最长的一帧间隔；/后为屏幕最高刷新率。静止时不画，显示 –")
        }
    }
}

// MARK: - 压测（调试用）
// `--args -WgSenseInitialTab trace -WgSenseTraceBench /path/log.txt`：打开路由追踪页后按固定剧本自动操作镜头，
// 每半秒把各层帧率连同当前场景写进日志，跑完退出。模拟输入按 120Hz 送，和触控板事件频率一致。

@MainActor
enum TraceBench {
    private static var log: FileHandle?
    private static var phase = "start"

    static func runIfRequested() async {
        let args = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        // `-WgSenseTraceCam 经度,纬度,缩放`：打开后镜头直接停在这里（截图核对底图用）。
        // 西经是负数，以 - 开头会被当成参数名，前面加个空格：`-WgSenseTraceCam " -118.3,34.3,12"`
        if let s = args["WgSenseTraceCam"] as? String {
            let v = s.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if v.count == 3 {
                try? await Task.sleep(for: .seconds(4))      // 等开场动画走完，免得被它盖掉
                TraceMapModel.shared.takeOver(TraceCam(lon: v[0], lat: v[1], zoom: v[2]), animated: false)
            }
        }
        // `-WgSenseTraceRun 目标`：打开后自动追踪一次（截图核对航线与边界辐射用）
        if let host = args["WgSenseTraceRun"] as? String {
            try? await Task.sleep(for: .seconds(args["WgSenseTraceCam"] == nil ? 2 : 0.5))
            TraceStore.shared.start(host, tunnelInterface: nil)
        }
        guard let path = args["WgSenseTraceBench"] as? String else { return }
        FileManager.default.createFile(atPath: path, contents: nil)
        log = FileHandle(forWritingAtPath: path)
        write("screen \(NSScreen.main?.maximumFramesPerSecond ?? 0)Hz")
        let m = TraceMapModel.shared
        TraceFPS.benchOwnsStats = true
        let sampler = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                let s = TraceFPS.drain().map { "\($0.0.name)=\($0.fps)/\($0.gapMs)ms" }.joined(separator: " ")
                write("\(phase)\t\(s)\t\(TraceFPS.drainCosts())")
            }
        }
        // 主线程卡顿探针：每 4ms 醒一次，记下比预期晚了多少（主线程被占住的时长）
        let probe = Task { @MainActor in
            while !Task.isCancelled {
                let t0 = CACurrentMediaTime()
                try? await Task.sleep(for: .milliseconds(4))
                TraceFPS.cost("main.lag", since: t0 + 0.004)
            }
        }
        defer { probe.cancel() }
        try? await Task.sleep(for: .seconds(4))
        _ = TraceFPS.drain()

        phase = "spin"            // 待机自转（开场后停手 4 秒才开始转）
        m.takeOver(TraceCam(lon: 100, lat: 30, zoom: 1.2), animated: false)
        m.flight.setSpin(true)
        try? await Task.sleep(for: .seconds(8))

        phase = "fling"           // 拖动松手的惯性
        m.takeOver(TraceCam(lon: 100, lat: 30, zoom: 1.2), animated: false)
        m.flight.release(lon: 160, lat: 0)
        try? await Task.sleep(for: .seconds(3))

        phase = "fly"             // 按钮缩放的飞行（地球 → 平面 → 地球）
        m.zoom(by: 15); try? await Task.sleep(for: .seconds(1.6))
        m.zoom(by: 1 / 15); try? await Task.sleep(for: .seconds(1.6))

        phase = "drag-globe"      // 地球形态下拖动
        await feed(seconds: 3) { m.nudge(dx: 6, dy: 1) }

        phase = "pinch"           // 连续捏合放大，跨过地球 → 平面的展平（按时间算缩放，掉帧也走完全程）
        let t0 = Date()
        await feed(seconds: 3) {
            let k = min(1, Date().timeIntervalSince(t0) / 3)
            m.takeOver(TraceCam(lon: 114, lat: 25, zoom: 0.9 * pow(20 / 0.9, k)), animated: false)
        }

        phase = "drag-morph"      // 展平过渡中（缩放 10）拖动
        m.takeOver(TraceCam(lon: 114, lat: 25, zoom: 10), animated: false)
        await feed(seconds: 3) { m.nudge(dx: 6, dy: 1) }

        phase = "drag-flat"       // 完全展平（缩放 20）拖动
        m.takeOver(TraceCam(lon: 114, lat: 25, zoom: 20), animated: false)
        await feed(seconds: 3) { m.nudge(dx: 6, dy: 1) }

        phase = "scroll-pan"      // 双指按下拖：挪视图
        await feed(seconds: 2) { m.pan.width += 2 }
        m.follow()

        phase = "trace"           // 追踪中：航线层逐帧画
        TraceStore.shared.start("www.tsinghua.edu.cn", tunnelInterface: nil)
        try? await Task.sleep(for: .seconds(20))

        sampler.cancel()
        write("done")
        try? log?.close()
        NSApp.terminate(nil)
    }

    private static func feed(seconds: Double, _ step: () -> Void) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            step()
            try? await Task.sleep(for: .microseconds(8333))
        }
    }

    private static func write(_ s: String) {
        log?.write(Data((String(format: "%.2f\t", CACurrentMediaTime()) + s + "\n").utf8))
    }
}
