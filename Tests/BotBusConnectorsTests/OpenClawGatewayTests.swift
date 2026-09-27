import Foundation
import XCTest
@testable import BotBusConnectorKit
@testable import BotBusConnectors
import BotBusProtocol

// MARK: - 假 Gateway

/// 按协议 v4 应答的假 Gateway：记下收到的每个请求，按方法给默认应答，测试可随时改剧本或主动推事件。
/// 不开端口、不碰 `~/.openclaw`——连接是内存里的 `ScriptedGatewayConnection`。
final class FakeOpenClawServer: @unchecked Sendable {
    struct Request: Sendable {
        let id: String
        let method: String
        let params: JSONValue?
    }

    typealias Responder = @Sendable (JSONValue?) -> Result<JSONValue, OpenClawGatewayError>

    private let lock = NSLock()
    private var _requests: [Request] = []
    private var _connections: [ScriptedGatewayConnection] = []
    private var _responders: [String: Responder] = [:]

    // 剧本开关
    var sendChallenge = true
    var refuseConnections = false
    var connectError: (code: String, message: String)?
    var helloProtocol: Int64 = 4
    /// 这些方法收到了也不回（测超时、乱序）。
    var silentMethods: Set<String> = []
    var rows: [JSONValue] = []
    var pendingApprovals: [JSONValue] = []
    var history: JSONValue = ["messages": []]
    var createdKey = "agent:main:botbus-1"

    init() {}

    var requests: [Request] { lock.withLock { _requests } }
    var connections: [ScriptedGatewayConnection] { lock.withLock { _connections } }
    var latest: ScriptedGatewayConnection? { connections.last }

    func requests(_ method: String) -> [Request] { requests.filter { $0.method == method } }

    func setResponder(_ method: String, _ responder: @escaping Responder) {
        lock.withLock { _responders[method] = responder }
    }

    func register(_ connection: ScriptedGatewayConnection) {
        lock.withLock { _connections.append(connection) }
        if sendChallenge {
            connection.deliver(["type": "event", "event": "connect.challenge", "payload": ["nonce": "n-1", "ts": 1_737_264_000_000]])
        }
    }

    /// 连接收到一帧请求时调用；返回要回给客户端的帧（nil = 不回）。
    func receive(_ frame: JSONValue) -> JSONValue? {
        guard frame["type"]?.stringValue == "req", let id = frame["id"]?.stringValue,
              let method = frame["method"]?.stringValue else { return nil }
        lock.withLock { _requests.append(Request(id: id, method: method, params: frame["params"])) }
        if method == "connect" {
            if let connectError {
                return Self.failure(id: id, code: connectError.code, message: connectError.message)
            }
            return Self.success(id: id, payload: [
                "type": "hello-ok", "protocol": .int(helloProtocol),
                "server": ["version": "2026.9.6", "connId": "c-1"],
                "features": ["methods": ["sessions.list"], "events": ["chat"]],
                "snapshot": [:],
                "auth": ["role": "operator", "scopes": ["operator.read", "operator.write", "operator.approvals"]],
                "policy": ["maxPayload": 26_214_400, "maxBufferedBytes": 52_428_800, "tickIntervalMs": 15000],
            ])
        }
        if silentMethods.contains(method) { return nil }
        let custom = lock.withLock { _responders[method] }
        let result = custom?(frame["params"]) ?? defaultResponse(method)
        switch result {
        case .success(let payload): return Self.success(id: id, payload: payload)
        case .failure(let error): return Self.failure(id: id, code: error.code ?? "INVALID_REQUEST", message: error.message)
        }
    }

    private func defaultResponse(_ method: String) -> Result<JSONValue, OpenClawGatewayError> {
        switch method {
        case "sessions.subscribe": return .success(["subscribed": true, "list": ["sessions": .array(rows), "hasMore": false]])
        case "sessions.list": return .success(["sessions": .array(rows), "hasMore": false])
        case "exec.approval.list": return .success(.array(pendingApprovals))
        case "sessions.create": return .success(["ok": true, "key": .string(createdKey), "sessionId": "s-new"])
        case "chat.send": return .success(["runId": "run-1", "status": "started"])
        case "chat.abort": return .success(["ok": true, "aborted": true])
        case "exec.approval.resolve": return .success(["ok": true])
        case "chat.history": return .success(history)
        default: return .failure(OpenClawGatewayError(.requestFailed, code: "UNKNOWN_METHOD", message: "unknown method \(method)"))
        }
    }

