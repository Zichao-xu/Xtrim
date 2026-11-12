import AppKit
import SwiftUI

// MARK: - Proxy workspace

struct ProxyView: View {
    @EnvironmentObject private var client: DaemonClient
    /// 记住上次所在的子页（原版 LAST_ROUTE_NAME_KEY）。
    @AppStorage("pp.section") private var section: ProxySection = .proxies

    var body: some View {
        VStack(spacing: 0) {
            ProxyPageHeader(section: section)
            ProxySectionTabs(selection: $section)
            if let error = client.proxyError, !error.isEmpty {
                ProxyFeedbackBar(message: error, color: .red) {
                    client.proxyError = nil
                }
            } else if let notice = client.proxyNotice, !notice.isEmpty {
                ProxyFeedbackBar(message: notice, color: .green) {
                    client.proxyNotice = nil
                }
            }
            Divider().opacity(0.12)
            page
        }
        .onAppear {
            client.stopPolling()
        }
        .onDisappear {
            client.startPolling()
        }
        .task(id: section) {
            await refresh(section)
        }
        // 内容宽度与其他页面一致（WgLayout.pageMaxWidth + 两侧内边距），切页时标题不跳位。
        .frame(maxWidth: WgLayout.pageMaxWidth + WgTheme.pagePadding * 2, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var page: some View {
        switch section {
        case .overview:
            PPOverviewPage()
                .wgPadding(.horizontal, WgTheme.pageGap)
        case .proxies:
            PPProxiesPage()
                .wgPadding(.horizontal, WgTheme.pageGap)
        case .connections:
            ProxyConnectionsPage()
        case .rules:
            ProxyRulesPage()
        case .logs:
            ProxyLogsPage()
        case .settings:
            ProxySettingsPage()
        }
    }

    private func refresh(_ section: ProxySection) async {
        await client.fetchProxyStatus()
        if section == .settings {
            await client.fetchProxySettings()
        }
        guard client.proxyRunning else { return }
        switch section {
        case .overview:
            await client.fetchProxyVersion()
            await client.fetchProxyConfig()
            await client.fetchProxies()
            await client.fetchConnections()
            await client.fetchProxyProviders()
        case .proxies:
            await client.fetchProxies()
            await client.fetchProxyProviders()
        case .connections:
            await client.fetchConnections()
        case .rules:
            await client.fetchRules()
            await client.fetchRuleProviders()
        case .logs:
            await client.fetchProxyLogs()
        case .settings:
            await client.fetchProxyConfig()
        }
    }
}

enum ProxySection: String, CaseIterable, Identifiable {
    case overview, proxies, connections, rules, logs, settings

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .overview: return "概览"
        case .proxies: return "代理"
        case .connections: return "连接"
        case .rules: return "规则"
        case .logs: return "日志"
        case .settings: return "设置"
        }
    }

    var icon: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.50percent"
        case .proxies: return "point.3.connected.trianglepath.dotted"
        case .connections: return "arrow.up.arrow.down"
        case .rules: return "list.bullet.rectangle"
        case .logs: return "text.alignleft"
        case .settings: return "gearshape"
        }
    }
}

private struct ProxySectionTabs: View {
    @Binding var selection: ProxySection
    @Namespace private var indicator
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // 平行四边形页签彼此咬合；当前页 = 白色弱玻璃（位置滑动过渡），其余为淡玻璃。
        HStack(spacing: -6) {
            ForEach(ProxySection.allCases) { item in
                Button {
                    withAnimation(WgDesign.spring) { selection = item }
                } label: {
                    let index = (ProxySection.allCases.firstIndex(of: item) ?? 0) + 1
                    let on = selection == item
                    HStack(spacing: WgSpace.s) {
                        Text(verbatim: String(format: "%02d", index))
                            .font(WgInk.mono(.caption, .medium))
                            .foregroundStyle(on ? WgInk.ink2 : WgInk.ink4)
                        Text(item.title)
                            .font(.system(size: WgType.body, weight: on ? .bold : .semibold))
                            .foregroundStyle(on ? WgInk.ink : WgInk.ink2)
                    }
                    .wgPadding(.leading, .m).wgPadding(.trailing, .m)
                    .frame(height: 34)
                    .background {
                        if on {
                            Color.clear.wgGlassAccent(SlantShape(slant: 8))
                                .matchedGeometryEffect(id: "tab", in: indicator)
                        } else {
                            WgShapePlate(shape: SlantShape(slant: 8), fill: Color.primary.opacity(0.05), border: .clear, highlight: .clear)
                        }
                    }
                    .contentShape(Rectangle())   // 点击区域用矩形（见 WgInteractiveSurface 的说明）
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(item.title))
                .accessibilityHint("切换代理页面")
            }
        }
        .fixedSize()
        .frame(maxWidth: .infinity, alignment: .leading)
        .wgPadding(.horizontal, WgTheme.pageGap)
        .wgPadding(.bottom, .l)
        .focusEffectDisabled()
    }
}

private struct ProxyPageHeader: View {
    @EnvironmentObject private var client: DaemonClient
    @ObservedObject private var backends = MihomoBackendStore.shared
    let section: ProxySection

    /// 面板跟随出口自动换后端：标题写明当前连的是本机内核还是路由器。
    private var subtitle: String {
        guard let b = backends.active else { return "MIHOMO" }
        return b.isLocal ? "MIHOMO · 本机内核 \(b.host):\(b.port)" : "MIHOMO · \(b.displayName) \(b.host):\(b.port)"
    }

    var body: some View {
        WgPageHeader(title: "面板",
                     subtitleText: subtitle,
                     word: "PANEL") {
            // 节点信息块：左上斜切的黑色弱玻璃，等宽两列。
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                GridRow {
                    Text(verbatim: "CORE").font(WgInk.mono(.caption)).tracking(1).foregroundStyle(WgInk.ink3)
                    Text(verbatim: coreVersion).font(WgInk.mono(.caption, .medium)).foregroundStyle(WgInk.ink)
                }
                GridRow {
                    Text(verbatim: "STATE").font(WgInk.mono(.caption)).tracking(1).foregroundStyle(WgInk.ink3)
                    HStack(spacing: WgSpace.xs) {
                        Rectangle().fill(linked ? WgInk.ink : WgInk.ink4).frame(width: 6, height: 6)
                        statusLabel.font(WgInk.mono(.caption, .medium)).foregroundStyle(WgInk.ink)
                    }
                }
            }
            .lineLimit(1)
            .wgPadding(.leading, .m).wgPadding(.trailing, .l).wgPadding(.vertical, .s)
            .wgGlassPanel(ChamferShape(tl: 12))

            Button {
                Task { await client.fetchProxyStatus() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(WgToolbarIconButtonStyle())
            .accessibilityLabel("刷新代理状态")
            .help("刷新连接状态")
        }
        .wgPadding(.horizontal, WgTheme.pageGap)
        .wgPadding(.bottom, .l)
    }

    @ViewBuilder
    /// 本机内核后端的状态由网络服务报告；路由器后端沿用网络服务里的控制器客户端。
    private var isLocal: Bool { backends.active?.isLocal == true }
    private var coreVersion: String {
        isLocal ? (client.mihomo?.version ?? "—") : (client.mihomoVersion?.version ?? "—")
    }
    private var linked: Bool { isLocal ? client.mihomo?.running == true : client.proxyRunning }

    @ViewBuilder
    private var statusLabel: some View {
        if isLocal {
            Text(client.mihomo?.running == true ? "本机运行中" : "本机未运行")
        } else if client.proxyRunning {
            Text(verbatim: "LINKED")
        } else if client.proxyServiceRunning {
            Text("控制器未连接")
        } else {
            Text("daemon 离线")
        }
    }
}

private struct ProxyFeedbackBar: View {
    let message: String
    let color: Color
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: WgSpace.s) {
            Image(systemName: color == .red ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(color)
            Text(LocalizedStringKey(message))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭提示")
            .help("关闭")
        }
        .wgPadding(.horizontal, WgTheme.pageGap)
        .frame(minHeight: 36)
        .background(color.opacity(0.07))
    }
}

private struct ProxyUnavailableView: View {
    @EnvironmentObject private var client: DaemonClient
    var onRetry: (() -> Void)?
    var openSettings: (() -> Void)?
    var startDaemon: (() -> Void)?

