import Foundation

struct DaemonControlAPIClient {
    private let api: DaemonAPIClient

    init(api: DaemonAPIClient = DaemonAPIClient()) {
        self.api = api
    }

    func status(timeout: TimeInterval = 20) async throws -> DaemonStatus {
        try await api.decode(DaemonStatus.self, path: "api/status", timeout: timeout)
    }

    func profiles() async throws -> [String] {
        try await api.decode([String].self, path: "api/profiles")
    }

    func logs(limit: Int) async throws -> DaemonLogsResponse {
        try await api.decode(
            DaemonLogsResponse.self,
            path: "api/logs",
            queryItems: [URLQueryItem(name: "n", value: "\(limit)")]
        )
    }

    func firewall() async throws -> FirewallResponse {
        try await api.decode(FirewallResponse.self, path: "api/firewall")
    }

    func updateFirewall(_ settings: FirewallSettings) async throws -> FirewallResponse {
        var body: [String: Any] = [
            "auto_block": settings.auto_block,
            "force_domestic": settings.force_domestic,
            "allow_bypass": settings.allow_bypass ?? false,
            "block_probes": settings.block_probes ?? false
        ]
        if let hosts = settings.allow_hosts { body["allow_hosts"] = hosts }
        let data = try await api.request("api/firewall", method: "POST", body: body)
        return try JSONDecoder().decode(FirewallResponse.self, from: data)
    }

    func mihomo() async throws -> MihomoStatus {
        try await api.decode(MihomoStatus.self, path: "api/mihomo")
    }

    func mihomo(action: String) async throws -> MihomoStatus {
        try await api.decode(MihomoStatus.self, path: "api/mihomo", method: "POST", body: ["action": action], timeout: 30)
    }

    @discardableResult
    func setExit(_ exit: String) async throws -> Data {
        try await api.request("api/exit", method: "POST", body: ["exit": exit], timeout: 60)
    }

    func tunnelIPv6() async throws -> TunnelIPv6Settings {
        try await api.decode(TunnelIPv6Settings.self, path: "api/tunnel/ipv6")
    }

    func updateTunnelIPv6(_ settings: TunnelIPv6Settings) async throws -> TunnelIPv6Settings {
        let body: [String: Any] = [
            "mode": settings.mode,
            "prefix": settings.prefix,
            "probe_targets": settings.probe_targets
        ]
        let data = try await api.request("api/tunnel/ipv6", method: "POST", body: body)
        return try JSONDecoder().decode(TunnelIPv6Settings.self, from: data)
    }

    func traffic() async throws -> TrafficStats {
        try await api.decode(TrafficStats.self, path: "api/traffic")
    }

    func command(_ endpoint: String, timeout: TimeInterval = 5) async throws {
        _ = try await api.request("api/\(endpoint)", method: "POST", timeout: timeout)
    }

    func shutdownAppOwnedDaemon() async throws {
        _ = try await api.request("api/shutdown", method: "POST", timeout: 2)
    }

    func importProfile(name: String, content: String) async throws {
        _ = try await api.request(
            "api/profile/import",
            method: "POST",
            body: ["name": name, "content": content]
        )
    }

    func exportProfile(name: String) async throws -> ProfileExportResponse {
        try await api.decode(
            ProfileExportResponse.self,
            path: "api/profile/export",
            queryItems: [URLQueryItem(name: "name", value: name)]
        )
    }

    func saveProfile(_ profile: WGProfile) async throws {
        let body: [String: Any] = [
            "Name": profile.name,
            "Interface": [
                "PrivateKey": profile.privateKey,
                "Address": profile.address,
                "DNS": profile.dns,
                "MTU": profile.mtu
            ],
            "Peers": [[
                "PublicKey": profile.publicKey,
                "PresharedKey": profile.presharedKey,
                "Endpoint": profile.endpoint,
                "AllowedIPs": profile.allowedIPs
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) },
                "PersistentKeepaliveInterval": profile.keepalive
            ]]
        ]
        _ = try await api.request("api/profile/save", method: "POST", body: body)
    }

    func deleteProfile(name: String) async throws {
        _ = try await api.request(
            "api/profile/delete",
            method: "POST",
            queryItems: [URLQueryItem(name: "name", value: name)]
        )
    }

    func syncConfig(
        trustedNetworkPrefixes: [String],
        autoConnectUntrusted: Bool,
        desiredVPNEnabled: Bool,
        desiredGuardEnabled: Bool,
        intervalSeconds: Int,
        autoUpGraceSeconds: Int,
        healthCheckTarget: String
    ) async throws {
        let body: [String: Any] = [
            "trusted_network_prefixes": trustedNetworkPrefixes,
            "home_network_prefixes": trustedNetworkPrefixes,
            "desired_vpn_enabled": desiredVPNEnabled,
            "desired_guard_enabled": desiredGuardEnabled,
            "auto_connect_untrusted": autoConnectUntrusted,
            "auto_connect_away": autoConnectUntrusted,
            "interval_seconds": intervalSeconds,
            "auto_up_grace_seconds": autoUpGraceSeconds,
            "health_check_target": healthCheckTarget,
            "health_check_interval_seconds": 30
        ]
        _ = try await api.request("api/config", method: "POST", body: body)
    }
}
