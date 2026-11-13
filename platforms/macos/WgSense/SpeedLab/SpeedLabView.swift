import SwiftUI

// 测速台页面（规格 §8）：骨架恒定，只往里填数。
//
//   线路条（A 执行端 ▸ B 路径 ▸ C 目标，选项全部来自名册与探测）→ 双表盘 → 台账四格 → 抽屉（曲线 / 参数 / 历史 / 测速源 / 端点）

struct SpeedLabView: View {
    @ObservedObject private var lab = SpeedLabStore.shared

    @Environment(\.wgRegionColor) private var region
    @State private var tail = false
    @State private var adding = false

    var body: some View {
        WgPage(title: "测速", word: "SPEED LAB", maxWidth: 1600) {
            LazyVStack(alignment: .leading, spacing: WgSpace.l) {
                setup
                hud
                SLDrawer(key: "curve", title: String(localized: "全程曲线", bundle: .wgLocalized), code: "CRV") { SLCurve(lab: lab) }
                SLDrawer(key: "params", title: String(localized: "测法", bundle: .wgLocalized), code: "MTD", badge: lab.params == SLParams() ? "" : String(localized: "已改", bundle: .wgLocalized)) { SLMethodForm(lab: lab) }
                SLDrawer(key: "history", title: String(localized: "历史", bundle: .wgLocalized), code: "LOG", badge: lab.history.isEmpty ? "" : "\(lab.history.count)") {
                    SLHistoryList(lab: lab)
                }
                SLDrawer(key: "sources", title: String(localized: "测速源", bundle: .wgLocalized), code: "SRC") { SLSourcesForm(lab: lab) }
                SLDrawer(key: "endpoints", title: String(localized: "端点", bundle: .wgLocalized), code: "EP", badge: "\(lab.roster.count)") { SLEndpointsForm(lab: lab) }
            }
        }
        .sheet(isPresented: $adding) {
            VStack(alignment: .leading, spacing: WgSpace.m) {
                Text(verbatim: String(localized: "添加端点", bundle: .wgLocalized)).font(.system(size: WgInk.sizeSubsection, weight: .semibold))
                SLEndpointsForm(lab: lab, listing: false)
                HStack { Spacer(); Button("完成") { adding = false }.keyboardShortcut(.defaultAction) }
            }
            .wgPadding(.m).frame(width: 640)
        }
        // 测完再刷 1 秒：让收尾的闪入（0 → ⅓ → ⅔ → 1）播完，之后彻底静止
        .task(id: lab.runnerID) {
            while !Task.isCancelled {
                lab.warmRunner()
                try? await Task.sleep(for: .seconds(50))
            }
        }
        .task(id: lab.finishedAt) {
            guard lab.finishedAt != nil else { return }
            tail = true
            try? await Task.sleep(for: .seconds(1.2))
            tail = false
        }
    }

    // MARK: HUD

    /// 测速中按屏幕刷新率（垂直同步）推进画面时钟；空闲时暂停，零开销。
    private var hud: some View {
        SLHUDLayout {
            // HUD 按实际宽度画：缩放到上限后高度不变、横向展开（见 SLHUD.scale）
            TimelineView(.animation(paused: !(lab.running || tail))) { timeline in
                SLHUD(data: SLHUDData(lab), now: timeline.date)
            }
            startButton
        }
    }

    /// START / STOP：HUD 里唯一的按钮，也是白色的分配者——每个状态全屏只有一样东西是白的：
    ///   待机 = START 白底；测速中 = 读数是高光，STOP 退成描边；测完 = 结果读数是高光，START 退成灰底（仍是唯一实心块）。
    private var startButton: some View {
        let done = lab.finishedAt != nil && !lab.running
        return Button {
            if lab.running { lab.stop() } else { lab.start() }
        } label: {
            // 按设计尺寸 26pt 写，放不下时随按钮等比缩小（按钮大小由 SLHUDLayout 按 HUD 宽度给）
            Text(verbatim: lab.running ? "STOP" : "START")
                .font(.system(size: WgType.large, weight: .heavy, design: .monospaced)).tracking(10)
                .minimumScaleFactor(0.2).lineLimit(1)
                .foregroundStyle(lab.running ? Color(white: 0.84) : Color(red: 0.06, green: 0.063, blue: 0.07))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(SLPlate(shape: SLRatioChamfer(), fill: lab.running ? nil : Color(white: done ? 0.7 : 0.95),
                                    stroke: lab.running ? Color(white: 0.56) : nil))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!lab.running && lab.blocker != nil)
        .keyboardShortcut(.return, modifiers: .command)
        .help(lab.target?.isPublic == true && !lab.running ? "将占满宽带约 \(lab.params.duration * (lab.params.directions == .both ? 2 : 1) + 8) 秒" : "")
    }

    // MARK: 线路
    //
    // 一根条三段：A 执行端 ▸ B 路径 ▸ C 目标。三个都是变量，选项全部来自数据：
    // 初始全空；A/C 的选项只来自名册（「发现」探到的 + 「添加」的），B 只来自对执行端的探测。

    private var setup: some View {
        VStack(alignment: .leading, spacing: WgSpace.s) {
            route
            if let hint = lab.discoverNote ?? lab.blocker ?? pathHint ?? (lab.target?.kind == .peer ? String(localized: "WG peer 不能远程登录：要求它自己开着 iperf3 服务端（端口 \(lab.params.iperfPort)）", bundle: .wgLocalized) : nil) {
                Text(verbatim: hint).font(WgInk.mono(.caption))
                    .foregroundStyle(lab.discoverNote == nil && lab.blocker != nil ? WgInk.warn : WgInk.ink3)
            }
        }
    }

    /// A / C 菜单尾部：发现、添加。
    @ViewBuilder private var rosterActions: some View {
        Divider()
        Button(lab.discovering ? "发现中…" : "发现…") { lab.discover() }.disabled(lab.discovering)
        Button("添加…") { adding = true }
    }

    /// 探测失败时说清 B 为什么只剩系统路由。
    private var pathHint: String? {
        guard lab.pathSelectable, let e = lab.ifaceErrors[lab.runnerID] else { return nil }
        return String(localized: "探测 \(lab.runner?.name ?? "") 的网卡失败：\(e)", bundle: .wgLocalized)
    }

    /// B 的注记：选中网卡的地址与速率，或系统路由的说明。
    private var pathDetail: String {
        guard lab.pathSelectable else { return String(localized: "iperf3 · 由对端地址决定", bundle: .wgLocalized) }
        if lab.probing.contains(lab.runnerID) { return String(localized: "发现网卡中…", bundle: .wgLocalized) }
        guard let name = lab.route else { return lab.runnerIfaces.isEmpty ? String(localized: "点开发现网卡", bundle: .wgLocalized) : String(localized: "未选择", bundle: .wgLocalized) }
        if name == SLIface.system, lab.runnerIfaces.first(where: \.isSystem) == nil { return String(localized: "跟随系统路由与 DNS", bundle: .wgLocalized) }
        guard let i = lab.runnerIfaces.first(where: { $0.name == name }) else { return String(localized: "本次未发现，点开重新发现", bundle: .wgLocalized) }
        return Self.ifaceNote(i)
    }

