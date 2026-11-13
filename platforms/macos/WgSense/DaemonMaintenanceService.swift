import Foundation
import SwiftUI

struct DaemonDiagnostics {
    var generatedAt: Date = Date()
    var apiReachable: Bool = false
    var apiSummary: String = String(localized: "daemon API 未连接", bundle: .wgLocalized)
    var launchDaemonPlistExists: Bool = false
    var launchDaemonLoaded: Bool = false
    var launchDaemonKeepAlive: Bool = false
    var receiveMoverPlistExists: Bool = false
    var helperInstalled: Bool = false
    var bundledHelperAvailable: Bool = false
    var persistedConfigExists: Bool = false
    var logFileExists: Bool = false
    var dnsSummary: String = String(localized: "未检测", bundle: .wgLocalized)
    var processLines: [String] = []
    var routeLines: [String] = []
    var utunLines: [String] = []
    var recentLifecycleLines: [String] = []

    var installedSummary: String {
        guard launchDaemonPlistExists else { return String(localized: "未安装", bundle: .wgLocalized) }
        let loaded = launchDaemonLoaded ? String(localized: "已加载", bundle: .wgLocalized) : String(localized: "未加载", bundle: .wgLocalized)
        let keepAlive = launchDaemonKeepAlive ? String(localized: "自动拉起", bundle: .wgLocalized) : String(localized: "不会自动拉起", bundle: .wgLocalized)
        return String(localized: "已安装 / \(loaded) / \(keepAlive)", bundle: .wgLocalized)
    }

    var permissionSummary: String {
        helperInstalled ? String(localized: "系统 helper 已存在", bundle: .wgLocalized) : String(localized: "系统 helper 未安装", bundle: .wgLocalized)
    }

    /// 隧道正常连接时，全量路由和隧道 DNS 本来就该存在，不算残留。
    var tunnelConnected: Bool { apiSummary.hasSuffix("Connected") }

    var hasResidue: Bool {
        !tunnelConnected && (!routeLines.isEmpty || dnsSummary.contains("10.66.66.1"))
    }

    var residualSummary: String {
        if tunnelConnected { return String(localized: "隧道运行中，路由与 DNS 属正常", bundle: .wgLocalized) }
        return hasResidue ? String(localized: "发现疑似残留的路由或 DNS", bundle: .wgLocalized) : String(localized: "无残留", bundle: .wgLocalized)
    }

    var exportText: String {
        var lines: [String] = []
        lines.append("WgSense daemon diagnostics")
        lines.append("Generated: \(generatedAt)")
        lines.append("")
        lines.append("API: \(apiSummary)")
        lines.append("System service: \(installedSummary)")
        lines.append("Persisted config: \(persistedConfigExists ? "present" : "missing")")
        lines.append("Receive mover plist: \(receiveMoverPlistExists ? "present" : "missing")")
        lines.append("Installed helper: \(helperInstalled ? "present" : "missing")")
        lines.append("Bundled helper: \(bundledHelperAvailable ? "present" : "missing")")
        lines.append("Log file: \(logFileExists ? "present" : "missing")")
        lines.append("DNS: \(dnsSummary)")
        lines.append("")
        lines.append("[Processes]")
        lines.append(contentsOf: processLines.isEmpty ? ["none"] : processLines)
        lines.append("")
        lines.append("[Suspicious routes]")
        lines.append(contentsOf: routeLines.isEmpty ? ["none"] : routeLines)
        lines.append("")
        lines.append("[utun]")
        lines.append(contentsOf: utunLines.isEmpty ? ["none"] : utunLines)
        lines.append("")
        lines.append("[Recent daemon lifecycle]")
        lines.append(contentsOf: recentLifecycleLines.isEmpty ? ["none"] : recentLifecycleLines)
        return lines.joined(separator: "\n")
    }
}

