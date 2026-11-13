import Foundation

// 在执行端跑 speedlab.sh，逐行回传事件。
//
// 本机：/bin/sh -s；远端：ssh … sh -s（脚本经 stdin 下发，免多层引号）。
// SSH 复用一条主连接（ControlMaster）：探测、起服务端、测速、收尾连着几次调用不再重复握手。
// 取消 = 结束本地进程；远端脚本下一次输出时收到 SIGPIPE 自行收尾，另有看门狗兜底。

struct SLShell {
    var endpoint: SLEndpoint

    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// 执行端脚本正文（随 App 打包）。
    static let script: String? = Bundle.main.url(forResource: "speedlab", withExtension: "sh")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    private static let controlDir: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WgSense/ssh", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir
    }()

    private var sshOptions: [String] {
        [
            "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ControlMaster=auto", "-o", "ControlPath=\(Self.controlDir.path)/%C", "-o", "ControlPersist=60",
            "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=3",
        ]
    }

    private func launchCommand() -> (URL, [String]) {
        if endpoint.kind == .local {
            return (URL(fileURLWithPath: "/bin/sh"), ["-s"])
        }
        return (URL(fileURLWithPath: "/usr/bin/ssh"),
                sshOptions + ["-p", "\(endpoint.sshPort)", "\(endpoint.sshUser)@\(endpoint.host)", "sh -s"])
    }

    private func prelude(_ vars: [String: String]) -> String {
        var lines: [String] = []
        // App 进程的 PATH 很短，本机要能找到 Homebrew 装的 iperf3。
        if endpoint.kind == .local { lines.append("PATH=/opt/homebrew/bin:/usr/local/bin:$PATH") }
        for (key, value) in vars.sorted(by: { $0.key < $1.key }) {
            lines.append("\(key)='\(value.replacingOccurrences(of: "'", with: "'\\''"))'")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// 跑一次脚本，事件逐条流出；任务取消即结束进程。
    /// 预先建好 SSH 主连接（ControlPersist 60 秒）：点开始时省掉约 2 秒握手。失败无所谓，开测时照常重连。
    func warm() {
        guard endpoint.kind == .ssh else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = sshOptions + ["-p", "\(endpoint.sshPort)", "\(endpoint.sshUser)@\(endpoint.host)", "true"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    func stream(_ vars: [String: String]) -> AsyncThrowingStream<SLEvent, Error> {
        AsyncThrowingStream { continuation in
            guard let script = Self.script else {
                continuation.finish(throwing: Failure(message: "App 内缺少测速脚本"))
                return
            }
            let (exe, args) = launchCommand()
            let process = Process()
            process.executableURL = exe
            process.arguments = args
            let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = stderr

            let state = LineState()
            stdout.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                for line in state.feed(data) {
                    if let event = SLEvent.parse(line[...]) {
                        if event.ev == "err" { state.sawError = true }
                        continuation.yield(event)
                    }
                }
            }
            process.terminationHandler = { proc in
                stdout.fileHandleForReading.readabilityHandler = nil
                let rest = stdout.fileHandleForReading.readDataToEndOfFile()
                for line in state.feed(rest) + state.flush() {
                    if let event = SLEvent.parse(line[...]) {
                        if event.ev == "err" { state.sawError = true }
                        continuation.yield(event)
                    }
                }
                let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if proc.terminationStatus != 0, !state.sawError, proc.terminationReason != .uncaughtSignal {
                    continuation.finish(throwing: Failure(message: Self.explain(err, status: proc.terminationStatus)))
                } else {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in
                if process.isRunning { process.terminate() }
            }
            do {
                try process.run()
            } catch {
                continuation.finish(throwing: Failure(message: "无法启动 \(exe.lastPathComponent)：\(error.localizedDescription)"))
                return
            }
            let payload = Data((prelude(vars) + script).utf8)
            DispatchQueue.global(qos: .userInitiated).async {
                stdin.fileHandleForWriting.write(payload)
                try? stdin.fileHandleForWriting.close()
            }
        }
    }

    /// 跑完收齐全部事件；脚本报错（err 事件）抛出。
    func collect(_ vars: [String: String]) async throws -> [SLEvent] {
        var events: [SLEvent] = []
        for try await event in stream(vars) {
            if event.ev == "err" { throw Failure(message: event.msg ?? String(localized: "执行端报错", bundle: .wgLocalized)) }
            events.append(event)
        }
        return events
    }

    /// 把本地文件传到执行端（scp，复用主连接）。
    func upload(_ local: URL, to remote: String) async throws {
        guard endpoint.kind == .ssh else { return }
        let args = ["-O", "-q"] + sshOptions + ["-P", "\(endpoint.sshPort)", local.path, "\(endpoint.sshUser)@\(endpoint.host):\(remote)"]
        try await Self.runTool(URL(fileURLWithPath: "/usr/bin/scp"), args)
    }

    static func runTool(_ exe: URL, _ args: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = exe
            process.arguments = args
            let stderr = Pipe()
            process.standardError = stderr
            process.standardOutput = FileHandle.nullDevice
            process.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    continuation.resume(throwing: Failure(message: explain(err, status: proc.terminationStatus)))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }

    /// 把 ssh 的英文报错翻成能照着处理的一句话。
    static func explain(_ stderr: String, status: Int32) -> String {
        let s = stderr.lowercased()
        if s.contains("permission denied") { return String(localized: "SSH 认证失败：这台 Mac 的公钥没有加到对方的 authorized_keys", bundle: .wgLocalized) }
        if s.contains("connection refused") { return String(localized: "SSH 端口拒绝连接：检查端口号", bundle: .wgLocalized) }
        if s.contains("timed out") || s.contains("no route") { return String(localized: "连不上这台机器（超时/无路由）", bundle: .wgLocalized) }
        if s.contains("could not resolve") { return String(localized: "主机名解析失败", bundle: .wgLocalized) }
        if s.contains("host key verification failed") || s.contains("remote host identification has changed") {
            return String(localized: "对方主机指纹变了：先在终端 ssh-keygen -R 清掉旧记录", bundle: .wgLocalized)
        }
        let line = stderr.split(separator: "\n").last.map(String.init) ?? ""
        return line.isEmpty ? String(localized: "执行端退出码 \(status)", bundle: .wgLocalized) : line
    }
}

/// 把字节流切成行（跨读取边界拼接）。
private final class LineState: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()
    private var _sawError = false
    var sawError: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _sawError }
        set { lock.lock(); _sawError = newValue; lock.unlock() }
    }

    func feed(_ data: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
        var lines: [String] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let chunk = buffer[buffer.startIndex..<nl]
            lines.append(String(decoding: chunk, as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        return lines
    }

    func flush() -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard !buffer.isEmpty else { return [] }
        let line = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll()
        return [line]
    }
}
