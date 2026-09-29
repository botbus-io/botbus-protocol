import Foundation

/// 一条已建立的 WebSocket 连接。RelayClient 只依赖这两个协议，测试用假实现。
public protocol WebSocketConnection: AnyObject, Sendable {
    func send(text: String) async throws
    /// 阻塞直到收到一帧文本；对端关闭时抛 WebSocketClosed。
    func receiveText() async throws -> String
    func sendPing() async throws
    func close()
    /// 握手 101 上对端报的协议版本（Relay 的 `X-Protocol-Version`，协议 2.8）。连的不是 Relay、
    /// 或传输拿不到响应头时为 nil（按 `ProtocolVersion.legacy` 算）。RelayClient 在要求更高的 Relay 时用它（协议 3.6）。
    var relayProtocolVersion: String? { get }
}

public extension WebSocketConnection {
    var relayProtocolVersion: String? { nil }
}

public protocol WebSocketTransport: Sendable {
    /// 完成握手后返回；握手被拒抛 WebSocketHandshakeFailed（status 为 HTTP 状态码，拿不到时为 nil）。
    func connect(url: URL, headers: [String: String]) async throws -> WebSocketConnection
}

/// 对端关闭连接。Relay 的约定：4000 = 被同一 pair 的新连接顶掉，4001 = 配对已撤销。
public struct WebSocketClosed: Error, Equatable, Sendable {
    public let code: Int
    public let reason: String

    public init(code: Int, reason: String = "") {
        self.code = code
        self.reason = reason
    }
}

public struct WebSocketHandshakeFailed: Error, Sendable {
    public let status: Int?
    public let underlying: Error?

    public init(status: Int?, underlying: Error?) {
        self.status = status
        self.underlying = underlying
    }
}
