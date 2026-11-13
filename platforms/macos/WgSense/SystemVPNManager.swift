import Foundation
import NetworkExtension
import Security

enum SystemVPNError: LocalizedError {
    case emptyConfiguration
    case keychainUnavailable(String)
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyConfiguration:
            return String(localized: "WireGuard 配置为空", bundle: .wgLocalized)
        case .keychainUnavailable(let message):
            return message
        case .saveFailed(let message):
            return message
        }
    }
}

struct SystemVPNManager {
    private let providerBundleIdentifier = "com.wgsense.macos.PacketTunnel"

    func installProfile(name: String, configuration: String) async throws {
        let trimmed = configuration.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SystemVPNError.emptyConfiguration }

        let managers = try await loadManagers()
        let description = displayName(for: name)
        let manager = managers.first { $0.localizedDescription == description } ?? NETunnelProviderManager()
        let previousReference = manager.protocolConfiguration?.passwordReference
        let passwordReference = try makeConfigurationReference(
            profileName: description,
            configuration: trimmed,
            replacing: previousReference
        )
        let tunnelProtocol = NETunnelProviderProtocol()

        tunnelProtocol.providerBundleIdentifier = providerBundleIdentifier
        tunnelProtocol.serverAddress = serverAddress(from: trimmed) ?? "WireGuard"
        tunnelProtocol.passwordReference = passwordReference
        tunnelProtocol.providerConfiguration = ["profileName": name]
        tunnelProtocol.disconnectOnSleep = false

        manager.localizedDescription = description
        manager.protocolConfiguration = tunnelProtocol
        manager.isEnabled = true
        manager.onDemandRules = nil
        manager.isOnDemandEnabled = false

        try await save(manager)
        try await manager.loadFromPreferences()
    }

    func removeProfile(name: String) async throws {
        let description = displayName(for: name)
        for manager in try await loadManagers() where manager.localizedDescription == description {
            if let ref = manager.protocolConfiguration?.passwordReference {
                deleteConfigurationReference(ref)
            }
            try await remove(manager)
        }
    }

    private func displayName(for name: String) -> String {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? "WgSense" : "WgSense-\(clean)"
    }

    private func loadManagers() async throws -> [NETunnelProviderManager] {
        try await withCheckedThrowingContinuation { continuation in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: managers ?? [])
                }
            }
        }
    }

    private func save(_ manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.saveToPreferences { error in
                if let error {
                    continuation.resume(throwing: SystemVPNError.saveFailed(error.localizedDescription))
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func remove(_ manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.removeFromPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func serverAddress(from configuration: String) -> String? {
        for line in configuration.components(separatedBy: .newlines) {
            let parts = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2, parts[0].caseInsensitiveCompare("Endpoint") == .orderedSame else {
                continue
            }
            return parts[1].split(separator: ":").first.map(String.init)
        }
        return nil
    }

    private func makeConfigurationReference(profileName: String, configuration: String, replacing oldRef: Data?) throws -> Data {
        guard let appBundleIdentifier = Bundle.main.bundleIdentifier else {
            throw SystemVPNError.keychainUnavailable(String(localized: "无法读取 App 标识，不能保存系统 VPN 配置", bundle: .wgLocalized))
        }
        guard let extensionPath = Bundle.main.builtInPlugInsURL?
            .appendingPathComponent("WgSensePacketTunnel.appex", isDirectory: true).path else {
            throw SystemVPNError.keychainUnavailable(String(localized: "找不到 Xtrim 系统 VPN 扩展", bundle: .wgLocalized))
        }

        var extensionApp: SecTrustedApplication?
        var mainApp: SecTrustedApplication?
        var status = SecTrustedApplicationCreateFromPath(extensionPath, &extensionApp)
        guard status == errSecSuccess, let extensionApp else {
            throw SystemVPNError.keychainUnavailable(String(localized: "无法授权系统 VPN 扩展读取配置：\(status)", bundle: .wgLocalized))
        }
        status = SecTrustedApplicationCreateFromPath(nil, &mainApp)
        guard status == errSecSuccess, let mainApp else {
            throw SystemVPNError.keychainUnavailable(String(localized: "无法授权 Xtrim 读取配置：\(status)", bundle: .wgLocalized))
        }

        let itemLabel = "WgSense VPN: \(profileName)"
        var access: SecAccess?
        status = SecAccessCreate(itemLabel as CFString, [extensionApp, mainApp] as CFArray, &access)
        guard status == errSecSuccess, let access else {
            throw SystemVPNError.keychainUnavailable(String(localized: "无法创建 VPN 配置钥匙串权限：\(status)", bundle: .wgLocalized))
        }

        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrLabel: itemLabel,
            kSecAttrAccount: profileName + ": " + UUID().uuidString,
            kSecAttrDescription: "wg-quick config",
            kSecAttrService: appBundleIdentifier,
            kSecAttrSynchronizable: false,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrAccess: access,
            kSecValueData: configuration.data(using: .utf8) as Any,
            kSecReturnPersistentRef: true
        ]

        var ref: CFTypeRef?
        status = SecItemAdd(query as CFDictionary, &ref)
        guard status == errSecSuccess, let passwordReference = ref as? Data else {
            throw SystemVPNError.keychainUnavailable(String(localized: "保存 VPN 配置到钥匙串失败：\(status)", bundle: .wgLocalized))
        }
        if let oldRef {
            deleteConfigurationReference(oldRef)
        }
        return passwordReference
    }

    private func deleteConfigurationReference(_ ref: Data) {
        SecItemDelete([kSecValuePersistentRef: ref] as CFDictionary)
    }
}