enum MaintenanceAction: String, Identifiable {
    case installSystemHelper
    case uninstallSystemHelper
    case restartSystemHelper
    case cleanupNetworkState

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .installSystemHelper: return "安装系统 helper"
        case .uninstallSystemHelper: return "卸载系统 helper"
        case .restartSystemHelper: return "重启系统服务"
        case .cleanupNetworkState: return "清理残留网络状态"
        }
    }

    var message: LocalizedStringKey {
        switch self {
        case .installSystemHelper:
            return "会安装 Xtrim daemon、接收文件搬运 helper 和 launchd 配置，需要管理员授权。"
        case .uninstallSystemHelper:
            return "会停止并删除 Xtrim 系统服务与 helper，可保留用户配置和传输数据。"
        case .restartSystemHelper:
            return "会重启 com.wgsense.daemon。若当前正在连接 WireGuard，连接会短暂中断。"
        case .cleanupNetworkState:
            return "会请求在线的 Xtrim 服务断开并清理它管理的隧道、DNS 和路由。服务不在线时只报告诊断，不改动系统网络设置。"
        }
    }

    var role: String {
        switch self {
        case .installSystemHelper, .restartSystemHelper: return "default"
        case .uninstallSystemHelper, .cleanupNetworkState: return "destructive"
        }
    }
}

struct DaemonMaintenanceService {
    private let controlAPI = DaemonControlAPIClient()

    func diagnostics() async -> DaemonDiagnostics {
        async let api = apiSummary()
        async let plist = fileExists("/Library/LaunchDaemons/com.wgsense.daemon.plist")
        async let keepAlive = commandHasOutput("/usr/bin/plutil -extract KeepAlive raw -o - /Library/LaunchDaemons/com.wgsense.daemon.plist 2>/dev/null | /usr/bin/grep -qx true && echo yes")
        async let moverPlist = fileExists("\(NSHomeDirectory())/Library/LaunchAgents/com.wgsense.receive-mover.plist")
        async let helper = fileExists("/usr/local/libexec/wgsense-daemon")
        async let bundled = bundledDaemonPath() != nil
        async let persistedConfig = fileExists("\(NSHomeDirectory())/.local/share/wgsense/settings.json")
        async let logFile = fileExists("/var/log/wgsense-daemon.log")
        async let loaded = commandHasOutput("launchctl print system/com.wgsense.daemon 2>/dev/null | head -1")
        async let dns = ShellCommand.sh("networksetup -getdnsservers Wi-Fi 2>/dev/null || true")
        async let processes = ShellCommand.sh("ps ax -o pid,command | /usr/bin/grep -E 'wgsense|wireguard-go' | /usr/bin/grep -v grep || true")
        async let routes = ShellCommand.sh("netstat -rn -f inet | /usr/bin/grep -E '^(0/1|128\\.0/1|10\\.66|198\\.18|198\\.19)|^default.*utun' || true")
        async let utuns = ShellCommand.sh("ifconfig | /usr/bin/grep -E '^(utun[0-9]+:|\\tinet )' || true")
        async let lifecycle = ShellCommand.sh("tail -n 220 /var/log/wgsense-daemon.log 2>/dev/null | /usr/bin/grep -E '收到退出信号|收到信号|WgSense daemon 启动|已加载运行配置|未指定启动暂停状态|配置已更新|自动连接失败|探测失败|命中受信任网络' || true")

        let apiResult = await api
        var result = DaemonDiagnostics()
        result.apiReachable = apiResult.reachable
        result.apiSummary = apiResult.summary
        result.launchDaemonPlistExists = await plist
        result.launchDaemonLoaded = await loaded
        result.launchDaemonKeepAlive = await keepAlive
        result.receiveMoverPlistExists = await moverPlist
        result.helperInstalled = await helper
        result.bundledHelperAvailable = await bundled
        result.persistedConfigExists = await persistedConfig
        result.logFileExists = await logFile
        result.dnsSummary = cleanLines((await dns).output).joined(separator: " / ")
        result.processLines = cleanLines((await processes).output)
        result.routeLines = cleanLines((await routes).output)
        result.utunLines = cleanLines((await utuns).output)
        result.recentLifecycleLines = cleanLines((await lifecycle).output)
        return result
    }

