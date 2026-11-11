import Foundation

struct DaemonStatus: Codable, Equatable {
    var trusted_network: Bool?
    var at_home: Bool
    var state: String
    var paused: Bool
    var desired_vpn_enabled: Bool?
    var desired_guard_enabled: Bool?
    var service: String
    var passive: Bool?
    var auto_connect_untrusted: Bool?
    var auto_connect_away: Bool?
    var app_owned: Bool?
    var health_failures: Int?
    var auto_failures: Int?
    var next_auto_attempt: String?
    var last_health_check: String?
    var last_auto_up: String?
    var tunnel_interface: String?
    var last_handshake: String?
    var last_handshake_age_seconds: Int?
    var peer_tx_bytes: UInt64?
    var peer_rx_bytes: UInt64?
    /// 发包地址失效后自愈重绑（BindUpdate）的累计次数。
    var bind_rebinds: Int?
    var network_interfaces: [NetworkInterface]?
    var firewall: FirewallStatus?
    /// 隧道接管了什么、哪些不走隧道以及原因。
    var coverage: TunnelCoverage?
    /// 当前出口：wireguard / mihomo（tailscale 预留）。旧版网络服务没有这个字段 = 只有 WireGuard。
    var exit: String?

    var isTrustedNetwork: Bool { trusted_network ?? at_home }

    var primaryIPv4: String? {
        network_interfaces?.lazy.compactMap { $0.ipv4s.first }.first
    }
}

/// 出站拦截当前实际生效情况（daemon 侧 pf + hosts）。
struct FirewallStatus: Codable, Equatable {
    var active: Bool
    var forced: Bool
    var reason: String
    var interfaces: [String]?
    /// 隧道锁定生效中：全局隧道连着，物理网卡只放行局域网与 WG 服务器。
    var locked: Bool?
    /// 锁定的出口：tunnel（WireGuard）/ proxy（内置 mihomo）。
    var lock_kind: String?
    /// 本套规则生效以来被拒绝的出站包数。
    var blocked_packets: UInt64?
    /// 放行项当前解析到的地址，普通拦截模式下才有。
    var allowed_hosts: [FirewallAllowedHost]?
    var error: String?
    var updated_at: String?
}

/// 一个放行项及其解析结果。
struct FirewallAllowedHost: Codable, Equatable {
    var host: String
    var ips: [String]?
}

/// 出站拦截设置，单独存于 daemon 的 firewall.json，不随 /api/config 同步。
struct FirewallSettings: Codable, Equatable {
    /// 拦截物理网卡上的境外直连（字段名沿用 v1.0.4）。
    var auto_block: Bool
    var force_domestic: Bool
    /// 关闭隧道锁定（默认 nil/false = 锁定）。
    var allow_bypass: Bool?
    /// 连诊断探测（ICMP 回显，traceroute / ping）也拦（默认 nil/false = 普通拦截模式下放行探测）。
    var block_probes: Bool?
    /// 拦截境外直连时额外放行的域名或 IP。nil = 运行中的服务还不支持。
    var allow_hosts: [String]?
}

/// 隧道覆盖范围（daemon /api/status 的 coverage）。
struct TunnelCoverage: Codable, Equatable {
    var full_tunnel: Bool
    var ipv6: TunnelIPv6Status
    var bypass: [TunnelBypassPath]?
    var dns: [String]?
    var dns_service: String?
}

struct TunnelIPv6Status: Codable, Equatable {
    var mode: String
    var state: String
    var address: String?
    var derived: Bool?
    var last_probe: String?
    var last_probe_ok: Bool?
    var next_probe: String?
    var targets: [String]?
    var error: String?
}

struct TunnelBypassPath: Codable, Equatable, Hashable {
    var destination: String
    var via: String
    var reason: String
}

/// 全局隧道的公网 IPv6 设置（daemon /api/tunnel/ipv6）。
struct TunnelIPv6Settings: Codable, Equatable {
    var mode: String
    var prefix: String
    var probe_targets: [String]
}

/// 内置代理内核（daemon /api/mihomo）。
struct MihomoStatus: Codable, Equatable {
    /// 这份网络服务带了内核。
    var bundled: Bool
    var version: String?
    /// 用户希望它运行（跨服务重启保持）。
    var desired: Bool
    var running: Bool
    var pid: Int?
    var started_at: String?
    var controller: String
    var mixed_port: Int
    var config_path: String
    var user: String?
    /// 上次意外退出的原因。
    var last_exit: String?
    var error: String?
    /// 配置来源（从 op 同步时为 root@host:/etc/mihomo）；nil = 默认配置，不能作为出口。
    var source: String?
    var synced_at: String?
    /// 同步时剔除的、只能在路由器上用的节点。
    var dropped: [String]?
    /// 正在被接管 DNS 的网络服务（如 Wi-Fi）。
    var dns_service: String?
}

struct FirewallResponse: Codable, Equatable {
    var settings: FirewallSettings
    var status: FirewallStatus
}

struct NetworkInterface: Codable, Equatable {
    var name: String
    var hardware_port: String?
    var ipv4s: [String]
    var active: Bool
    var priority: Int?
    var speed_mbps: Int?
}

struct TrafficStats: Codable, Equatable {
    var tx_speed: Double
    var rx_speed: Double
    var tx_bytes: UInt64
    var rx_bytes: UInt64
}

struct DaemonLogsResponse: Codable {
    let lines: [String]
    let count: Int
}

struct ProfileExportResponse: Codable {
    let name: String
    let content: String
}

struct WGProfile: Codable {
    var name: String = ""
    var privateKey: String = ""
    var address: String = ""
    var dns: String = ""
    var mtu: Int = 1420
    var publicKey: String = ""
    var presharedKey: String = ""
    var endpoint: String = ""
    var allowedIPs: String = "0.0.0.0/0, ::/0"
    var keepalive: Int = 25

    var wireGuardConfig: String {
        """
        [Interface]
        PrivateKey = \(privateKey)
        Address = \(address)
        DNS = \(dns)
        MTU = \(mtu)

        [Peer]
        PublicKey = \(publicKey)
        PresharedKey = \(presharedKey)
        Endpoint = \(endpoint)
        AllowedIPs = \(allowedIPs)
        PersistentKeepalive = \(keepalive)
        """
    }
}
