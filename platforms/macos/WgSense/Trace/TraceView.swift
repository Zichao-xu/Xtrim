import SwiftUI

// 路由追踪页（全息模式）：地球是窗口背景（TraceStage.swift），这里是浮在上面的目标条、图例与详情抽屉。
//
//   地图是两层：底层地球（海面 / 陆地 / 国界 / 省界 / 国名）只随镜头重画；上层航线、脉冲、标注按屏幕刷新推进，
//   只在主窗口真可见且有东西可画时跑（WgWindowVisibility），收起即停。
//   白色只给一样东西：待机时是 TRACE 按钮；追踪中 / 完成后是地图上的目标点。

struct TraceView: View {
    @ObservedObject private var trace = TraceStore.shared
    /// 镜头对象不订阅：拖动 / 缩放每秒改上百次，订阅了会让整页浮层（目标栏、抽屉表格）跟着逐帧重算。
    /// 要随镜头变的只有 AUTO 按钮，它单独订阅（TraceAutoButton）。
    private var model: TraceMapModel { .shared }
    @EnvironmentObject private var client: DaemonClient
    @State private var draft = TraceStore.shared.target
    /// 右下角（Fake-IP 适配 + 跳点）收起成一个小按钮。
    @AppStorage("trace.cornerCollapsed") private var cornerCollapsed = false

