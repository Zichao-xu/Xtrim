import SwiftUI
import WidgetKit

private struct WgSenseWidgetStatus: Decodable {
    let trustedNetwork: Bool?
    let atHome: Bool
    let state: String
    let paused: Bool
    let service: String

    enum CodingKeys: String, CodingKey {
        case trustedNetwork = "trusted_network"
        case atHome = "at_home"
        case state
        case paused
        case service
    }

    var isTrusted: Bool { trustedNetwork ?? atHome }
}

private struct WgSenseWidgetEntry: TimelineEntry {
    let date: Date
    let status: WgSenseWidgetStatus?
}

private struct WgSenseWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> WgSenseWidgetEntry {
        WgSenseWidgetEntry(
            date: .now,
            status: WgSenseWidgetStatus(
                trustedNetwork: false,
                atHome: false,
                state: "Connected",
                paused: false,
                service: "default"
            )
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (WgSenseWidgetEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
        } else {
            loadStatus(completion: completion)
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WgSenseWidgetEntry>) -> Void) {
        loadStatus { entry in
            completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(15))))
        }
    }

    private func loadStatus(completion: @escaping (WgSenseWidgetEntry) -> Void) {
        guard let url = URL(string: "http://127.0.0.1:8765/api/status") else {
            completion(WgSenseWidgetEntry(date: .now, status: nil))
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        URLSession.shared.dataTask(with: request) { data, _, _ in
            let status = data.flatMap { try? JSONDecoder().decode(WgSenseWidgetStatus.self, from: $0) }
            completion(WgSenseWidgetEntry(date: .now, status: status))
        }.resume()
    }
}

private struct WgSenseWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WgSenseWidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: connected ? "shield.fill" : "shield.slash")
                    .font(.title2)
                    .foregroundStyle(statusColor)
                Text("Xtrim")
                    .font(.headline)
                Spacer(minLength: 0)
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
            }

            Spacer(minLength: 0)

            Text(statusTitle)
                .font(family == .systemSmall ? .title3 : .title2)
                .fontWeight(.semibold)
                .lineLimit(1)

            if family != .systemSmall {
                HStack(spacing: 14) {
                    Label(entry.status?.service ?? "--", systemImage: "doc.text")
                    Label(networkTitle, systemImage: entry.status?.isTrusted == true ? "house.fill" : "wifi")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            } else {
                Text(entry.status?.service ?? "--")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .containerBackground(for: .widget) {
            Color(nsColor: .windowBackgroundColor)
        }
        .widgetURL(URL(string: "wgsense://open"))
    }

    private var connected: Bool { entry.status?.state == "Connected" }

    private var statusColor: Color {
        guard let status = entry.status else { return .orange }
        if status.paused { return .orange }
        return connected ? .green : .secondary
    }

    private var statusTitle: LocalizedStringKey {
        guard let status = entry.status else { return "服务离线" }
        if status.paused { return "已暂停" }
        return connected ? "已连接" : "未连接"
    }

    private var networkTitle: LocalizedStringKey {
        entry.status?.isTrusted == true ? "受信任网络" : "非受信任网络"
    }
}

@main
struct WgSenseWidget: Widget {
    let kind = "WgSenseStatusWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WgSenseWidgetProvider()) { entry in
            WgSenseWidgetView(entry: entry)
        }
        .configurationDisplayName("Xtrim 状态")
        .description("快速查看 VPN、配置与当前网络状态。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
