import Foundation
import BotBusConnectorKit

/// ACP 的 client 一侧：BotBus 对一个 agent（子进程或反向连接）发的全部调用。只负责拼参数和解结果，
/// 会话状态归 `AcpConnector`。
public struct AcpClient: Sendable {
    public static let initializeTimeout: TimeInterval = 10
    public static let sessionTimeout: TimeInterval = 60

    public let peer: JSONRPCPeer

    public init(peer: JSONRPCPeer) {
        self.peer = peer
    }

    /// 握手。BotBus 声明**不提供** fs 与 terminal：工具由 agent 自己执行，BotBus 只看和批。
    public func initialize(clientVersion: String, timeout: TimeInterval = AcpClient.initializeTimeout) async throws -> AcpCapabilities {
        let result = try await peer.request("initialize", params: [
            "protocolVersion": .int(AcpProtocol.version),
            "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false],
            "clientInfo": ["name": "botbus", "version": .string(clientVersion)],
        ], timeout: timeout)
        let capabilities = AcpCapabilities(initializeResult: result)
        guard capabilities.protocolVersion == AcpProtocol.version else {
            throw ConnectorError("不支持的 ACP 版本：\(capabilities.protocolVersion)")
        }
        return capabilities
    }

    public func newSession(cwd: String, mcpServers: [AcpMcpServer]) async throws -> String {
        let result = try await peer.request("session/new", params: [
            "cwd": .string(cwd), "mcpServers": .array(mcpServers.map(\.json)),
        ], timeout: Self.sessionTimeout)
        guard let id = result["sessionId"]?.stringValue, !id.isEmpty else {
            throw ConnectorError("agent 没有返回会话 id")
        }
        return id
    }

    /// 载入一个旧会话。历史经 `session/update` 重放，在这个调用返回之前到达。
    public func loadSession(_ sessionId: String, cwd: String, mcpServers: [AcpMcpServer]) async throws {
        _ = try await peer.request("session/load", params: [
            "sessionId": .string(sessionId), "cwd": .string(cwd), "mcpServers": .array(mcpServers.map(\.json)),
        ], timeout: Self.sessionTimeout)
    }

    /// 接上一个旧会话继续聊（`session/resume`，ACP 的不稳定扩展）。**不重放历史**，之后直接 `session/prompt`。
    /// `cwd` 要和会话建立时一致（dsh 会核对）。
    public func resumeSession(_ sessionId: String, cwd: String, mcpServers: [AcpMcpServer]) async throws {
        _ = try await peer.request("session/resume", params: [
            "sessionId": .string(sessionId), "cwd": .string(cwd), "mcpServers": .array(mcpServers.map(\.json)),
        ], timeout: Self.sessionTimeout)
    }

    /// 一轮对话，**等到这一轮结束才返回**（可能几分钟），所以没有超时。
    public func prompt(_ sessionId: String, text: String, images: [AcpImage]) async throws -> AcpStopReason {
        guard !text.isEmpty || !images.isEmpty else {
            throw ConnectorError("消息不能为空")
        }
        var blocks: [JSONValue] = []
        if !text.isEmpty { blocks.append(["type": "text", "text": .string(text)]) }
        for image in images {
            blocks.append(["type": "image", "mimeType": .string(image.mimeType), "data": .string(image.base64)])
        }
        let result = try await peer.request("session/prompt", params: [
            "sessionId": .string(sessionId), "prompt": .array(blocks),
        ])
        return result["stopReason"]?.stringValue.flatMap(AcpStopReason.init(rawValue:)) ?? .endTurn
    }

    public func cancel(_ sessionId: String) async {
        await peer.notify("session/cancel", params: ["sessionId": .string(sessionId)])
    }

    /// `session/list`，按 `nextCursor` 翻页，最多翻 `maxPages` 页——超过这个页数就默默截断，
    /// 不当错误处理，也不告诉调用方还有没翻完的页。
    public func listSessions(maxPages: Int = 5) async throws -> [AcpSessionInfo] {
        var sessions: [AcpSessionInfo] = []
        var cursor: String?
        for _ in 0..<maxPages {
            var params: [String: JSONValue] = [:]
            if let cursor { params["cursor"] = .string(cursor) }
            let result = try await peer.request("session/list", params: .object(params), timeout: Self.sessionTimeout)
            sessions += result["sessions"]?.arrayValue?.compactMap(AcpSessionInfo.init(json:)) ?? []
            guard let next = result["nextCursor"]?.stringValue, !next.isEmpty else { break }
            cursor = next
        }
        return sessions
    }
}