    // 全息模式：地球是窗口背景（TraceGlobeStage），这一页只是浮在上面的几块——
    //   左上标题与目标条、左下图号 / 缩放 / 图例、右下常驻的 Fake-IP 适配与跳点。空白处不接点击，拖动与捏合穿透到背后的地球。
    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: WgSpace.m) {
                // 第一行：标题与目标栏
                HStack(alignment: .top, spacing: WgSpace.l) {
                    VStack(alignment: .leading, spacing: WgSpace.m) {
                        WgPageHeader(title: "路由追踪") { EmptyView() }
                        // 不再垫整块底板：每个控件各自磨砂、各自悬浮，之间露出地球
                        VStack(alignment: .leading, spacing: WgSpace.s) {
                            bar
                            note
                        }
                    }
                    .frame(maxWidth: 1080, alignment: .leading)
                    // 把顶部浮层的底边报给地球：地球中心对准它以下的区域
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { model.topInset = $0 }
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
            }

            // 右下角：Fake-IP 适配与跳点，和左下角图例同一颗粒度，底边对齐
            Group {
                if cornerCollapsed { cornerHandle } else { drawerPanel }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)

            TraceMapLegend(trace: trace,
                           zoomOut: { model.zoom(by: 1 / 1.8) }, zoomIn: { model.zoom(by: 1.8) },
                           follow: { model.follow() })
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: trace.target) { _, v in if v != draft { draft = v } }
        // 调试用：`--args -WgSenseInitialTab trace -WgSenseTraceTarget 1.1.1.1` 打开即追踪（仅命令行参数域）。
        .task {
            let args = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            guard let host = args["WgSenseTraceTarget"] as? String, !trace.running, trace.hops.isEmpty else { return }
            try? await Task.sleep(for: .seconds(1.5))
            draft = host
            run(host)
        }
    }

    // MARK: 抽屉

    /// 右侧常驻：Fake-IP 适配 + 跳点台账，没有框，字直接浮在画面上。
    /// 右下角常驻：Fake-IP 适配 + 跳点台账，没有框，字直接浮在画面上。跳点多了在自己这块里上下滚（滚动条不显示），
    /// 高度上限留出顶部标题与目标栏；宽度取跳点表的自然宽度，全部显示。
    private var drawerPanel: some View {
        VStack(alignment: .trailing, spacing: WgSpace.l) {
            TraceFakeIPPanel()
            ScrollView(.vertical, showsIndicators: false) {
                TraceHopTable(trace: trace)
            }
            .defaultScrollAnchor(.bottom)
            .frame(maxHeight: 320)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: TraceHopTable.naturalWidth, alignment: .trailing)
        // 收起按钮在这块的右上角
        .overlay(alignment: .topTrailing) {
            Button { withAnimation(WgDesign.spring) { cornerCollapsed = true } } label: {
                Image(systemName: "chevron.right").font(.system(size: WgType.micro, weight: .bold)).foregroundStyle(WgInk.ink3)
                    .frame(width: 28, height: 28).traceHolo().contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("收起 Fake-IP 适配与跳点")
            // 内容右对齐后图号行贴着右边：按钮放到这块正上方，不压字
            .offset(y: -40)
        }
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }

    /// 收起后右下角只留的小按钮：带跳数与 Fake-IP 判定摘要，点开展开。
    private var cornerHandle: some View {
        Button { withAnimation(WgDesign.spring) { cornerCollapsed = false } } label: {
            HStack(spacing: WgSpace.s) {
                Image(systemName: "chevron.left").font(.system(size: WgType.micro, weight: .bold))
                Text(verbatim: "FIG.02–03").font(WgInk.mono(.micro, .bold)).tracking(1.4)
                Text(verbatim: [trace.hops.isEmpty ? nil : String(format: String(localized: "%02d 跳", bundle: .wgLocalized), trace.hops.count),
                                trace.proxied != nil ? String(localized: "FIP 接管", bundle: .wgLocalized) : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(WgInk.mono(.micro, .medium)).tracking(1.2)
            }
            .foregroundStyle(WgInk.ink2)
            .wgPadding(.horizontal, .s)
            .frame(height: 28)
            .traceHolo()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("展开 Fake-IP 适配与跳点")
        .transition(.opacity)
    }

    // MARK: 目标条

    /// 一排悬浮控件：输入框 + TRACE 紧挨着，后面是快捷目标；放不下时快捷目标从后往前少显示几个，不滚动、不溢出。
    private var bar: some View {
        let wgEndpoint = self.wgEndpoint
        let recent = trace.recent.filter { $0 != wgEndpoint }
        return HStack(spacing: WgSpace.s) {
            HStack(spacing: WgSpace.s) {
                Text(verbatim: "TGT").font(WgInk.mono(.micro, .bold)).tracking(1).foregroundStyle(WgInk.ink3)
                TextField("", text: $draft, prompt: Text(verbatim: String(localized: "域名或 IP，例如 \(wgEndpoint ?? "github.com")", bundle: .wgLocalized)))
                    .textFieldStyle(.plain)
                    .font(WgInk.mono(.body))
                    .onSubmit { run(draft) }
                    .disabled(trace.running)
            }
            .wgPadding(.horizontal, .m)
            .frame(height: 30)
            .frame(minWidth: 240, maxWidth: 360)
            .traceHolo()
            startButton
            TraceChipRow(spacing: WgSpace.s) {
                if let ep = wgEndpoint { chip(ep, code: "WG") }
                ForEach(recent.prefix(6), id: \.self) { chip($0) }
            }
        }
    }

    private func chip(_ host: String, code: String? = nil) -> some View {
        Button { draft = host; run(host) } label: {
            HStack(spacing: WgSpace.xs) {
                if let code { Text(verbatim: code).font(WgInk.mono(.micro, .bold)).foregroundStyle(WgInk.ink3) }
                Text(verbatim: host).font(WgInk.mono(.caption)).foregroundStyle(host == trace.target ? WgInk.ink : WgInk.ink2)
            }
            .wgPadding(.horizontal, .m)
            .frame(height: 30)
            .traceHolo(active: host == trace.target)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(trace.running)
        .contextMenu {
            if code == nil { Button("从最近移除") { trace.forget(host) } }
        }
        .help(code == nil ? "最近追踪过" : "当前 WG 配置的服务器地址")
    }

    private var startButton: some View {
        let idle = !trace.running && trace.hops.isEmpty
        return Button {
            if trace.running { trace.stop() } else { run(draft) }
        } label: {
            Text(verbatim: trace.running ? "STOP" : "TRACE")
                .font(.system(size: WgType.body, weight: .heavy, design: .monospaced)).tracking(5)
                .foregroundStyle(trace.running ? Color(white: 0.84) : Color(red: 0.06, green: 0.063, blue: 0.07))
                .frame(width: 112, height: 30)
                .background(SLPlate(shape: ChamferShape(tr: 9, bl: 9),
                                    fill: trace.running ? nil : Color(white: idle ? 0.95 : 0.7),
                                    stroke: trace.running ? Color(white: 0.56) : nil))
                // 停止态是空心的，垫一层磨砂，浮在地球上也读得清
                .background { if trace.running { TraceHoloFrame() } }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!trace.running && draft.trimmingCharacters(in: .whitespaces).isEmpty)
        .keyboardShortcut(.return, modifiers: .command)
    }

    private func run(_ host: String) {
        trace.start(host, tunnelInterface: client.status?.tunnel_interface)
    }

    /// 当前 WG 配置里 Endpoint 的主机名（去掉端口）。
    /// 当前 WG 配置的服务器地址：读配置文件，按配置名缓存 10 秒（页面每次重算都读盘会卡主线程；
    /// 过期重读，改了配置里的 Endpoint 也跟得上）。
    private var wgEndpoint: String? {
        let name = client.status?.service ?? client.profiles.first
        if let hit = TraceEndpointCache.value, hit.name == name, hit.at.timeIntervalSinceNow > -10 { return hit.host }
        let host = Self.readEndpoint(client)
        TraceEndpointCache.value = (name, host, Date())
        return host
    }

    private static func readEndpoint(_ client: DaemonClient) -> String? {
        let store = ProfileFileStore()
        guard let name = client.status?.service ?? client.profiles.first, let conf = store.readProfile(name) else { return nil }
        guard let line = conf.split(separator: "\n").first(where: { $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("endpoint") }),
              let eq = line.firstIndex(of: "=") else { return nil }
        var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("["), let close = value.firstIndex(of: "]") {
            value = String(value[value.index(after: value.startIndex)..<close])
        } else if let colon = value.lastIndex(of: ":") {
            value = String(value[..<colon])
        }
        return value.isEmpty ? nil : value
    }

    // MARK: 注记

    private var note: some View {
        var text: String
        var tint = WgInk.ink3
        if let e = trace.error {
            text = e; tint = WgInk.warn
        } else if trace.startedAt == nil {
            text = String(localized: "跟随系统路由；定位只把公网跳点发给 ip-api.com，内网与隧道地址不出本机", bundle: .wgLocalized)
        } else {
            var parts: [String] = []
            if let i = trace.interface {
                parts.append(i == client.status?.tunnel_interface ? String(localized: "经 \(i) · WG 隧道", bundle: .wgLocalized) : String(localized: "经 \(i) · 直连", bundle: .wgLocalized))
            }
            if let g = trace.firstLocated?.geo { parts.append(String(localized: "起点 \(g.place) · \(g.isp)", bundle: .wgLocalized)) }
            if let px = trace.proxied {
                parts.append(Self.proxyNote(px, target: trace.target))
            } else if let d = trace.destination, d != trace.target {
                parts.append("\(trace.target) → \(d)")
            }
            if trace.inspectingProxy { parts.append(String(localized: "查询代理去向…", bundle: .wgLocalized)) }
            if trace.locating { parts.append(String(localized: "定位中…", bundle: .wgLocalized)) }
            if let f = trace.finishedAt, let s = trace.startedAt {
                parts.append(trace.reached ? String(format: String(localized: "到达 · %.1f 秒", bundle: .wgLocalized), f.timeIntervalSince(s))
                             : trace.gaveUp ? String(localized: "连续 \(TraceStore.silentLimit) 跳无响应，提前结束", bundle: .wgLocalized) : String(localized: "未到达终点", bundle: .wgLocalized))
            }
            text = parts.joined(separator: "  ·  ")
            if trace.finishedAt != nil, trace.allSilent {
                // 按当时的实际状态解释，不预设环境
                let blocking = client.status?.firewall?.active == true && trace.interface != client.status?.tunnel_interface
                text = blocking
                    ? String(localized: "全程无响应：出站拦截正在生效，直连只放行国内与局域网，追境外目标需先连 WG", bundle: .wgLocalized)
                    : String(localized: "全程无响应：沿途设备不回应探测，或出口被防火墙拦下", bundle: .wgLocalized)
                tint = WgInk.warn
            }
        }
        return Text(verbatim: text).font(WgInk.mono(.caption)).foregroundStyle(tint).lineLimit(2)
            .wgPadding(.horizontal, .m)
            .wgPadding(.vertical, .xs)
            .traceHolo()
    }

    /// 代理接管的一句话：接管了什么、真实去向、走了哪条链。只写查到的。
    static func proxyNote(_ px: TraceProxyPath, target: String) -> String {
        guard px.backend else {
            return String(localized: "\(target) 解析到 \(px.systemIP)，落在兜底网段，疑似代理 fake-ip；代理后端无响应，查不到真实去向", bundle: .wgLocalized)
        }
        var s = String(localized: "代理接管：\(target) → \(px.systemIP)，真实 \(px.realIP ?? String(localized: "未解析", bundle: .wgLocalized))", bundle: .wgLocalized)
        if let rule = px.rule, !rule.isEmpty { s += String(localized: " · 规则 \(rule)", bundle: .wgLocalized) }
        if px.isDirect { s += String(localized: " · 直连出站", bundle: .wgLocalized) }
        else if !px.chain.isEmpty { s += " · " + px.chain.reversed().joined(separator: " › ") }
        s += String(localized: " · 本机只追得到代理网关，之后为代理段", bundle: .wgLocalized)
        return s
    }

}

@MainActor
enum TraceEndpointCache {
    static var value: (name: String?, host: String?, at: Date)?
}

/// 快捷目标一排：从左往右放，放不下的不显示（不换行、不滚动）。每个子视图只量一次，
/// 不像 ViewThatFits 那样把每种个数的组合整排量一遍（压测里那样一次布局要 70ms）。
struct TraceChipRow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let h = sizes.map(\.height).max() ?? 0
        let limit = proposal.width ?? .infinity
        var w: CGFloat = 0
        for s in sizes {
            let next = w == 0 ? s.width : w + spacing + s.width
            if next > limit { break }
            w = next
        }
        return CGSize(width: w, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width <= bounds.maxX + 0.5 {
                v.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(s))
                x += s.width + spacing
            } else {
                // 放不下的挪到画面外（Layout 必须摆放每个子视图）；后面的也一律不放
                x = .greatestFiniteMagnitude / 4
                v.place(at: CGPoint(x: -100_000, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(s))
            }
        }
    }
}

// MARK: - 航线（跳点按地理位置合并成站）

struct TraceStop: Equatable {
    var lon: Double
    var lat: Double
    var first: Int
    var last: Int
    var place: String
    var latency: Double?
    var appearAt: Date
    var isOrigin = false
    var isDestination = false
    /// 代理段的站（节点、真实目标）：本机追不到，线型区分；tag 代替 TTL 编号。
    var isProxy = false
    var tag: String?
    /// 所在国家（ISO 两位代码）：边界辐射只在这个国家里传播。
    var code = ""

    var ttlText: String {
        if let tag { return tag }
        return first == last ? String(format: "%02d", first) : String(format: "%02d–%02d", first, last)
    }
}

struct TraceRoute: Equatable {
    var stops: [TraceStop] = []
    var scanning = false
    var reached = false

    @MainActor init(_ trace: TraceStore) {
        scanning = trace.running
        reached = trace.reached
        var out: [TraceStop] = []
        for hop in trace.hops {
            guard let g = hop.geo else {
                // 没有坐标的跳点并进当前站（内网、隧道、无响应、定位未回）
                if let i = out.indices.last { out[i].last = hop.ttl }
                continue
            }
            if let i = out.indices.last, abs(out[i].lon - g.lon) < 0.6, abs(out[i].lat - g.lat) < 0.6 {
                out[i].last = hop.ttl
                out[i].latency = hop.best ?? out[i].latency
            } else {
                // 第一站是路径起点（本地运营商公网边缘），画成准星
                out.append(TraceStop(lon: g.lon, lat: g.lat, first: hop.ttl, last: hop.ttl, place: g.place,
                                     latency: hop.best, appearAt: hop.locatedAt ?? hop.arrivedAt, isOrigin: out.isEmpty, code: g.code))
            }
        }
        // 代理段：节点 → 真实目标。只画查到坐标的；没有本地起点时节点自己当起点
        if let px = trace.proxied, px.backend {
            // 本机路径被网关截断：起点用本网络的学习记录（板块 07 写明来源）
            if out.isEmpty, let o = px.origin {
                out.append(TraceStop(lon: o.geo.lon, lat: o.geo.lat, first: 0, last: 0, place: String(localized: "\(o.geo.place)（学习）", bundle: .wgLocalized),
                                     latency: nil, appearAt: px.resolvedAt, isOrigin: true, tag: "00", code: o.geo.code))
            }
            if let g = px.nodeGeo, let node = px.node {
                out.append(TraceStop(lon: g.lon, lat: g.lat, first: 0, last: 0, place: "\(node) · \(g.place)",
                                     latency: nil, appearAt: px.resolvedAt, isOrigin: out.isEmpty, isProxy: true, tag: "PX", code: g.code))
            }
            if let g = px.realGeo {
                out.append(TraceStop(lon: g.lon, lat: g.lat, first: 0, last: 0, place: g.place,
                                     latency: nil, appearAt: px.resolvedAt, isOrigin: out.isEmpty, isProxy: true, tag: "DST", code: g.code))
            }
        }
        let done = trace.reached || trace.finishedAt != nil
        if let i = out.indices.last, out.count > 1, trace.reached || (trace.proxied?.realGeo != nil && done) {
            out[i].isDestination = true
        }
        stops = out
    }
}

/// 地图的逐帧部分：按时间算镜头，地球形态走 GPU（贴图球 + 静态装饰层），展平后走矢量 Canvas；航线层叠在最上。
struct TraceMapLive: View {
    var flight: TraceFlight
    var route: TraceRoute
    var focus: Int?
    var visible: Bool
    var running: Bool
    /// 地球中心相对画幅中心的偏移（点）。
    var shift: CGSize = .zero
    /// 用户挪动视图的位移（点）。
    var pan: CGSize = .zero

    /// SwiftUI 逐帧刷新开不开（由外层算好传进来，见 TraceGlobeStage.needsFrames）。
    /// 不能在这里按当前时间现算：飞行结束时这一层的输入都没变，SwiftUI 不会重算它，
    /// 现算的结果停在「还在飞」——逐帧时间轴就一直空跑，带着整个窗口每帧重排（实测占 35% CPU）。
    var needsFrames = false

    var body: some View {
        GeometryReader { geo in
            // 动起来就跟屏幕刷新率走（ProMotion 120Hz）；静止时暂停
            TimelineView(.animation(minimumInterval: nil, paused: !needsFrames)) { tl in
                let cam = flight.cam(at: tl.date)
                let globeMode = cam.morph == 0
                ZStack {
                    // 深空底：地球形态下半透明（星空底下隐约透出窗口玻璃）；一开始展平就迅速加深，展平到 25% 时已完全不透明，
                    // 平面地图看着像平面时就不透底，保证可读性
                    Color.black.opacity(0.45 + 0.55 * min(1, cam.morph / 0.25))
                    // 地图全在 GPU（纯 Metal）：地球与平面是同一套网格（着色器里插值），星空、光环、国名、侧栏模糊也在同一帧里画；
                    // 这里只交镜头模型。侧栏底下的渐变模糊宽度 = 水平偏移 × 2
                    TraceMetalMapView(flight: flight, visible: visible, shift: shift, pan: pan, blurWidth: shift.width * 2,
                                      radiations: route.stops.indices.dropFirst().map { i in
                                          let a = route.stops[i - 1], b = route.stops[i]
                                          return TraceRadEvent(fromLon: a.lon, fromLat: a.lat, fromCode: a.code,
                                                               lon: b.lon, lat: b.lat, code: b.code, start: b.appearAt,
                                                               isLast: i == route.stops.count - 1) })
                        .allowsHitTesting(false)
                    if globeMode {
                        TraceGlobeShading(zoom: cam.zoom, shift: shift, pan: pan).equatable()
                    }
                    TraceRouteLayer(route: route, cam: cam, now: tl.date, focus: focus, shift: shift, pan: pan)
                }
                .clipped()
            }
        }
        .allowsHitTesting(false)
    }
}

/// 独立宿主：内容逐帧变化时不向外报告尺寸变化，外层页面不跟着重新布局。只在外层状态变化时换一次内容。
struct TraceIsolatedHost: NSViewRepresentable {
    var content: AnyView

    /// 只负责显示：鼠标事件交给外层 SwiftUI 手势。
    final class PassthroughHost: NSHostingView<AnyView> {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> NSHostingView<AnyView> {
        let view = PassthroughHost(rootView: content)
        view.sizingOptions = []
        // 不让出标题栏：地图铺到窗口最顶上（外层已 ignoresSafeArea，宿主内部也要一致，否则平面图顶部空出一条黑边）
        view.safeAreaRegions = []
        return view
    }

    func updateNSView(_ view: NSHostingView<AnyView>, context: Context) {
        view.rootView = content
    }
}

// MARK: - 上层：航线 / 脉冲 / 站点 / 标注

struct TraceRouteLayer: View {
    var route: TraceRoute
    var cam: TraceCam
    var now: Date
    var focus: Int?
    var shift: CGSize = .zero
    var pan: CGSize = .zero
    @Environment(\.colorScheme) private var scheme

    /// 压在实心前景色上的反色（目标标签字、中转点芯）。
    private var inverse: Color { scheme == .dark ? Color(white: 0.06) : Color(white: 0.97) }

    var body: some View {
        Canvas { ctx, size in
            TraceFPS.tick(.route)
            let proj = TraceGlobeProjection(cam: cam, size: size, shift: shift, pan: pan)
            let marks = route.stops.map { proj.project(lon: $0.lon, lat: $0.lat) }
            let t = now.timeIntervalSinceReferenceDate

            // 航线本身是 GPU 画的闪电（TraceMetalMap 的边界辐射层）；这里只在闪电击中终点时扩一次冲击环
            for i in route.stops.indices.dropFirst() where marks[i].1 {
                let since = now.timeIntervalSince(route.stops[i].appearAt) - TraceRadEvent.strike
                if since >= 0, since < 0.9 { ring(&ctx, at: marks[i].0, progress: since / 0.9, maxR: 16, alpha: 0.6) }
            }

            // 站点（转到地球背面的不画）
            for (i, s) in route.stops.enumerated() where marks[i].1 {
                let pt = marks[i].0
                let focused = focus.map { s.first...max(s.first, s.last) ~= $0 } ?? false
                if s.isDestination {
                    for k in 0..<2 { ring(&ctx, at: pt, progress: ((t / 2.2) + Double(k) * 0.5).truncatingRemainder(dividingBy: 1), maxR: 22, alpha: 0.5) }
                    ctx.fill(Path(CGRect(x: pt.x - 3.5, y: pt.y - 3.5, width: 7, height: 7)), with: .color(.primary))
                } else if s.isOrigin {
                    ctx.stroke(Path(ellipseIn: CGRect(x: pt.x - 4, y: pt.y - 4, width: 8, height: 8)), with: .color(.primary.opacity(0.8)), lineWidth: 1)
                    var cross = Path()
                    cross.move(to: CGPoint(x: pt.x - 8, y: pt.y)); cross.addLine(to: CGPoint(x: pt.x - 5, y: pt.y))
                    cross.move(to: CGPoint(x: pt.x + 5, y: pt.y)); cross.addLine(to: CGPoint(x: pt.x + 8, y: pt.y))
                    cross.move(to: CGPoint(x: pt.x, y: pt.y - 8)); cross.addLine(to: CGPoint(x: pt.x, y: pt.y - 5))
                    cross.move(to: CGPoint(x: pt.x, y: pt.y + 5)); cross.addLine(to: CGPoint(x: pt.x, y: pt.y + 8))
                    ctx.stroke(cross, with: .color(.primary.opacity(0.6)), lineWidth: 0.8)
                } else {
                    let rr: CGFloat = focused ? 3.5 : 2.5
                    let rect = CGRect(x: pt.x - rr, y: pt.y - rr, width: rr * 2, height: rr * 2)
                    ctx.fill(Path(rect), with: .color(inverse))
                    ctx.stroke(Path(rect), with: .color(.primary.opacity(focused ? 1 : 0.7)), lineWidth: 1)
                }
                label(&ctx, s, at: pt, index: i, size: size, focused: focused)
            }

            // 扫描头：正在探测下一跳，雷达环停在最后一站
            if route.scanning, let last = marks.last, last.1 {
                ring(&ctx, at: last.0, progress: (t / 1.4).truncatingRemainder(dividingBy: 1), maxR: 26, alpha: 0.7)
            }
        }
    }

    private func ring(_ ctx: inout GraphicsContext, at p: CGPoint, progress: Double, maxR: CGFloat, alpha: Double) {
        let e = 1 - pow(1 - progress, 3)
        let r = 3 + CGFloat(e) * maxR
        ctx.stroke(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                   with: .color(.primary.opacity(alpha * (1 - progress))), lineWidth: 0.8)
    }

    /// 引线标注：斜线 12pt + 下划横线，文字压在横线上。偶数站朝上、奇数站朝下，靠右缘时翻到左边。
    private func label(_ ctx: inout GraphicsContext, _ s: TraceStop, at pt: CGPoint, index: Int, size: CGSize, focused: Bool) {
        var parts = [s.ttlText, s.isOrigin ? String(localized: "起点 \(s.place)", bundle: .wgLocalized) : s.place]
        if let ms = s.latency { parts.append(String(format: "%.0fms", ms)) }
        let strong = s.isDestination || focused
        let text = ctx.resolve(Text(verbatim: parts.joined(separator: "  "))
            .font(WgInk.mono(.micro, strong ? .bold : .regular))
            .foregroundStyle(s.isDestination ? inverse : Color.primary.opacity(strong ? 1 : 0.7)))
        let w = text.measure(in: size).width + 8
        let up = index % 2 == 0
        let left = pt.x + 14 + w > size.width
        let dx: CGFloat = left ? -12 : 12, dy: CGFloat = up ? -12 : 12
        let knee = CGPoint(x: pt.x + dx, y: pt.y + dy)
        let end = CGPoint(x: knee.x + (left ? -w : w), y: knee.y)
        var lead = Path(); lead.move(to: pt); lead.addLine(to: knee); lead.addLine(to: end)
        ctx.stroke(lead, with: .color(.primary.opacity(strong ? 0.8 : 0.35)), lineWidth: 0.6)
        let origin = CGPoint(x: left ? end.x + 4 : knee.x + 4, y: knee.y - 1)
        if s.isDestination {
            // 目标：反白标签块（全图唯一实心白块）
            ctx.fill(Path(CGRect(x: min(knee.x, end.x), y: knee.y - 13, width: w, height: 13)), with: .color(.primary))
        }
        ctx.draw(text, at: origin, anchor: .bottomLeading)
    }

}

// MARK: - 左下：图号 / 计数 / 缩放 / 图例

private struct TraceMapLegend: View {
    @ObservedObject var trace: TraceStore
    var zoomOut: () -> Void
    var zoomIn: () -> Void
    var follow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: WgSpace.s) {
            HStack(alignment: .firstTextBaseline, spacing: WgSpace.l) {
                Text(verbatim: "FIG.01  ROUTE TRACE").font(WgInk.mono(.micro, .bold)).tracking(1.4).foregroundStyle(WgInk.ink2)
                Text(verbatim: counter).font(WgInk.mono(.micro, .medium)).tracking(1.2).foregroundStyle(WgInk.ink2).monospacedDigit()
            }
            // 帧率单独一行：放在图号行末会把这一角拉得很宽，压到右下角的跳点表
            TraceFPSLabel()
            Text(verbatim: "ORTHO ⇄ AZIMUTHAL EQUIDISTANT · NATURAL EARTH 50M").font(WgInk.mono(.micro)).tracking(1).foregroundStyle(WgInk.ink4)
            HStack(spacing: WgSpace.m) {
                HStack(spacing: WgSpace.xs) {
                    zoomButton("minus", help: String(localized: "缩小", bundle: .wgLocalized), action: zoomOut)
                    zoomButton("plus", help: String(localized: "放大", bundle: .wgLocalized), action: zoomIn)
                    TraceAutoButton(action: follow)
                }
                legend("○", String(localized: "起点", bundle: .wgLocalized)); legend("□", String(localized: "中转", bundle: .wgLocalized)); legend("■", String(localized: "目标", bundle: .wgLocalized)); legend("···", String(localized: "实测", bundle: .wgLocalized)); legend("- -", String(localized: "代理段", bundle: .wgLocalized))
            }
        }
    }

    /// HOP 07/30 · 12.4s，位数固定。
    private var counter: String {
        let n = trace.hops.last?.ttl ?? 0
        let elapsed = (trace.finishedAt ?? (trace.running ? Date() : trace.startedAt) ?? Date()).timeIntervalSince(trace.startedAt ?? Date())
        let state = trace.running ? "SCAN" : trace.reached ? "DONE" : trace.startedAt == nil ? "IDLE" : "HALT"
        return String(format: "%@  HOP %02d/%02d  %5.1fs", state, n, TraceStore.maxHops, max(0, elapsed))
    }

    private func zoomButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: WgType.micro, weight: .bold)).foregroundStyle(WgInk.ink2)
                .frame(width: 28, height: 28)
                .traceHolo()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func legend(_ mark: String, _ name: String) -> some View {
        HStack(spacing: WgSpace.xs) {
            Text(verbatim: mark).font(WgInk.mono(.micro, .bold)).foregroundStyle(WgInk.ink2)
            Text(verbatim: name).font(WgInk.mono(.micro)).foregroundStyle(WgInk.ink3)
        }
    }
}

