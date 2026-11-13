import Foundation

struct TransferAPIClient {
    private let api: DaemonAPIClient

    init(api: DaemonAPIClient = DaemonAPIClient()) {
        self.api = api
    }

    func devices(timeoutSec: Int) async throws -> [TransferDevice] {
        let response = try await api.decode(
            TransferDevicesResponse.self,
            path: "api/transfer/devices",
            queryItems: [URLQueryItem(name: "timeout", value: "\(timeoutSec)")]
        )
        return response.devices
    }

    func scan(timeoutSec: Int, subnet: String?) async throws -> [TransferDevice] {
        var items = [URLQueryItem(name: "timeout", value: "\(timeoutSec)")]
        if let subnet, !subnet.isEmpty {
            items.append(URLQueryItem(name: "subnet", value: subnet))
        }
        let response = try await api.decode(
            TransferDevicesResponse.self,
            path: "api/transfer/scan",
            queryItems: items
        )
        return response.devices
    }

    func addManualDevice(addr: String) async throws -> TransferDevice {
        try await api.decode(
            TransferDevice.self,
            path: "api/transfer/add-device",
            method: "POST",
            body: ["addr": addr]
        )
    }

    func removeManualDevice(deviceID: String) async throws -> Bool {
        let response = try await api.decode(
            OKResponse.self,
            path: "api/transfer/remove-device",
            method: "POST",
            body: ["id": deviceID]
        )
        return response.ok
    }

    func receiveState() async throws -> TransferReceiveState {
        try await api.decode(TransferReceiveState.self, path: "api/transfer/receive")
    }

    func setReceiveEnabled(_ enabled: Bool) async throws -> TransferReceiveState {
        try await api.decode(
            TransferReceiveState.self,
            path: enabled ? "api/transfer/start" : "api/transfer/stop",
            method: "POST"
        )
    }

    func resolveRequest(_ requestID: String, accepted: Bool) async throws {
        _ = try await api.request(
            "api/transfer/decision",
            method: "POST",
            body: ["request_id": requestID, "accepted": accepted]
        )
    }

    func startSend(to deviceID: String, paths: [String]) async throws -> TransferSendTask {
        let response = try await api.decode(
            StartSendResponse.self,
            path: "api/transfer/send",
            method: "POST",
            body: ["id": deviceID, "paths": paths],
            timeout: 15
        )
        guard response.ok else { throw DaemonAPIError.response(String(localized: "创建发送任务失败", bundle: .wgLocalized)) }
        return response.task
    }

    func tasks() async throws -> TransferSendTasksState {
        try await api.decode(TransferSendTasksState.self, path: "api/transfer/tasks")
    }

    func cancel(taskID: String) async throws {
        _ = try await api.request(
            "api/transfer/cancel",
            method: "POST",
            body: ["task_id": taskID]
        )
    }
}

private struct TransferDevicesResponse: Codable {
    let devices: [TransferDevice]
}

private struct StartSendResponse: Codable {
    let ok: Bool
    let task: TransferSendTask
}

private struct OKResponse: Codable {
    let ok: Bool
}
