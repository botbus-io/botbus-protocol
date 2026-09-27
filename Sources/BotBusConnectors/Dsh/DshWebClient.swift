import CryptoKit
import Foundation
import BotBusConnectorKit
import os

/// 本机一个 `dsh web` 的地址。dsh 要求 Host 是回环地址，cookie 按 `authority` 签，所以一律用 `127.0.0.1:<port>`。
public struct DshWebEndpoint: Hashable, Sendable {
    public var port: Int

    public init(port: Int) {
        self.port = port
    }

    public var authority: String { "127.0.0.1:\(port)" }
    public var baseURL: URL { URL(string: "http://\(authority)")! }
    public var muxURL: URL { URL(string: "ws://\(authority)/api/remote.mux")! }

    public func methodURL(_ method: String) -> URL { URL(string: "http://\(authority)/api/\(method)")! }
}

/// 一元调用的 HTTP 层，测试注入假的。
public protocol DshHTTPTransport: Sendable {
    /// POST 并返回状态码与响应体。连不上抛错（任何错误都当"web 不在"）。
    func post(_ url: URL, headers: [String: String], body: Data) async throws -> (status: Int, body: Data)
}

/// 生产用：ephemeral 会话、不存 cookie、15 秒超时。
public struct URLSessionDshHTTPTransport: DshHTTPTransport {
    public static let timeout: TimeInterval = 15
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.timeoutIntervalForRequest = Self.timeout
        configuration.connectionProxyDictionary = [:]
        session = URLSession(configuration: configuration)
    }

    public func post(_ url: URL, headers: [String: String], body: Data) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = Self.timeout
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

/// web 通道的错误。`message` 里可能带 dsh 自己的错误文本（`containsPrivateDetail`），只给界面、不进公开日志。
public enum DshWebError: Error, LocalizedError, Hashable, Sendable {
    /// 401：cookie 不被认（密钥换了、web 用的是别的 `DSH_HOME`）。
    case unauthorized
    case httpStatus(Int)
    case malformedResponse(method: String)
    /// `result.ok == false`：dsh 回的 `{code, message}`。
    case remote(code: String?, message: String)
    /// mux 上某条流报错。
    case streamFailed(code: String?, message: String)
    /// mux 连接断了（或还没连上就用）。
    case disconnected
    case timeout

    public var errorDescription: String? {
        switch self {
        case .unauthorized: "DeepSeek Harness 网页端拒绝了 BotBus 的登录"
        case .httpStatus(let status): "DeepSeek Harness 网页端返回 HTTP \(status)"
        case .malformedResponse(let method): "看不懂 DeepSeek Harness 网页端的回应：\(method)"
        case .remote(_, let message), .streamFailed(_, let message): message
        case .disconnected: "和 DeepSeek Harness 网页端的连接断开了"
        case .timeout: "DeepSeek Harness 网页端没有及时回应"
        }
    }

    public var containsPrivateDetail: Bool {
        switch self {
        case .remote, .streamFailed: true
        default: false
        }
    }

    /// 能公开进日志的类别（不带 dsh 的错误文本）。
    public var logCategory: String {
        switch self {
        case .unauthorized: "unauthorized"
        case .httpStatus(let status): "http \(status)"
        case .malformedResponse(let method): "malformed \(method)"
        case .remote(let code, _): "remote \(code ?? "?")"
        case .streamFailed(let code, _): "stream \(code ?? "?")"
        case .disconnected: "disconnected"
        case .timeout: "timeout"
        }
    }
}

/// `dsh web` 的一元调用（`POST /api/<ns>/<method>`）。无状态、可并发；每次请求现签一张 cookie。
///
/// 请求体 `{type:"client-request", rpcId, method, payload:{args:{<参数名>: 参数}}}`，参数名 `session/list` 是 `_request`、
/// 其余是 `request`；`$events/result` 例外，`args` 就是结果本身。回应 `{type:"server-response", rpcId, result:{ok, value | error}}`。
/// 日志只记方法名与类别，不记参数、回应与 cookie。
public struct DshWebClient: Sendable {
    static let log = Logger(subsystem: "io.botbus.agent", category: "dsh")