    var body: some View {
        VStack(spacing: WgSpace.l) {
            ContentUnavailableView {
                Label(
                    title: { Text(LocalizedStringKey(client.proxyServiceRunning ? "控制器未连接" : "后台服务未启动")) },
                    icon: { Image(systemName: client.proxyServiceRunning ? "network.slash" : "gearshape.2") }
                )
            } description: {
                Text(LocalizedStringKey(client.proxyServiceRunning ? "请在设置中检查 Mihomo 地址与密钥" : "先启动 Xtrim 后台服务，再连接 Mihomo 控制器"))
            }
            HStack(spacing: WgSpace.m) {
                if let startDaemon, !client.proxyServiceRunning {
                    Button(action: startDaemon) {
                        Label {
                            Text(LocalizedStringKey(client.isAuthorizingDaemon ? "等待授权" : "启动后台服务"))
                        } icon: {
                            Image(systemName: "play.circle")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(client.isAuthorizingDaemon)
                    .accessibilityHint("弹出 macOS 管理员授权并启动 Xtrim 后台服务")
                }
                if let onRetry {
                    Button(action: onRetry) {
                        Label("重试连接", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityHint("重新读取 daemon 与 Mihomo 控制器状态")
                }
                if let openSettings {
                    Button(action: openSettings) {
                        Label("打开设置", systemImage: "gearshape")
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint("切换到代理设置页面")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Overview

private struct ProxyOverviewPage: View {
    @EnvironmentObject private var client: DaemonClient
    @ObservedObject private var live = ProxyLiveStore.shared
	@AppStorage("proxyEmojiEnabled") private var emojiEnabled = true
    @Binding var section: ProxySection
    @State private var samples: [ProxyOverviewSample] = []

    private var groups: [(String, DaemonClient.ProxyInfo)] {
        client.proxies
            .filter { !($0.value.all ?? []).isEmpty }
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
    }

    private var nodesCount: Int {
        client.proxies.values.filter { ($0.all ?? []).isEmpty && !proxySystemTypes.contains($0.type) }.count
    }

	private var sortedProviders: [DaemonClient.ProxyProviderInfo] {
		client.proxyProviders.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
	}

    private var current: ProxyOverviewSample {
        samples.last ?? ProxyOverviewSample(
            time: Date(),
            uploadTotal: client.connections?.uploadTotal ?? 0,
            downloadTotal: client.connections?.downloadTotal ?? 0,
            uploadSpeed: 0,
            downloadSpeed: 0,
            connectionCount: client.connections?.connections.count ?? 0,
            memoryBytes: nil
        )
    }

    private var sourceStats: [ProxySourceStat] {
        Dictionary(grouping: client.connections?.connections ?? []) { connection in
            connection.metadata.sourceIP?.isEmpty == false ? connection.metadata.sourceIP! : "unknown"
        }
        .map { source, values in
            ProxySourceStat(
                source: source,
                download: values.reduce(0) { $0 + $1.download },
                upload: values.reduce(0) { $0 + $1.upload },
                connections: values.count
            )
        }
        .sorted { $0.total > $1.total }
    }

    private var ruleHitStats: [ProxyBarDatum] {
        Dictionary(grouping: client.connections?.connections ?? []) { connection in
            connection.rule?.isEmpty == false ? connection.rule! : "Match"
        }
        .map { ProxyBarDatum(label: $0.key, value: Double($0.value.count)) }
        .sorted { $0.value > $1.value }
    }

    private var ruleUnhitStats: [ProxyBarDatum] {
        let hit = Set(ruleHitStats.map(\.label))
        return client.rules
            .filter { !hit.contains($0.proxy ?? $0.payload ?? $0.type) }
            .prefix(18)
            .enumerated()
            .map { index, rule in
                ProxyBarDatum(
                    label: rule.payload ?? rule.proxy ?? rule.type,
                    value: Double(max((rule.size ?? 0) / 1000, Int64(client.rules.count - index)))
                )
            }
    }

    var body: some View {
        if !client.proxyRunning {
            ProxyUnavailableView(
                onRetry: { Task { await client.fetchProxyStatus() } },
                openSettings: { section = .settings },
                startDaemon: { Task { await client.startDaemonForProxy() } }
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: WgSpace.m) {
                    ProxyOverviewMetricStrip(sample: current)

                    ProxyPanel {
                        HStack(spacing: WgSpace.m) {
                            ProxyLineChart(
                                title: "实时速度",
                                series: [
                                    ProxyChartSeries(name: "上传速度", color: .cyan, points: samples.map { ProxyChartPoint(time: $0.time, value: $0.uploadSpeed) }),
                                    ProxyChartSeries(name: "下载速度", color: .indigo, points: samples.map { ProxyChartPoint(time: $0.time, value: $0.downloadSpeed) })
                                ],
                                formatter: proxyFormatBytesPerSecond
                            )
                            ProxyLineChart(
                                title: "内存使用",
                                series: [
                                    ProxyChartSeries(name: "内存使用", color: .indigo, points: samples.compactMap { sample in
                                        sample.memoryBytes.map { ProxyChartPoint(time: sample.time, value: Double($0)) }
                                    })
                                ],
                                formatter: { proxyFormatBytes(Int64($0)) },
                                emptyText: "Mihomo API 未暴露内存"
                            )
                            ProxyLineChart(
                                title: "连接",
                                series: [
                                    ProxyChartSeries(name: "连接", color: .indigo, points: samples.map { ProxyChartPoint(time: $0.time, value: Double($0.connectionCount)) })
                                ],
                                formatter: { String(format: "%.0f", $0) }
                            )
                        }
                        .frame(height: 230)
                    }

                    ProxyPanel(title: "网络信息") {
                        ProxyNetworkInformationView(
                            latencyLow: client.proxySettings?.latencyLow ?? 200,
                            latencyMedium: client.proxySettings?.latencyMedium ?? 500
                        )
                    }

                    ProxyPanel(title: "连接拓扑") {
                        ProxyTopologyView(connections: client.connections?.connections ?? [])
                    }

                    ProxyPanel(title: "连接统计") {
                        ProxySourceStatsTable(stats: sourceStats)
                    }

                    ProxyPanel(title: "规则命中统计") {
                        HStack(spacing: WgSpace.m) {
                            ProxyBarChart(title: "命中统计", data: Array(ruleHitStats.prefix(18)), color: .indigo)
                            ProxyBarChart(title: "未命中统计", data: Array(ruleUnhitStats.prefix(18)), color: .cyan)
                        }
                        .frame(height: 300)
                    }
                }
                .wgPadding(WgTheme.pageGap)
            }
            .wgTimelineScroller()
            .task {
                await refreshOverview(checkStatus: true)
                var refreshCount = 0
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    refreshCount += 1
                    await refreshOverview(checkStatus: refreshCount.isMultiple(of: 10))
                }
            }
        }
    }

    private var availableModes: [String] {
        let modes = client.mihomoConfig?.modes ?? client.mihomoConfig?.modeList ?? []
        return modes.isEmpty ? ["rule", "global", "direct"] : modes
    }

    private var modeBinding: Binding<String> {
        Binding(
            get: { client.mihomoConfig?.mode ?? "rule" },
            set: { mode in Task { _ = await client.updateProxyMode(mode) } }
        )
    }

    private func refreshOverview(checkStatus: Bool = false) async {
        let before = samples.last
        if checkStatus {
            await client.fetchProxyStatus()
        }
        guard client.proxyRunning else { return }
        await client.fetchConnections()
        if client.mihomoConfig == nil { await client.fetchProxyConfig() }
        if client.proxies.isEmpty { await client.fetchProxies() }
        if client.rules.isEmpty { await client.fetchRules() }
        if client.proxyProviders.isEmpty { await client.fetchProxyProviders() }

        let now = Date()
        let uploadTotal = client.connections?.uploadTotal ?? 0
        let downloadTotal = client.connections?.downloadTotal ?? 0
        let interval = max(now.timeIntervalSince(before?.time ?? now), 1)
        let uploadSpeed = before.map { max(0, Double(uploadTotal - $0.uploadTotal) / interval) } ?? 0
        let downloadSpeed = before.map { max(0, Double(downloadTotal - $0.downloadTotal) / interval) } ?? 0
        samples.append(
            ProxyOverviewSample(
                time: now,
                uploadTotal: uploadTotal,
                downloadTotal: downloadTotal,
                uploadSpeed: uploadSpeed,
                downloadSpeed: downloadSpeed,
                connectionCount: client.connections?.connections.count ?? 0,
                memoryBytes: nil
            )
        )
        if samples.count > 120 {
            samples.removeFirst(samples.count - 120)
        }
    }
}

private struct ProxyOverviewSample: Identifiable {
    let id = UUID()
    let time: Date
    let uploadTotal: Int64
    let downloadTotal: Int64
    let uploadSpeed: Double
    let downloadSpeed: Double
    let connectionCount: Int
    let memoryBytes: Int64?
}

private struct ProxySourceStat: Identifiable {
    var id: String { source }
    let source: String
    let download: Int64
    let upload: Int64
    let connections: Int
    var total: Int64 { download + upload }
}

private struct ProxyBarDatum: Identifiable {
    var id: String { label }
    let label: String
    let value: Double
}

private struct ProxyChartPoint: Hashable {
    let time: Date
    let value: Double
}

private struct ProxyChartSeries: Identifiable {
    var id: String { name }
    let name: String
    let color: Color
    let points: [ProxyChartPoint]

    var values: [Double] { points.map(\.value) }
}

private struct ProxyPanel<Content: View>: View {
    var title: LocalizedStringKey?
    let content: Content

    init(title: LocalizedStringKey? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WgSpace.l) {
            if let title {
                Text(title).font(.headline)
            }
            content
        }
        .wgPadding(.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .wgGlassSurface(cornerRadius: WgTheme.cardRadius)
    }
}

private struct ProxyOverviewMetricStrip: View {
    let sample: ProxyOverviewSample

    var body: some View {
        ProxyPanel {
            HStack(spacing: 0) {
                metric("连接", "\(sample.connectionCount)")
                metric("内存使用", sample.memoryBytes.map { proxyFormatBytes($0) } ?? "—")
                metric("下载", proxyFormatBytes(sample.downloadTotal))
                metric("下载速度", proxyFormatBytesPerSecond(sample.downloadSpeed))
                metric("上传", proxyFormatBytes(sample.uploadTotal))
                metric("上传速度", proxyFormatBytesPerSecond(sample.uploadSpeed))
            }
        }
    }

    private func metric(_ title: LocalizedStringKey, _ value: String) -> some View {
        VStack(spacing: WgSpace.s) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: WgType.large, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ProxyLineChart: View {
    let title: LocalizedStringKey
    let series: [ProxyChartSeries]
    let formatter: (Double) -> String
    var emptyText: LocalizedStringKey = "暂无数据"

    private let timeWindow: TimeInterval = 60
    private var allValues: [Double] { series.flatMap(\.values) }

    var body: some View {
        VStack(alignment: .leading, spacing: WgSpace.s) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            GeometryReader { geometry in
                if allValues.isEmpty {
                    Text(emptyText)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black.opacity(0.10), in: RoundedRectangle(cornerRadius: WgRadius.s))
                } else {
                    ProxyCoreAnimationChart(series: series, timeWindow: timeWindow)
                    .overlay(alignment: .topLeading) {
                        Text(formatter(allValues.last ?? allValues.max() ?? 0))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .wgPadding(.s)
                            .contentTransition(.numericText())
                    }
                }
            }
            legend
        }
    }

    private var legend: some View {
        HStack(spacing: WgSpace.m) {
            ForEach(series) { item in
                HStack(spacing: WgSpace.xs) {
                    Circle().fill(item.color).frame(width: 8, height: 8)
                    Text(item.name).font(.caption2)
                }
                .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "pause.circle").font(.caption).foregroundStyle(.secondary)
        }
    }

}

private struct ProxyCoreAnimationChart: NSViewRepresentable {
    let series: [ProxyChartSeries]
    let timeWindow: TimeInterval

    func makeNSView(context: Context) -> ProxyChartLayerView {
        ProxyChartLayerView()
    }

    func updateNSView(_ nsView: ProxyChartLayerView, context: Context) {
        nsView.update(series: series, timeWindow: timeWindow)
    }
}

private final class ProxyChartLayerView: NSView {
    private let gridLayer = CAShapeLayer()
    private var lineLayers: [CAShapeLayer] = []
    private var fillLayers: [CAShapeLayer] = []
    private var chartSeries: [ProxyChartSeries] = []
    private var timeWindow: TimeInterval = 60
    private var dataSignature = ""

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(gridLayer)
        gridLayer.fillColor = nil
        gridLayer.strokeColor = NSColor.white.withAlphaComponent(0.08).cgColor
        gridLayer.lineWidth = 0.6
        gridLayer.lineDashPattern = [4, 4]
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(series: [ProxyChartSeries], timeWindow: TimeInterval) {
        chartSeries = series
        self.timeWindow = timeWindow
        ensureLayerCount(series.count)
        let signature = series.map { item in
            let last = item.points.last
            return "\(item.name):\(last?.time.timeIntervalSinceReferenceDate ?? 0):\(last?.value ?? 0):\(item.points.count)"
        }.joined(separator: "|")
        let shouldAnimate = !dataSignature.isEmpty && signature != dataSignature
        dataSignature = signature
        updatePaths(animated: shouldAnimate)
    }

    override func layout() {
        super.layout()
        gridLayer.frame = bounds
        updateGrid()
        updatePaths(animated: false)
    }

    private func ensureLayerCount(_ count: Int) {
        while lineLayers.count < count {
            let fill = CAShapeLayer()
            fill.fillRule = .nonZero
            layer?.addSublayer(fill)
            fillLayers.append(fill)

            let line = CAShapeLayer()
            line.fillColor = nil
            line.lineWidth = 2
            line.lineCap = .round
            line.lineJoin = .round
            layer?.addSublayer(line)
            lineLayers.append(line)
        }
        while lineLayers.count > count {
            lineLayers.removeLast().removeFromSuperlayer()
            fillLayers.removeLast().removeFromSuperlayer()
        }
    }

    private func updateGrid() {
        let rect = bounds.insetBy(dx: 4, dy: 4)
        let path = CGMutablePath()
        for index in 0...3 {
            let y = rect.minY + rect.height * CGFloat(index) / 3
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        gridLayer.path = path
    }

    private func updatePaths(animated: Bool) {
        guard bounds.width > 8, bounds.height > 8 else { return }
        let rect = bounds.insetBy(dx: 4, dy: 4)
        let latestTime = chartSeries.compactMap { $0.points.last?.time }.max() ?? Date()
        let visibleValues = chartSeries.flatMap { item in
            item.points.filter { latestTime.timeIntervalSince($0.time) <= timeWindow + 1 }.map(\.value)
        }
        let maxValue = max(visibleValues.max() ?? 1, 1)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, item) in chartSeries.enumerated() {
            let points = screenPoints(item.points, latestTime: latestTime, maxValue: maxValue, rect: rect)
            let linePath = curvePath(points, rect: rect)
            let fillPath = linePath.mutableCopy() ?? CGMutablePath()
            if let first = points.first, let last = points.last {
                fillPath.addLine(to: CGPoint(x: last.x, y: rect.maxY))
                fillPath.addLine(to: CGPoint(x: first.x, y: rect.maxY))
                fillPath.closeSubpath()
            }

            let nsColor = NSColor(item.color)
            let line = lineLayers[index]
            let fill = fillLayers[index]
            let oldLinePath = line.presentation()?.path ?? line.path
            line.strokeColor = nsColor.withAlphaComponent(0.92).cgColor
            fill.fillColor = nsColor.withAlphaComponent(0.14).cgColor
            line.path = linePath
            fill.path = fillPath

            if animated, let oldLinePath {
                line.add(pathAnimation(from: oldLinePath, to: linePath), forKey: "path")
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0.78
                fade.toValue = 1
                fade.duration = 0.28
                fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
                fill.add(fade, forKey: "opacity")
            }
        }
        CATransaction.commit()
    }

    private func pathAnimation(from: CGPath, to: CGPath) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "path")
        animation.fromValue = from
        animation.toValue = to
        animation.duration = 0.52
        animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.78, 0.24, 1)
        return animation
    }

    private func screenPoints(
        _ points: [ProxyChartPoint],
        latestTime: Date,
        maxValue: Double,
        rect: CGRect
    ) -> [CGPoint] {
        points.sorted { $0.time < $1.time }.compactMap { point in
            let age = max(0, latestTime.timeIntervalSince(point.time))
            let x = rect.maxX - rect.width * CGFloat(age / timeWindow)
            guard x >= rect.minX - 2, x <= rect.maxX + 2 else { return nil }
            let normalized = min(max(point.value / maxValue, 0), 1)
            return CGPoint(x: x, y: rect.maxY - rect.height * CGFloat(normalized))
        }
    }

    private func curvePath(_ points: [CGPoint], rect: CGRect) -> CGMutablePath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 1 else {
            path.addLine(to: CGPoint(x: min(first.x + 1, rect.maxX), y: first.y))
            return path
        }
        for index in 0..<(points.count - 1) {
            let p0 = points[max(index - 1, 0)]
            let p1 = points[index]
            let p2 = points[index + 1]
            let p3 = points[min(index + 2, points.count - 1)]
            let tension: CGFloat = 0.82
            let c1 = CGPoint(
                x: p1.x + (p2.x - p0.x) * tension / 6,
                y: min(max(p1.y + (p2.y - p0.y) * tension / 6, rect.minY), rect.maxY)
            )
            let c2 = CGPoint(
                x: p2.x - (p3.x - p1.x) * tension / 6,
                y: min(max(p2.y - (p3.y - p1.y) * tension / 6, rect.minY), rect.maxY)
            )
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }
}

private struct ProxyInfoBox: View {
    let lines: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: WgSpace.s) {
            ForEach(lines, id: \.0) { key, value in
                HStack(alignment: .firstTextBaseline) {
                    Text(key)
                        .foregroundStyle(.secondary)
                        .frame(width: 72, alignment: .leading)
                    Text(value)
                        .textSelection(.enabled)
                        .lineLimit(1)
                    Spacer()
                }
            }
        }
        .font(.system(.callout, design: .monospaced))
        .wgPadding(.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.10), in: RoundedRectangle(cornerRadius: WgRadius.s))
    }
}

private struct ProxyNetworkIdentity: Identifiable, Sendable {
    let id: String
    let source: String
    let ip: String?
    let description: String
    let error: String?
}

private struct ProxyNetworkLatency: Identifiable, Sendable {
    let id: String
    let name: String
    let milliseconds: Int?
}

private struct ProxyIPSBResponse: Decodable {
    let ip: String?
    let country: String?
    let region: String?
    let city: String?
    let isp: String?
    let organization: String?
    let asnOrganization: String?

    enum CodingKeys: String, CodingKey {
        case ip, country, region, city, isp, organization
        case asnOrganization = "asn_organization"
    }
}

private enum ProxyNetworkProbe {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 7
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: configuration)
    }()