    static func success(id: String, payload: JSONValue) -> JSONValue {
        ["type": "res", "id": .string(id), "ok": true, "payload": payload]
    }

    static func failure(id: String, code: String, message: String) -> JSONValue {
        ["type": "res", "id": .string(id), "ok": false, "error": ["code": .string(code), "message": .string(message)]]
    }

    /// 往最新那条连接推一个事件。
    func push(_ event: String, _ payload: JSONValue) {
        latest?.deliver(["type": "event", "event": .string(event), "payload": payload, "seq": 1])
    }

    /// 手动回一个之前没回的请求。
    func respond(to request: Request, payload: JSONValue) {
        latest?.deliver(Self.success(id: request.id, payload: payload))
    }
}

/// 内存里的一条 WebSocket：客户端发的帧交给 `FakeOpenClawServer`，应答与事件经 `deliver` 塞回去。
final class ScriptedGatewayConnection: WebSocketConnection, @unchecked Sendable {
    private let server: FakeOpenClawServer
    private let continuation: AsyncStream<Result<String, Error>>.Continuation
    private var iterator: AsyncStream<Result<String, Error>>.Iterator
    let sent = Locked<[JSONValue]>([])
    let closed = Locked(false)

    init(server: FakeOpenClawServer) {
        self.server = server
        var captured: AsyncStream<Result<String, Error>>.Continuation!
        let stream = AsyncStream<Result<String, Error>> { captured = $0 }
        continuation = captured
        iterator = stream.makeAsyncIterator()
    }

    func send(text: String) async throws {
        if closed.current { throw WebSocketClosed(code: 1006, reason: "closed") }
        let frame = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        sent.withLock { $0.append(frame) }
        if let reply = server.receive(frame) { deliver(reply) }
    }

    func receiveText() async throws -> String {
        guard let next = await iterator.next() else { throw WebSocketClosed(code: 1000, reason: "") }
        return try next.get()
    }

    func sendPing() async throws {}

    func close() {
        closed.withLock { $0 = true }
        continuation.finish()
    }

    func deliver(_ frame: JSONValue) {
        let data = try! JSONEncoder().encode(frame)
        continuation.yield(.success(String(decoding: data, as: UTF8.self)))
    }

    func deliverRaw(_ text: String) { continuation.yield(.success(text)) }

    /// 模拟 Gateway 进程退出。
    func dropFromServer(code: Int = 1006) {
        continuation.yield(.failure(WebSocketClosed(code: code, reason: "")))
        continuation.finish()
    }
}

final class FakeOpenClawTransport: WebSocketTransport, @unchecked Sendable {
    let server: FakeOpenClawServer
    let urls = Locked<[URL]>([])

    init(server: FakeOpenClawServer) { self.server = server }

    func connect(url: URL, headers: [String: String]) async throws -> WebSocketConnection {
        urls.withLock { $0.append(url) }
        if server.refuseConnections { throw WebSocketHandshakeFailed(status: nil, underlying: nil) }
        let connection = ScriptedGatewayConnection(server: server)
        server.register(connection)
        return connection
    }
}

// MARK: - 测试

final class OpenClawGatewayTests: XCTestCase {
    private func makeGateway(_ server: FakeOpenClawServer, token: String? = "secret-token", password: String? = nil,
                             requestTimeout: TimeInterval = 2, challengeTimeout: TimeInterval = 1) -> OpenClawGateway {
        OpenClawGateway(transport: FakeOpenClawTransport(server: server),
                        configuration: .init(url: URL(string: "ws://127.0.0.1:18789")!, token: token, password: password,
                                             clientVersion: "1.2.3", requestTimeout: requestTimeout,
                                             connectTimeout: 2, challengeTimeout: challengeTimeout, pingInterval: 0))
    }