    public let endpoint: DshWebEndpoint
    private let secret: SymmetricKey
    private let http: any DshHTTPTransport
    private let now: @Sendable () -> Date

    public init(endpoint: DshWebEndpoint, secret: SymmetricKey,
                http: any DshHTTPTransport = URLSessionDshHTTPTransport(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.endpoint = endpoint
        self.secret = secret
        self.http = http
        self.now = now
    }

    /// `Cookie` 头的值。mux 握手也用它。
    public func cookieHeader() -> String {
        DshWebCookie.header(secret: secret, authority: endpoint.authority, now: now())
    }

    /// 发一次调用，返回 `result.value`（没有就是 `.null`）。
    public func call(_ method: String, _ argument: JSONValue) async throws -> JSONValue {
        let args: JSONValue
        switch method {
        case "$events/result": args = argument
        case "session/list": args = ["_request": argument]
        default: args = ["request": argument]
        }
        let envelope: JSONValue = [
            "type": "client-request", "rpcId": .string(UUID().uuidString), "method": .string(method),
            "payload": ["args": args],
        ]
        let body = try JSONEncoder().encode(envelope)
        let (status, data) = try await http.post(endpoint.methodURL(method), headers: [
            "Cookie": cookieHeader(), "Content-Type": "application/json",
        ], body: body)
        if status == 401 || status == 403 { throw DshWebError.unauthorized }
        guard (200..<300).contains(status) else { throw DshWebError.httpStatus(status) }
        guard let response = try? JSONDecoder().decode(JSONValue.self, from: data),
              let result = response["result"], let ok = result["ok"]?.boolValue else {
            throw DshWebError.malformedResponse(method: method)
        }
        guard ok else {
            throw DshWebError.remote(code: result.path("error", "code")?.stringValue,
                                     message: result.path("error", "message")?.stringValue ?? "DeepSeek Harness 报错")
        }
        return result["value"] ?? .null
    }

    /// `session/list`：每次都重读持久层，ACP 进程建的会话也在里面。子 agent、空会话由调用方过滤。
    public func listSessions() async throws -> [DshWebSessionSummary] {
        let value = try await call("session/list", [:])
        guard let items = value["items"]?.arrayValue else { throw DshWebError.malformedResponse(method: "session/list") }
        return items.compactMap(DshWebSessionSummary.init(json:))
    }

    /// 续聊（`mode: "queue"`：这一轮在跑就排在后面）。web 没载入的会话会自己载入（之后一直持锁）。
    /// 返回 dsh 是否接受（`accepted`）。`requestId` 会成为 `user/message.source.rpcId`。
    @discardableResult
    public func prompt(sessionId: String, text: String, requestId: String = "botbus-\(UUID().uuidString)") async throws -> Bool {
        let value = try await call("session/prompt", [
            "requestId": .string(requestId), "sessionId": .string(sessionId), "mode": "queue",
            "content": [["type": "text", "text": .string(text)]],
        ])
        return value["accepted"]?.boolValue ?? true
    }

    /// 中断这一轮（以 `aborted{user}` 收尾）。
    public func cancel(sessionId: String) async throws {
        _ = try await call("session/cancel", ["sessionId": .string(sessionId)])
    }

    /// 取一页历史，**不激活会话**（不像 follow 会让 web 载入并锁住它）。`throughSeq` 是这一页的最后一条（超过会话实际的
    /// 最后一条会报错），`beforeSeq` 往前翻页。返回的事件与有没有更早的。不知道游标时用 `latestPage`。
    public func page(sessionId: String, throughSeq: Int64, beforeSeq: Int64? = nil,
                     maxMessages: Int = 50) async throws -> (events: [DshSessionEvent], hasMore: Bool) {
        var request: [String: JSONValue] = [
            "address": ["kind": "session", "sessionId": .string(sessionId)],
            "throughSeq": .int(throughSeq), "maxMessages": .int(Int64(maxMessages)),
        ]
        if let beforeSeq { request["beforeSeq"] = .int(beforeSeq) }
        let value = try await call("session/page", .object(request))
        guard let records = value["records"]?.arrayValue else { throw DshWebError.malformedResponse(method: "session/page") }
        return (records.compactMap(DshSessionEvent.init(json:)), value["hasMore"]?.boolValue ?? false)
    }

    /// 最近的一页历史，不激活会话、也不信 `asOfSeq`：`asOfSeq` 来自投影缓存，ACP 进程写的缓存常常停在会话刚建好时，
    /// 按它取会漏掉之后的全部事件。做法是先用一个一定越界的 `throughSeq` 问一次，dsh 回
    /// `gateway/bad-request`「… is past cursor <N>」，从里面取出真正的游标再取一次。
    /// 依赖这句错误文案（dsh 0.1.5-rc.3），认不出来时抛原来的错误；调用方能读盘的话优先读盘（`DshTranscriptDecoder`）。
    public func latestPage(sessionId: String, maxMessages: Int = 50) async throws -> (events: [DshSessionEvent], hasMore: Bool) {
        do {
            return try await page(sessionId: sessionId, throughSeq: Self.probeSeq, maxMessages: maxMessages)
        } catch DshWebError.remote(let code, let message) where code == "gateway/bad-request" {
            guard let cursor = Self.cursor(fromPastCursorMessage: message) else {
                throw DshWebError.remote(code: code, message: message)
            }
            guard cursor >= 0 else { return ([], false) }
            return try await page(sessionId: sessionId, throughSeq: cursor, maxMessages: maxMessages)
        }
    }

    static let probeSeq: Int64 = 9_007_199_254_740_991

    /// `session page through seq X is past cursor N` → N（-1 = 空会话）。
    static func cursor(fromPastCursorMessage message: String) -> Int64? {
        guard let range = message.range(of: "past cursor ") else { return nil }
        let digits = message[range.upperBound...].prefix { $0 == "-" || $0.isNumber }
        return Int64(digits)
    }

    /// 回一条 waterfall（`$events/result`）。`clientId` 是这条 `$events` 流 `ready` 给的。
    public func answer(clientId: String, eventId: String, value: JSONValue) async throws {
        _ = try await call("$events/result", [
            "clientId": .string(clientId), "eventId": .string(eventId),
            "outcome": ["kind": "result", "value": value],
        ])
    }

    /// 审批：允许（只这一次）或拒绝。dsh 的审批没有"以后都允许"。
    public func answerApproval(clientId: String, eventId: String, allow: Bool) async throws {
        try await answer(clientId: clientId, eventId: eventId, value: .string(allow ? "allowed-once" : "rejected"))
    }

    /// 提问：`answers` 是 题目 id → 选中的选项名。
    public func answerQuestions(clientId: String, eventId: String, answers: [String: [String]]) async throws {
        try await answerQuestions(clientId: clientId, eventId: eventId,
                                  answers: answers.sorted { $0.key < $1.key }.map { DshQuestionAnswer(id: $0.key, selected: $0.value) })
    }

    /// 提问，带自己写的回答（`custom`）：dsh 的 `AskUserQuestionAnswer` 是 `{answers:[{id, selected, custom?}]}`，
    /// 单选题有 `custom` 时它盖过选项（`selected` 为空）；跳过一题就是 `{id, selected: []}`。
    public func answerQuestions(clientId: String, eventId: String, answers: [DshQuestionAnswer]) async throws {
        try await answer(clientId: clientId, eventId: eventId, value: ["answers": .array(answers.map(\.json))])
    }
}

/// 一道题的回答（`AskUserQuestionAnswer.answers[]`）。
public struct DshQuestionAnswer: Hashable, Sendable {
    public var id: String
    public var selected: [String]
    public var custom: String?

