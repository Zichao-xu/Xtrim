import Foundation

/// 从 op（「面板」当前后端所在的路由器）同步 mihomo 配置给本机内置内核。
///
/// App 以登录用户身份用 SSH 把 /etc/mihomo 下需要的文件打包落到本机缓存，再交给网络服务：
/// 网络服务只收白名单里的文件，把路由器专用的部分改写成 Mac 版，内核校验通过才替换。
/// SSH 私钥等敏感文件不打包。GEO 数据库只在第一次同步时带上（体积大、很少变）。
enum MihomoSync {
    static let remoteDir = "/etc/mihomo"

    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// 打包并导入；返回导入后的内核状态。
    @MainActor
    static func run(client: DaemonClient, includeGeo: Bool) async throws -> MihomoStatus {
        let fetched = try await fetch(includeGeo: includeGeo)
        defer { try? FileManager.default.removeItem(at: fetched.bundle) }
        return try await client.importMihomo(bundle: fetched.bundle.path, origin: fetched.origin)
    }

    /// 只拉取打包到本机缓存，不导入（切换出口时要先趁隧道还连着把配置拿到手）。
    @MainActor
    static func fetch(includeGeo: Bool) async throws -> (bundle: URL, origin: String) {
        guard let backend = MihomoBackendStore.shared.active else {
            throw Failure(message: "「面板」还没有配置路由器后端，不知道从哪里同步")
        }
        let ssh = OpenWrtSSH(backend: backend)
        let files = ["config.yaml", "airport.yaml", "rule_provider"]
            + (includeGeo ? ["GeoIP.dat", "GeoSite.dat", "Country.mmdb", "ASN.mmdb"] : [])
        // 文件不存在不报错（airport.yaml 等可选），tar 只打存在的
        let list = files.map { OpenWrtSSH.quote($0) }.joined(separator: " ")
        let script = """
        cd \(OpenWrtSSH.quote(remoteDir)) || exit 3
        [ -f config.yaml ] || exit 4
        set --
        for f in \(list); do [ -e "$f" ] && set -- "$@" "$f"; done
        tar czf - "$@"
        """
        let data: Data
        do {
            data = try await ssh.run(script, timeout: 120)
        } catch {
            throw Failure(message: "从 \(backend.effectiveSSHHost) 拉取配置失败：\(error.localizedDescription)")
        }
        guard data.count > 64 else { throw Failure(message: "路由器上没有 \(remoteDir)/config.yaml") }
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WgSense", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let bundle = cache.appendingPathComponent("op-mihomo.tgz")
        try data.write(to: bundle, options: .atomic)
        return (bundle, "\(backend.sshUser)@\(backend.effectiveSSHHost):\(remoteDir)")
    }
}
