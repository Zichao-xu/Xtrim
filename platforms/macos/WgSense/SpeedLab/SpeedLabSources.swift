import Foundation

// 公网测速源：数据，不是代码。
//
//   源列表 = 远程 JSON（默认放在 secret gist，地址在「测速源」里填）+ 用户手动添加的。
//   拉到就缓存到本地；拉不到用上次的缓存。代码里不放任何源地址——节点早晚会失效，失效了改远程文件即可，不用发版。
//   每次测速后按试跑结果记健康分：连续失败「测法 · 坏源退役」次的源自动跳过；全部都被跳过时再全部重试一遍。

struct SLCatalogFile: Codable, Equatable {
    struct Entry: Codable, Equatable, Hashable {
        var url: String
        var note: String?
    }
    var version: Int?
    var updated: String?
    var download: [Entry]
    var upload: [Entry]
}

struct SLSourceHealth: Codable, Equatable {
    var fails = 0
    var lastOK: Date?
    var lastMbps: Double?
}

@MainActor
final class SLSourceCatalog: ObservableObject {
    static let shared = SLSourceCatalog()

    @Published var url: String { didSet { UserDefaults.standard.set(url, forKey: Keys.url) } }
    @Published private(set) var file: SLCatalogFile?
    @Published private(set) var fetchedAt: Date?
    @Published private(set) var fetchError: String?
    @Published private(set) var fetching = false
    @Published private(set) var health: [String: SLSourceHealth] = [:] { didSet { saveHealth() } }

    private enum Keys {
        static let url = "speedLab.catalogURL"
        static let health = "speedLab.sourceHealth"
        static let fetchedAt = "speedLab.catalogFetchedAt"
    }

    private init() {
        url = UserDefaults.standard.string(forKey: Keys.url) ?? ""
        file = Self.loadCache()
        fetchedAt = UserDefaults.standard.object(forKey: Keys.fetchedAt) as? Date
        if let data = UserDefaults.standard.data(forKey: Keys.health),
           let saved = try? JSONDecoder().decode([String: SLSourceHealth].self, from: data) {
            health = saved
        }
    }

    // MARK: 拉取

    /// 一小时内拉过就不再拉（除非强制）。
    func refreshIfStale() {
        guard !url.isEmpty, fetchedAt.map({ Date().timeIntervalSince($0) > 3600 }) ?? true else { return }
        Task { await refresh() }
    }

    func refresh() async {
        guard let target = URL(string: url.trimmingCharacters(in: .whitespaces)), target.scheme?.hasPrefix("http") == true else {
            fetchError = url.isEmpty ? nil : String(localized: "地址无效", bundle: .wgLocalized)
            return
        }
        fetching = true
        defer { fetching = false }
        var request = URLRequest(url: target, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("WgSense", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                fetchError = String(localized: "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)，继续用缓存", bundle: .wgLocalized)
                return
            }
            let parsed = try JSONDecoder().decode(SLCatalogFile.self, from: data)
            file = parsed
            fetchedAt = Date()
            fetchError = nil
            UserDefaults.standard.set(fetchedAt, forKey: Keys.fetchedAt)
            try? data.write(to: Self.cacheURL, options: .atomic)
        } catch is DecodingError {
            fetchError = String(localized: "格式不对（需要 download / upload 两个数组），继续用缓存", bundle: .wgLocalized)
        } catch {
            fetchError = String(localized: "拉取失败：\(error.localizedDescription)，继续用缓存", bundle: .wgLocalized)
        }
    }

    // MARK: 选源

    /// 某方向本次要试跑的源：远程 + 手动，去重；跳过连续失败的，全被跳过时全部重试。
    func candidates(_ dir: String, manual: [String], retireAfter: Int) -> [String] {
        let remote = (dir == "dl" ? file?.download : file?.upload)?.map(\.url) ?? []
        var all: [String] = []
        for u in remote + manual where !all.contains(u) && !u.contains(" ") { all.append(u) }
        let alive = all.filter { (health[$0]?.fails ?? 0) < retireAfter }
        return alive.isEmpty ? all : alive
    }

    func isRetired(_ url: String, after retireAfter: Int) -> Bool { (health[url]?.fails ?? 0) >= retireAfter }

    /// 测速结束：按试跑结果更新健康分。
    func record(_ results: [SLSourceResult]) {
        var h = health
        for r in results {
            var e = h[r.url] ?? SLSourceHealth()
            if r.mbps > 0 { e.fails = 0; e.lastOK = r.at; e.lastMbps = r.mbps } else { e.fails += 1 }
            h[r.url] = e
        }
        health = h
    }

    func resetHealth(_ url: String) { health[url] = nil }

    // MARK: 持久化

    private static var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WgSense", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("speedlab-sources.json")
    }

    private static func loadCache() -> SLCatalogFile? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode(SLCatalogFile.self, from: data)
    }

    private func saveHealth() {
        if let data = try? JSONEncoder().encode(health) { UserDefaults.standard.set(data, forKey: Keys.health) }
    }
}
