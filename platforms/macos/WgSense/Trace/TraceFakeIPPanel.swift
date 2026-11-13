import SwiftUI

// Fake-IP 适配板块：常驻在右下角，和左下角图例同一颗粒度。
//   图号行：问的是哪个代理后端；中间：七步判定逐条摆出（行数恒定，只换状态与内容）；底部：开关与判定依据（兜底网段、主动访问）。

struct TraceFakeIPPanel: View {
    @ObservedObject private var fip = TraceFakeIPAdapter.shared

    // 和左下角图例同一颗粒度：等宽小字，图号行加粗，说明行最淡，行与行之间不画线
    var body: some View {
        VStack(alignment: .trailing, spacing: WgSpace.s) {
            HStack(alignment: .firstTextBaseline, spacing: WgSpace.l) {
                Text(verbatim: "FIG.02  FAKE-IP").font(WgInk.mono(.micro, .bold)).tracking(1.4).foregroundStyle(WgInk.ink2)
                Text(verbatim: fip.enabled ? String(localized: "后端 \(fip.backend ?? "—")", bundle: .wgLocalized) : String(localized: "已关闭", bundle: .wgLocalized))
                    .font(WgInk.mono(.micro, .medium)).tracking(1.2).foregroundStyle(WgInk.ink2).lineLimit(1)
            }
            Text(verbatim: String(localized: "后端解析 ≠ 系统解析 = 被接管", bundle: .wgLocalized))
                .font(WgInk.mono(.micro)).tracking(1).foregroundStyle(WgInk.ink4)
                .help("代理后端对同一域名的真实解析与系统解析不一致 = 被接管；后端答不上时，只在系统地址落进兜底网段时提示疑似")

            VStack(alignment: .trailing, spacing: WgSpace.xs) {
                ForEach(fip.steps) { step in stepRow(step) }
            }

            HStack(spacing: WgSpace.xs) {
                TraceHoloToggle(title: fip.enabled ? String(localized: "FIP 开", bundle: .wgLocalized) : String(localized: "FIP 关", bundle: .wgLocalized), on: fip.enabled) { fip.enabled.toggle() }
                    .help("关闭后只显示系统解析的原始路径，不问代理后端")
                HStack(spacing: WgSpace.xs) {
                    Text(verbatim: String(localized: "兜底", bundle: .wgLocalized)).font(WgInk.mono(.micro)).foregroundStyle(WgInk.ink3)
                    TextField("", text: $fip.fallbackRanges, prompt: Text(verbatim: TraceFakeIPAdapter.defaultRanges))
                        .textFieldStyle(.plain).font(WgInk.mono(.micro))
                        .frame(width: 112)
                }
                .wgPadding(.horizontal, .s)
                .frame(height: 28)
                .traceHolo()
                .help("CIDR，逗号或空格分隔。默认 198.18.0.0/15 是 RFC 2544 保留段，Clash 系代理常用作 fake-ip 段")
                TraceHoloToggle(title: String(localized: "主动访问", bundle: .wgLocalized), on: fip.probeConnection) { fip.probeConnection.toggle() }
                    .help("连接表里没有这条连接时，向目标发一次 HTTPS HEAD 请求，让代理后端记下它，才能读到规则与节点")
                if !fip.invalidRanges.isEmpty {
                    Text(verbatim: String(localized: "无法识别：", bundle: .wgLocalized) + fip.invalidRanges.joined(separator: ", "))
                        .font(WgInk.mono(.micro)).foregroundStyle(WgInk.warn)
                } else if fip.fallbackRanges != TraceFakeIPAdapter.defaultRanges {
                    Button("恢复默认") { fip.fallbackRanges = TraceFakeIPAdapter.defaultRanges }
                        .buttonStyle(.plain).font(WgInk.mono(.micro)).foregroundStyle(WgInk.ink3)
                }
            }
        }
    }

    private func stepRow(_ step: TraceFIPStep) -> some View {
        HStack(spacing: WgSpace.s) {
            Text(verbatim: step.code).frame(width: 18, alignment: .leading).foregroundStyle(WgInk.ink4)
            Text(verbatim: step.title).frame(width: 64, alignment: .leading).foregroundStyle(WgInk.ink3)
            Text(verbatim: mark(step.state)).frame(width: 30, alignment: .leading)
                .foregroundStyle(tint(step.state)).fontWeight(step.state == .hit ? .bold : .regular)
            Text(verbatim: step.detail.isEmpty ? "…" : step.detail).lineLimit(1).truncationMode(.middle)
                .frame(width: 180, alignment: .leading)
                .foregroundStyle(step.state == .skip || step.state == .pending ? WgInk.ink4 : WgInk.ink2)
                .help(step.detail)
        }
        .font(WgInk.mono(.micro))
    }

    private func mark(_ s: TraceFIPStep.State) -> String {
        switch s {
        case .pending: return "…"
        case .ok: return "OK"
        case .hit: return String(localized: "接管", bundle: .wgLocalized)
        case .miss: return String(localized: "缺", bundle: .wgLocalized)
        case .skip: return "—"
        }
    }

    private func tint(_ s: TraceFIPStep.State) -> Color {
        switch s {
        case .hit: return WgInk.ink
        case .miss: return WgInk.warn
        case .ok: return WgInk.ink2
        case .pending, .skip: return WgInk.ink4
        }
    }
}

/// 全息小开关（和 AUTO 同款取景框）：开时框线与角标提亮、字变白。
struct TraceHoloToggle: View {
    var title: String
    var on: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(verbatim: title).font(WgInk.mono(.micro, .bold)).tracking(1)
                .foregroundStyle(on ? WgInk.ink : WgInk.ink3)
                .wgPadding(.horizontal, .s)
                .frame(height: 28)
                .traceHolo(active: on)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