    func testHandshakeWaitsForChallengeThenSendsConnect() async throws {
        let server = FakeOpenClawServer()
        let gateway = makeGateway(server)
        let hello = try await gateway.connect()

        XCTAssertEqual(hello["type"]?.stringValue, "hello-ok")
        let connected = await gateway.isConnected
        XCTAssertTrue(connected)
        // 第一帧必须是 connect。
        let first = try XCTUnwrap(server.latest?.sent.current.first)
        XCTAssertEqual(first["method"]?.stringValue, "connect")
        let params = try XCTUnwrap(first["params"])
        XCTAssertEqual(params["minProtocol"]?.intValue, 4)
        XCTAssertEqual(params["maxProtocol"]?.intValue, 4)
        XCTAssertEqual(params.path("client", "id")?.stringValue, "gateway-client")
        XCTAssertEqual(params.path("client", "mode")?.stringValue, "backend")
        XCTAssertEqual(params.path("client", "platform")?.stringValue, "macos")
        XCTAssertEqual(params.path("client", "version")?.stringValue, "1.2.3")
        XCTAssertEqual(params["role"]?.stringValue, "operator")
        XCTAssertEqual(params["scopes"]?.arrayValue?.compactMap(\.stringValue),
                       ["operator.read", "operator.write", "operator.approvals"])
        XCTAssertEqual(params["caps"]?.arrayValue?.compactMap(\.stringValue), ["tool-events", "exec-approvals"])
        XCTAssertEqual(params.path("auth", "token")?.stringValue, "secret-token")
        XCTAssertNil(params.path("auth", "password"))
        // ConnectParams 是闭合对象：只能发 schema 里有的键。
        let allowed: Set<String> = ["minProtocol", "maxProtocol", "client", "caps", "commands", "permissions", "pathEnv",
                                    "role", "scopes", "device", "auth", "locale", "userAgent"]
        XCTAssertTrue(Set(params.objectValue!.keys).isSubset(of: allowed))
        XCTAssertTrue(Set(params["client"]!.objectValue!.keys)
            .isSubset(of: ["id", "displayName", "version", "buildId", "platform", "deviceFamily", "modelIdentifier",
                           "timeZone", "mode", "instanceId"]))
    }

    func testHandshakeProceedsWithoutChallengeAndOmitsEmptyAuth() async throws {
        let server = FakeOpenClawServer()
        server.sendChallenge = false
        let gateway = makeGateway(server, token: nil, challengeTimeout: 0.1)
        try await gateway.connect()
        let params = try XCTUnwrap(server.requests("connect").first?.params)
        XCTAssertNil(params["auth"])
    }

    func testPasswordIsSentWhenConfigured() async throws {
        let server = FakeOpenClawServer()
        let gateway = makeGateway(server, token: nil, password: "pw")
        try await gateway.connect()
        let params = try XCTUnwrap(server.requests("connect").first?.params)
        XCTAssertEqual(params.path("auth", "password")?.stringValue, "pw")
        XCTAssertNil(params.path("auth", "token"))
    }