    func perform(_ action: MaintenanceAction) async -> ShellCommandResult {
        switch action {
        case .installSystemHelper:
            return await installSystemHelper()
        case .uninstallSystemHelper:
            return await runPackagedScript("wgsense-uninstall-services.sh", userArgument: true, timeout: 60)
        case .restartSystemHelper:
            let outcome = await DaemonServiceCoordinator.shared.restart()
            return ShellCommandResult(status: outcome.ok ? 0 : -1, output: outcome.message)
        case .cleanupNetworkState:
            return await cleanupNetworkState()
        }
    }

    func exportDiagnostics(_ diagnostics: DaemonDiagnostics, to url: URL) throws {
        try diagnostics.exportText.write(to: url, atomically: true, encoding: .utf8)
    }

    func exportDaemonLog(to url: URL) async -> ShellCommandResult {
        let destination = ShellCommand.quote(url.path)
        let command = """
        if [[ -r /var/log/wgsense-daemon.log ]]; then
          /bin/cp /var/log/wgsense-daemon.log \(destination)
        else
          echo 'WgSense daemon log is missing or not readable.' > \(destination)
        fi
        """
        return await ShellCommand.sh(command, timeout: 10)
    }

    private func installSystemHelper() async -> ShellCommandResult {
        let outcome = await DaemonServiceCoordinator.shared.ensure(.maintenance)
        return ShellCommandResult(status: outcome.ok ? 0 : -1, output: outcome.message)
    }

    private func cleanupNetworkState() async -> ShellCommandResult {
        let verified = await DaemonServiceCoordinator.shared.ensure(.stopOnly)
        guard verified.ok else {
            return ShellCommandResult(
                status: -1,
                output: String(localized: "Xtrim 服务不在线，未触碰系统 DNS 或路由；请导出诊断后单独处理：\(verified.message)", bundle: .wgLocalized)
            )
        }
        do {
            try await controlAPI.command("disconnect", timeout: 30)
            return ShellCommandResult(status: 0, output: String(localized: "已请求 Xtrim 清理它自身管理的隧道、DNS 和路由", bundle: .wgLocalized))
        } catch {
            return ShellCommandResult(status: -1, output: String(localized: "Xtrim 清理失败；未执行通用 DNS/路由删除：\(error.localizedDescription)", bundle: .wgLocalized))
        }
    }

    private func runPackagedScript(_ name: String, userArgument: Bool = false, timeout: TimeInterval) async -> ShellCommandResult {
        guard let script = packagedScriptPath(name) else {
            return ShellCommandResult(status: -1, output: String(localized: "App bundle 内缺少 \(name)", bundle: .wgLocalized))
        }
        var command = ShellCommand.quote(script)
        if userArgument {
            let username = NSUserName()
            guard !username.isEmpty && username != "root" else {
                return ShellCommandResult(status: -1, output: String(localized: "无法确定登录用户", bundle: .wgLocalized))
            }
            command += " \(ShellCommand.quote(username))"
        }
        return await ShellCommand.administrator(command, timeout: timeout)
    }

    private func apiSummary() async -> (reachable: Bool, summary: String) {
        do {
            let status = try await controlAPI.status(timeout: 1.5)
            let owner = status.app_owned == true ? String(localized: "App 临时服务", bundle: .wgLocalized) : String(localized: "系统/外部服务", bundle: .wgLocalized)
            let mode = status.passive == true ? String(localized: "被动", bundle: .wgLocalized) : String(localized: "网络管理", bundle: .wgLocalized)
            return (true, "\(owner) / \(mode) / \(status.state)")
        } catch {
            return (false, String(localized: "daemon API 未连接", bundle: .wgLocalized))
        }
    }

    private func fileExists(_ path: String) async -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    private func commandHasOutput(_ command: String) async -> Bool {
        !cleanLines((await ShellCommand.sh(command, timeout: 5)).output).isEmpty
    }

    private func bundledDaemonPath() -> String? {
        Bundle.main.path(forResource: "wgsense-daemon", ofType: nil, inDirectory: "libexec")
    }

    private func packagedScriptPath(_ name: String) -> String? {
        Bundle.main.path(forResource: name, ofType: nil, inDirectory: "packaging")
    }

    private func cleanLines(_ output: String) -> [String] {
        output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