    /// 菜单一行：显示名 · 地址（名字不是地址时）· 在哪发现。
    static func menuLine(_ ep: SLEndpoint) -> String {
        ([ep.name] + (ep.name != ep.address ? [ep.address] : []) + [ep.via]).joined(separator: "  ·  ")
    }

    static func ifaceTitle(_ i: SLIface) -> String { i.isSystem ? String(localized: "系统路由", bundle: .wgLocalized) : i.name }

    static func ifaceNote(_ i: SLIface) -> String {
        if i.isSystem { return String(localized: "跟随系统路由与 DNS · 当前走 \(i.phy)", bundle: .wgLocalized) }
        return [i.addr, i.phy != i.name ? String(localized: "经 \(i.phy)", bundle: .wgLocalized) : "", linkText(i.link), i.isDefault ? String(localized: "默认出口", bundle: .wgLocalized) : ""]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var route: some View {
        HStack(spacing: 0) {
            SLSelector(code: "A", title: String(localized: "执行端", bundle: .wgLocalized), value: lab.runner?.name ?? String(localized: "未选择", bundle: .wgLocalized),
                       detail: lab.runner?.address ?? (lab.runners.isEmpty ? String(localized: "点开发现或添加", bundle: .wgLocalized) : "")) {
                ForEach(lab.runners) { ep in
                    Button { lab.runnerID = ep.id } label: { Text(verbatim: Self.menuLine(ep)) }
                }
                rosterActions
            }
            SLJoint()
            SLSelector(code: "B", title: String(localized: "路径", bundle: .wgLocalized),
                       value: lab.pathSelectable ? (lab.route.map { $0 == SLIface.system ? String(localized: "系统路由", bundle: .wgLocalized) : $0 } ?? String(localized: "未选择", bundle: .wgLocalized)) : String(localized: "按地址", bundle: .wgLocalized),
                       detail: pathDetail,
                       enabled: lab.pathSelectable && lab.runner != nil) {
                ForEach(lab.runnerIfaces) { i in
                    Button { lab.route = i.name } label: { Text(verbatim: "\(Self.ifaceTitle(i))  ·  \(Self.ifaceNote(i))") }
                }
                if !lab.runnerIfaces.isEmpty { Divider() }
                Button(lab.probing.contains(lab.runnerID) ? "发现中…" : "发现网卡") { lab.refreshIfaces() }
            }
            SLJoint()
            SLSelector(code: "C", title: String(localized: "目标", bundle: .wgLocalized), value: lab.target?.name ?? String(localized: "未选择", bundle: .wgLocalized),
                       detail: lab.target?.address ?? (lab.targets.isEmpty ? String(localized: "点开发现或添加", bundle: .wgLocalized) : "")) {
                ForEach(lab.targets) { ep in
                    Button { lab.targetID = ep.id } label: { Text(verbatim: Self.menuLine(ep)) }
                }
                rosterActions
            }
        }
        .wgRegionContrast()
        .background(SLChamferPlate(cut: WgInk.cutControl, fill: region.fill(default: WgInk.well)))
        .disabled(lab.running)
    }

    static func linkText(_ raw: String) -> String {
        let parts = raw.split(separator: " ")
        guard let v = parts.first.flatMap({ Int($0) }) else { return raw }
        let speed = v >= 1000 && v % 1000 == 0 ? "\(v / 1000)G" : (v >= 1000 ? String(format: "%.1fG", Double(v) / 1000) : "\(v)M")
        let rest = parts.dropFirst().joined(separator: " ")
        let duplex = rest == "full" ? String(localized: "全双工", bundle: .wgLocalized) : rest == "half" ? String(localized: "半双工", bundle: .wgLocalized) : rest
        return [speed, duplex].filter { !$0.isEmpty }.joined(separator: " ")
    }

}

// MARK: - 部件

/// 场景小签：选中 = 白色弱玻璃，其余发丝框。
struct SLChipStyle: ButtonStyle {
    var selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: WgType.body, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? WgInk.ink : WgInk.ink3)
            .wgPadding(.horizontal, .m).frame(height: 22)
            .background {
                if selected {
                    Color.clear.wgGlassAccent(ChamferShape(tr: 6))
                } else {
                    ChamferShape(tr: 6).strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// 线路条上的一段：标签 / 值 / 地址，整段可点开菜单。
struct SLSelector<Items: View>: View {
    var code: String
    var title: String
    var value: String
    var detail: String
    var enabled = true
    @ViewBuilder var items: () -> Items

    var body: some View {
        Menu {
            items()
        } label: {
            HStack(spacing: WgSpace.s) {
                VStack(alignment: .leading, spacing: WgSpace.xs) {
                    Text(verbatim: "\(code) / \(title)").font(WgInk.mono(.caption, .medium)).tracking(1.2).foregroundStyle(WgInk.ink3)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: value).font(.system(size: WgType.sub, weight: .medium)).foregroundStyle(WgInk.ink).lineLimit(1)
                        Text(verbatim: detail.isEmpty ? " " : detail).font(WgInk.mono(.micro)).foregroundStyle(WgInk.ink3).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if enabled {
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: WgType.micro, weight: .semibold)).foregroundStyle(WgInk.ink3)
                }
            }
            .wgPadding(.horizontal, .l).wgPadding(.vertical, .m)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.55)
        .frame(maxWidth: .infinity)
    }
}

/// 两段之间的接缝：竖发丝线，正中一枚箭头指明 A → B → C。
private struct SLJoint: View {
    var body: some View {
        VStack(spacing: WgSpace.xs) {
            Rectangle().fill(Color.primary.opacity(0.14)).frame(width: 1)
            Image(systemName: "arrowtriangle.right.fill").font(.system(size: WgType.micro)).foregroundStyle(Color.primary.opacity(0.45))
            Rectangle().fill(Color.primary.opacity(0.14)).frame(width: 1)
        }
        .frame(width: 8)
        .wgPadding(.vertical, .m)
    }
}

/// 抽屉：默认收起，展开状态按 key 记住。
struct SLDrawer<Content: View>: View {
    var key: String
    var title: String
    var code: String
    var badge: String = ""
    @ViewBuilder var content: () -> Content
    @AppStorage private var open: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.wgRegionColor) private var region

