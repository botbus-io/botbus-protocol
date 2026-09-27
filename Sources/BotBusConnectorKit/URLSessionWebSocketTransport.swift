import Foundation
import BotBusProtocol

/// 基于 URLSessionWebSocketTask 的真实传输。
/// 握手结果用一次 ping 逼出来：若失败，再用普通 GET 探测同一地址的 HTTP 状态——Relay 对合法凭据返回 426（缺 Upgrade），
/// 对无效或已撤销的凭据返回 401，这样 RelayClient 能可靠区分"暂时连不上"和"该重新配对"。
public final class URLSessionWebSocketTransport: WebSocketTransport {
    /// 握手 ping 与会话内 ping 的上限。Agent 是 24/7 后台进程，不能吃 URLSession 默认的 60 秒超时：
    /// 对方 TCP 通了却迟迟不完成升级（半死代理、错端口）时 8 秒内没 pong 就判失败进退避，
    /// 而且 stop() 取消外层 Task 时挂着的 ping 必须立刻中断。
    public static let handshakeTimeout: TimeInterval = 8

    private let configuration: URLSessionConfiguration

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration
    }

    public func connect(url: URL, headers: [String: String]) async throws -> WebSocketConnection {
        var request = URLRequest(url: url)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let session = URLSession(configuration: configuration)
        let task = session.webSocketTask(with: request)
        task.resume()
        do {
            try await URLSessionWebSocketConnection.ping(task, timeout: Self.handshakeTimeout)
        } catch {
            task.cancel(with: .abnormalClosure, reason: nil)
            session.invalidateAndCancel()
            var status = (task.response as? HTTPURLResponse)?.statusCode
            // 握手超时或正在 stop() 时不再探测：对方连 HTTP 响应都没给，再等 10 秒也不会变成 401；探测只为在"被拒"时拿状态码。
            let timedOut = (error as? URLError)?.code == .timedOut
            if status == nil, !timedOut, !Task.isCancelled {
                status = await probeStatus(url: url, headers: headers)
            }
            throw WebSocketHandshakeFailed(status: status, underlying: error)
        }
        let connection = URLSessionWebSocketConnection(task: task, session: session)
        // 101 上带着 Relay 的版本（协议 2.8）。旧 Relay 不带，按 2.7 算。
        let upgrade = task.response as? HTTPURLResponse
        if let problem = ProtocolVersion.incompatibility(
            status: upgrade?.statusCode ?? 101,
            relayVersion: upgrade?.value(forHTTPHeaderField: ProtocolVersion.header)) {
            connection.close()
            throw problem
        }
        return connection
    }

    /// 把 wss://…/agent/ws 当普通 https GET 一次，只为拿 HTTP 状态码。
    private func probeStatus(url: URL, headers: [String: String]) async -> Int? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = components.scheme == "ws" ? "http" : "https"
        guard let httpURL = components.url else { return nil }
        var request = URLRequest(url: httpURL)
        request.timeoutInterval = 10
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        guard let (_, response) = try? await session.data(for: request) else { return nil }
        return (response as? HTTPURLResponse)?.statusCode
    }
}