    private static let latencyTargets: [(String, String)] = [
        ("Baidu", "https://www.baidu.com/favicon.ico"),
        ("Cloudflare", "https://www.cloudflare.com/cdn-cgi/trace"),
        ("GitHub", "https://github.com/favicon.ico"),
        ("YouTube", "https://www.youtube.com/generate_204")
    ]

    static func identities() async -> [ProxyNetworkIdentity] {
        async let ipip = loadIPIP()
        async let ipSB = loadIPSB()
        return await [ipip, ipSB]
    }

    static func latencies() async -> [ProxyNetworkLatency] {
        await withTaskGroup(of: ProxyNetworkLatency.self) { group in
            for (name, address) in latencyTargets {
                group.addTask {
                    await measure(name: name, address: address)
                }
            }

            var values: [String: ProxyNetworkLatency] = [:]
            for await result in group {
                values[result.id] = result
            }
            return latencyTargets.map { target in
                values[target.0] ?? ProxyNetworkLatency(id: target.0, name: target.0, milliseconds: nil)
            }
        }
    }

    private static func loadIPIP() async -> ProxyNetworkIdentity {
        do {
            let (data, _) = try await request("https://myip.ipip.net")
            let text = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let pattern = #"当前 IP：([^\s]+)\s+来自于：(.+)"#
            let regex = try NSRegularExpression(pattern: pattern)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: range),
                  let ipRange = Range(match.range(at: 1), in: text),
                  let descriptionRange = Range(match.range(at: 2), in: text) else {
                throw URLError(.cannotParseResponse)
            }
            return ProxyNetworkIdentity(
                id: "ipip.net",
                source: "ipip.net",
                ip: String(text[ipRange]),
                description: String(text[descriptionRange]),
                error: nil
            )
        } catch {
            return ProxyNetworkIdentity(
                id: "ipip.net",
                source: "ipip.net",
                ip: nil,
                description: "",
                error: proxyNetworkErrorText(error)
            )
        }
    }

    private static func loadIPSB() async -> ProxyNetworkIdentity {
        do {
            let (data, _) = try await request("https://api.ip.sb/geoip")
            let response = try JSONDecoder().decode(ProxyIPSBResponse.self, from: data)
            let location: [String] = [response.country, response.region, response.city]
                .compactMap { (value: String?) -> String? in
                    guard let value, !value.isEmpty else { return nil }
                    return value
                }
            let provider = response.isp ?? response.organization ?? response.asnOrganization
            let description = (location + [provider].compactMap { $0 }).joined(separator: " ")
            return ProxyNetworkIdentity(
                id: "ip.sb",
                source: "ip.sb",
                ip: response.ip,
                description: description.isEmpty ? "未知出口" : description,
                error: nil
            )
        } catch {
            return ProxyNetworkIdentity(
                id: "ip.sb",
                source: "ip.sb",
                ip: nil,
                description: "",
                error: proxyNetworkErrorText(error)
            )
        }
    }

    private static func measure(name: String, address: String) async -> ProxyNetworkLatency {
        let startedAt = Date()
        do {
            _ = try await request(address)
            let milliseconds = max(1, Int(Date().timeIntervalSince(startedAt) * 1_000))
            return ProxyNetworkLatency(id: name, name: name, milliseconds: milliseconds)
        } catch {
            return ProxyNetworkLatency(id: name, name: name, milliseconds: nil)
        }
    }

    private static func request(_ address: String) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: address) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("WgSense/0.1", forHTTPHeaderField: "User-Agent")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200..<500).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return (data, response)
    }

    private static func proxyNetworkErrorText(_ error: Error) -> String {
        if let urlError = error as? URLError, urlError.code == .timedOut {
            return "检测超时"
        }
        return "检测失败"
    }
}

private struct ProxyNetworkInformationView: View {
    let latencyLow: Int
    let latencyMedium: Int
    @State private var identities: [ProxyNetworkIdentity] = []
    @State private var latencies: [ProxyNetworkLatency] = []
    @State private var revealsIPAddress = false
    @State private var isRefreshing = false