    init(key: String, title: String, code: String, badge: String = "", @ViewBuilder content: @escaping () -> Content) {
        self.key = key; self.title = title; self.code = code; self.badge = badge; self.content = content
        _open = AppStorage(wrappedValue: false, "speedLab.drawer.\(key)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WgSpace.m) {
            Button {
                withAnimation(WgDesign.spring) { open.toggle() }
            } label: {
                HStack(spacing: WgSpace.s) {
                    Image(systemName: "chevron.right").font(.system(size: WgType.micro, weight: .bold))
                        .rotationEffect(.degrees(open ? 90 : 0)).foregroundStyle(WgInk.ink3)
                    WgTagBox(code: code, title: LocalizedStringKey(title))
                    if !badge.isEmpty { Text(verbatim: badge).font(WgInk.mono(.caption)).foregroundStyle(WgInk.ink3) }
                    SLRuler()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                content()
                    .wgPadding(.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .wgRegionContrast()
                    .background(SLChamferPlate(cut: WgInk.cutTile, fill: region.fill(default: WgInk.panelFill(scheme)), border: WgInk.panelBorder(region.scheme ?? scheme)))
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

// MARK: - 全程曲线

/// 下行虚点线、上行实线，单色墨；跑完后就是整次测量的全程图。
struct SLCurve: View {
    @ObservedObject var lab: SpeedLabStore

    var body: some View {
        let down = lab.downSeries.isEmpty ? (lab.lastForCurrent?.downSeries ?? []) : lab.downSeries
        let up = lab.upSeries.isEmpty ? (lab.lastForCurrent?.upSeries ?? []) : lab.upSeries
        let top = max(1, (down + up).max() ?? 1) * 1.1
        let live = !lab.upSeries.isEmpty
        let upSide = live ? lab.upSide : lab.lastForCurrent.map { $0.upSide ?? .sender }
        VStack(alignment: .leading, spacing: WgSpace.s) {
            Canvas { ctx, size in
                let tick = lab.downSeries.isEmpty && lab.upSeries.isEmpty ? (lab.lastForCurrent?.tick ?? 1) : lab.tick
                let n = max(Int(Double(lab.params.duration) / tick), down.count, up.count, 2)
                let upTick = live ? lab.upTick : (lab.lastForCurrent?.upTick ?? tick)
                let upN = upTick == tick ? n : max(Int(Double(lab.params.duration) / upTick), up.count, 2)
                for f in [0.0, 0.5, 1.0] {
                    var g = Path()
                    let y = size.height * (1 - f)
                    g.move(to: CGPoint(x: 0, y: y)); g.addLine(to: CGPoint(x: size.width, y: y))
                    ctx.stroke(g, with: .color(Color.primary.opacity(0.12)), style: StrokeStyle(lineWidth: 0.5, dash: [1, 4]))
                    ctx.draw(Text(verbatim: SLFormat.compact(top * f, unit: lab.params.unit)).font(.system(size: WgType.micro, design: .monospaced))
                        .foregroundColor(Color.primary.opacity(0.4)), at: CGPoint(x: 4, y: max(6, y - 6)), anchor: .leading)
                }
                func line(_ series: [Double], n: Int, dash: [CGFloat], half: Int) {
                    guard series.count > 1 else { return }
                    var p = Path()
                    let width = size.width / 2
                    for (i, v) in series.enumerated() {
                        let x = CGFloat(half) * width + width * CGFloat(i) / CGFloat(n - 1)
                        let y = size.height * (1 - CGFloat(v / top))
                        i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
                    }
                    ctx.stroke(p, with: .color(.primary), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, dash: dash))
                }
                line(down, n: n, dash: [2, 2.5], half: 0)
                line(up, n: upN, dash: [], half: 1)
                var mid = Path()
                mid.move(to: CGPoint(x: size.width / 2, y: 0)); mid.addLine(to: CGPoint(x: size.width / 2, y: size.height))
                ctx.stroke(mid, with: .color(Color.primary.opacity(0.18)), lineWidth: 0.5)
            }
            .frame(height: 130)
            // 拖动缩放时弹性快照把曲线整体横向拉伸（真排版也是这样），而不是把线拆开
            HStack {
                Text(verbatim: String(localized: "↓ 下行 ┄", bundle: .wgLocalized)).font(WgInk.mono(.micro)).foregroundStyle(WgInk.ink3)
                Spacer()
                Text(verbatim: String(localized: "↑ 上行 ─", bundle: .wgLocalized) + (upSide.map { " \($0.title)" } ?? "")).font(WgInk.mono(.micro)).foregroundStyle(WgInk.ink3)
            }
        }
    }
}

// MARK: - 参数

/// 测法：一次测速里每个决定都摊开——分阶段列出取值（可改，改过的标出、可逐项恢复），
/// 并写出这一步在执行端实际跑的命令。
struct SLMethodForm: View {
    @ObservedObject var lab: SpeedLabStore
    private let factory = SLParams()
    /// 正在编辑的那一行（标题）。其余行只是文字，整行一个点击区。
    @State private var editing: String?

    private var m: SLParams { lab.params }
    private var nic: String {
        if let r = lab.route, r != SLIface.system { return r }
        return String(localized: "<计数网卡>", bundle: .wgLocalized)
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: WgSpace.m) {
            HStack {
                Text(verbatim: String(localized: "每一项都会影响测出来的数。改过的项标 ●，可单项恢复；每次测速会把当时的测法存进历史。", bundle: .wgLocalized))
                    .font(.system(size: WgType.body)).foregroundStyle(WgInk.ink3)
                Spacer()
                Button("全部恢复出厂") { lab.params = SLParams() }.disabled(m == factory)
            }

            section(String(localized: "通用", bundle: .wgLocalized), commands: [
                String(localized: "# 采样：每 \(SLParams.num(m.tick)) 秒读一次网卡累计字节，相邻两次之差 ÷ 实际间隔 = 速率", bundle: .wgLocalized),
                "cat /sys/class/net/\(nic)/statistics/rx_bytes /sys/class/net/\(nic)/statistics/tx_bytes   # Linux",
                "netstat -ibn -I \(nic)   # macOS",
                String(localized: "# 空载延迟：先空跑 \(m.idleSeconds) 秒，期间与测速全程一直 ping", bundle: .wgLocalized),
                String(localized: "ping \(m.pingHost.isEmpty ? String(localized: "<公网测速：\(m.dns)｜iperf3：对端>", bundle: .wgLocalized) : m.pingHost)", bundle: .wgLocalized),
            ]) {
                pick(String(localized: "方向", bundle: .wgLocalized), String(localized: "测哪几个方向，依次进行", bundle: .wgLocalized), \.directions, SLDirections.allCases, title: \.title)
                pick(String(localized: "单位", bundle: .wgLocalized), String(localized: "只影响显示", bundle: .wgLocalized), \.unit, SLUnit.allCases, title: \.title)
                int(String(localized: "每个方向时长", bundle: .wgLocalized), String(localized: "下行、上行各跑多久", bundle: .wgLocalized), \.duration, 3...120, String(localized: "秒", bundle: .wgLocalized))
                dbl(String(localized: "采样间隔", bundle: .wgLocalized), String(localized: "多久读一次计数；执行端不支持小数 sleep 时自动退到 1 秒", bundle: .wgLocalized), \.tick, 0.05...2, step: 0.05, String(localized: "秒", bundle: .wgLocalized))
                int(String(localized: "空载延迟时长", bundle: .wgLocalized), String(localized: "开跑前不加负载、只测延迟的时长", bundle: .wgLocalized), \.idleSeconds, 0...30, String(localized: "秒", bundle: .wgLocalized))
                text(String(localized: "ping 对象", bundle: .wgLocalized), String(localized: "空 = 公网测速 ping 下面的 DNS，iperf3 ping 对端", bundle: .wgLocalized), \.pingHost, placeholder: String(localized: "自动", bundle: .wgLocalized))
                int(String(localized: "看门狗余量", bundle: .wgLocalized), String(localized: "总时长 × 2 再加这么多秒还没结束就强制收尾", bundle: .wgLocalized), \.watchdogExtra, 10...600, String(localized: "秒", bundle: .wgLocalized))
            }

            section(String(localized: "寻址", bundle: .wgLocalized), commands: [
                String(localized: "nslookup <测速域名> \(m.dns)          # 绑网卡时用它解析，绕开系统 DNS / fake-ip", bundle: .wgLocalized),
                String(localized: "nslookup \(m.probeDomain)              # 探测：系统 DNS 答 198.18.x 即被 fake-ip 接管", bundle: .wgLocalized),
                m.exitIPURL.isEmpty ? String(localized: "# 不查出口 IP", bundle: .wgLocalized) : String(localized: "curl -s \(m.exitIPURL)   # 出口 IP", bundle: .wgLocalized),
            ]) {
                text(String(localized: "真实 DNS", bundle: .wgLocalized), String(localized: "绑网卡测速时解析测速域名；也用来判定「系统路由」实际走哪张网卡", bundle: .wgLocalized), \.dns, placeholder: "IP")
                text(String(localized: "fake-ip 探测域名", bundle: .wgLocalized), String(localized: "探测时用系统 DNS 解析它，看是否被代理接管", bundle: .wgLocalized), \.probeDomain, placeholder: String(localized: "域名", bundle: .wgLocalized))
                text(String(localized: "出口 IP 查询", bundle: .wgLocalized), String(localized: "空 = 不查", bundle: .wgLocalized), \.exitIPURL, placeholder: String(localized: "不查", bundle: .wgLocalized))
                text("User-Agent", String(localized: "所有 HTTP 请求带的 UA", bundle: .wgLocalized), \.userAgent, placeholder: "UA")
            }

            section(String(localized: "公网 · 选源", bundle: .wgLocalized), commands: [
                String(localized: "# 每个候选源并行试跑，速度相加", bundle: .wgLocalized),
                String(localized: "curl -s -o /dev/null -m \(m.pickDownSeconds) <下行源>   × \(m.pickDownConns) 并行", bundle: .wgLocalized),
                String(localized: "dd if=/dev/zero bs=1M count=\(m.pickUpMB) | curl -s -o /dev/null -m \(m.pickUpSeconds) -X POST -T - <上行源>", bundle: .wgLocalized),
                String(localized: "# 比最快的慢 \(SLParams.num(m.pickSlowRatio)) 倍以上的淘汰；下行留前 \(m.pickDownKeep) 个，上行留前 \(m.pickUpKeep) 个", bundle: .wgLocalized),
                String(localized: "# 跳转逐跳手动跟随（每跳用真实 DNS 解析），最多 \(m.redirectMax) 跳、每跳 \(m.redirectTimeout) 秒", bundle: .wgLocalized),
            ]) {
                int(String(localized: "下行试跑连接数", bundle: .wgLocalized), String(localized: "每个源同时开几条", bundle: .wgLocalized), \.pickDownConns, 1...16, String(localized: "条", bundle: .wgLocalized))
                int(String(localized: "下行试跑时长", bundle: .wgLocalized), "", \.pickDownSeconds, 1...15, String(localized: "秒", bundle: .wgLocalized))
                int(String(localized: "上行试跑数据量", bundle: .wgLocalized), "", \.pickUpMB, 1...1024, "MB")
                int(String(localized: "上行试跑时长", bundle: .wgLocalized), "", \.pickUpSeconds, 1...15, String(localized: "秒", bundle: .wgLocalized))
                dbl(String(localized: "淘汰倍数", bundle: .wgLocalized), String(localized: "比最快的源慢这么多倍以上就不用", bundle: .wgLocalized), \.pickSlowRatio, 1...20, step: 0.5, String(localized: "倍", bundle: .wgLocalized))
                int(String(localized: "下行保留源数", bundle: .wgLocalized), "", \.pickDownKeep, 1...10, String(localized: "个", bundle: .wgLocalized))
                int(String(localized: "上行保留源数", bundle: .wgLocalized), "", \.pickUpKeep, 1...10, String(localized: "个", bundle: .wgLocalized))
                int(String(localized: "跳转上限", bundle: .wgLocalized), "", \.redirectMax, 0...10, String(localized: "跳", bundle: .wgLocalized))
                int(String(localized: "每跳超时", bundle: .wgLocalized), "", \.redirectTimeout, 1...30, String(localized: "秒", bundle: .wgLocalized))
                int(String(localized: "坏源退役", bundle: .wgLocalized), String(localized: "连续失败这么多次后不再试，全部退役时全部重试", bundle: .wgLocalized), \.retireAfter, 1...20, String(localized: "次", bundle: .wgLocalized))
            }

            section(String(localized: "公网 · 下行 / 上行", bundle: .wgLocalized), commands: [
                String(localized: "curl -s -o /dev/null \(lab.route.map { $0 == SLIface.system ? "" : String(localized: "--interface \($0) --resolve <域名:端口:IP> ", bundle: .wgLocalized) } ?? "")--speed-limit \(Int(m.stallMBps * 1_048_576)) --speed-time \(m.stallSeconds) <下行源>   × \(m.httpDownThreads)，到点为止，断了重连", bundle: .wgLocalized),
                String(localized: "dd if=/dev/zero bs=1M count=\(m.upChunkMB) | curl -s -o /dev/null -X POST -T - <上行源>   × \(m.httpUpThreads)，单条长连接", bundle: .wgLocalized),
                String(localized: "# 线程按入选源轮流分配；速率读的是网卡计数，不用 curl 自报", bundle: .wgLocalized),
            ]) {
                int(String(localized: "下行线程", bundle: .wgLocalized), "", \.httpDownThreads, 1...64, String(localized: "条", bundle: .wgLocalized))
                dbl(String(localized: "卡死阈值", bundle: .wgLocalized), String(localized: "低于这个速度持续下面的秒数就断开换节点", bundle: .wgLocalized), \.stallMBps, 0...100, step: 0.5, "MB/s")
                int(String(localized: "卡死判定时长", bundle: .wgLocalized), "", \.stallSeconds, 1...30, String(localized: "秒", bundle: .wgLocalized))
                int(String(localized: "上行线程", bundle: .wgLocalized), "", \.httpUpThreads, 1...32, String(localized: "条", bundle: .wgLocalized))
                int(String(localized: "每条上行推送量", bundle: .wgLocalized), String(localized: "一条连接推完这么多再重连", bundle: .wgLocalized), \.upChunkMB, 64...65536, "MB")
            }

            section(String(localized: "iperf3（目标是另一台机器）", bundle: .wgLocalized), commands: [
                String(localized: "iperf3 -s -p \(m.iperfPort) -D -i \(SLParams.num(max(m.tick, 0.1))) -f m --forceflush --logfile <日志>   # 对端；端口被占顺延到 \(m.iperfPort + m.iperfPortSpan)，\(m.iperfServerTTL) 秒后自退", bundle: .wgLocalized),
                String(localized: "iperf3 -c <对端> -p \(m.iperfPort) -P \(m.iperfStreams) -t \(m.duration)\(m.iperfRate == .tool ? " -i \(SLParams.num(m.tick))" : "") -R   # 下行；上行去掉 -R，加 --get-server-output", bundle: .wgLocalized),
                m.iperfRate == .tool ? String(localized: "# 下行速率取 iperf3 每 \(SLParams.num(m.tick)) 秒报的 [SUM] 行", bundle: .wgLocalized) : String(localized: "# 下行速率读网卡计数，iperf3 只造流量", bundle: .wgLocalized),
                String(localized: "# 上行取接收端：实时回传对端日志的 [SUM] 行；对端不是我们起的，测完用 --get-server-output 带回的换掉；都拿不到才用发送端，读数旁标 src", bundle: .wgLocalized),
                String(localized: "sleep \(m.directionGap)   # 两个方向之间", bundle: .wgLocalized),
            ]) {
                int(String(localized: "并发流", bundle: .wgLocalized), "", \.iperfStreams, 1...64, String(localized: "条", bundle: .wgLocalized))
                int(String(localized: "端口", bundle: .wgLocalized), "", \.iperfPort, 1024...65000, "")
                int(String(localized: "端口顺延范围", bundle: .wgLocalized), String(localized: "被占时往后试几个", bundle: .wgLocalized), \.iperfPortSpan, 0...50, String(localized: "个", bundle: .wgLocalized))
                pick(String(localized: "速率来源", bundle: .wgLocalized), String(localized: "网卡计数与公网测速同一把尺子；iperf3 自报只算它自己的流量。上行有接收端数据时不看这一项", bundle: .wgLocalized), \.iperfRate, SLRateSource.allCases, title: \.title)
                int(String(localized: "方向间隔", bundle: .wgLocalized), "", \.directionGap, 0...10, String(localized: "秒", bundle: .wgLocalized))
                int(String(localized: "服务端寿命", bundle: .wgLocalized), String(localized: "App 忘了停时服务端自己退出", bundle: .wgLocalized), \.iperfServerTTL, 30...3600, String(localized: "秒", bundle: .wgLocalized))
            }

            section(String(localized: "结果怎么算", bundle: .wgLocalized), commands: [
                String(localized: "# 去掉前 \(SLParams.num(m.warmupSeconds)) 秒（爬坡），剩下的取\(m.statistic.title) = 稳定值", bundle: .wgLocalized),
                String(localized: "# \(SLParams.num(m.peakWindow)) 秒滑动平均的最大值 = 峰值", bundle: .wgLocalized),
                String(localized: "# 最后 \(SLParams.num(m.flatWindow)) 秒里 \(Int(m.flatShare * 100))% 的采样落在稳定值 ±\(SLParams.num(m.flatTolerance * 100))% 内 = 平稳", bundle: .wgLocalized),
                String(localized: "# 负载延迟 = 该方向测速期间 RTT 的中位数", bundle: .wgLocalized),
            ]) {
                pick(String(localized: "稳定值统计量", bundle: .wgLocalized), "", \.statistic, SLStatistic.allCases, title: \.title)
                dbl(String(localized: "预热丢弃", bundle: .wgLocalized), String(localized: "开头这段不计入稳定值", bundle: .wgLocalized), \.warmupSeconds, 0...10, step: 0.5, String(localized: "秒", bundle: .wgLocalized))
                dbl(String(localized: "峰值窗口", bundle: .wgLocalized), "", \.peakWindow, 0.1...5, step: 0.1, String(localized: "秒", bundle: .wgLocalized))
                dbl(String(localized: "平稳判定窗口", bundle: .wgLocalized), "", \.flatWindow, 1...20, step: 0.5, String(localized: "秒", bundle: .wgLocalized))
                dbl(String(localized: "平稳容差", bundle: .wgLocalized), "", \.flatTolerance, 0.01...0.5, step: 0.01, "×")
                dbl(String(localized: "平稳占比", bundle: .wgLocalized), "", \.flatShare, 0.5...1, step: 0.05, "×")
            }
        }
        .disabled(lab.running)
    }

    // MARK: 版式

    private func section<C: View>(_ title: String, commands: [String], @ViewBuilder _ rows: () -> C) -> some View {
        VStack(alignment: .leading, spacing: WgSpace.s) {
            Text(verbatim: title).font(.system(size: WgType.sub, weight: .semibold))
            rows()
            Text(verbatim: commands.joined(separator: "\n"))
                .font(WgInk.mono(.caption)).foregroundStyle(WgInk.ink2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .wgPadding(.m)
                .background(SLChamferPlate(cut: WgInk.cutControl, bottomLeft: false, fill: WgInk.well))
        }
    }

    private func row<V: Equatable, C: View>(_ title: String, _ note: String, _ kp: WritableKeyPath<SLParams, V>,
                                             value: String, @ViewBuilder _ editor: () -> C) -> some View {
        let changed = m[keyPath: kp] != factory[keyPath: kp], open = editing == title
        return HStack(spacing: WgSpace.s) {
            Text(verbatim: changed ? "●" : " ").font(.system(size: WgType.micro)).foregroundStyle(WgInk.ink).frame(width: 8)
            Text(verbatim: title).font(.system(size: WgType.sub)).foregroundStyle(WgInk.ink2).frame(width: 130, alignment: .leading)
            Text(verbatim: note).font(.system(size: WgType.body)).foregroundStyle(WgInk.ink3).lineLimit(1)
            Spacer(minLength: 8)
            if open {
                editor()
                Image(systemName: "arrow.uturn.backward").foregroundStyle(WgInk.ink3).opacity(changed ? 1 : 0.3)
                    .onTapGesture { if changed && !lab.running { lab.params[keyPath: kp] = factory[keyPath: kp] } }
            } else {
                Text(verbatim: value).font(.system(size: WgType.sub, design: .monospaced)).foregroundStyle(WgInk.ink).lineLimit(1)
            }
        }
        .wgPadding(.vertical, .zero)
        .contentShape(Rectangle())
        .onTapGesture { if !lab.running { editing = open ? nil : title } }
    }

    // 控件：平时只是文字（−/+ 步进、点数值直接输入、点选项切下一个）。整页常驻几十个原生步进器/输入框时，
    // 滚动中焦点系统每帧逐个重算它们的位置，测速页因此掉帧到 68%。

    private func int(_ title: String, _ note: String, _ kp: WritableKeyPath<SLParams, Int>, _ range: ClosedRange<Int>, _ unit: String) -> some View {
        row(title, note, kp, value: "\(m[keyPath: kp]) \(unit)") {
            SLStepValue(text: "\(m[keyPath: kp])", unit: unit, enabled: !lab.running,
                        step: { d in lab.params[keyPath: kp] = min(range.upperBound, max(range.lowerBound, m[keyPath: kp] + d)) },
                        commit: { s in if let v = Int(s) { lab.params[keyPath: kp] = min(range.upperBound, max(range.lowerBound, v)) } })
        }
    }

    private func dbl(_ title: String, _ note: String, _ kp: WritableKeyPath<SLParams, Double>, _ range: ClosedRange<Double>,
                     step: Double, _ unit: String) -> some View {
        row(title, note, kp, value: "\(SLParams.num((m[keyPath: kp] * 100).rounded() / 100)) \(unit)") {
            SLStepValue(text: SLParams.num((m[keyPath: kp] * 100).rounded() / 100), unit: unit, enabled: !lab.running,
                        step: { d in lab.params[keyPath: kp] = min(range.upperBound, max(range.lowerBound, m[keyPath: kp] + Double(d) * step)) },
                        commit: { s in if let v = Double(s) { lab.params[keyPath: kp] = min(range.upperBound, max(range.lowerBound, v)) } })
        }
    }

    private func text(_ title: String, _ note: String, _ kp: WritableKeyPath<SLParams, String>, placeholder: String) -> some View {
        row(title, note, kp, value: m[keyPath: kp].isEmpty ? placeholder : m[keyPath: kp]) {
            SLInlineEdit(value: m[keyPath: kp], placeholder: placeholder, enabled: !lab.running) { lab.params[keyPath: kp] = $0 }
                .frame(width: 260, alignment: .trailing)
        }
    }

    private func pick<V: Hashable & Identifiable>(_ title: String, _ note: String, _ kp: WritableKeyPath<SLParams, V>,
                                                 _ options: [V], title label: KeyPath<V, String>) -> some View {
        row(title, note, kp, value: m[keyPath: kp][keyPath: label]) {
            // 点哪个选哪个：选项平铺成文字，选中的满墨加下划线
            HStack(spacing: WgSpace.m) {
                ForEach(options) { o in
                    let on = o == m[keyPath: kp]
                    Text(verbatim: o[keyPath: label]).font(.system(size: WgType.sub, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? WgInk.ink : WgInk.ink3)
                        .overlay(alignment: .bottom) { Rectangle().fill(on ? WgInk.ink : .clear).frame(height: 1).offset(y: 2) }
                        .contentShape(Rectangle())
                        .onTapGesture { if !lab.running { lab.params[keyPath: kp] = o } }
                }
            }
        }
    }
}

// MARK: - 历史

struct SLHistoryList: View {
    @ObservedObject var lab: SpeedLabStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if lab.history.isEmpty {
                Text("还没有测速记录").font(.system(size: WgType.sub)).foregroundStyle(WgInk.ink3)
            } else {
                SLHistoryStrip(history: lab.history, unit: lab.params.unit).wgPadding(.bottom, .m)
                ForEach(lab.history.prefix(30)) { r in
                    HStack(spacing: WgSpace.m) {
                        Text(verbatim: r.date.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute()))
                            .font(WgInk.mono(.caption)).foregroundStyle(WgInk.ink3).frame(width: 92, alignment: .leading)
                        Text(verbatim: SLHistoryList.routeText(r)).font(.system(size: WgType.sub)).lineLimit(1)
                        Spacer()
                        if let error = r.error {
                            Text(verbatim: error).font(WgInk.mono(.caption)).foregroundStyle(WgInk.alert).lineLimit(1)
                        } else {
                            Text(verbatim: "↓\(SLFormat.compact(r.down?.stable, unit: lab.params.unit))  ↑\(SLFormat.compact(r.up?.stable, unit: lab.params.unit))")
                                .font(.system(size: WgType.sub, design: .monospaced))
                            Text(verbatim: SpeedLabView.linkText(r.linkText)).font(WgInk.mono(.caption))
                                .foregroundStyle((r.linkMbps ?? 1000) <= 100 && !r.linkText.contains("Wi-Fi") ? WgInk.alert : WgInk.ink3)
                                .frame(width: 84, alignment: .trailing)
                        }
                    }
                    .wgPadding(.vertical, .xs)
                    .overlay(alignment: .bottom) { Rectangle().fill(WgInk.rule).frame(height: 1) }
                    .contentShape(Rectangle())
                    .onTapGesture { lab.use(r) }
                }
                HStack {
                    Spacer()
                    Button("清空历史", role: .destructive) { lab.clearHistory() }
                        .buttonStyle(.plain).font(.system(size: WgType.body)).foregroundStyle(WgInk.ink3)
                }.wgPadding(.top, .s)
            }
        }
    }
}

extension SLHistoryList {
    /// 一条记录的完整线路：A → B → C（B 为网卡名 / 系统路由 / iperf3）。
    static func routeText(_ r: SLResult) -> String { "\(r.runner) → \(r.path) → \(r.target)" }
}

/// 名册表：每列一种扫描事实；名称列是你起的名字（空着就显示主机名或地址）。
/// 用普通行而不是系统 Table：嵌在滚动页里的 NSTableView 每帧重算全部行的追踪区域，滚动掉帧。
struct SLRosterTable: View {
    @ObservedObject var lab: SpeedLabStore
    /// 各列等分剩余宽度、放不下就截断：固定宽度会把整页撑出窗口，回读宽度再排又会让拖侧栏时每帧多排一遍。
    private let cols = [String(localized: "名称", bundle: .wgLocalized), String(localized: "地址", bundle: .wgLocalized), String(localized: "主机名", bundle: .wgLocalized), String(localized: "在哪发现", bundle: .wgLocalized), String(localized: "能做什么", bundle: .wgLocalized), String(localized: "最近看到", bundle: .wgLocalized)]

    var body: some View {
        if lab.roster.isEmpty {
            Text(verbatim: String(localized: "空。点「发现」扫描，或在下面添加。", bundle: .wgLocalized)).font(.system(size: WgType.sub)).foregroundStyle(WgInk.ink3)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: WgSpace.m) {
                    ForEach(cols, id: \.self) { c in
                        Text(verbatim: c).font(.system(size: WgType.body, weight: .medium)).foregroundStyle(WgInk.ink3).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Color.clear.frame(width: 16, height: 1)
                }
                .wgPadding(.bottom, .xs)
                ForEach(lab.roster) { ep in
                    HStack(spacing: WgSpace.m) {
                        SLInlineEdit(value: ep.label, placeholder: ep.hostname.isEmpty ? ep.address : ep.hostname,
                                     enabled: true, bold: true) { lab.rename(ep.id, to: $0) }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        cell(ep.address, mono: true)
                        cell(ep.hostname, mono: true)
                        cell(ep.via)
                        cell(ep.ability)
                        cell(ep.seenAt.map { $0.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute()) } ?? "", mono: true)
                        Button { lab.remove(ep) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).foregroundStyle(WgInk.ink3)
                            .frame(width: 16)
                    }
                    .wgPadding(.vertical, .xs)
                    .overlay(alignment: .bottom) { Rectangle().fill(WgInk.rule).frame(height: 1) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func cell(_ s: String, mono: Bool = false) -> some View {
        Text(verbatim: s).font(mono ? .system(size: WgType.body, design: .monospaced) : .system(size: WgType.sub))
            .foregroundStyle(WgInk.ink2).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
    }

}

/// 点了才变输入框的文字：常驻时没有原生控件，滚动不给焦点系统添负担。回车或失焦提交。
struct SLInlineEdit: View {
    var value: String
    var placeholder: String
    var enabled = true
    var bold = false
    var commit: (String) -> Void
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        if editing {
            TextField(placeholder, text: $draft)
                .textFieldStyle(.plain).font(.system(size: WgType.sub, weight: bold ? .semibold : .regular, design: bold ? .default : .monospaced))
                .focused($focused)
                .onSubmit { finish() }
                .onChange(of: focused) { _, f in if !f { finish() } }
                .onAppear { focused = true }
        } else {
            Text(verbatim: value.isEmpty ? placeholder : value)
                .font(.system(size: WgType.sub, weight: bold ? .semibold : .regular, design: bold ? .default : .monospaced))
                .foregroundStyle(value.isEmpty ? WgInk.ink3 : WgInk.ink).lineLimit(1)
                .contentShape(Rectangle())
                .onTapGesture { guard enabled else { return }; draft = value; editing = true }
        }
    }

    private func finish() {
        guard editing else { return }
        editing = false
        if draft != value { commit(draft.trimmingCharacters(in: .whitespaces)) }
    }
}

/// 数值：− 数值 单位 +。点 −/+ 步进，点数值直接输入。
struct SLStepValue: View {
    var text: String
    var unit: String
    var enabled = true
    var step: (Int) -> Void
    var commit: (String) -> Void

    var body: some View {
        HStack(spacing: WgSpace.s) {
            Text(verbatim: "−").foregroundStyle(WgInk.ink3).contentShape(Rectangle()).onTapGesture { if enabled { step(-1) } }
            SLInlineEdit(value: text, placeholder: text, enabled: enabled, commit: commit)
            Text(verbatim: unit).font(.system(size: WgType.body)).foregroundStyle(WgInk.ink3)
            Text(verbatim: "+").foregroundStyle(WgInk.ink3).contentShape(Rectangle()).onTapGesture { if enabled { step(1) } }
        }
        .font(.system(size: WgType.body, design: .monospaced))
    }
}

/// HUD 与叠在上面的 START：宽度由外部给，高度按 1280×720 定比，按钮按设计坐标等比摆放。
/// 在布局阶段直接算，不经过 GeometryReader / 状态回读，拖侧栏改宽度时一帧只排一遍。
struct SLHUDLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? SLHUD.size.width
        return CGSize(width: w, height: SLHUD.size.height * SLHUD.scale(forWidth: w))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let s = SLHUD.scale(forWidth: bounds.width)
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
        guard subviews.count > 1 else { return }
        // START 宽 300（设计坐标），中线对齐
        subviews[1].place(at: CGPoint(x: bounds.midX - 150 * s, y: bounds.minY + 396 * s),
                          proposal: ProposedViewSize(width: 300 * s, height: 52 * s))
    }
}

/// START 的斜切：右上、左下各切掉高度的 31%（随按钮大小等比）。
struct SLRatioChamfer: Shape {
    func path(in r: CGRect) -> Path {
        ChamferShape(tl: 0, tr: r.height * 0.31, br: 0, bl: r.height * 0.31).path(in: r)
    }
}

/// 随宽度变化的斜切底板：中间用矩形拼，只有两个切角是固定大小的小画布。
/// 整块用 Canvas 画的话，拖侧栏时它每帧都要按新尺寸重新申请显存、整张重画（抽屉面板高达数千点）；
/// 矩形不占独立显存，固定大小的切角也不会重画。全部不接点击，不进窗口的拖动区计算。
struct SLChamferPlate: View {
    var cut: CGFloat
    var bottomLeft = true
    var fill: Color
    var border: Color? = nil

    var body: some View {
        let bl = bottomLeft ? cut : 0
        ZStack(alignment: .topLeading) {
            // 填充：上带（让出右上角）、中间、下带（让出左下角）
            VStack(spacing: 0) {
                HStack(spacing: 0) { fill; Color.clear.frame(width: cut) }.frame(height: cut)
                fill
                if bl > 0 { HStack(spacing: 0) { Color.clear.frame(width: bl); fill }.frame(height: bl) }
            }
            if let border {
                // 边线：四条直边（避开切角）
                VStack(spacing: 0) {
                    HStack(spacing: 0) { border.frame(height: 1); Color.clear.frame(width: cut, height: 1) }
                    Spacer(minLength: 0)
                    HStack(spacing: 0) { Color.clear.frame(width: bl, height: 1); border.frame(height: 1) }
                }
                HStack(spacing: 0) {
                    VStack(spacing: 0) { border.frame(width: 1); Color.clear.frame(width: 1, height: bl) }
                    Spacer(minLength: 0)
                    VStack(spacing: 0) { Color.clear.frame(width: 1, height: cut); border.frame(width: 1) }
                }
            }
        }
        .overlay(alignment: .topTrailing) { corner(flip: false) }
        .overlay(alignment: .bottomLeading) { if bl > 0 { corner(flip: true) } }
        .allowsHitTesting(false)
    }

    /// 切角三角（固定大小，宽度变化时不重画）。
    private func corner(flip: Bool) -> some View {
        Canvas { ctx, size in
            var p = Path()
            if flip {
                p.move(to: CGPoint(x: 0, y: 0)); p.addLine(to: CGPoint(x: size.width, y: size.height)); p.addLine(to: CGPoint(x: size.width, y: 0))
            } else {
                p.move(to: CGPoint(x: 0, y: 0)); p.addLine(to: CGPoint(x: size.width, y: size.height)); p.addLine(to: CGPoint(x: 0, y: size.height))
            }
            p.closeSubpath()
            ctx.fill(p, with: .color(fill))
            if let border {
                var e = Path(); e.move(to: CGPoint(x: 0, y: 0)); e.addLine(to: CGPoint(x: size.width, y: size.height))
                ctx.stroke(e, with: .color(border), lineWidth: 1)
            }
        }
        .frame(width: flip ? (bottomLeft ? cut : 0) : cut, height: flip ? (bottomLeft ? cut : 0) : cut)
    }
}

/// 抽屉标题旁的刻度尺：按固定超宽尺寸画一次，再按实际宽度裁掉。画布尺寸不随页面宽度变，拖侧栏时不重画。
struct SLRuler: View {
    var body: some View {
        // 超宽画布放在 overlay 里：不参与尺寸计算（直接 frame(width: 2400) 会把页面理想宽度撑到 2400）
        Color.clear.frame(height: 10).frame(maxWidth: .infinity)
            .overlay(alignment: .leading) { WgRuler(opacity: 0.25).frame(width: 2400) }
            .clipped()
            .allowsHitTesting(false)
    }
}

/// Share the live layer-backed plate with ordinary pages and sidebar tiles.
struct SLPlate<S: Shape>: View {
    var shape: S
    var fill: Color? = nil
    var stroke: Color? = nil
    var body: some View {
        WgShapePlate(shape: shape, fill: fill ?? .clear, border: stroke ?? .clear, highlight: .clear)
    }
}

/// 历史点阵：每次测量一个点（下行稳定值），网口降速那次圈出来。
struct SLHistoryStrip: View {
    var history: [SLResult]
    var unit: SLUnit

    var body: some View {
        let points = Array(history.prefix(60).reversed()).filter { $0.down != nil }
        let top = max(1, points.compactMap { $0.down?.stable }.max() ?? 1)
        Canvas { ctx, size in
            guard !points.isEmpty else { return }
            let step = size.width / CGFloat(max(points.count - 1, 1))
            for (i, r) in points.enumerated() {
                let v = r.down?.stable ?? 0
                let c = CGPoint(x: points.count == 1 ? size.width / 2 : CGFloat(i) * step, y: size.height - 4 - (size.height - 8) * CGFloat(v / top))
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 2, y: c.y - 2, width: 4, height: 4)), with: .color(Color.primary.opacity(0.7)))
                if let link = r.linkMbps, link <= 100, !r.linkText.contains("Wi-Fi") {
                    ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)), with: .color(WgInk.alert), lineWidth: 1)
                }
            }
        }
        .frame(height: 44)
    }
}