/// 用 actor 让 send 严格按调用顺序入队：URLSessionWebSocketTask.send 只在调用顺序确定时保证帧顺序，
/// 而 RelayClient 的 send 在 await 处会重入，靠 actor 邮箱排队最省心。
public actor URLSessionWebSocketConnection: WebSocketConnection {
    public let task: URLSessionWebSocketTask
    private let session: URLSession

    public init(task: URLSessionWebSocketTask, session: URLSession) {
        self.task = task
        self.session = session
    }

    public func send(text: String) async throws {
        try await task.send(.string(text))
    }

    public func receiveText() async throws -> String {
        do {
            switch try await task.receive() {
            case .string(let text): return text
            case .data(let data): return String(decoding: data, as: UTF8.self)
            @unknown default: return ""
            }
        } catch {
            // 对端关闭后 receive 抛错；closeCode 里有 Relay 给的 4000 / 4001（ObjC 枚举保留原始整数值）。
            let code = task.closeCode.rawValue
            if code != 0 {
                let reason = task.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? ""
                throw WebSocketClosed(code: code, reason: reason)
            }
            throw error
        }
    }

    public func sendPing() async throws {
        do {
            try await Self.ping(task, timeout: URLSessionWebSocketTransport.handshakeTimeout)
        } catch {
            // TCP 半死时 receive() 可能一直挂着；ping 失败或超时就主动取消，让 receiveText 抛错触发重连。
            task.cancel(with: .abnormalClosure, reason: nil)
            throw error
        }
    }

    public nonisolated func close() {
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }

    /// 发一次 ping 并等 pong，最多等 timeout 秒。薄包装，真正的逻辑在下面可注入的版本里。
    public static func ping(_ task: URLSessionWebSocketTask, timeout: TimeInterval) async throws {
        try await ping(timeout: timeout,
                       cancel: { task.cancel(with: .abnormalClosure, reason: nil) },
                       sendPing: { handler in task.sendPing(pongReceiveHandler: handler) })
    }

    /// 可注入版本：pong、超时、外层取消三条路径共用同一个 `OneShotContinuation`，先到者定胜负。
    ///
    /// 这里刻意不用 TaskGroup：`withThrowingTaskGroup` 返回前会隐式等所有子任务结束，而
    /// `group.cancelAll()` 只是"请求"取消。sendPing 的 pong 回调永远不来时，ping 子任务的 continuation
    /// 就永远不 resume，于是整个调用挂死——RelayClient 的 30 秒 ping 循环会静默停摆，
    /// 握手路径则一直卡在"正在连接 Relay…"，连取消外层 Task 都救不回来。
    /// 把超时收进同一个 continuation 里，超时一到就有人 resume，不存在挂死的可能。
    ///
    /// 只有"赢下 resume 权"的失败分支才 `cancel()`：否则会把已经 pong 成功的连接误杀。
    /// pong 带错误返回时不在这里 cancel，交给调用方（`sendPing()` 与 `connect()` 的 catch）处理，
    /// 与改造前一致。超时仍旧抛 `URLError(.timedOut)`——`connect()` 靠它判断要不要再探 HTTP 状态码。
    public static func ping(timeout: TimeInterval,
                     cancel: @escaping @Sendable () -> Void,
                     sendPing: @escaping @Sendable (@escaping @Sendable (Error?) -> Void) -> Void) async throws {
        let box = OneShotContinuation<Void>()
        let timeoutTask = Task {
            // sleep 被取消时直接收工，不能当成超时。
            guard (try? await Task.sleep(for: .seconds(timeout))) != nil else { return }
            if box.resume(throwing: URLError(.timedOut)) { cancel() }
        }
        // 赢家路径上顺手把计时器收掉，超时任务不会比本次调用多活。
        defer { timeoutTask.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                box.install(continuation)
                sendPing { error in
                    if let error { box.resume(throwing: error) } else { box.resume(returning: ()) }
                }
            }
        } onCancel: {
            // 取消赢了就 cancel 底层 task，让挂着的 sendPing 回调立刻带错返回，
            // 否则 URLSession 要等它自己的 60 秒超时才罢休。
            if box.resume(throwing: CancellationError()) { cancel() }
        }
    }
}

/// 二进制消息：预览隧道（AgentCore 的 `PreviewTunnelTransport`）复用同一套握手。
public extension URLSessionWebSocketConnection {
    public func setMaximumMessageSize(_ size: Int) {
        task.maximumMessageSize = size
    }

    /// 与 `send(text:)` 一样经 actor 邮箱排队，调用顺序即帧顺序。
    public func sendBinary(_ data: Data) async throws {
        try await task.send(.data(data))
    }

    public func receiveBinary() async throws -> Data {
        do {
            switch try await task.receive() {
            case .data(let data): return data
            // 协议只用二进制；文本消息按字节交给解码器，解不出来就当坏帧丢掉。
            case .string(let text): return Data(text.utf8)
            @unknown default: return Data()
            }
        } catch {
            let code = task.closeCode.rawValue
            if code != 0 {
                let reason = task.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? ""
                throw WebSocketClosed(code: code, reason: reason)
            }
            throw error
        }
    }
}

