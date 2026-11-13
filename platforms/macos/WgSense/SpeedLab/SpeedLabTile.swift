import SwiftUI

// 侧栏「测速」磁贴：入口 + 一眼看结果。
//
//   小：标题 + 上次（或进行中）读数
//   中：右侧两块迷你表盘
//   大：迷你表盘 + 场景按钮，不进页面直接开测
// 平时是静态画面；只有测速进行中才随读数更新。

struct SLSpeedTile: View {
    var size: TileSize
    var isSelected: Bool
    var isEditMode: Bool
    var open: () -> Void
    @ObservedObject private var lab = SpeedLabStore.shared

    var body: some View {
        let last = lab.lastResult
        VStack(alignment: .leading, spacing: WgSpace.s) {
            HStack(alignment: .center, spacing: WgSpace.m) {
                VStack(alignment: .leading, spacing: WgSpace.xs) {
                    Text(TileKind.speedtest.title).font(.system(size: WgType.title, weight: .bold)).lineLimit(1)
                    Text(verbatim: status(last))
                        .font(.system(size: WgType.body, weight: .medium).monospacedDigit())
                        .foregroundStyle(lab.error != nil && !lab.running ? WgInk.alert : WgInk.ink3)
                        .lineLimit(1)
                }
                if size == .medium {
                    Spacer(minLength: 4)
                    gauges(last).frame(height: 60)
                }
            }
            if size == .large {
                gauges(last).frame(height: 74).frame(maxWidth: .infinity)
                Spacer(minLength: 0)
                quickButtons
            }
        }
        .wgPadding(.leading, .l).wgPadding(.trailing, .m).wgPadding(.vertical, .m)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: size == .large ? .topLeading : .leading)
        .overlay(alignment: .topLeading) {
            Rectangle().fill(WgInk.ink.opacity(lab.running ? 0.9 : 0.45)).frame(width: 3, height: 20)
        }
        .overlay(alignment: .topTrailing) {
            Text(verbatim: TileKind.speedtest.code).font(WgInk.mono(.micro)).tracking(1).foregroundStyle(WgInk.ink4).wgPadding(.s)
        }
        .wgInteractiveSurface(isSelected: isSelected, isEnabled: !isEditMode, action: open)
    }

    private func status(_ last: SLResult?) -> String {
        let unit = lab.params.unit
        if lab.running {
            if let v = lab.upNow ?? lab.downNow {
                return "\(lab.phase.title) \(SLFormat.compact(v, unit: unit)) \(unit.title)"
            }
            return lab.note
        }
        guard let last else { return String(localized: "未测", bundle: .wgLocalized) }
        if let error = last.error { return error }
        // 小磁贴没有表盘：读数写在状态行；中、大磁贴读数在表盘上，状态行只写时间。
        if size == .small {
            return "↓\(SLFormat.compact(last.down?.stable, unit: unit)) ↑\(SLFormat.compact(last.up?.stable, unit: unit))"
        }
        return String(localized: "上次 ", bundle: .wgLocalized) + last.date.formatted(.relative(presentation: .numeric, unitsStyle: .narrow))
    }

    /// 两条通道的缩略：长度 = 吞吐 / 协商速率（和 HUD 两翼同一含义），右侧读数。
    private func gauges(_ last: SLResult?) -> some View {
        let scale = Double(lab.running ? (lab.linkMbps ?? 1000) : (last?.linkMbps ?? 1000))
        return VStack(alignment: .leading, spacing: WgSpace.s) {
            // 测速中下行测完（上行已开始）就定格在下行稳态值，不显示收尾的 0
            channel("↓", lab.running ? (lab.upNow != nil ? lab.downStat?.stable ?? lab.downNow : lab.downNow) : last?.down?.stable, scale)
            channel("↑", lab.running ? lab.upNow : last?.up?.stable, scale)
        }
        .frame(width: 128)
    }

    private func channel(_ arrow: String, _ value: Double?, _ scale: Double) -> some View {
        HStack(spacing: WgSpace.s) {
            Text(verbatim: arrow).font(WgInk.mono(.caption, .bold)).foregroundStyle(WgInk.ink3)
            GeometryReader { geo in
                let f = CGFloat(min(1, (value ?? 0) / max(scale, 1)))
                ZStack(alignment: .leading) {
                    ChamferShape(tr: 4).fill(WgInk.field)
                    ChamferShape(tr: 4).fill(WgInk.ink).frame(width: geo.size.width * f)
                }
            }
            .frame(height: 8)
            Text(verbatim: SLFormat.compact(value, unit: lab.params.unit))
                .font(WgInk.mono(.caption, .medium)).foregroundStyle(value == nil ? WgInk.ink4 : WgInk.ink)
                .frame(width: 34, alignment: .trailing)
        }
    }

    private var quickButtons: some View {
        HStack(spacing: WgSpace.s) {
            if lab.running {
                Button { lab.stop() } label: { Label("停止", systemImage: "stop.fill") }
                    .buttonStyle(SLChipStyle(selected: true))
            } else {
                // 最近用过的线路（从历史得出）；没有历史就按当前线路开测
                let recent = lab.recentRoutes()
                if recent.isEmpty {
                    Button("开测") { lab.start() }.buttonStyle(SLChipStyle(selected: false))
                }
                ForEach(recent) { r in
                    Button(SLHistoryList.routeText(r)) {
                        lab.use(r)
                        lab.start()
                    }
                    .buttonStyle(SLChipStyle(selected: false))
                    .lineLimit(1)
                    .help("开测：\(SLHistoryList.routeText(r))")
                }
            }
            Spacer(minLength: 0)
        }
        .disabled(isEditMode)
    }
}