// MARK: - 测速源

struct SLSourcesForm: View {
    @ObservedObject var lab: SpeedLabStore
    @ObservedObject private var catalog = SLSourceCatalog.shared
    @State private var newDown = ""
    @State private var newUp = ""

    var body: some View {
        VStack(alignment: .leading, spacing: WgSpace.l) {
            // 远程源列表：节点失效时改远程文件，不用发版
            VStack(alignment: .leading, spacing: WgSpace.s) {
                Text(verbatim: String(localized: "源列表", bundle: .wgLocalized)).font(.system(size: WgType.sub, weight: .semibold))
                HStack {
                    TextField("https://gist.githubusercontent.com/…/raw/sources.json", text: $catalog.url)
                        .textFieldStyle(.roundedBorder).font(.system(size: WgType.body, design: .monospaced))
                        .onSubmit { Task { await catalog.refresh() } }
                    Button(catalog.fetching ? "拉取中…" : "拉取") { Task { await catalog.refresh() } }
                        .disabled(catalog.fetching || catalog.url.isEmpty)
                }
                Text(verbatim: status).font(WgInk.mono(.micro)).foregroundStyle(catalog.fetchError == nil ? WgInk.ink3 : WgInk.warn)
            }
            group(String(localized: "↓ 下行", bundle: .wgLocalized), remote: catalog.file?.download ?? [], manual: $lab.downloadSources, draft: $newDown)
            group(String(localized: "↑ 上行", bundle: .wgLocalized), remote: catalog.file?.upload ?? [], manual: $lab.uploadSources, draft: $newUp)
        }
        .disabled(lab.running)
    }