    public init(id: String, selected: [String], custom: String? = nil) {
        self.id = id
        self.selected = selected
        self.custom = custom
    }

    var json: JSONValue {
        var object: [String: JSONValue] = ["id": .string(id), "selected": .array(selected.map(JSONValue.string))]
        if let custom { object["custom"] = .string(custom) }
        return .object(object)
    }

    /// 什么都没答（跳过）。
    public var isEmpty: Bool { selected.isEmpty && (custom?.isEmpty ?? true) }
}

/// mux 上的一条逻辑流。`items` 在 dsh 发 `end` 时正常结束，`error` 帧或连接断开时抛错；
/// 调用方不再迭代（取消迭代它的 Task）时自动给 dsh 发 `cancel`。
public struct DshWebStream: Sendable {
    public let id: String
    public let items: AsyncThrowingStream<JSONValue, Error>
}

/// `dsh web` 的流式通道：一条 WebSocket（`/api/remote.mux`），上面按 `streamId` 复用多条逻辑流。
///
/// 发 `{type:"open", streamId, endpoint, payload:{args}}` / `{type:"cancel", streamId}`；收 `item` / `error` / `end`。
/// 连接只有一个读循环；断开后所有流以 `DshWebError.disconnected` 结束，`onClose` 回调一次，不自动重连（由拥有者决定）。
///
/// 默认传输是 `OpenClawWebSocketTransport`：握手同 Relay 那套（ping 逼结果），但不查 Relay 的版本头、单帧上限放大到 32 MiB
///（follow 的首帧 snapshot 可能很大）。握手只带 `Cookie`，不带 `Origin`（dsh 只在带了 Origin 时核对它）。
public actor DshWebMux {
    public let endpoint: DshWebEndpoint
    private let cookie: @Sendable () -> String
    private let transport: any WebSocketTransport
    private var connection: (any WebSocketConnection)?
    private var connecting: Task<any WebSocketConnection, Error>?
    private var streams: [String: AsyncThrowingStream<JSONValue, Error>.Continuation] = [:]
    private var nextStream = 0
    private var closed = false
    private var onClose: (@Sendable () async -> Void)?

    public init(endpoint: DshWebEndpoint, cookie: @escaping @Sendable () -> String,
                transport: any WebSocketTransport = OpenClawWebSocketTransport()) {
        self.endpoint = endpoint
        self.cookie = cookie
        self.transport = transport
    }

    public init(client: DshWebClient, transport: any WebSocketTransport = OpenClawWebSocketTransport()) {
        self.init(endpoint: client.endpoint, cookie: { client.cookieHeader() }, transport: transport)
    }

    public var isConnected: Bool { connection != nil && !closed }

    /// 连接断开（对端关、读失败，不含自己 `close()`）时调一次。
    public func setOnClose(_ handler: (@Sendable () async -> Void)?) {
        onClose = handler
    }

    /// 握手。已连上就直接返回；同时到的几次共用一次握手。关过的 mux 不能再连（新建一个）。
    public func connect() async throws {
        guard !closed else { throw DshWebError.disconnected }
        if connection != nil { return }
        if let connecting { _ = try await connecting.value; return }
        let task = Task { [transport, endpoint, cookie] in
            try await transport.connect(url: endpoint.muxURL, headers: ["Cookie": cookie()])
        }
        connecting = task
        defer { connecting = nil }
        let established: any WebSocketConnection
        do {
            established = try await task.value
        } catch let failed as WebSocketHandshakeFailed where failed.status == 401 || failed.status == 403 {
            throw DshWebError.unauthorized
        }
        guard !closed else {
            established.close()
            throw DshWebError.disconnected
        }
        connection = established
        Task { await self.readLoop(established) }
    }

    /// 开一条流。`args` 是 `payload.args`：`$events` 为 `{}`，`session/follow` 为 `{request:{…}}`。
    public func open(endpoint name: String, args: JSONValue) async throws -> DshWebStream {
        guard let connection, !closed else { throw DshWebError.disconnected }
        nextStream += 1
        let id = "botbus-\(nextStream)"
        let (items, continuation) = AsyncThrowingStream<JSONValue, Error>.makeStream()
        continuation.onTermination = { [weak self] reason in
            // 调用方不迭代了：告诉 dsh 关掉这条流。dsh 自己结束（end / error / 断开）时不用发。
            if case .cancelled = reason { Task { await self?.cancel(id) } }
        }
        streams[id] = continuation
        let frame: JSONValue = ["type": "open", "streamId": .string(id), "endpoint": .string(name), "payload": ["args": args]]
        do {
            try await connection.send(text: frame.encodedString())
        } catch {
            streams.removeValue(forKey: id)?.finish(throwing: DshWebError.disconnected)
            throw DshWebError.disconnected
        }
        return DshWebStream(id: id, items: items)
    }

    /// `$events`：首条是 `ready`，之后是 emit / waterfall / cancel（按 `DshEventsFrame(json:)` 解）。
    public func openEvents() async throws -> DshWebStream {
        try await open(endpoint: "$events", args: [:])
    }

    /// `session/follow`：首帧 snapshot（最近 `maxMessages` 条消息及其间的事件），之后逐条 event（按 `DshFollowFrame(json:)` 解）。
    /// **会让 web 载入这个会话**（之后一直持锁，ACP 的 resume 就会撞锁）；只读历史用 `DshWebClient.page`。
    public func follow(sessionId: String, maxMessages: Int = 50) async throws -> DshWebStream {
        try await open(endpoint: "session/follow", args: ["request": [
            "address": ["kind": "session", "sessionId": .string(sessionId)], "maxMessages": .int(Int64(maxMessages)),
        ]])
    }

    /// 关一条流：从路由表摘掉、正常结束它，并告诉 dsh（连接还在的话）。
    public func cancel(_ streamId: String) async {
        guard let continuation = streams.removeValue(forKey: streamId) else { return }
        continuation.finish()
        guard let connection, !closed else { return }
        let frame: JSONValue = ["type": "cancel", "streamId": .string(streamId)]
        try? await connection.send(text: frame.encodedString())
    }

    /// 保活：发一次 WebSocket ping。失败说明连接已死，读循环随即收尾。
    public func ping() async throws {
        guard let connection, !closed else { throw DshWebError.disconnected }
        try await connection.sendPing()
    }

    /// 主动关：所有流以 `disconnected` 结束，不调 `onClose`。
    public func close() {
        guard !closed else { return }
        closed = true
        connection?.close()
        connection = nil
        finishAll()
    }

    private func readLoop(_ connection: any WebSocketConnection) async {
        while true {
            let text: String
            do {
                text = try await connection.receiveText()
            } catch {
                break
            }
            route(text)
        }
        guard !closed, self.connection === connection else { return }
        closed = true
        self.connection = nil
        connection.close()
        finishAll()
        await onClose?()
    }

    /// 按 `streamId` 分发一帧。认不出的帧、没人要的流直接丢。
    func route(_ text: String) {
        guard let frame = try? JSONValue.decode(text), let id = frame["streamId"]?.stringValue,
              let continuation = streams[id] else { return }
        switch frame["type"]?.stringValue {
        case "item":
            continuation.yield(frame["value"] ?? .null)
        case "error":
            streams.removeValue(forKey: id)
            continuation.finish(throwing: DshWebError.streamFailed(code: frame.path("error", "code")?.stringValue,
                                                                   message: frame.path("error", "message")?.stringValue ?? "流出错了"))
        case "end":
            streams.removeValue(forKey: id)
            continuation.finish()
        default:
            return
        }
    }

    private func finishAll() {
        let all = streams
        streams.removeAll()
        for continuation in all.values { continuation.finish(throwing: DshWebError.disconnected) }
    }
}

extension JSONValue {
    /// 一行紧凑 JSON（WebSocket 文本帧）。编不出来（不会发生：值都来自字面量）时给 `null`。
    func encodedString() -> String {
        (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }

    static func decode(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }
}