/// AUTO（跟拍）按钮：单独订阅镜头对象，镜头逐帧变时只重算这一个按钮。
private struct TraceAutoButton: View {
    @ObservedObject private var model = TraceMapModel.shared
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(verbatim: "AUTO").font(WgInk.mono(.micro, .bold)).tracking(1)
                .foregroundStyle(!model.manual ? WgInk.ink : WgInk.ink3)
                .frame(width: 48, height: 28)
                .traceHolo(active: !model.manual)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("跟拍：镜头跟着航线走，视图挪回原位（Esc）")
    }
}

// MARK: - 跳点台账

private struct TraceHopTable: View {
    @ObservedObject var trace: TraceStore

    // 和左下角图例同一颗粒度：等宽小字，行高紧凑，只在表头下画一道发丝线
    // 收在右下角，只留五列：TTL / 地址 / 位置 / 最快一次 / 丢包；网络（ASN · 运营商）与三次探测明细放在悬停提示里
    private enum W {
        static let ttl: CGFloat = 22
        static let ip: CGFloat = 108
        static let place: CGFloat = 116
        static let rtt: CGFloat = 46
        static let loss: CGFloat = 34
    }

    /// 表格的自然宽度：各列宽 + 列间距（5 列 4 个间隔）。右下角这块的宽度从这里取，列宽改了自动跟着变。
    static var naturalWidth: CGFloat {
        W.ttl + W.ip + W.place + W.rtt + W.loss + WgSpace.s * 4
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: WgSpace.l) {
                Text(verbatim: "FIG.03  HOPS").font(WgInk.mono(.micro, .bold)).tracking(1.4).foregroundStyle(WgInk.ink2)
                Text(verbatim: trace.hops.isEmpty ? (trace.running ? String(localized: "等待第一跳…", bundle: .wgLocalized) : String(localized: "尚未追踪", bundle: .wgLocalized)) : String(format: String(localized: "%02d 跳", bundle: .wgLocalized), trace.hops.count))
                    .font(WgInk.mono(.micro, .medium)).tracking(1.2).foregroundStyle(WgInk.ink2)
            }
            .wgPadding(.bottom, .s)
            header
            ForEach(trace.hops) { hop in
                row(hop)
                    .transition(.opacity.combined(with: .offset(y: 6)))
            }
            if let px = trace.proxied, px.backend {
                if !px.isDirect, px.node != nil || px.nodeServer != nil {
                    proxyRow(code: "PX", address: px.nodeIP ?? px.nodeServer ?? "—", geo: px.nodeGeo,
                             note: [px.node, px.nodeServer.flatMap { $0 == px.nodeIP ? nil : $0 }].compactMap { $0 }.joined(separator: " · "))
                }
                if let ip = px.realIP {
                    proxyRow(code: "DST", address: ip, geo: px.realGeo, note: String(localized: "真实目标（代理后端解析）", bundle: .wgLocalized))
                }
            }
        }
        .animation(WgDesign.spring, value: trace.hops.count)
    }

    private var header: some View {
        HStack(spacing: WgSpace.s) {
            cell("TTL", W.ttl); cell(String(localized: "地址", bundle: .wgLocalized), W.ip); cell(String(localized: "位置", bundle: .wgLocalized), W.place)
            cell("RTT", W.rtt, .trailing); cell(String(localized: "丢包", bundle: .wgLocalized), W.loss, .trailing)
        }
        .font(WgInk.mono(.micro)).tracking(1).foregroundStyle(WgInk.ink4)
        .frame(height: 18)
        .overlay(alignment: .bottom) { Rectangle().fill(WgInk.rule).frame(height: 1) }
    }

    private func cell(_ s: String, _ w: CGFloat, _ a: Alignment = .leading) -> some View {
        Text(verbatim: s).frame(width: w, alignment: a)
    }

    private func row(_ hop: TraceHop) -> some View {
        let silent = hop.ip == nil
        let focused = trace.focus == hop.ttl
        return HStack(spacing: WgSpace.s) {
            Text(verbatim: String(format: "%02d", hop.ttl)).frame(width: W.ttl, alignment: .leading).foregroundStyle(WgInk.ink3)
            Text(verbatim: hop.ip ?? "*").frame(width: W.ip, alignment: .leading)
                .foregroundStyle(hop.ip == trace.destination && trace.reached ? WgInk.ink : WgInk.ink2)
                .help(hop.alternates.isEmpty ? "" : String(localized: "同跳其他地址：", bundle: .wgLocalized) + hop.alternates.joined(separator: ", "))
            Text(verbatim: placeText(hop)).frame(width: W.place, alignment: .leading).lineLimit(1)
                .foregroundStyle(hop.geo == nil ? WgInk.ink4 : WgInk.ink2)
            Text(verbatim: hop.best.map { String(format: "%.1f", $0) } ?? "*")
                .frame(width: W.rtt, alignment: .trailing)
                .foregroundStyle(hop.best == nil ? WgInk.ink4 : WgInk.ink2)
            Text(verbatim: String(format: "%.0f%%", hop.loss * 100)).frame(width: W.loss, alignment: .trailing)
                .foregroundStyle(hop.loss >= 1 ? WgInk.ink4 : hop.loss > 0 ? WgInk.warn : WgInk.ink3)
        }
        .font(WgInk.mono(.micro))
        .monospacedDigit()
        .opacity(silent ? 0.7 : 1)
        .frame(height: 18)
        .background(focused ? WgInk.field : .clear)
        .contentShape(Rectangle())
        .help(rowHelp(hop))
        .onHover { inside in
            if inside { trace.focus = hop.ttl } else if trace.focus == hop.ttl { trace.focus = nil }
        }
    }

    /// 悬停提示：网络（ASN · 运营商）与三次探测明细。
    private func rowHelp(_ hop: TraceHop) -> String {
        let net = hop.geo.map { [$0.asn, $0.isp].filter { !$0.isEmpty }.joined(separator: " · ") } ?? ""
        let probes = (0..<TraceStore.probes).map { i in i < hop.rtts.count ? hop.rtts[i].map { String(format: "%.1f ms", $0) } ?? "*" : "*" }
        return ([net, String(localized: "探测 ", bundle: .wgLocalized) + probes.joined(separator: " / ")] + (hop.alternates.isEmpty ? [] : [String(localized: "同跳其他地址：", bundle: .wgLocalized) + hop.alternates.joined(separator: ", ")]))
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// 代理段的行：本机没有逐跳数据，探测列留空。
    private func proxyRow(code: String, address: String, geo: TraceGeo?, note: String) -> some View {
        HStack(spacing: WgSpace.s) {
            Text(verbatim: code).frame(width: W.ttl, alignment: .leading).foregroundStyle(WgInk.ink3)
            Text(verbatim: address).frame(width: W.ip, alignment: .leading).lineLimit(1).foregroundStyle(WgInk.ink2)
            Text(verbatim: geo.map { [$0.city, $0.country].filter { !$0.isEmpty }.joined(separator: " · ") } ?? (trace.locating ? String(localized: "定位中…", bundle: .wgLocalized) : String(localized: "未定位", bundle: .wgLocalized)))
                .frame(width: W.place, alignment: .leading).lineLimit(1).foregroundStyle(geo == nil ? WgInk.ink4 : WgInk.ink2)
            Text(verbatim: String(localized: "代理段", bundle: .wgLocalized)).frame(width: W.rtt + W.loss + WgSpace.s, alignment: .trailing).foregroundStyle(WgInk.ink4)
        }
        .help(([note] + [geo.map { [$0.asn, $0.isp].filter { !$0.isEmpty }.joined(separator: " · ") } ?? "", String(localized: "代理段 · 本机不可测", bundle: .wgLocalized)]).filter { !$0.isEmpty }.joined(separator: "\n"))
        .font(WgInk.mono(.micro))
        .frame(height: 18)
        .overlay(alignment: .top) { Rectangle().fill(WgInk.rule).frame(height: 1).opacity(code == "PX" ? 1 : 0) }
    }

    private func placeText(_ hop: TraceHop) -> String {
        if let px = trace.proxied, hop.ip == px.systemIP {
            return px.backend ? String(localized: "代理接管 · fake-ip", bundle: .wgLocalized) : String(localized: "兜底网段 · 疑似 fake-ip", bundle: .wgLocalized)
        }
        if let g = hop.geo { return [g.city, g.country].filter { !$0.isEmpty }.joined(separator: " · ") }
        if hop.kind == .publicNet { return trace.locating ? String(localized: "定位中…", bundle: .wgLocalized) : String(localized: "未定位", bundle: .wgLocalized) }
        return hop.kind.label
    }
}