    var body: some View {
        HStack(alignment: .top, spacing: WgSpace.m) {
            identityColumn
                .frame(maxWidth: .infinity, minHeight: 124, alignment: .topLeading)

            Divider().opacity(0.18)

            latencyColumn
                .frame(maxWidth: .infinity, minHeight: 124, alignment: .topLeading)
        }
        .wgPadding(.vertical, .xs)
        .task {
            await refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await refresh()
            }
        }
    }

    private var identityColumn: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(alignment: .leading, spacing: WgSpace.m) {
                if identities.isEmpty {
                    ProgressView("正在检测公网出口")
                        .controlSize(.small)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(identities) { identity in
                        HStack(alignment: .firstTextBaseline, spacing: WgSpace.s) {
                            Text(identity.source)
                                .frame(width: 70, alignment: .leading)
                            Text(":").foregroundStyle(.secondary)
                            if let error = identity.error {
                                Text(error).foregroundStyle(.red)
                            } else {
                                Text(identityLine(identity))
                                    .textSelection(.enabled)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
            }
            .font(.system(.callout, design: .rounded))
            .wgInset(.trailing, 82)

            HStack(spacing: WgSpace.s) {
                Button {
                    withAnimation(.smooth(duration: 0.2)) {
                        revealsIPAddress.toggle()
                    }
                } label: {
                    Image(systemName: revealsIPAddress ? "eye" : "eye.slash")
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .wgGlassSurface(cornerRadius: WgRadius.s, interactive: true)
                .help(revealsIPAddress ? "隐藏 IP 地址" : "显示 IP 地址")

                Button {
                    Task { await refresh() }
                } label: {
                    Group {
                        if isRefreshing {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "bolt")
                        }
                    }
                    .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .wgGlassSurface(cornerRadius: WgRadius.s, interactive: true)
                .disabled(isRefreshing)
                .help("立即重新检测")
            }
        }
    }

    private var latencyColumn: some View {
        VStack(alignment: .leading, spacing: WgSpace.s) {
            ForEach(latencies.isEmpty ? placeholderLatencies : latencies) { latency in
                HStack(spacing: WgSpace.s) {
                    Text(latency.name)
                        .frame(width: 104, alignment: .leading)
                    Text(":").foregroundStyle(.secondary)
                    Text(latency.milliseconds.map { "\($0) ms" } ?? (isRefreshing ? "检测中" : "超时"))
                        .foregroundStyle(latencyColor(latency.milliseconds))
                        .contentTransition(.numericText())
                    Spacer()
                }
            }
        }
        .font(.system(.callout, design: .rounded))
    }

    private var placeholderLatencies: [ProxyNetworkLatency] {
        ["Baidu", "Cloudflare", "GitHub", "YouTube"].map {
            ProxyNetworkLatency(id: $0, name: $0, milliseconds: nil)
        }
    }

    private func identityLine(_ identity: ProxyNetworkIdentity) -> String {
        guard let ip = identity.ip else { return identity.description }
        let shownIP = revealsIPAddress ? ip : maskedIPAddress(ip)
        return "\(identity.description) (\(shownIP))"
    }

    private func maskedIPAddress(_ ip: String) -> String {
        if ip.contains(":") { return "****:****:****:****" }
        return "***.***.***.***"
    }

    private func latencyColor(_ milliseconds: Int?) -> Color {
        guard let milliseconds else { return .secondary }
        if milliseconds < latencyLow { return .green }
        if milliseconds < latencyMedium { return .orange }
        return .red
    }

    @MainActor
    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        async let loadedIdentities = ProxyNetworkProbe.identities()
        async let loadedLatencies = ProxyNetworkProbe.latencies()
        let result = await (loadedIdentities, loadedLatencies)
        withAnimation(.smooth(duration: 0.28)) {
            identities = result.0
            latencies = result.1
            isRefreshing = false
        }
    }
}

private struct ProxyTopologyView: View {
    let connections: [DaemonClient.ConnectionInfo]
    private let graph: ProxyTopologyGraph
    private let totalBytes: Int64
    @State private var selectedNodeID: String?
    @State private var hoveredNodeID: String?

    init(connections: [DaemonClient.ConnectionInfo]) {
        self.connections = connections
        self.graph = ProxyTopologyGraph(connections: connections)
        self.totalBytes = connections.reduce(0) { $0 + $1.upload + $1.download }
    }

    private var activeNodeID: String? { hoveredNodeID ?? selectedNodeID }

    private var selectedNode: ProxyTopologyNode? {
        guard let selectedNodeID else { return nil }
        return graph.nodes.first { $0.id == selectedNodeID }
    }

    private var activeNode: ProxyTopologyNode? {
        guard let activeNodeID else { return nil }
        return graph.nodes.first { $0.id == activeNodeID }
    }

    private var canvasHeight: CGFloat { graph.recommendedHeight }
    private var canvasMinWidth: CGFloat { graph.recommendedWidth }

    var body: some View {
        VStack(alignment: .leading, spacing: WgSpace.m) {
            ScrollView(.horizontal, showsIndicators: canvasMinWidth > 900) {
                topologyCanvas
                    .frame(minWidth: canvasMinWidth, maxWidth: .infinity, minHeight: canvasHeight)
            }
            .frame(minHeight: canvasHeight)

            ProxyTopologySelectionBar(
                selected: selectedNode,
                connectionCount: connections.count,
                totalBytes: totalBytes
            ) {
                withAnimation(.smooth(duration: 0.2, extraBounce: 0.06)) {
                    selectedNodeID = nil
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var topologyCanvas: some View {
        GeometryReader { geometry in
            let layout = graph.layout(in: CGSize(width: max(geometry.size.width, canvasMinWidth), height: canvasHeight))
            let activeNodeIDs = activeNodeID.map { graph.connectedNodeIDs(to: $0) } ?? Set(graph.nodes.map(\.id))
            let activeLinkIDs = activeNodeID.map { graph.connectedLinkIDs(to: $0) } ?? Set(graph.links.map(\.id))
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: WgRadius.s, style: .continuous)
                    .fill(Color.black.opacity(0.10))
                Canvas(opaque: false, colorMode: .linear, rendersAsynchronously: true) { context, size in
                    for link in graph.links {
                        guard
                            let from = layout.nodeRects[link.from],
                            let to = layout.nodeRects[link.to]
                        else { continue }
                        let isActive = activeNodeID == nil || activeLinkIDs.contains(link.id)
                        let lineWidth = layout.width(for: link)
                        let path = topologyPath(from: from, to: to)
                        let start = CGPoint(x: from.maxX, y: from.midY)
                        let end = CGPoint(x: to.minX, y: to.midY)

                        context.stroke(
                            path,
                            with: .linearGradient(
                                Gradient(colors: [
                                    link.color.opacity(isActive ? 0.48 : 0.035),
                                    link.color.opacity(isActive ? 0.20 : 0.018)
                                ]),
                                startPoint: start,
                                endPoint: end
                            ),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
                        )

                    }
                }

                ProxyTopologyFlowView(
                    segments: graph.links.compactMap { link in
                        guard let from = layout.nodeRects[link.from], let to = layout.nodeRects[link.to] else { return nil }
                        return ProxyTopologyFlowSegment(
                            id: link.id,
                            from: from,
                            to: to,
                            color: NSColor(link.color),
                            lineWidth: max(1.2, min(4.5, layout.width(for: link) * 0.28)),
                            duration: layout.flowDuration(for: link),
                            isActive: activeNodeID == nil || activeLinkIDs.contains(link.id)
                        )
                    }
                )
                .allowsHitTesting(false)

                ForEach(graph.nodes) { node in
                    if let rect = layout.nodeRects[node.id] {
                        ProxyTopologyNodeButton(
                            node: node,
                            isSelected: selectedNodeID == node.id,
                            isHovered: hoveredNodeID == node.id,
                            isDimmed: activeNodeID.map { _ in !activeNodeIDs.contains(node.id) } ?? false
                        ) {
                            withAnimation(.smooth(duration: 0.32, extraBounce: 0.18)) {
                                selectedNodeID = selectedNodeID == node.id ? nil : node.id
                            }
                        }
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .onHover { hovering in
                            withAnimation(.smooth(duration: 0.24, extraBounce: 0.08)) {
                                if hovering {
                                    hoveredNodeID = node.id
                                } else if hoveredNodeID == node.id {
                                    hoveredNodeID = nil
                                }
                            }
                        }
                        .help("\(node.label) · \(node.count) 个连接 · \(proxyFormatBytes(node.bytes))")
                        .accessibilityLabel("\(node.label)，\(node.count) 个连接，\(proxyFormatBytes(node.bytes))")
                        .accessibilityHint("点击后锁定或取消锁定此拓扑节点")
                    }
                }

                if let activeNode, let rect = layout.nodeRects[activeNode.id] {
                    ProxyTopologyTooltip(node: activeNode)
                        .position(
                            x: min(max(rect.midX, 130), max(130, geometry.size.width - 130)),
                            y: max(34, rect.minY - 18)
                        )
                        .allowsHitTesting(false)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .animation(.smooth(duration: 0.24, extraBounce: 0.08), value: activeNodeID)
        }
    }

    private func topologyPath(from: CGRect, to: CGRect) -> Path {
        var path = Path()
        let start = CGPoint(x: from.maxX, y: from.midY)
        let end = CGPoint(x: to.minX, y: to.midY)
        let controlOffset = max((end.x - start.x) * 0.46, 36)
        path.move(to: start)
        path.addCurve(
            to: end,
            control1: CGPoint(x: start.x + controlOffset, y: start.y),
            control2: CGPoint(x: end.x - controlOffset, y: end.y)
        )
        return path
    }
}

private struct ProxyTopologyFlowSegment {
    let id: String
    let from: CGRect
    let to: CGRect
    let color: NSColor
    let lineWidth: CGFloat
    let duration: TimeInterval
    let isActive: Bool
}

private struct ProxyTopologyFlowView: NSViewRepresentable {
    let segments: [ProxyTopologyFlowSegment]

    func makeNSView(context: Context) -> ProxyTopologyFlowLayerView {
        ProxyTopologyFlowLayerView()
    }

    func updateNSView(_ nsView: ProxyTopologyFlowLayerView, context: Context) {
        nsView.update(segments)
    }
}

private final class ProxyTopologyFlowLayerView: NSView {
    private var signature = ""
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.isGeometryFlipped = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(_ segments: [ProxyTopologyFlowSegment]) {
        let nextSignature = segments.map {
            "\($0.id):\(Int($0.from.maxX)):\(Int($0.from.midY)):\(Int($0.to.minX)):\(Int($0.to.midY)):\(String(format: "%.2f", $0.lineWidth)):\(String(format: "%.2f", $0.duration)):\($0.isActive)"
        }.joined(separator: "|")
        guard nextSignature != signature else { return }
        signature = nextSignature
        layer?.sublayers?.forEach { $0.removeFromSuperlayer() }

        for segment in segments where segment.isActive {
            let shape = CAShapeLayer()
            let path = CGMutablePath()
            let start = CGPoint(x: segment.from.maxX, y: segment.from.midY)
            let end = CGPoint(x: segment.to.minX, y: segment.to.midY)
            let controlOffset = max((end.x - start.x) * 0.46, 36)
            path.move(to: start)
            path.addCurve(
                to: end,
                control1: CGPoint(x: start.x + controlOffset, y: start.y),
                control2: CGPoint(x: end.x - controlOffset, y: end.y)
            )
            shape.path = path
            shape.fillColor = nil
            shape.strokeColor = segment.color.withAlphaComponent(0.34).cgColor
            shape.lineWidth = segment.lineWidth
            shape.lineCap = .round
            shape.lineJoin = .round
            shape.lineDashPattern = [10, 22]
            layer?.addSublayer(shape)

            let flow = CABasicAnimation(keyPath: "lineDashPhase")
            flow.fromValue = 0
            flow.toValue = -32
            flow.duration = segment.duration
            flow.repeatCount = .infinity
            flow.timingFunction = CAMediaTimingFunction(name: .linear)
            shape.add(flow, forKey: "traffic-flow")
        }
    }
}

private struct ProxyTopologyNode: Identifiable, Hashable {
    let id: String
    let layer: Int
    let label: String
    let count: Int
    let bytes: Int64
    let color: Color
}

private struct ProxyTopologyLink: Identifiable, Hashable {
    let from: String
    let to: String
    let count: Int
    let bytes: Int64
    let color: Color

    var id: String { "\(from)->\(to)" }
}

private struct ProxyTopologyGraph {
    let layers: [[ProxyTopologyNode]]
    let links: [ProxyTopologyLink]
    private let paths: [[String]]

    var nodes: [ProxyTopologyNode] { layers.flatMap { $0 } }
    var recommendedHeight: CGFloat {
        let maxLayerCount = CGFloat(max(layers.map(\.count).max() ?? 1, 1))
        let base = 72 + maxLayerCount * 38
        return min(max(base, 320), 760)
    }
    var recommendedWidth: CGFloat {
        let maxLabelLength = nodes.map { CGFloat(min($0.label.count, 26)) }.max() ?? 12
        let nodeWidth = max(150, min(230, 96 + maxLabelLength * 5))
        return max(900, nodeWidth * 4 + 280)
    }
    var animationKey: String {
        let nodeKey = nodes.map { "\($0.id):\($0.count):\($0.bytes)" }.joined(separator: "|")
        let linkKey = links.map { "\($0.id):\($0.count):\($0.bytes)" }.joined(separator: "|")
        return nodeKey + "#" + linkKey
    }

    init(connections: [DaemonClient.ConnectionInfo]) {
        let palettes: [Color] = [.indigo, .mint, .yellow, .pink]
        let layerValues = ProxyTopologyGraph.layerValues(for: connections)
        var builtLayers: [[ProxyTopologyNode]] = []

        for layer in 0..<4 {
            let values = layerValues[layer]
            let nodes = values.map { value -> ProxyTopologyNode in
                let matched = connections.filter { connection in
                    ProxyTopologyGraph.value(for: connection, layer: layer, allowed: values) == value
                }
                return ProxyTopologyNode(
                    id: "\(layer)|\(value)",
                    layer: layer,
                    label: value,
                    count: matched.count,
                    bytes: matched.reduce(0) { $0 + $1.upload + $1.download },
                    color: palettes[layer]
                )
            }
            builtLayers.append(nodes.isEmpty ? [
                ProxyTopologyNode(id: "\(layer)|暂无", layer: layer, label: "暂无", count: 0, bytes: 0, color: palettes[layer])
            ] : nodes)
        }

        self.layers = builtLayers

        var linkBuckets: [String: (from: String, to: String, count: Int, bytes: Int64, color: Color)] = [:]
        var builtPaths: [[String]] = []
        for connection in connections {
            let pathNodes = (0..<4).map { layer -> String in
                let name = ProxyTopologyGraph.value(for: connection, layer: layer, allowed: layerValues[layer])
                return "\(layer)|\(name)"
            }
            builtPaths.append(pathNodes)
            for layer in 0..<3 {
                let from = pathNodes[layer]
                let to = pathNodes[layer + 1]
                let key = "\(from)->\(to)"
                let bytes = connection.upload + connection.download
                if var bucket = linkBuckets[key] {
                    bucket.count += 1
                    bucket.bytes += bytes
                    linkBuckets[key] = bucket
                } else {
                    linkBuckets[key] = (from, to, 1, bytes, palettes[layer + 1])
                }
            }
        }

        self.links = linkBuckets.values
            .map { ProxyTopologyLink(from: $0.from, to: $0.to, count: $0.count, bytes: $0.bytes, color: $0.color) }
            .sorted { lhs, rhs in
                if lhs.bytes == rhs.bytes { return lhs.count > rhs.count }
                return lhs.bytes > rhs.bytes
            }
        self.paths = builtPaths
    }

    func layout(in size: CGSize) -> ProxyTopologyLayout {
        ProxyTopologyLayout(graph: self, size: size)
    }

    func isNode(_ nodeID: String, connectedTo activeID: String) -> Bool {
        connectedNodeIDs(to: activeID).contains(nodeID)
    }

    func isLink(_ link: ProxyTopologyLink, connectedTo nodeIDs: Set<String>) -> Bool {
        nodeIDs.contains(link.from) && nodeIDs.contains(link.to)
    }

    func connectedNodeIDs(to activeID: String) -> Set<String> {
        guard nodes.contains(where: { $0.id == activeID }) else { return [] }
        let matchingPaths = paths.filter { $0.contains(activeID) }
        let ids = matchingPaths.flatMap { $0 }
        return ids.isEmpty ? [activeID] : Set(ids)
    }

    func connectedLinkIDs(to activeID: String) -> Set<String> {
        let matchingPaths = paths.filter { $0.contains(activeID) }
        let ids = matchingPaths.flatMap { path in
            zip(path, path.dropFirst()).map { "\($0)->\($1)" }
        }
        return Set(ids)
    }

    private static func layerValues(for connections: [DaemonClient.ConnectionInfo]) -> [[String]] {
        let rawLayers = [
            values(connections, layer: 0),
            values(connections, layer: 1),
            values(connections, layer: 2),
            values(connections, layer: 3)
        ]
        let limits = [7, 9, 8, 6]
        return rawLayers.enumerated().map { index, values in
            let top = topValues(values, limit: limits[index])
            if top.isEmpty { return ["暂无"] }
            return Set(values).subtracting(top).isEmpty ? top : top + ["其他"]
        }
    }

    private static func values(_ connections: [DaemonClient.ConnectionInfo], layer: Int) -> [String] {
        connections.map { value(for: $0, layer: layer, allowed: nil) }
    }

    private static func value(for connection: DaemonClient.ConnectionInfo, layer: Int, allowed: [String]?) -> String {
        let raw: String
        switch layer {
        case 0:
            raw = connection.metadata.sourceIP?.isEmpty == false ? connection.metadata.sourceIP! : "unknown"
        case 1:
            raw = connection.rule?.isEmpty == false ? connection.rule! : "Match"
        case 2:
            raw = connection.chains?.first?.isEmpty == false ? connection.chains!.first! : "策略"
        default:
            raw = connection.chains?.last?.isEmpty == false ? connection.chains!.last! : "DIRECT"
        }
        guard let allowed, !allowed.contains(raw), allowed.contains("其他") else { return raw }
        return "其他"
    }
}

private struct ProxyTopologyLayout {
    let nodeRects: [String: CGRect]
    private let maxLinkBytes: Int64

    init(graph: ProxyTopologyGraph, size: CGSize) {
        let horizontalPadding: CGFloat = 28
        let verticalPadding: CGFloat = 22
        let nodeWidth = max(132, min(210, size.width * 0.14))
        let availableWidth = max(1, size.width - horizontalPadding * 2 - nodeWidth)
        let maxLayerIndex = max(graph.layers.count - 1, 1)
        var rects: [String: CGRect] = [:]

        for (layerIndex, layer) in graph.layers.enumerated() {
            let x = horizontalPadding + availableWidth * CGFloat(layerIndex) / CGFloat(maxLayerIndex)
            let totalWeight = max(layer.reduce(0) { $0 + max($1.count, 1) }, 1)
            let gap = max(6, min(14, (size.height - verticalPadding * 2) / CGFloat(max(layer.count, 1)) * 0.12))
            let availableHeight = max(1, size.height - verticalPadding * 2 - gap * CGFloat(max(layer.count - 1, 0)))
            let baseHeight = min(30, max(18, availableHeight / CGFloat(max(layer.count, 1)) * 0.56))
            let weightedHeightPool = max(0, availableHeight - baseHeight * CGFloat(layer.count))
            var y = verticalPadding
            for node in layer {
                let weight = CGFloat(max(node.count, 1)) / CGFloat(totalWeight)
                let height = min(98, baseHeight + weightedHeightPool * weight)
                rects[node.id] = CGRect(x: x, y: y, width: nodeWidth, height: height)
                y += height + gap
            }
        }

        self.nodeRects = rects
        self.maxLinkBytes = max(graph.links.map(\.bytes).max() ?? 1, 1)
    }

    func width(for link: ProxyTopologyLink) -> CGFloat {
        let normalized = CGFloat(max(Double(link.bytes) / Double(maxLinkBytes), 0.06))
        return max(2, min(26, 2 + normalized.squareRoot() * 24))
    }

    func flowDuration(for link: ProxyTopologyLink) -> TimeInterval {
        let normalized = min(max(Double(link.bytes) / Double(maxLinkBytes), 0), 1)
        return 2.6 - normalized.squareRoot() * 2.15
    }
}

private struct ProxyTopologyNodeButton: View {
    let node: ProxyTopologyNode
    let isSelected: Bool
    let isHovered: Bool
    let isDimmed: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .center, spacing: WgSpace.xs) {
                    Text(shortLabel(node.label, maxLength: 24))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isSelected || isHovered ? node.color : (isDimmed ? Color.secondary : Color.primary))
                        .lineLimit(1)
                    HStack(spacing: WgSpace.xs) {
                        Text("\(node.count)")
                        Text(proxyFormatBytes(node.bytes))
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(isSelected || isHovered ? node.color.opacity(0.72) : Color.secondary.opacity(0.55))
            }
            .multilineTextAlignment(.center)
            .wgPadding(.vertical, .zero)
            .wgPadding(.horizontal, .s)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(isSelected || isHovered ? 1.025 : 1)
        .opacity(isDimmed ? 0.30 : 1)
    }
}

private struct ProxyTopologyTooltip: View {
    let node: ProxyTopologyNode

    var body: some View {
        VStack(alignment: .leading, spacing: WgSpace.xs) {
            Text(node.label)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Text("\(node.count) 个连接 · \(proxyFormatBytes(node.bytes))")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .wgPadding(.horizontal, .m)
        .wgPadding(.vertical, .s)
        .frame(maxWidth: 260, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: WgRadius.s, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: WgRadius.s, style: .continuous)
                .stroke(node.color.opacity(0.32), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.28), radius: 12, x: 0, y: 8)
    }
}

private struct ProxyTopologySelectionBar: View {
    let selected: ProxyTopologyNode?
    let connectionCount: Int
    let totalBytes: Int64
    let clearSelection: () -> Void

    var body: some View {
        HStack(spacing: WgSpace.m) {
            if let selected {
                Circle().fill(selected.color).frame(width: 8, height: 8)
                Text(selected.label)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text("\(selected.count) 个连接")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(proxyFormatBytes(selected.bytes))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: clearSelection) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: WgType.title, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("取消选择拓扑节点")
                .help("取消选择")
            } else {
                Text("\(connectionCount) 个活动连接")
                    .font(.caption.weight(.semibold))
                Text("总流量 \(proxyFormatBytes(totalBytes))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text("悬停高亮，点击节点锁定")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .wgPadding(.horizontal, .m)
        .frame(height: 34)
        .background(Color.black.opacity(0.10), in: RoundedRectangle(cornerRadius: WgRadius.s, style: .continuous))
    }
}

private struct ProxySourceStatsTable: View {
    let stats: [ProxySourceStat]

    var body: some View {
        VStack(spacing: 0) {
            row(["源IP", "下载", "上传", "总流量", "连接数"], header: true)
            ForEach(stats.prefix(10)) { stat in
                row([
                    stat.source,
                    proxyFormatBytes(stat.download),
                    proxyFormatBytes(stat.upload),
                    proxyFormatBytes(stat.total),
                    "\(stat.connections)"
                ])
            }
            if stats.isEmpty {
                Text("暂无活动连接")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: WgRadius.s))
    }

    private func row(_ values: [String], header: Bool = false) -> some View {
        HStack {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                Text(value)
                    .font(header ? .caption.weight(.semibold) : .callout)
                    .foregroundStyle(header ? .secondary : .primary)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: index == 0 ? .leading : .trailing)
            }
        }
        .wgPadding(.horizontal, .m)
        .frame(height: header ? 36 : 42)
        .background(header ? Color.black.opacity(0.14) : Color.white.opacity(0.025))
    }
}

private struct ProxyBarChart: View {
    let title: LocalizedStringKey
    let data: [ProxyBarDatum]
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: WgSpace.s) {
            Text(title).font(.subheadline.weight(.semibold))
            GeometryReader { geometry in
                Canvas { context, size in
                    let rect = CGRect(x: 34, y: 8, width: max(1, size.width - 42), height: max(1, size.height - 42))
                    let maxValue = max(data.map(\.value).max() ?? 1, 1)
                    drawGrid(rect, context: &context)
                    let barWidth = rect.width / CGFloat(max(data.count, 1)) * 0.64
                    for (index, item) in data.enumerated() {
                        let x = rect.minX + rect.width * (CGFloat(index) + 0.5) / CGFloat(max(data.count, 1))
                        let h = rect.height * CGFloat(item.value / maxValue)
                        let bar = CGRect(x: x - barWidth / 2, y: rect.maxY - h, width: barWidth, height: h)
                        context.fill(Path(roundedRect: bar, cornerRadius: WgRadius.m), with: .color(color.opacity(0.82)))
                        context.draw(Text("\(Int(item.value))").font(.caption2).foregroundStyle(.primary), at: CGPoint(x: x, y: max(rect.minY, bar.minY - 9)), anchor: .center)
                    }
                }
                .overlay(alignment: .bottom) {
                    HStack {
                        ForEach(data.prefix(3)) { item in
                            Text(shortLabel(item.label))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .wgPadding(.leading, .xl)
                }
            }
        }
    }

    private func drawGrid(_ rect: CGRect, context: inout GraphicsContext) {
        var grid = Path()
        for i in 0...4 {
            let y = rect.minY + rect.height * CGFloat(i) / 4
            grid.move(to: CGPoint(x: rect.minX, y: y))
            grid.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        context.stroke(grid, with: .color(.white.opacity(0.08)), style: StrokeStyle(lineWidth: 0.6, dash: [4, 4]))
    }
}

private struct ProxyMetric: View {
    let title: LocalizedStringKey
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: WgSpace.m) {
            Image(systemName: icon)
                .font(.system(size: WgType.body, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: WgSpace.zero) {
                Text(value).font(.title3.weight(.semibold)).monospacedDigit()
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .wgPadding(.m)
        .frame(minHeight: 64)
        .wgGlassSurface(cornerRadius: WgTheme.cardRadius, tint: color)
    }
}

private struct ProviderUsageRow: View {
    let provider: DaemonClient.ProxyProviderInfo
	let emojiEnabled: Bool

    var body: some View {
        HStack(spacing: WgSpace.m) {
            VStack(alignment: .leading, spacing: WgSpace.xs) {
                Text(proxyDisplayName(provider.name, emojiEnabled: emojiEnabled)).font(.subheadline.weight(.medium))
                Text("\(provider.proxyCount) 个节点")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            if let info = provider.subscriptionInfo, let total = info.total, total > 0 {
                VStack(alignment: .trailing, spacing: WgSpace.xs) {
                    Text("\(proxyFormatBytes((info.download ?? 0) + (info.upload ?? 0))) / \(proxyFormatBytes(total))")
                        .font(.caption.monospacedDigit())
                    ProgressView(value: min(Double((info.download ?? 0) + (info.upload ?? 0)) / Double(total), 1))
                        .frame(width: 160)
                }
            } else {
                Text(proxyFormatDate(provider.updatedAt))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .wgPadding(.vertical, .m)
    }
}

// MARK: - Proxies

private enum ProxyBrowserMode: String, CaseIterable, Identifiable {
    case groups, providers, nodes
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .groups: return "策略组"
        case .providers: return "订阅"
        case .nodes: return "全部节点"
        }
    }
}

private struct ProxyBrowserPage: View {
    @EnvironmentObject private var client: DaemonClient
	@AppStorage("proxyEmojiEnabled") private var emojiEnabled = true
    @State private var mode: ProxyBrowserMode = .groups
    @State private var search = ""
    @State private var delays: [String: Int64] = [:]
    @State private var testingAll = false

    private var groups: [(String, DaemonClient.ProxyInfo)] {
        client.proxies
            .filter { !($0.value.all ?? []).isEmpty }
            .filter { search.isEmpty || $0.key.localizedCaseInsensitiveContains(search) }
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
    }

    private var nodes: [DaemonClient.ProxyInfo] {
        client.proxies.values
            .filter { ($0.all ?? []).isEmpty && !proxySystemTypes.contains($0.type) }
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        if !client.proxyRunning {
            ProxyUnavailableView()
        } else {
            VStack(spacing: 0) {
                HStack(spacing: WgSpace.m) {
                    Picker("视图", selection: $mode) {
                        ForEach(ProxyBrowserMode.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 280)

                    Spacer()
                    HStack(spacing: WgSpace.s) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                        TextField("搜索", text: $search).textFieldStyle(.plain)
                    }
                    .wgPadding(.horizontal, .s)
                    .frame(width: 230, height: 30)
                    .wgFloatingControlSurface(cornerRadius: WgRadius.s)

                    if mode == .groups {
                        Button {
                            Task { await testVisibleGroups() }
                        } label: {
                            Image(systemName: testingAll ? "hourglass" : "stopwatch")
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.plain)
                        .disabled(testingAll)
                        .help("测试可见策略组")
                    }

                    Button {
                        Task { await refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise").frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .help("刷新")
                }
                .wgPadding(.horizontal, .m)
                .frame(height: 52)
                Divider().opacity(0.12)

                switch mode {
                case .groups: groupsContent
                case .providers: providersContent
                case .nodes: nodesContent
                }
            }
        }
    }

    private var groupsContent: some View {
        ScrollView {
            LazyVStack(spacing: WgSpace.m) {
                ForEach(groups, id: \.0) { name, info in
                    ProxyGroupRow(
                        name: name,
                        info: info,
                        proxies: client.proxies,
                        delays: delays,
						emojiEnabled: emojiEnabled,
                        select: { node in
                            Task { _ = await client.selectProxy(group: name, name: node) }
                        },
                        testNode: { node in
                            Task {
                                if let result = await client.testDelay(name: node), let delay = result.delay {
                                    delays[node] = delay
                                }
                            }
                        },
                        testGroup: {
                            Task {
                                if let result = await client.testGroupDelay(group: name) {
                                    delays.merge(result.delays) { _, new in new }
                                }
                            }
                        }
                    )
                }
            }
            .wgPadding(.m)
        }
        .wgTimelineScroller()
        .overlay {
            if groups.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
    }

    private var providersContent: some View {
        ScrollView {
            LazyVStack(spacing: WgSpace.m) {
                ForEach(client.proxyProviders.values.sorted(by: { $0.name < $1.name })) { provider in
                    ProxyProviderRow(provider: provider, emojiEnabled: emojiEnabled)
                }
            }
            .wgPadding(.m)
        }
        .wgTimelineScroller()
        .overlay {
            if client.proxyProviders.isEmpty {
                ContentUnavailableView("暂无订阅", systemImage: "tray")
            }
        }
    }

    private var nodesContent: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: WgSpace.m)], spacing: WgSpace.m) {
                ForEach(nodes) { node in
                    ProxyNodeCell(node: node, delay: delays[node.name] ?? node.history?.last?.delay, emojiEnabled: emojiEnabled) {
                        Task {
                            if let result = await client.testDelay(name: node.name), let delay = result.delay {
                                delays[node.name] = delay
                            }
                        }
                    }
                }
            }
            .wgPadding(.m)
        }
        .wgTimelineScroller()
        .overlay {
            if nodes.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
    }

    private func refresh() async {
        await client.fetchProxies()
        await client.fetchProxyProviders()
    }

    private func testVisibleGroups() async {
        guard !testingAll else { return }
        testingAll = true
        defer { testingAll = false }
        for (name, _) in groups {
            if let result = await client.testGroupDelay(group: name) {
                delays.merge(result.delays) { _, new in new }
            }
        }
    }
}

private struct ProxyGroupRow: View {
    let name: String
    let info: DaemonClient.ProxyInfo
    let proxies: [String: DaemonClient.ProxyInfo]
    let delays: [String: Int64]
	let emojiEnabled: Bool
    let select: (String) -> Void
    let testNode: (String) -> Void
    let testGroup: () -> Void
    @State private var expanded = false

    private var options: [String] { info.all ?? [] }
    private var visibleOptions: [String] { expanded ? options : Array(options.prefix(8)) }

    var body: some View {
        VStack(alignment: .leading, spacing: WgSpace.m) {
            HStack(spacing: WgSpace.m) {
                VStack(alignment: .leading, spacing: WgSpace.xs) {
                    HStack(spacing: WgSpace.s) {
                        Text(proxyDisplayName(name, emojiEnabled: emojiEnabled)).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(info.type)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Text(proxyStrategyPath(from: name, proxies: proxies).joined(separator: "  ›  "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button(action: testGroup) {
                    Image(systemName: "stopwatch").frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("测试策略组")
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: WgSpace.s)], spacing: WgSpace.s) {
                ForEach(visibleOptions, id: \.self) { node in
                    ProxyChoiceButton(
                        name: node,
                        selected: info.now == node,
                        nestedSelection: proxies[node]?.now,
                        delay: delays[node] ?? proxies[node]?.history?.last?.delay,
						emojiEnabled: emojiEnabled,
                        select: { select(node) },
                        test: { testNode(node) }
                    )
                }
            }

            if options.count > 8 {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
                } label: {
                    Label(expanded ? "收起" : "显示全部 \(options.count) 项", systemImage: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .wgPadding(.m)
        .wgGlassSurface(cornerRadius: WgTheme.cardRadius)
    }
}

private struct ProxyChoiceButton: View {
    let name: String
    let selected: Bool
    let nestedSelection: String?
    let delay: Int64?
	let emojiEnabled: Bool
    let select: () -> Void
    let test: () -> Void

    var body: some View {
        HStack(spacing: WgSpace.s) {
            Button(action: select) {
                HStack(spacing: WgSpace.s) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? WgTheme.accent : Color.secondary.opacity(0.45))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(proxyDisplayName(name, emojiEnabled: emojiEnabled)).font(.caption.weight(selected ? .semibold : .regular)).lineLimit(1)
                        if let nestedSelection, !nestedSelection.isEmpty {
                            Text(proxyDisplayName(nestedSelection, emojiEnabled: emojiEnabled)).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(action: test) {
                Text(proxyDelayText(delay))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(proxyDelayColor(delay))
                    .frame(minWidth: 34, minHeight: 24)
            }
            .buttonStyle(.plain)
            .help("测试延迟")
        }
        .wgPadding(.leading, .s)
        .wgPadding(.trailing, .xs)
        .frame(height: nestedSelection == nil ? 34 : 42)
        .background(selected ? WgTheme.accent.opacity(0.12) : Color.white.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: WgRadius.s))
        .overlay(RoundedRectangle(cornerRadius: WgRadius.s).stroke(selected ? WgTheme.accent.opacity(0.35) : WgTheme.cardBorder))
    }
}

private struct ProxyNodeCell: View {
    let node: DaemonClient.ProxyInfo
    let delay: Int64?
	let emojiEnabled: Bool
    let test: () -> Void

    var body: some View {
        HStack(spacing: WgSpace.m) {
            Circle()
                .fill(node.alive == false ? Color.red : Color.green)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: WgSpace.zero) {
                Text(proxyDisplayName(node.name, emojiEnabled: emojiEnabled)).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(node.type + (node.sourceProvider.map { " · \($0)" } ?? ""))
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer()
            Button(action: test) {
                Text(proxyDelayText(delay))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(proxyDelayColor(delay))
                    .frame(minWidth: 44, minHeight: 28)
            }
            .buttonStyle(.plain)
            .help("测试延迟")
        }
        .wgPadding(.m)
        .frame(height: 58)
        .wgGlassSurface()
    }
}

private struct ProxyProviderRow: View {
    @EnvironmentObject private var client: DaemonClient
    let provider: DaemonClient.ProxyProviderInfo
	let emojiEnabled: Bool
    @State private var busyAction: String?

    var body: some View {
        HStack(spacing: WgSpace.l) {
            Image(systemName: "shippingbox")
                .font(.system(size: WgType.body))
                .foregroundStyle(.blue)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: WgSpace.xs) {
                HStack(spacing: WgSpace.s) {
                    Text(proxyDisplayName(provider.name, emojiEnabled: emojiEnabled)).font(.subheadline.weight(.semibold))
                    Text(provider.vehicleType ?? provider.type ?? "Provider")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                HStack(spacing: WgSpace.m) {
                    Text("\(provider.proxyCount) 个节点").font(.caption).foregroundStyle(.secondary)
                    Text(proxyFormatDate(provider.updatedAt)).font(.caption).foregroundStyle(.tertiary)
                    if let info = provider.subscriptionInfo, let total = info.total, total > 0 {
                        Text("已用 \(proxyFormatBytes((info.download ?? 0) + (info.upload ?? 0))) / \(proxyFormatBytes(total))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Button {
                run("health") { await client.healthCheckProvider(name: provider.name) }
            } label: {
                Image(systemName: busyAction == "health" ? "hourglass" : "stopwatch")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .disabled(busyAction != nil)
            .help("测试订阅节点")
            Button {
                run("update") { await client.updateProvider(name: provider.name) }
            } label: {
                Image(systemName: busyAction == "update" ? "hourglass" : "arrow.down.circle")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .disabled(busyAction != nil)
            .help("更新订阅")
        }
        .wgPadding(.m)
        .wgGlassSurface()
    }

    private func run(_ action: String, operation: @escaping () async -> Bool) {
        busyAction = action
        Task {
            _ = await operation()
            busyAction = nil
        }
    }
}

// MARK: - Connections

private struct ProxyConnectionsPage: View {
    @EnvironmentObject private var client: DaemonClient
    @ObservedObject private var live = ProxyLiveStore.shared
    @State private var search = ""
    @State private var confirmCloseAll = false

    private var filtered: [DaemonClient.ConnectionInfo] {
        let values = client.connections?.connections ?? []
        guard !search.isEmpty else { return values }
        return values.filter { connection in
            [connection.metadata.host, connection.metadata.destinationIP, connection.metadata.process, connection.rule]
                .compactMap { $0 }
                .contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }

    var body: some View {
        if !client.proxyRunning {
            ProxyUnavailableView()
        } else {
            VStack(spacing: 0) {
                HStack(spacing: WgSpace.m) {
                    Text("\(filtered.count) 个连接")
                        .font(.subheadline.weight(.semibold))
                    Text("↓ \(proxyFormatBytes(client.connections?.downloadTotal))")
                        .font(.caption.monospacedDigit()).foregroundStyle(.green)
                    Text("↑ \(proxyFormatBytes(client.connections?.uploadTotal))")
                        .font(.caption.monospacedDigit()).foregroundStyle(.blue)
                    Spacer()
                    HStack(spacing: WgSpace.s) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                        TextField("域名、IP、进程或规则", text: $search).textFieldStyle(.plain)
                    }
                    .wgPadding(.horizontal, .s)
                    .frame(width: 260, height: 30)
                    .wgFloatingControlSurface(cornerRadius: WgRadius.s)
                    Button {
                        confirmCloseAll = true
                    } label: {
                        Image(systemName: "xmark.circle").frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .disabled(filtered.isEmpty)
                    .help("关闭全部连接")
                }
                .wgPadding(.horizontal, .m)
                .frame(height: 52)
                Divider().opacity(0.12)

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { connection in
                            ProxyConnectionRow(connection: connection)
                            Divider().opacity(0.1)
                        }
                    }
                    .wgPadding(.horizontal, .m)
                }
                .wgTimelineScroller()
                .overlay {
                    if filtered.isEmpty {
                        ContentUnavailableView("暂无活动连接", systemImage: "link.badge.plus")
                    }
                }
            }
            .confirmationDialog("关闭全部活动连接？", isPresented: $confirmCloseAll) {
                Button("关闭全部", role: .destructive) {
                    Task { _ = await client.closeAllConnections() }
                }
            }
            .task {
                while !Task.isCancelled {
                    await client.fetchConnections()
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
    }
}

private struct ProxyConnectionRow: View {
    @EnvironmentObject private var client: DaemonClient
    let connection: DaemonClient.ConnectionInfo
    @State private var closing = false

    var body: some View {
        HStack(spacing: WgSpace.m) {
            Image(systemName: connection.metadata.netWork?.lowercased() == "udp" ? "wave.3.right" : "arrow.left.arrow.right")
                .foregroundStyle(connection.metadata.netWork?.lowercased() == "udp" ? Color.orange : Color.blue)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: WgSpace.xs) {
                Text(primaryDestination).font(.subheadline.weight(.medium)).lineLimit(1)
                HStack(spacing: WgSpace.s) {
                    Text(connection.metadata.process ?? "未知进程")
                    Text(connection.metadata.netWork?.uppercased() ?? "")
                    if let rule = connection.rule { Text(rule) }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: WgSpace.zero) {
                Text("↓ \(proxyFormatBytes(connection.download))  ↑ \(proxyFormatBytes(connection.upload))")
                    .font(.caption.monospacedDigit())
                Text((connection.chains ?? []).joined(separator: " › "))
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
            .frame(width: 230, alignment: .trailing)
            Button {
                closing = true
                Task {
                    _ = await client.closeConnection(id: connection.id)
                    closing = false
                }
            } label: {
                Image(systemName: closing ? "hourglass" : "xmark")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(closing)
            .help("关闭连接")
        }
        .frame(minHeight: 56)
    }

    private var primaryDestination: String {
        if let host = connection.metadata.host, !host.isEmpty { return host }
        let ip = connection.metadata.destinationIP ?? "未知目标"
        let port = connection.metadata.destinationPort ?? ""
        return port.isEmpty ? ip : "\(ip):\(port)"
    }
}

// MARK: - Rules

private enum ProxyRulesMode: String, CaseIterable, Identifiable {
    case rules, providers
    var id: String { rawValue }
    var title: LocalizedStringKey { self == .rules ? "生效规则" : "规则集" }
}

private struct ProxyRulesPage: View {
    @EnvironmentObject private var client: DaemonClient
    @State private var mode: ProxyRulesMode = .rules
    @State private var search = ""

    private var filteredRules: [DaemonClient.RuleInfo] {
        guard !search.isEmpty else { return client.rules }
        return client.rules.filter {
            [$0.type, $0.payload, $0.proxy].compactMap { $0 }.contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }

    private var filteredProviders: [DaemonClient.RuleProviderInfo] {
        client.ruleProviders.values
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
            .sorted { $0.name < $1.name }
    }

    var body: some View {
        if !client.proxyRunning {
            ProxyUnavailableView()
        } else {
            VStack(spacing: 0) {
                HStack(spacing: WgSpace.m) {
                    Picker("规则视图", selection: $mode) {
                        ForEach(ProxyRulesMode.allCases) { item in Text(item.title).tag(item) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                    Spacer()
                    HStack(spacing: WgSpace.s) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                        TextField("搜索规则", text: $search).textFieldStyle(.plain)
                    }
                    .wgPadding(.horizontal, .s)
                    .frame(width: 240, height: 30)
                    .wgFloatingControlSurface(cornerRadius: WgRadius.s)
                    Button {
                        Task { await refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise").frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .help("刷新规则")
                }
                .wgPadding(.horizontal, .m)
                .frame(height: 52)
                Divider().opacity(0.12)

                if mode == .rules {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(filteredRules) { rule in
                                ProxyRuleRow(rule: rule)
                                Divider().opacity(0.1)
                            }
                        }
                        .wgPadding(.horizontal, .m)
                    }
                    .wgTimelineScroller()
                } else {
                    ScrollView {
                        LazyVStack(spacing: WgSpace.m) {
                            ForEach(filteredProviders) { provider in
                                ProxyRuleProviderRow(provider: provider)
                            }
                        }
                        .wgPadding(.m)
                    }
                    .wgTimelineScroller()
                }
            }
        }
    }

    private func refresh() async {
        await client.fetchRules()
        await client.fetchRuleProviders()
    }
}

private struct ProxyRuleRow: View {
    let rule: DaemonClient.RuleInfo

    var body: some View {
        HStack(spacing: WgSpace.m) {
            Text(rule.type)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(proxyRuleColor(rule.type))
                .frame(width: 84, alignment: .leading)
            Text(rule.payload?.isEmpty == false ? rule.payload! : "MATCH")
                .font(.caption.monospaced())
                .lineLimit(1)
            Spacer()
            if let size = rule.size, size > 0 {
                Text("\(size)").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            }
            Text(rule.proxy ?? "")
                .font(.caption.weight(.medium))
                .foregroundStyle(WgTheme.accent)
                .frame(width: 150, alignment: .trailing)
                .lineLimit(1)
        }
        .frame(minHeight: 42)
        .opacity(rule.disabled == true ? 0.45 : 1)
    }
}

private struct ProxyRuleProviderRow: View {
    @EnvironmentObject private var client: DaemonClient
    let provider: DaemonClient.RuleProviderInfo
    @State private var updating = false

    var body: some View {
        HStack(spacing: WgSpace.m) {
            Image(systemName: "doc.text.magnifyingglass")
                .foregroundStyle(.orange)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: WgSpace.xs) {
                HStack(spacing: WgSpace.s) {
                    Text(provider.name).font(.subheadline.weight(.semibold))
                    Text(provider.behavior ?? "rule-set").font(.caption2).foregroundStyle(.tertiary)
                }
                Text("\(provider.ruleCount ?? 0) 条 · \(provider.format ?? provider.vehicleType ?? "") · \(proxyFormatDate(provider.updatedAt))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                updating = true
                Task {
                    _ = await client.updateRuleProvider(name: provider.name)
                    updating = false
                }
            } label: {
                Image(systemName: updating ? "hourglass" : "arrow.down.circle")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .disabled(updating)
            .help("更新规则集")
        }
        .wgPadding(.m)
        .wgGlassSurface()
    }
}

// MARK: - Logs

private enum ProxyLogFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case debug = "Debug"
    case info = "Info"
    case warning = "Warning"
    case error = "Error"
    var id: String { rawValue }
    var title: LocalizedStringKey { LocalizedStringKey(rawValue) }
}

private struct ProxyLogsPage: View {
    @EnvironmentObject private var client: DaemonClient
    @State private var filter: ProxyLogFilter = .all
    @State private var autoRefresh = true
    @State private var search = ""

    private var filtered: [DaemonClient.ProxyLogEntry] {
        client.proxyLogs.filter { entry in
            let levelMatches = filter == .all || entry.level.localizedCaseInsensitiveContains(filter.rawValue)
            let searchMatches = search.isEmpty || entry.payload.localizedCaseInsensitiveContains(search)
            return levelMatches && searchMatches
        }
    }

    var body: some View {
        if !client.proxyRunning {
            ProxyUnavailableView()
        } else {
            VStack(spacing: 0) {
                HStack(spacing: WgSpace.m) {
                    Picker("级别", selection: $filter) {
                        ForEach(ProxyLogFilter.allCases) { item in Text(item.title).tag(item) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 360)
                    Spacer()
                    HStack(spacing: WgSpace.s) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                        TextField("筛选日志", text: $search).textFieldStyle(.plain)
                    }
                    .wgPadding(.horizontal, .s)
                    .frame(width: 220, height: 30)
                    .wgFloatingControlSurface(cornerRadius: WgRadius.s)
                    Toggle("自动刷新", isOn: $autoRefresh)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    Button {
                        client.proxyLogs.removeAll()
                    } label: {
                        Image(systemName: "trash").frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .help("清空本地日志视图")
                }
                .wgPadding(.horizontal, .m)
                .frame(height: 52)
                Divider().opacity(0.12)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filtered) { entry in
                            HStack(alignment: .top, spacing: WgSpace.m) {
                                Text(proxyLogTime(entry.time))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 68, alignment: .leading)
                                Text(entry.level.uppercased())
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(proxyLogColor(entry.level))
                                    .frame(width: 58, alignment: .leading)
                                Text(entry.payload)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .wgPadding(.vertical, .s)
                            Divider().opacity(0.07)
                        }
                    }
                    .wgPadding(.horizontal, .m)
                }
                .wgTimelineScroller()
                .overlay {
                    if filtered.isEmpty {
                        ContentUnavailableView("暂无日志", systemImage: "text.alignleft")
                    }
                }
            }
            .task(id: autoRefresh) {
                guard autoRefresh else { return }
                while !Task.isCancelled {
                    await client.fetchProxyLogs()
                    try? await Task.sleep(for: .seconds(1.5))
                }
            }
        }
    }
}

// MARK: - Settings

private struct ProxySettingsPage: View {
    @EnvironmentObject private var client: DaemonClient

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WgSpace.xl) {
				ProxyAppearanceSettings()
                ProxyControllerSettingsEditor()
                ProxyRuntimeSettingsEditor()
                ProxyMaintenanceSettings()
                ProxyDNSQuerySettings()
            }
            .wgPadding(WgTheme.pageGap)
            .frame(maxWidth: 920, alignment: .leading)
        }
        .wgTimelineScroller()
        .task {
            await client.fetchProxySettings()
            if client.proxyRunning { await client.fetchProxyConfig() }
        }
    }
}

private struct ProxyAppearanceSettings: View {
	@AppStorage("proxyEmojiEnabled") private var emojiEnabled = true

	var body: some View {
		ProxySectionBlock(title: "显示", icon: "textformat") {
			ProxySettingRow(label: "Emoji") {
				HStack {
					Toggle("显示 Emoji 标识", isOn: $emojiEnabled)
						.toggleStyle(.switch)
						.controlSize(.small)
					Spacer()
					Text("Apple Color Emoji")
						.font(.caption)
						.foregroundStyle(.tertiary)
				}
			}
		}
	}
}

private struct ProxyControllerSettingsEditor: View {
    @EnvironmentObject private var client: DaemonClient
    @State private var address = ""
    @State private var secret = ""
    @State private var testURL = ""
    @State private var timeout = 5000
    @State private var low = 200
    @State private var medium = 500
    @State private var loaded = false
    @State private var saving = false
    @State private var confirmClearSecret = false
    @State private var startingDaemon = false

    var body: some View {
        ProxySectionBlock(title: "控制器", icon: "network") {
            VStack(spacing: WgSpace.m) {
                controllerStatusRow
                ProxySettingRow(label: "地址") {
                    TextField("http://127.0.0.1:9090", text: $address)
                        .textFieldStyle(.roundedBorder)
                }
                ProxySettingRow(label: "密钥") {
                    HStack(spacing: WgSpace.s) {
                        SecureField(client.proxySettings?.secretSet == true ? "已保存，留空保持不变" : "可选", text: $secret)
                            .textFieldStyle(.roundedBorder)
                        if client.proxySettings?.secretSet == true {
                            Button {
                                confirmClearSecret = true
                            } label: {
                                Image(systemName: "key.slash").frame(width: 28, height: 28)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("清除已保存密钥")
                            .help("清除已保存密钥")
                        }
                    }
                }
                ProxySettingRow(label: "延迟测试 URL") {
                    TextField("https://www.gstatic.com/generate_204", text: $testURL)
                        .textFieldStyle(.roundedBorder)
                }
                ProxySettingRow(label: "超时") {
                    HStack {
                        TextField("5000", value: $timeout, format: .number)
                            .textFieldStyle(.roundedBorder).frame(width: 110)
                        Text("毫秒").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                }
                ProxySettingRow(label: "延迟阈值") {
                    HStack(spacing: WgSpace.s) {
                        TextField("200", value: $low, format: .number)
                            .textFieldStyle(.roundedBorder).frame(width: 90)
                        Text("/ ").foregroundStyle(.tertiary)
                        TextField("500", value: $medium, format: .number)
                            .textFieldStyle(.roundedBorder).frame(width: 90)
                        Text("毫秒").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                }
                HStack {
                    if saveDisabledReason != nil {
                        Text(saveDisabledReason ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        save(secretOverride: secret.isEmpty ? nil : secret)
                    } label: {
                        Label(saving ? "正在测试" : "保存并测试", systemImage: saving ? "hourglass" : "checkmark.circle")
                    }
                    .disabled(saving || address.isEmpty || testURL.isEmpty)
                }
            }
        }
        .task {
            if client.proxySettings == nil { await client.fetchProxySettings() }
            loadValues()
        }
        .onChange(of: client.proxySettings?.address) { _, _ in loadValues() }
        .confirmationDialog("清除控制器密钥？", isPresented: $confirmClearSecret) {
            Button("清除密钥", role: .destructive) { save(secretOverride: "") }
        }
    }

    private var controllerStatusRow: some View {
        HStack(spacing: WgSpace.m) {
            Image(systemName: client.proxyServiceRunning ? (client.proxyRunning ? "checkmark.circle.fill" : "exclamationmark.triangle.fill") : "powerplug")
                .foregroundStyle(client.proxyServiceRunning ? (client.proxyRunning ? .green : .orange) : .orange)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: WgSpace.zero) {
                Text(client.proxyServiceRunning ? (client.proxyRunning ? "控制器已连接" : "后台服务已启动，控制器未连接") : "后台服务未启动")
                    .font(.callout.weight(.medium))
                Text(client.proxyServiceRunning ? "地址或密钥错误时会连接失败。" : "点击启动后台服务，系统会要求管理员授权。不会自动连接 VPN。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !client.proxyServiceRunning {
                Button {
                    startDaemon()
                } label: {
                    Label(startingDaemon || client.isAuthorizingDaemon ? "等待授权" : "启动后台服务", systemImage: "play.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(startingDaemon || client.isAuthorizingDaemon)
                .accessibilityHint("只启动后台服务，不连接 VPN")
            } else {
                Button {
                    Task {
                        await client.fetchProxySettings()
                        await client.fetchProxyStatus()
                    }
                } label: {
                    Label("重新检测", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
        }
        .wgPadding(.m)
        .background(Color.black.opacity(0.10), in: RoundedRectangle(cornerRadius: WgRadius.s, style: .continuous))
    }

    private var saveDisabledReason: String? {
        if saving { return "正在保存并测试..." }
        if address.isEmpty { return "请输入控制器地址" }
        if testURL.isEmpty { return "请输入延迟测试 URL" }
        if !client.proxyServiceRunning { return "请先启动后台服务" }
        return nil
    }

    private func loadValues() {
        guard !loaded, let settings = client.proxySettings else { return }
        address = settings.address
        testURL = settings.latencyTestURL
        timeout = settings.latencyTimeout
        low = settings.latencyLow
        medium = settings.latencyMedium
        loaded = true
    }

    private func save(secretOverride: String?) {
        guard client.proxyServiceRunning else {
            startDaemon()
            return
        }
        saving = true
        Task {
            let connected = await client.saveProxySettings(
                address: address,
                secret: secretOverride,
                latencyTestURL: testURL,
                latencyTimeout: timeout,
                latencyLow: low,
                latencyMedium: medium
            )
            if connected { secret = "" }
            saving = false
        }
    }

    private func startDaemon() {
        startingDaemon = true
        Task {
            _ = await client.startDaemonForProxy()
            startingDaemon = false
        }
    }
}

private struct ProxyRuntimeSettingsEditor: View {
    @EnvironmentObject private var client: DaemonClient
    @State private var mode = "rule"
    @State private var logLevel = "info"
    @State private var allowLAN = false
    @State private var tun = false
    @State private var ipv6 = false
    @State private var bindAddress = "*"
    @State private var port = 0
    @State private var socksPort = 0
    @State private var redirPort = 0
    @State private var tproxyPort = 0
    @State private var mixedPort = 0
    @State private var loaded = false
    @State private var applying = false
    @State private var confirmSensitiveApply = false

    var body: some View {
        ProxySectionBlock(title: "运行配置", icon: "slider.horizontal.3") {
            if let config = client.mihomoConfig {
                VStack(spacing: WgSpace.m) {
                    ProxySettingRow(label: "模式") {
                        Picker("模式", selection: $mode) {
                            ForEach(availableModes(config), id: \.self) { value in
                                Text(value.uppercased()).tag(value)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 420)
                    }
                    ProxySettingRow(label: "日志级别") {
                        Picker("日志级别", selection: $logLevel) {
                            ForEach(["silent", "error", "warning", "info", "debug"], id: \.self) {
                                Text($0.capitalized).tag($0)
                            }
                        }
                        .frame(width: 180)
                    }
                    ProxySettingRow(label: "网络") {
                        HStack(spacing: WgSpace.m) {
                            Toggle("TUN", isOn: $tun)
                            Toggle("允许局域网", isOn: $allowLAN)
                            Toggle("IPv6", isOn: $ipv6)
                            Spacer()
                        }
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }
                    ProxySettingRow(label: "绑定地址") {
                        TextField("*", text: $bindAddress).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                    }
                    ProxySettingRow(label: "端口") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: WgSpace.s)], spacing: WgSpace.s) {
                            ProxyPortField(label: "HTTP", value: $port)
                            ProxyPortField(label: "SOCKS", value: $socksPort)
                            ProxyPortField(label: "Mixed", value: $mixedPort)
                            ProxyPortField(label: "Redir", value: $redirPort)
                            ProxyPortField(label: "TProxy", value: $tproxyPort)
                        }
                    }
                    HStack {
                        Spacer()
                        Button {
                            if tun != (config.tun?.enable ?? false) || allowLAN != (config.allowLan ?? false) {
                                confirmSensitiveApply = true
                            } else {
                                apply()
                            }
                        } label: {
                            Label(applying ? "正在应用" : "应用运行配置", systemImage: applying ? "hourglass" : "checkmark")
                        }
                        .disabled(applying || !client.proxyRunning)
                    }
                }
                .onAppear { load(config) }
            } else {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(client.proxyRunning ? "读取运行配置" : "控制器未连接")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(height: 42)
            }
        }
        .task {
            if client.proxyRunning && client.mihomoConfig == nil { await client.fetchProxyConfig() }
            if let config = client.mihomoConfig { load(config) }
        }
        .confirmationDialog("应用网络配置？", isPresented: $confirmSensitiveApply) {
            Button("应用配置") { apply() }
            Button("取消", role: .cancel) {}
        }
    }

    private func availableModes(_ config: DaemonClient.MihomoConfig) -> [String] {
        let values = config.modes ?? config.modeList ?? []
        return values.isEmpty ? ["rule", "global", "direct"] : values
    }

    private func load(_ config: DaemonClient.MihomoConfig) {
        guard !loaded else { return }
        mode = config.mode ?? "rule"
        logLevel = config.logLevel ?? "info"
        allowLAN = config.allowLan ?? false
        tun = config.tun?.enable ?? false
        ipv6 = config.ipv6 ?? false
        bindAddress = config.bindAddress ?? "*"
        port = config.port ?? 0
        socksPort = config.socksPort ?? 0
        redirPort = config.redirPort ?? 0
        tproxyPort = config.tproxyPort ?? 0
        mixedPort = config.mixedPort ?? 0
        loaded = true
    }

    private func apply() {
        applying = true
        let values: [String: Any] = [
            "mode": mode,
            "log-level": logLevel,
            "allow-lan": allowLAN,
            "bind-address": bindAddress,
            "ipv6": ipv6,
            "tun": ["enable": tun],
            "port": port,
            "socks-port": socksPort,
            "redir-port": redirPort,
            "tproxy-port": tproxyPort,
            "mixed-port": mixedPort
        ]
        Task {
            _ = await client.patchProxyConfig(values, success: "运行配置已应用")
            applying = false
        }
    }
}

private struct ProxyMaintenanceSettings: View {
    @EnvironmentObject private var client: DaemonClient
    @State private var busyAction: String?
    @State private var confirmRestart = false

    var body: some View {
        ProxySectionBlock(title: "维护", icon: "wrench.and.screwdriver") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: WgSpace.s)], spacing: WgSpace.s) {
                ProxyActionButton(title: "清除 DNS 缓存", icon: "network.badge.shield.half.filled", busy: busyAction == "flush-dns") {
                    run("flush-dns", success: "DNS 缓存已清除")
                }
                ProxyActionButton(title: "清除 FakeIP", icon: "eraser", busy: busyAction == "flush-fakeip") {
                    run("flush-fakeip", success: "FakeIP 缓存已清除")
                }
                ProxyActionButton(title: "重载配置", icon: "arrow.triangle.2.circlepath", busy: busyAction == "reload-configs") {
                    run("reload-configs", success: "配置已重载")
                }
                ProxyActionButton(title: "更新 Geo 数据", icon: "globe", busy: busyAction == "update-geo") {
                    run("update-geo", success: "Geo 数据已更新")
                }
                ProxyActionButton(title: "重启核心", icon: "power", roleColor: .red, busy: busyAction == "restart-core") {
                    confirmRestart = true
                }
            }
        }
        .disabled(!client.proxyRunning || busyAction != nil)
        .confirmationDialog("重启 Mihomo 核心？", isPresented: $confirmRestart) {
            Button("重启核心", role: .destructive) {
                run("restart-core", success: "核心重启请求已发送")
            }
        }
    }

    private func run(_ action: String, success: String) {
        busyAction = action
        Task {
            _ = await client.performProxyAction(action, success: success)
            busyAction = nil
            await client.fetchProxyStatus()
        }
    }
}

private struct ProxyActionButton: View {
    let title: LocalizedStringKey
    let icon: String
    var roleColor: Color = .primary
    let busy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: WgSpace.s) {
                Image(systemName: busy ? "hourglass" : icon)
                    .foregroundStyle(roleColor)
                    .frame(width: 20)
                Text(title).font(.subheadline)
                Spacer()
            }
            .wgPadding(.horizontal, .m)
            .frame(height: 38)
            .wgGlassSurface(cornerRadius: WgRadius.s, tint: roleColor.opacity(0.8), interactive: true)
        }
        .buttonStyle(.plain)
    }
}

private struct ProxyDNSQuerySettings: View {
    @EnvironmentObject private var client: DaemonClient
    @State private var name = ""
    @State private var type = "A"
    @State private var querying = false

    var body: some View {
        ProxySectionBlock(title: "DNS 查询", icon: "magnifyingglass") {
            VStack(alignment: .leading, spacing: WgSpace.m) {
                HStack(spacing: WgSpace.s) {
                    TextField("example.com", text: $name)
                        .textFieldStyle(.roundedBorder)
                    Picker("类型", selection: $type) {
                        ForEach(["A", "AAAA", "CNAME", "MX", "NS", "TXT", "SRV", "PTR"], id: \.self) {
                            Text($0).tag($0)
                        }
                    }
                    .frame(width: 110)
                    Button {
                        querying = true
                        Task {
                            _ = await client.queryProxyDNS(name: name, type: type)
                            querying = false
                        }
                    } label: {
                        Label(querying ? "查询中" : "查询", systemImage: querying ? "hourglass" : "magnifyingglass")
                    }
                    .disabled(querying || name.isEmpty || !client.proxyRunning)
                }
                if let answer = client.dnsQueryResult?.answer, !answer.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(answer) { record in
                            HStack {
                                Text(record.name ?? name).font(.caption.monospaced()).lineLimit(1)
                                Spacer()
                                Text(record.data ?? "").font(.caption.monospaced()).textSelection(.enabled)
                                Text(record.ttl.map { "\($0)s" } ?? "")
                                    .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                            }
                            .frame(minHeight: 34)
                            Divider().opacity(0.1)
                        }
                    }
                }
            }
        }
    }
}

private struct ProxySectionBlock<Content: View>: View {
    let title: LocalizedStringKey
    let icon: String
    let content: Content

    init(title: LocalizedStringKey, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WgSpace.m) {
            HStack(spacing: WgSpace.s) {
                Image(systemName: icon).foregroundStyle(WgTheme.accent).frame(width: 20)
                Text(title).font(.headline)
            }
            Divider().opacity(0.14)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ProxySettingRow<Content: View>: View {
    let label: LocalizedStringKey
    let content: Content

    init(label: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .center, spacing: WgSpace.l) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            content
            Spacer(minLength: 0)
        }
        .frame(minHeight: 32)
    }
}

private struct ProxyPortField: View {
    let label: LocalizedStringKey
    @Binding var value: Int

    var body: some View {
        HStack(spacing: WgSpace.s) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 45, alignment: .leading)
            TextField("0", value: $value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 68)
        }
    }
}

// MARK: - Shared formatting

private let proxySystemTypes: Set<String> = ["Direct", "Reject", "PassThrough", "Compatible", "Unknown"]

private func proxyDisplayName(_ rawName: String, emojiEnabled: Bool) -> String {
	let plainName = proxyNameWithoutLeadingEmoji(rawName)
	guard emojiEnabled else { return plainName }
	if plainName != rawName { return rawName }

	let lower = plainName.lowercased()
	let markers: [(String, String)] = [
		("香港", "🇭🇰"), ("hong kong", "🇭🇰"),
		("台湾", "🇹🇼"), ("taiwan", "🇹🇼"),
		("日本", "🇯🇵"), ("japan", "🇯🇵"),
		("新加坡", "🇸🇬"), ("singapore", "🇸🇬"),
		("美国", "🇺🇸"), ("united states", "🇺🇸"),
		("英国", "🇬🇧"), ("united kingdom", "🇬🇧"),
		("德国", "🇩🇪"), ("germany", "🇩🇪"),
		("法国", "🇫🇷"), ("france", "🇫🇷"),
		("加拿大", "🇨🇦"), ("canada", "🇨🇦"),
		("澳大利亚", "🇦🇺"), ("australia", "🇦🇺"),
		("人工智能", "🧠"), ("ai", "🧠"),
		("github", "💻"), ("youtube", "▶️"), ("苹果", "🍎"),
		("google", "🔎"), ("谷歌", "🔎"), ("微软", "🪟"),
		("游戏", "🎮"), ("流媒体", "🎬"), ("测试", "🧪"),
		("加密货币", "🪙"), ("默认", "🌐"), ("default", "🌐"),
		("其他", "🧩")
	]
	for (keyword, marker) in markers where lower.contains(keyword) {
		return "\(marker) \(plainName)"
	}
	return plainName
}

private func proxyNameWithoutLeadingEmoji(_ rawName: String) -> String {
	var name = rawName[...]
	while let first = name.first {
		let text = String(first)
		let isWhitespace = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
		let isEmoji = first.unicodeScalars.contains { $0.properties.isEmojiPresentation || $0.value == 0xFE0F }
		guard isWhitespace || isEmoji else { break }
		name.removeFirst()
	}
	return String(name)
}

private func proxyStrategyPath(
    from group: String,
    proxies: [String: DaemonClient.ProxyInfo]
) -> [String] {
    var result: [String] = []
    var current: String? = group
    var visited: Set<String> = []
    while let name = current, !name.isEmpty, !visited.contains(name), result.count < 12 {
        result.append(name)
        visited.insert(name)
        current = proxies[name]?.now
    }
    return result
}

private func proxyDelayText(_ delay: Int64?) -> String {
    guard let delay, delay > 0 else { return "--" }
    return "\(delay) ms"
}

private func proxyDelayColor(_ delay: Int64?) -> Color {
    guard let delay, delay > 0 else { return Color.secondary.opacity(0.55) }
    if delay < 200 { return .green }
    if delay < 500 { return .orange }
    return .red
}

private func proxyFormatBytes(_ value: Int64?) -> String {
    let bytes = Double(max(value ?? 0, 0))
    if bytes < 1024 { return String(format: "%.0f B", bytes) }
    if bytes < 1024 * 1024 { return String(format: "%.1f KB", bytes / 1024) }
    if bytes < 1024 * 1024 * 1024 { return String(format: "%.1f MB", bytes / 1024 / 1024) }
    return String(format: "%.2f GB", bytes / 1024 / 1024 / 1024)
}

private func proxyFormatBytesPerSecond(_ value: Double) -> String {
    "\(proxyFormatBytes(Int64(max(value, 0))))/s"
}

private func topValues(_ values: [String], limit: Int) -> [String] {
    let filtered = values.filter { !$0.isEmpty }
    let grouped = Dictionary(grouping: filtered, by: { $0 })
    let counted: [(String, Int)] = grouped.map { key, groupedValues in
        (key, groupedValues.count)
    }
    let sorted = counted.sorted { lhs, rhs in
        if lhs.1 == rhs.1 {
            return lhs.0.localizedCaseInsensitiveCompare(rhs.0) == .orderedAscending
        }
        return lhs.1 > rhs.1
    }
    return sorted.prefix(limit).map { $0.0 }
}

private func shortLabel(_ value: String, maxLength: Int = 22) -> String {
    guard value.count > maxLength else { return value }
    return String(value.prefix(maxLength - 1)) + "…"
}

private func proxyFormatDate(_ raw: String?) -> String {
    guard let raw, !raw.isEmpty, !raw.hasPrefix("0001-") else { return "未更新" }
    let formatter = ISO8601DateFormatter()
    guard let date = formatter.date(from: raw) else { return raw }
    return date.formatted(date: .abbreviated, time: .shortened)
}

private func proxyRuleColor(_ type: String) -> Color {
    let upper = type.uppercased()
    if upper.contains("DOMAIN") { return .blue }
    if upper.contains("IP") || upper.contains("GEOIP") { return .green }
    if upper.contains("PROCESS") { return .purple }
    if upper == "MATCH" { return .orange }
    return .secondary
}

private func proxyLogColor(_ level: String) -> Color {
    switch level.lowercased() {
    case "error", "fatal": return .red
    case "warning", "warn": return .orange
    case "debug": return .purple
    default: return .blue
    }
}

private func proxyLogTime(_ raw: String) -> String {
    let formatter = ISO8601DateFormatter()
    guard let date = formatter.date(from: raw) else { return raw }
    return date.formatted(date: .omitted, time: .standard)
}