    private var status: String {
        if let e = catalog.fetchError { return e }
        guard let f = catalog.file else { return catalog.url.isEmpty ? String(localized: "未配置", bundle: .wgLocalized) : String(localized: "还没拉取过", bundle: .wgLocalized) }
        var parts = [String(localized: "\(f.download.count) 下行 · \(f.upload.count) 上行", bundle: .wgLocalized)]
        if let u = f.updated { parts.append(String(localized: "列表更新于 \(u)", bundle: .wgLocalized)) }
        if let t = catalog.fetchedAt { parts.append(String(localized: "拉取于 ", bundle: .wgLocalized) + t.formatted(.relative(presentation: .named))) }
        return parts.joined(separator: " · ")
    }

    private func group(_ title: String, remote: [SLCatalogFile.Entry], manual: Binding<[String]>, draft: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: WgSpace.xs) {
            Text(verbatim: title).font(.system(size: WgType.sub, weight: .semibold))
            ForEach(remote, id: \.self) { e in sourceRow(e.url, note: e.note, removable: nil) }
            ForEach(manual.wrappedValue, id: \.self) { u in
                sourceRow(u, note: String(localized: "手动", bundle: .wgLocalized), removable: { manual.wrappedValue.removeAll { $0 == u } })
            }
            HStack {
                TextField("手动添加 https://…", text: draft).textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced))
                Button("添加") {
                    let url = draft.wrappedValue.trimmingCharacters(in: .whitespaces)
                    guard url.hasPrefix("http"), !url.contains(" "), !manual.wrappedValue.contains(url) else { return }
                    manual.wrappedValue.append(url)
                    draft.wrappedValue = ""
                }
            }
        }
    }

    /// 一行源：地址 · 备注 · 健康（上次实测 / 连续失败 / 已跳过）。
    private func sourceRow(_ url: String, note: String?, removable: (() -> Void)?) -> some View {
        let h = catalog.health[url], retired = catalog.isRetired(url, after: lab.params.retireAfter)
        return HStack(spacing: WgSpace.s) {
            Text(verbatim: URL(string: url)?.host ?? url).font(.system(size: WgType.body, design: .monospaced))
                .foregroundStyle(retired ? WgInk.ink4 : WgInk.ink2).lineLimit(1)
            if let note { Text(verbatim: note).font(WgInk.mono(.micro)).foregroundStyle(WgInk.ink3).lineLimit(1) }
            Spacer()
            Group {
                if retired {
                    Button("已跳过 · 重试") { catalog.resetHealth(url) }.buttonStyle(.plain).foregroundStyle(WgInk.warn)
                } else if let h, h.fails > 0 {
                    Text(verbatim: String(localized: "失败 \(h.fails) 次", bundle: .wgLocalized)).foregroundStyle(WgInk.warn)
                } else if let mb = h?.lastMbps, let t = h?.lastOK {
                    Text(verbatim: "\(Int(mb)) Mbps · " + t.formatted(.relative(presentation: .named)))
                } else {
                    Text(verbatim: String(localized: "未测", bundle: .wgLocalized))
                }
            }
            .font(WgInk.mono(.micro)).foregroundStyle(WgInk.ink3)
            if let removable {
                Button(action: removable) { Image(systemName: "minus.circle") }.buttonStyle(.plain).foregroundStyle(WgInk.ink3)
            }
        }
    }
}

