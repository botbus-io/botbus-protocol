import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import BotBusConnectorKit
#if canImport(os)
import os
#endif

/// OpenClaw Gateway 报的错，以及本机这一侧"没连上 / 超时 / 断了"。`message` 是给人看的中文整句，直接进菜单栏与命令回执。
public struct OpenClawGatewayError: LocalizedError, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// WebSocket 都没建起来（Gateway 没跑、端口不对）。
        case unreachable
        /// `connect` 被拒：token 错、缺设备签名、配对未批准……
        case rejected
        /// `hello-ok` 报的协议版本不是 v4。
        case protocolMismatch
        /// 某个请求在时限内没等到应答。
        case timedOut
        /// 连接断了（对端关闭或本机 `close()`），在途请求一律以此结束。
        case closed
        /// 握手还没完成就发请求。
        case notConnected
        /// 请求送到了，Gateway 回了 `ok:false`。
        case requestFailed
    }

    public let kind: Kind
    /// Gateway 的 `error.code`（`AUTH_TOKEN_MISMATCH`、`INVALID_REQUEST` 之类），本机错误为 nil。
    public let code: String?
    public let message: String

    public init(_ kind: Kind, code: String? = nil, message: String) {
        self.kind = kind
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// 连 OpenClaw Gateway（WebSocket 协议 v4）的一条连接：握手、按 id 配对请求与应答、把事件交给调用方。
///
/// **一个实例只管一条连接**，断了就作废：重连由 `OpenClawConnector` 新建实例，
/// 这样"迟到的应答认错了连接""旧连接的事件混进新连接"这类问题从结构上就不存在，不用像
/// `CodexAppServer` 那样靠代际号去认。
///
/// 帧格式（`packages/gateway-protocol/src/schema/frames.ts`）：
/// - 请求 `{type:"req", id, method, params?}`，应答 `{type:"res", id, ok, payload?, error?:{code,message}}`；
/// - 事件 `{type:"event", event, payload?, seq?}`。
///
/// 握手（`docs/gateway/protocol/handshake.md`）：服务端先推 `connect.challenge`，客户端第一帧必须是 `connect` 请求，
/// 成功应答的 payload 是 `hello-ok`。我们走"回环 + 共享密钥 + `gateway-client`/`backend`"这条免设备签名的路，
/// 所以 challenge 里的 nonce 用不上，只是等它到了再发（最多等 `challengeTimeout`，老 Gateway 不发 challenge）。
///
/// `ConnectParams` 是**闭合对象**（多一个未知字段就整帧拒收），这里只发 schema 里有的键；
/// 反过来解析应答时一律宽松：不认识的字段忽略，缺了就用兜底值。
public actor OpenClawGateway {
    public static let protocolVersion: Int64 = 4
    public static let clientId = "gateway-client"
    public static let clientMode = "backend"
    public static let scopes = ["operator.read", "operator.write", "operator.approvals"]
    /// `tool-events` 其实用不上，但 Gateway 会按发起端的 caps 裁剪 agent 可用的工具，
    /// 不声明的话手机发起的任务可能少工具；`exec-approvals` 是真用：审批要在手机上批。
    public static let caps = ["tool-events", "exec-approvals"]

    public static var defaultClientVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return (version?.isEmpty == false ? version : nil) ?? "0.0.0"
    }

    public struct Configuration: Sendable {
        public var url: URL
        public var token: String?
        public var password: String?
        public var clientVersion: String
        /// 普通请求的硬上限。`sessions.list` 带标题推导与最后一条消息，200 行也在秒级以内。
        public var requestTimeout: TimeInterval
        /// `connect` 请求的上限。Gateway 启动中会回可重试的 `UNAVAILABLE`，那也算失败，交给重连退避。
        public var connectTimeout: TimeInterval
        /// 等 `connect.challenge` 的上限；到点没来就直接发 `connect`。
        public var challengeTimeout: TimeInterval
        /// WebSocket ping 间隔：TCP 半死时靠它逼出错误（URLSession 的连接 ping 失败会主动取消，receive 随之抛错）。
        public var pingInterval: TimeInterval

        public init(url: URL, token: String? = nil, password: String? = nil,
                    clientVersion: String = OpenClawGateway.defaultClientVersion,
                    requestTimeout: TimeInterval = 15, connectTimeout: TimeInterval = 10,
                    challengeTimeout: TimeInterval = 2, pingInterval: TimeInterval = 30) {
            self.url = url
            self.token = token
            self.password = password
            self.clientVersion = clientVersion
            self.requestTimeout = requestTimeout
            self.connectTimeout = connectTimeout
            self.challengeTimeout = challengeTimeout
            self.pingInterval = pingInterval
        }

        public init(config: OpenClawConfig, clientVersion: String = OpenClawGateway.defaultClientVersion) {
            self.init(url: config.gatewayURL, token: config.token, password: config.password, clientVersion: clientVersion)
        }
    }

    public enum Event: Sendable {
        /// Gateway 推来的事件（`connect.challenge` 已被握手吃掉，不会出现在这里）。
        case event(name: String, payload: JSONValue?)
        /// 连接没了。流随即结束，之后不会再有事件。
        case disconnected(reason: String)
    }

    private enum State { case idle, handshaking, connected, closed }

    private struct Pending {
        let method: String
        let box: OneShotContinuation<JSONValue>
        let timer: Task<Void, Never>
    }

    private static let log = PlatformLogger(subsystem: "io.botbus.agent", category: "openclaw")

    /// 事件出口，单一消费者（连接器）。无界缓冲：握手与 `sessions.subscribe` 期间到达的事件先攒着，
    /// 快照落定后再按序消费——文档要求"先装监听再订阅"，攒着就等于装好了。
    public nonisolated let events: AsyncStream<Event>
    private let eventContinuation: AsyncStream<Event>.Continuation

    private let transport: WebSocketTransport
    private let configuration: Configuration
    private var state: State = .idle
    private var connection: WebSocketConnection?
    private var inFlight: [String: Pending] = [:]
    private var nextRequestNumber = 1
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    /// `connect.challenge` 的 payload；超时给 nil，连接先断则抛错。
    private let challenge = OneShotContinuation<JSONValue?>()
    /// 握手成功时 Gateway 回的 `hello-ok`（里面有 methods/events 列表与实际授予的 scopes）。
    public private(set) var hello: JSONValue?

    public init(transport: WebSocketTransport, configuration: Configuration) {
        self.transport = transport
        self.configuration = configuration
        var captured: AsyncStream<Event>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .unbounded) { captured = $0 }
        self.eventContinuation = captured
    }

    public var isConnected: Bool { state == .connected }

    // MARK: - 握手

    /// 建连并完成 `connect` 握手，返回 `hello-ok` payload。只能调一次；失败后实例作废。
    @discardableResult
    public func connect() async throws -> JSONValue {
        guard state == .idle else {
            throw OpenClawGatewayError(.notConnected, message: "OpenClaw Gateway 连接已经用过，需要重新建立")
        }
        state = .handshaking
        let connection: WebSocketConnection
        do {
            connection = try await transport.connect(url: configuration.url, headers: [:])
        } catch {
            finish(reason: "连接失败")
            throw OpenClawGatewayError(.unreachable, message: unreachableMessage)
        }
        // 握手期间被 close()：迟到的连接不能留着。
        guard state == .handshaking else {
            connection.close()
            throw OpenClawGatewayError(.closed, message: "OpenClaw Gateway 连接已关闭")
        }
        self.connection = connection
        receiveTask = Task { [weak self] in await self?.receiveLoop(connection) }

        let challengeTimer = Task { [challenge, seconds = configuration.challengeTimeout] in
            guard (try? await Task.sleep(for: .seconds(seconds))) != nil else { return }
            challenge.resume(returning: nil)
        }
        defer { challengeTimer.cancel() }

        do {
            // nonce 只有设备签名才用得上；免签名的 backend 路径里只是"等服务端先开口"。
            _ = try await challenge.value()
            let payload = try await perform(method: "connect", params: connectParams(), timeout: configuration.connectTimeout)
            try validateHello(payload)
            guard state == .handshaking else {
                throw OpenClawGatewayError(.closed, message: "OpenClaw Gateway 连接已关闭")
            }
            hello = payload
            state = .connected
            startPing(connection)
            return payload
        } catch let error as OpenClawGatewayError {
            let mapped: OpenClawGatewayError
            switch error.kind {
            case .requestFailed:
                mapped = OpenClawGatewayError(.rejected, code: error.code,
                                              message: "OpenClaw Gateway 拒绝了连接：\(error.message)")
            case .timedOut:
                mapped = OpenClawGatewayError(.timedOut, message: "OpenClaw Gateway 握手超时（\(address)）")
            case .closed:
                mapped = OpenClawGatewayError(.unreachable, message: unreachableMessage)
            default:
                mapped = error
            }
            close()
            throw mapped
        } catch {
            close()
            throw OpenClawGatewayError(.unreachable, message: unreachableMessage)
        }
    }

    /// `connect` 的 params。键必须都在 `ConnectParamsSchema` 里（闭合对象）。
    func connectParams() -> JSONValue {
        var auth: [String: JSONValue] = [:]
        if let token = configuration.token { auth["token"] = .string(token) }
        if let password = configuration.password { auth["password"] = .string(password) }
        var params: [String: JSONValue] = [
            "minProtocol": .int(Self.protocolVersion),
            "maxProtocol": .int(Self.protocolVersion),
            "client": [
                "id": .string(Self.clientId),
                "displayName": "BotBus",
                "version": .string(configuration.clientVersion.isEmpty ? "0.0.0" : configuration.clientVersion),
                "platform": "macos",
                "mode": .string(Self.clientMode),
            ],
            "role": "operator",
            "scopes": .array(Self.scopes.map { .string($0) }),
            "caps": .array(Self.caps.map { .string($0) }),
            "userAgent": .string("botbus/\(configuration.clientVersion)"),
        ]
        if !auth.isEmpty { params["auth"] = .object(auth) }
        return .object(params)
    }

    /// `hello-ok` 的形状只核两件事：确实是 hello（有 `type` 时），协议版本对得上（有 `protocol` 时）。
    /// 其余字段（features / snapshot / policy）一概不强求——协议 v4 一直在加字段。
    private func validateHello(_ payload: JSONValue) throws {
        if let type = payload["type"]?.stringValue, type != "hello-ok" {
            throw OpenClawGatewayError(.rejected, message: "OpenClaw Gateway 拒绝了连接：握手应答不是 hello-ok（\(type)）")
        }
        if let version = payload["protocol"]?.intValue, version != Self.protocolVersion {
            throw OpenClawGatewayError(.protocolMismatch,
                                       message: "OpenClaw Gateway 的协议版本是 v\(version)，BotBus 只支持 v\(Self.protocolVersion)，请升级两边中较旧的一方")
        }
    }

    private var address: String {
        guard let host = configuration.url.host else { return configuration.url.absoluteString }
        return configuration.url.port.map { "\(host):\($0)" } ?? host
    }

    private var unreachableMessage: String { "连不上 OpenClaw Gateway（\(address)）" }

    // MARK: - 请求

    /// 发一个请求并等应答的 payload（没有 payload 时给 `.null`）。`ok:false` 抛 `.requestFailed`。
    public func request(_ method: String, params: JSONValue? = nil, timeout: TimeInterval? = nil) async throws -> JSONValue {
        guard state == .connected else {
            throw OpenClawGatewayError(.notConnected, message: "OpenClaw Gateway 没有连上")
        }
        return try await perform(method: method, params: params, timeout: timeout ?? configuration.requestTimeout)
    }

    private func perform(method: String, params: JSONValue?, timeout: TimeInterval) async throws -> JSONValue {
        guard let connection else {
            throw OpenClawGatewayError(.notConnected, message: "OpenClaw Gateway 没有连上")
        }
        // id 用递增字符串：schema 要求非空字符串，一条连接内唯一就够了。
        let id = "botbus-\(nextRequestNumber)"
        nextRequestNumber += 1
        let box = OneShotContinuation<JSONValue>()
        // 超时与应答、断线共用同一个盒子，谁先到谁算——不会有 continuation 挂死或二次 resume。
        let timer = Task { [weak self] in
            guard (try? await Task.sleep(for: .seconds(timeout))) != nil else { return }
            let error = OpenClawGatewayError(.timedOut, message: "OpenClaw Gateway 在 \(Int(timeout.rounded())) 秒内没有回应 \(method)")
            guard box.resume(throwing: error) else { return }
            await self?.forget(id)
        }
        inFlight[id] = Pending(method: method, box: box, timer: timer)

        var frame: [String: JSONValue] = ["type": "req", "id": .string(id), "method": .string(method)]
        if let params { frame["params"] = params }
        do {
            let data = try JSONEncoder().encode(JSONValue.object(frame))
            try await connection.send(text: String(decoding: data, as: UTF8.self))
        } catch {
            if let pending = inFlight.removeValue(forKey: id) {
                pending.timer.cancel()
                pending.box.resume(throwing: OpenClawGatewayError(.closed, message: "OpenClaw Gateway 连接已断开"))
            }
        }
        defer { timer.cancel() }
        return try await box.value()
    }

    private func forget(_ id: String) {
        inFlight.removeValue(forKey: id)
    }

    // MARK: - 读

    private func receiveLoop(_ connection: WebSocketConnection) async {
        do {
            while !Task.isCancelled {
                let text = try await connection.receiveText()
                handle(text)
            }
        } catch let closed as WebSocketClosed {
            finish(reason: closed.reason.isEmpty ? "连接被关闭（\(closed.code)）" : "连接被关闭（\(closed.code)：\(closed.reason)）")
            return
        } catch {
            finish(reason: "连接中断")
            return
        }
        finish(reason: "连接已关闭")
    }

    /// 一帧。解不出来、类型不认识的一律丢掉——协议在快速迭代，不能因为一个新帧型就断连。
    private func handle(_ text: String) {
        guard let frame = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)),
              let type = frame["type"]?.stringValue else {
            Self.log.debug("忽略无法解析的 Gateway 帧")
            return
        }
        switch type {
        case "res":
            guard let id = Self.frameID(frame["id"]), let pending = inFlight.removeValue(forKey: id) else { return }
            pending.timer.cancel()
            if frame["ok"]?.boolValue == true {
                pending.box.resume(returning: frame["payload"] ?? .null)
            } else {
                let error = frame["error"]
                let message = error?["message"]?.stringValue ?? "未知错误"
                pending.box.resume(throwing: OpenClawGatewayError(.requestFailed, code: error?["code"]?.stringValue,
                                                                  message: message))
            }
        case "event":
            guard let name = frame["event"]?.stringValue else { return }
            if name == "connect.challenge" {
                challenge.resume(returning: frame["payload"] ?? .null)
                return
            }
            guard state != .closed else { return }
            eventContinuation.yield(.event(name: name, payload: frame["payload"]))
        default:
            return
        }
    }

    /// 应答 id 我们发的是字符串；万一对端回成数字也认。
    private static func frameID(_ value: JSONValue?) -> String? {
        if let text = value?.stringValue { return text }
        if let number = value?.intValue { return String(number) }
        return nil
    }

    private func startPing(_ connection: WebSocketConnection) {
        pingTask?.cancel()
        let interval = configuration.pingInterval
        guard interval > 0 else { return }
        pingTask = Task {
            while !Task.isCancelled {
                guard (try? await Task.sleep(for: .seconds(interval))) != nil else { return }
                try? await connection.sendPing()
            }
        }
    }

    // MARK: - 关闭

    /// 主动关闭。在途请求立即以 `.closed` 结束，事件流收尾（最后一个事件是 `.disconnected`）。幂等。
    public func close() {
        finish(reason: "连接已关闭")
    }

    private func finish(reason: String) {
        guard state != .closed else { return }
        state = .closed
        receiveTask?.cancel()
        receiveTask = nil
        pingTask?.cancel()
        pingTask = nil
        connection?.close()
        connection = nil
        let error = OpenClawGatewayError(.closed, message: "OpenClaw Gateway 连接已断开")
        challenge.resume(throwing: error)
        let taken = inFlight
        inFlight.removeAll()
        for pending in taken.values {
            pending.timer.cancel()
            pending.box.resume(throwing: error)
        }
        eventContinuation.yield(.disconnected(reason: reason))
        eventContinuation.finish()
    }
}