    func testAuthFailureSurfacesChineseMessage() async {
        let server = FakeOpenClawServer()
        server.connectError = ("AUTH_TOKEN_MISMATCH", "unauthorized: gateway token mismatch")
        let gateway = makeGateway(server)
        do {
            try await gateway.connect()
            XCTFail("应当被拒")
        } catch let error as OpenClawGatewayError {
            XCTAssertEqual(error.kind, .rejected)
            XCTAssertEqual(error.code, "AUTH_TOKEN_MISMATCH")
            XCTAssertEqual(error.message, "OpenClaw Gateway 拒绝了连接：unauthorized: gateway token mismatch")
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
        let connected = await gateway.isConnected
        XCTAssertFalse(connected)
        XCTAssertEqual(server.latest?.closed.current, true)
    }

    func testProtocolMismatchIsReported() async {
        let server = FakeOpenClawServer()
        server.helloProtocol = 5
        let gateway = makeGateway(server)
        do {
            try await gateway.connect()
            XCTFail("版本不符应当失败")
        } catch let error as OpenClawGatewayError {
            XCTAssertEqual(error.kind, .protocolMismatch)
            XCTAssertTrue(error.message.contains("v5"))
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
    }

    func testUnreachableGateway() async {
        let server = FakeOpenClawServer()
        server.refuseConnections = true
        let gateway = makeGateway(server)
        do {
            try await gateway.connect()
            XCTFail("应当连不上")
        } catch let error as OpenClawGatewayError {
            XCTAssertEqual(error.kind, .unreachable)
            XCTAssertEqual(error.message, "连不上 OpenClaw Gateway（127.0.0.1:18789）")
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
    }

    func testRequestBeforeConnectThrowsNotConnected() async {
        let gateway = makeGateway(FakeOpenClawServer())
        do {
            _ = try await gateway.request("sessions.list")
            XCTFail("没握手不能发请求")
        } catch let error as OpenClawGatewayError {
            XCTAssertEqual(error.kind, .notConnected)
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
    }

    func testResponsesAreMatchedByIdEvenOutOfOrder() async throws {
        let server = FakeOpenClawServer()
        server.silentMethods = ["first", "second"]
        let gateway = makeGateway(server)
        try await gateway.connect()

        async let a = gateway.request("first")
        async let b = gateway.request("second")
        await assertEventually { server.requests("first").count == 1 && server.requests("second").count == 1 }
        let first = server.requests("first")[0]
        let second = server.requests("second")[0]
        XCTAssertNotEqual(first.id, second.id)
        // 先回第二个，再回第一个。
        server.respond(to: second, payload: ["which": "second"])
        server.respond(to: first, payload: ["which": "first"])
        let (resultA, resultB) = try await (a, b)
        XCTAssertEqual(resultA["which"]?.stringValue, "first")
        XCTAssertEqual(resultB["which"]?.stringValue, "second")
    }

    func testErrorResponseBecomesRequestFailed() async throws {
        let server = FakeOpenClawServer()
        server.setResponder("sessions.create") { _ in
            .failure(OpenClawGatewayError(.requestFailed, code: "FORBIDDEN", message: "missing scope: operator.admin"))
        }
        let gateway = makeGateway(server)
        try await gateway.connect()
        do {
            _ = try await gateway.request("sessions.create", params: ["cwd": "/tmp"])
            XCTFail("应当失败")
        } catch let error as OpenClawGatewayError {
            XCTAssertEqual(error.kind, .requestFailed)
            XCTAssertEqual(error.code, "FORBIDDEN")
            XCTAssertEqual(error.message, "missing scope: operator.admin")
        }
    }

    func testRequestTimesOutAndLateReplyIsIgnored() async throws {
        let server = FakeOpenClawServer()
        server.silentMethods = ["slow"]
        let gateway = makeGateway(server, requestTimeout: 0.1)
        try await gateway.connect()
        do {
            _ = try await gateway.request("slow")
            XCTFail("应当超时")
        } catch let error as OpenClawGatewayError {
            XCTAssertEqual(error.kind, .timedOut)
        }
        // 迟到的应答没人认领，不能出事；连接照常可用。
        server.respond(to: server.requests("slow")[0], payload: ["late": true])
        let list = try await gateway.request("sessions.list")
        XCTAssertNotNil(list["sessions"])
    }

    func testEventsAreForwardedAndDisconnectFailsInFlight() async throws {
        let server = FakeOpenClawServer()
        server.silentMethods = ["slow"]
        let gateway = makeGateway(server)
        try await gateway.connect()

        let received = Locked<[String]>([])
        let consumer = Task {
            for await event in gateway.events {
                switch event {
                case .event(let name, _): received.withLock { $0.append(name) }
                case .disconnected: received.withLock { $0.append("<disconnected>") }
                }
            }
            received.withLock { $0.append("<end>") }
        }
        server.push("tick", ["ts": 1])
        server.latest?.deliverRaw("not json")
        server.latest?.deliver(["type": "mystery"])
        server.push("chat", ["sessionKey": "agent:main:main", "runId": "r", "state": "delta", "seq": 1])
        await assertEventually { received.current == ["tick", "chat"] }

        async let pending = gateway.request("slow")
        await assertEventually { server.requests("slow").count == 1 }
        server.latest?.dropFromServer()
        do {
            _ = try await pending
            XCTFail("断线后在途请求应当失败")
        } catch let error as OpenClawGatewayError {
            XCTAssertEqual(error.kind, .closed)
        }
        await assertEventually { received.current == ["tick", "chat", "<disconnected>", "<end>"] }
        consumer.cancel()
        let connected = await gateway.isConnected
        XCTAssertFalse(connected)
    }

    func testCloseEndsEventStream() async throws {
        let server = FakeOpenClawServer()
        let gateway = makeGateway(server)
        try await gateway.connect()
        await gateway.close()
        var events: [OpenClawGateway.Event] = []
        for await event in gateway.events { events.append(event) }
        XCTAssertEqual(events.count, 1)
        if case .disconnected = events.first {} else { XCTFail("最后一个事件应是 disconnected") }
        XCTAssertEqual(server.latest?.closed.current, true)
    }
}