// MARK: - 端点

struct SLEndpointsForm: View {
    @ObservedObject var lab: SpeedLabStore
    /// 抽屉里列出名册；添加弹窗里只要表单。
    var listing = true
    @State private var name = ""
    @State private var host = ""
    @State private var port = ""
    @State private var user = ""
    @State private var peerName = ""
    @State private var peerIP = ""

    var body: some View {
        VStack(alignment: .leading, spacing: WgSpace.s) {
            if listing {
                HStack(spacing: WgSpace.m) {
                    Button(lab.discovering ? "发现中…" : "发现") { lab.discover() }.disabled(lab.discovering)
                    Text(verbatim: String(localized: "将探测：", bundle: .wgLocalized) + lab.discoverScope.joined(separator: "、"))
                        .font(WgInk.mono(.caption)).foregroundStyle(WgInk.ink3).lineLimit(1)
                    Spacer()
                    Text(verbatim: String(localized: "\(lab.roster.count) 项", bundle: .wgLocalized)).font(WgInk.mono(.caption)).foregroundStyle(WgInk.ink3)
                }
                SLRosterTable(lab: lab)
                Rectangle().fill(WgInk.rule).frame(height: 1).wgPadding(.vertical, .s)
            }
            Text(verbatim: String(localized: "SSH 主机：可当执行端，也可当目标（用这台 Mac 的 SSH 公钥登录，不保存密码）", bundle: .wgLocalized)).font(.system(size: WgType.sub, weight: .semibold))
            HStack {
                TextField("名称", text: $name).frame(width: 110)
                TextField("主机 / IP", text: $host)
                TextField("端口 22", text: $port).frame(width: 64)
                TextField("用户 root", text: $user).frame(width: 90)
                Button("添加") {
                    let h = host.trimmingCharacters(in: .whitespaces)
                    let p = port.isEmpty ? 22 : (Int(port) ?? 0)
                    guard !h.isEmpty, (1...65535).contains(p) else { return }
                    lab.addSSH(name: name.trimmingCharacters(in: .whitespaces), host: h, port: p,
                               user: user.isEmpty ? "root" : user)
                    name = ""; host = ""; port = ""; user = ""
                }
            }
            Text(verbatim: String(localized: "仅地址：只能当目标，要求它自己开着 iperf3 服务端", bundle: .wgLocalized)).font(.system(size: WgType.sub, weight: .semibold)).wgPadding(.top, .s)
            HStack {
                TextField("名称", text: $peerName).frame(width: 110)
                TextField("IP", text: $peerIP)
                Button("添加") {
                    let ip = peerIP.trimmingCharacters(in: .whitespaces)
                    guard !ip.isEmpty else { return }
                    lab.addAddress(name: peerName.trimmingCharacters(in: .whitespaces), ip: ip)
                    peerName = ""; peerIP = ""
                }
            }
        }
        .textFieldStyle(.roundedBorder)
        .disabled(lab.running)
    }
}