/// 连 OpenClaw Gateway 用的 WebSocket 传输。和 `URLSessionWebSocketTransport` 同一套握手（ping 逼出结果），
/// 只多一件事：把单帧上限从 URLSession 默认的 1 MiB 调大。
///
/// Gateway 的帧上限是 25 MiB（`hello-ok.policy.maxPayload`），而 `sessions.list` 带标题与预览的 200 行、
/// 或者一页 `chat.history`，轻易就超过 1 MiB；超了 URLSession 直接判连接出错，表现为"连上就断、断了再连"的死循环。
/// Relay 那条连接的帧都很小，所以这个改动没有放进共享的传输里。
public final class OpenClawWebSocketTransport: WebSocketTransport {
    public static let maximumMessageSize = 32 * 1024 * 1024

    private let configuration: URLSessionConfiguration

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration
    }

    public func connect(url: URL, headers: [String: String]) async throws -> WebSocketConnection {
        var request = URLRequest(url: url)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let session = URLSession(configuration: configuration)
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = Self.maximumMessageSize
        task.resume()
        do {
            try await URLSessionWebSocketConnection.ping(task, timeout: URLSessionWebSocketTransport.handshakeTimeout)
        } catch {
            task.cancel(with: .abnormalClosure, reason: nil)
            session.invalidateAndCancel()
            throw WebSocketHandshakeFailed(status: (task.response as? HTTPURLResponse)?.statusCode, underlying: error)
        }
        return URLSessionWebSocketConnection(task: task, session: session)
    }
}
