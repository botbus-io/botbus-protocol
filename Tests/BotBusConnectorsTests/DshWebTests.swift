#if canImport(CryptoKit)
import CryptoKit
#endif
import XCTest
@testable import BotBusConnectorKit
@testable import BotBusConnectors

/// 全是编的数据：密钥是 0…31 这 32 个字节，不是任何真实的 dsh 密钥。
final class DshWebAuthTests: XCTestCase {
    static let syntheticSecret = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"

    private func yaml(secret: String = syntheticSecret, key: String = "client-connection/browser-session") -> String {
        """
        version: 1
        records:
          \(key):
            kind: grant
            payload:
              version: 1
              secret: \(secret)
        refs:
          DEEPSEEK_API_KEY: sk-not-a-real-key
        """
    }

    private func bytes(_ key: SymmetricKey?) -> [UInt8]? {
        key?.withUnsafeBytes { Array($0) }
    }

    func testReadsBrowserSessionSecret() {
        XCTAssertEqual(bytes(DshWebCredentials.browserSessionSecret(yaml: yaml())), Array(0..<32))
    }

    func testQuotedKeysAndValuesAreAccepted() {
        let text = """
        records:
          "client-connection/browser-session":
            payload:
              secret: '\(Self.syntheticSecret)'
        """
        XCTAssertEqual(bytes(DshWebCredentials.browserSessionSecret(yaml: text)), Array(0..<32))
    }

    func testRejectsWrongShapes() {
        // 别的记录里的 secret 不算。
        XCTAssertNil(DshWebCredentials.browserSessionSecret(yaml: yaml(key: "something/else")))
        // 不是 32 字节、带 padding、不是 base64url。
        XCTAssertNil(DshWebCredentials.browserSessionSecret(yaml: yaml(secret: "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHg")))
        XCTAssertNil(DshWebCredentials.browserSessionSecret(yaml: yaml(secret: Self.syntheticSecret + "=")))
        XCTAssertNil(DshWebCredentials.browserSessionSecret(yaml: yaml(secret: "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwd+h8")))
        // secret 不在 payload 下面。
        let misplaced = """
        records:
          client-connection/browser-session:
            secret: \(Self.syntheticSecret)
            payload:
              version: 1
        """
        XCTAssertNil(DshWebCredentials.browserSessionSecret(yaml: misplaced))
        XCTAssertNil(DshWebCredentials.browserSessionSecret(yaml: ""))
    }

    func testLoadFromMissingFileIsNil() {
        let paths = DshPaths(home: FileManager.default.temporaryDirectory.appendingPathComponent("no-dsh-\(UUID().uuidString)"))
        XCTAssertNil(DshWebCredentials.loadBrowserSessionSecret(paths: paths))
    }

    /// 向量用 node 按 dsh 的算法（`dsh-client-connection` 的 `encodeCookie`）现算的，密钥是上面的假密钥。
    func testCookieMatchesNodeVector() throws {
        let secret = try XCTUnwrap(DshWebCredentials.browserSessionSecret(yaml: yaml()))
        XCTAssertEqual(DshWebCookie.name(authority: "127.0.0.1:3181"), "dsh-auth-D1gu4AUZ6XwohD5r0eN4-fmFNLAOCeA62Dj465JieJs")
        XCTAssertEqual(DshWebCookie.value(secret: secret, authority: "127.0.0.1:3181",
                                          issuedAtMs: 1_790_000_000_000, expiresAtMs: 1_790_003_600_000),
                       "v1.eyJ2ZXJzaW9uIjoxLCJhdXRob3JpdHkiOiIxMjcuMC4wLjE6MzE4MSIsImlzc3VlZEF0IjoxNzkwMDAwMDAwMDAwLCJleHBpcmVzQXQiOjE3OTAwMDM2MDAwMDB9.DFxOWiL0d2udvGmnOuXL5CscTtqypVgodxy-pwjzwWU")
    }

    func testCookieHeaderIssuesSlightlyInThePast() throws {
        let secret = try XCTUnwrap(DshWebCredentials.browserSessionSecret(yaml: yaml()))
        let now = Date(timeIntervalSince1970: 1_790_000_005)
        let header = DshWebCookie.header(secret: secret, authority: "127.0.0.1:3181", now: now)
        XCTAssertEqual(header, "dsh-auth-D1gu4AUZ6XwohD5r0eN4-fmFNLAOCeA62Dj465JieJs="
                       + DshWebCookie.value(secret: secret, authority: "127.0.0.1:3181",
                                            issuedAtMs: 1_790_000_000_000, expiresAtMs: 1_790_003_600_000))
    }
}

/// 记下请求、按剧本回应的假 HTTP。
final class FakeDshHTTP: DshHTTPTransport, @unchecked Sendable {
    let requests = Locked<[(url: URL, headers: [String: String], body: JSONValue)]>([])
    var respond: @Sendable (_ method: String, _ body: JSONValue) -> (Int, JSONValue) = { _, _ in
        (200, ["type": "server-response", "result": ["ok": true, "value": [:]]])
    }

    func post(_ url: URL, headers: [String: String], body: Data) async throws -> (status: Int, body: Data) {
        let json = try JSONDecoder().decode(JSONValue.self, from: body)
        requests.withLock { $0.append((url, headers, json)) }
        let (status, response) = respond(json["method"]?.stringValue ?? "", json)
        return (status, try JSONEncoder().encode(response))
    }
}

final class DshWebClientTests: XCTestCase {
    private let secret = SymmetricKey(data: Data(0..<32))

    private func client(_ http: FakeDshHTTP) -> DshWebClient {
        DshWebClient(endpoint: DshWebEndpoint(port: 3181), secret: secret, http: http,
                     now: { Date(timeIntervalSince1970: 1_790_000_005) })
    }

    private static func ok(_ value: JSONValue) -> (Int, JSONValue) {
        (200, ["type": "server-response", "rpcId": "x", "result": ["ok": true, "value": value]])
    }

    func testEnvelopeAndArgumentNames() async throws {
        let http = FakeDshHTTP()
        http.respond = { method, _ in
            method == "session/list" ? Self.ok(["items": []]) : Self.ok(["accepted": true])
        }
        let web = client(http)
        _ = try await web.listSessions()
        try await web.prompt(sessionId: "session-1", text: "你好", requestId: "q1")
        try await web.answerApproval(clientId: "c1", eventId: "e1", allow: true)
        let sent = http.requests.current
        XCTAssertEqual(sent.map(\.url.absoluteString), [
            "http://127.0.0.1:3181/api/session/list", "http://127.0.0.1:3181/api/session/prompt",
            "http://127.0.0.1:3181/api/$events/result",
        ])
        XCTAssertEqual(sent[0].body["type"], "client-request")
        XCTAssertEqual(sent[0].body["method"], "session/list")
        XCTAssertEqual(sent[0].body.path("payload", "args"), ["_request": [:]])
        XCTAssertEqual(sent[1].body.path("payload", "args", "request"), [
            "requestId": "q1", "sessionId": "session-1", "mode": "queue",
            "content": [["type": "text", "text": "你好"]],
        ])
        XCTAssertEqual(sent[2].body.path("payload", "args"), [
            "clientId": "c1", "eventId": "e1", "outcome": ["kind": "result", "value": "allowed-once"],
        ])
        XCTAssertTrue(sent[0].headers["Cookie"]?.hasPrefix("dsh-auth-D1gu4AUZ6XwohD5r0eN4-fmFNLAOCeA62Dj465JieJs=v1.") == true)
        XCTAssertEqual(sent[0].headers["Content-Type"], "application/json")
        XCTAssertNil(sent[0].headers["Origin"])
    }

    func testAnswerQuestionsShape() async throws {
        let http = FakeDshHTTP()
        try await client(http).answerQuestions(clientId: "c1", eventId: "e2", answers: ["color": ["红"]])
        XCTAssertEqual(http.requests.current.first?.body.path("payload", "args", "outcome"), [
            "kind": "result", "value": ["answers": [["id": "color", "selected": ["红"]]]],
        ])
    }

    func testErrors() async {
        let http = FakeDshHTTP()
        http.respond = { method, _ in
            switch method {
            case "session/cancel": (401, "Unauthorized")
            case "session/prompt": (200, ["type": "server-response", "result": ["ok": false,
                                                                                "error": ["code": "session/busy", "message": "忙"]]])
            case "session/page": (500, "boom")
            default: (200, "not an envelope")
            }
        }
        let web = client(http)
        await XCTAssertThrowsDshError(try await web.cancel(sessionId: "s"), .unauthorized)
        await XCTAssertThrowsDshError(try await web.prompt(sessionId: "s", text: "x"), .remote(code: "session/busy", message: "忙"))
        await XCTAssertThrowsDshError(try await web.page(sessionId: "s", throughSeq: 3), .httpStatus(500))
        await XCTAssertThrowsDshError(try await web.listSessions(), .malformedResponse(method: "session/list"))
        XCTAssertTrue(DshWebError.remote(code: nil, message: "x").containsPrivateDetail)
        XCTAssertFalse(DshWebError.unauthorized.containsPrivateDetail)
        XCTAssertEqual(DshWebError.remote(code: "a", message: "秘密").logCategory, "remote a")
    }

    func testListSessionsDecodesSummaries() async throws {
        let http = FakeDshHTTP()
        http.respond = { _, _ in Self.ok(["items": [
            ["sessionId": "session-a", "updatedAt": 1_790_486_223_592, "running": true, "blank": false, "cwd": "/Users/me/app",
             "projections": ["asOfSeq": 31, "values": ["title": "修一个 bug"]]],
            ["sessionId": "child", "updatedAt": 1_790_486_000_000, "running": false, "blank": false, "cwd": "/Users/me/app",
             "parentSessionId": "session-a", "origin": "subagent"],
            ["sessionId": "", "running": false],
        ]]) }
        let items = try await client(http).listSessions()
        XCTAssertEqual(items.map(\.sessionId), ["session-a", "child"])
        XCTAssertEqual(items[0].title, "修一个 bug")
        XCTAssertEqual(items[0].asOfSeq, 31)
        XCTAssertEqual(items[0].running, true)
        XCTAssertEqual(items[0].updatedAt, Date(timeIntervalSince1970: 1_790_486_223.592))
        XCTAssertFalse(items[0].isSubagent)
        XCTAssertTrue(items[1].isSubagent)
    }

    func testLatestPageRecoversTheRealCursor() async throws {
        let http = FakeDshHTTP()
        http.respond = { _, body in
            let through = body.path("payload", "args", "request", "throughSeq")?.intValue
            if through == DshWebClient.probeSeq {
                return (200, ["type": "server-response", "result": ["ok": false, "error": [
                    "code": "gateway/bad-request", "message": "session page through seq 9007199254740991 is past cursor 16"]]])
            }
            return Self.ok(["records": [], "hasMore": false])
        }
        _ = try await client(http).latestPage(sessionId: "s", maxMessages: 5)
        XCTAssertEqual(http.requests.current.map { $0.body.path("payload", "args", "request", "throughSeq") }, [
            .int(DshWebClient.probeSeq), 16,
        ])
        XCTAssertEqual(DshWebClient.cursor(fromPastCursorMessage: "session page through seq 5 is past cursor -1"), -1)
        XCTAssertNil(DshWebClient.cursor(fromPastCursorMessage: "something else"))
    }

    func testPageRequestAndRecords() async throws {
        let http = FakeDshHTTP()
        http.respond = { _, _ in Self.ok(["records": [
            ["type": "event", "event": ["type": "user/message", "seq": 9, "time": 1_790_486_223_655,
                                        "data": ["content": [["type": "text", "text": "嗨"]], "source": ["kind": "user"]]]],
            ["type": "something-else"],
        ], "hasMore": true]) }
        let (events, hasMore) = try await client(http).page(sessionId: "session-a", throughSeq: 31, maxMessages: 20)
        XCTAssertEqual(events.map(\.seq), [9])
        XCTAssertEqual(events.first?.text, "嗨")
        XCTAssertTrue(hasMore)
        XCTAssertEqual(http.requests.current.first?.body.path("payload", "args", "request"), [
            "address": ["kind": "session", "sessionId": "session-a"], "throughSeq": 31, "maxMessages": 20,
        ])
    }
}

func XCTAssertThrowsDshError<T>(_ body: @autoclosure () async throws -> T, _ expected: DshWebError,
                                file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await body()
        XCTFail("应当抛 \(expected)", file: file, line: line)
    } catch let error as DshWebError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("抛了别的错误：\(error)", file: file, line: line)
    }
}

final class DshWebMuxTests: XCTestCase {
    private func connectedMux() async throws -> (DshWebMux, FakeTransport) {
        let transport = FakeTransport()
        let mux = DshWebMux(endpoint: DshWebEndpoint(port: 3181), cookie: { "dsh-auth-x=v1.a.b" }, transport: transport)
        try await mux.connect()
        return (mux, transport)
    }

    private func frame(_ text: String) throws -> JSONValue { try JSONValue.decode(text) }

    func testHandshakeCarriesCookieOnly() async throws {
        let (_, transport) = try await connectedMux()
        XCTAssertEqual(transport.headers, [["Cookie": "dsh-auth-x=v1.a.b"]])
    }

    func testRoutesItemsByStreamAndEnds() async throws {
        let (mux, transport) = try await connectedMux()
        let events = try await mux.openEvents()
        let follow = try await mux.follow(sessionId: "session-a", maxMessages: 10)
        let connection = try XCTUnwrap(transport.connections.first)
        let sent = try connection.sent.current.map(frame)
        XCTAssertEqual(sent[0], ["type": "open", "streamId": .string(events.id), "endpoint": "$events", "payload": ["args": [:]]])
        XCTAssertEqual(sent[1]["endpoint"], "session/follow")
        XCTAssertEqual(sent[1].path("payload", "args", "request"), [
            "address": ["kind": "session", "sessionId": "session-a"], "maxMessages": 10,
        ])

        connection.deliver(#"{"type":"item","streamId":"\#(events.id)","value":{"type":"ready","clientId":"c1","host":{"home":"/Users/me"}}}"#)
        connection.deliver(#"{"type":"item","streamId":"nobody","value":1}"#)
        connection.deliver(#"{"type":"item","streamId":"\#(follow.id)","value":{"type":"snapshot","header":{"id":"session-a","createdAt":1,"cwd":"/x","isSeeded":false,"delegationDepth":0},"cursor":5,"records":[],"hasMore":false}}"#)
        connection.deliver(#"{"type":"end","streamId":"\#(follow.id)"}"#)

        var eventIterator = events.items.makeAsyncIterator()
        let first = try await eventIterator.next()
        XCTAssertEqual(first.map(DshEventsFrame.init(json:)), .ready(clientId: "c1", home: "/Users/me"))

        var followed: [DshFollowFrame] = []
        for try await item in follow.items { followed.append(DshFollowFrame(json: item)) }
        XCTAssertEqual(followed.count, 1, "end 之后流正常结束")
        guard case .snapshot(let header, let cursor, _, _) = followed.first else { return XCTFail("应当是 snapshot") }
        XCTAssertEqual(header?.id, "session-a")
        XCTAssertEqual(cursor, 5)
    }

    func testErrorFrameFailsOnlyThatStream() async throws {
        let (mux, transport) = try await connectedMux()
        let stream = try await mux.open(endpoint: "session/follow", args: [:])
        let connection = try XCTUnwrap(transport.connections.first)
        connection.deliver(#"{"type":"error","streamId":"\#(stream.id)","error":{"code":"session/not-found","message":"没有","details":{}}}"#)
        do {
            for try await _ in stream.items {}
            XCTFail("应当抛错")
        } catch let error as DshWebError {
            XCTAssertEqual(error, .streamFailed(code: "session/not-found", message: "没有"))
        }
        let connected = await mux.isConnected
        XCTAssertTrue(connected)
    }

    func testDisconnectFailsAllStreamsAndNotifies() async throws {
        let (mux, transport) = try await connectedMux()
        let closed = Locked(0)
        await mux.setOnClose { closed.withLock { $0 += 1 } }
        let stream = try await mux.openEvents()
        try XCTUnwrap(transport.connections.first).closeFromServer(code: 1006)
        do {
            for try await _ in stream.items {}
            XCTFail("应当抛错")
        } catch let error as DshWebError {
            XCTAssertEqual(error, .disconnected)
        }
        await assertEventually { closed.current == 1 }
        let connected = await mux.isConnected
        XCTAssertFalse(connected)
        await XCTAssertThrowsDshError(try await mux.openEvents(), .disconnected)
    }

    func testConsumerCancellationSendsCancel() async throws {
        let (mux, transport) = try await connectedMux()
        let stream = try await mux.openEvents()
        let connection = try XCTUnwrap(transport.connections.first)
        let reader = Task { for try await _ in stream.items {} }
        reader.cancel()
        await assertEventually {
            connection.sent.current.contains { (try? JSONValue.decode($0)) == ["type": "cancel", "streamId": .string(stream.id)] }
        }
    }

    func testUnauthorizedHandshake() async {
        let transport = FakeTransport(plans: [.reject(status: 401)])
        let mux = DshWebMux(endpoint: DshWebEndpoint(port: 3181), cookie: { "c" }, transport: transport)
        await XCTAssertThrowsDshError(try await mux.connect(), .unauthorized)
    }
}

final class DshWebMessagesTests: XCTestCase {
    func testEventsFrames() {
        let emit = DshEventsFrame(json: ["type": "emit", "event": "api-session/status", "args": ["session-a", true]])
        XCTAssertEqual(emit, .emit(.status(sessionId: "session-a", running: true)))
        let added = DshEventsFrame(json: ["type": "emit", "event": "api-session/added",
                                          "args": [["sessionId": "session-b", "running": false, "blank": true, "cwd": "/x"]]])
        guard case .emit(.added(let summary)) = added else { return XCTFail("\(added)") }
        XCTAssertTrue(summary.blank)
        XCTAssertEqual(DshEventsFrame(json: ["type": "emit", "event": "api-session/removed", "args": ["session-b"]]),
                       .emit(.removed(sessionId: "session-b")))
        XCTAssertEqual(DshEventsFrame(json: ["type": "emit", "event": "api-session/activity", "args": ["s", 1_000]]),
                       .emit(.activity(sessionId: "s", at: Date(timeIntervalSince1970: 1))))
        XCTAssertEqual(DshEventsFrame(json: ["type": "emit", "event": "settings/document-updated", "args": ["x", 1]]),
                       .emit(.other(event: "settings/document-updated")))
        XCTAssertEqual(DshEventsFrame(json: ["type": "cancel", "eventId": "e1"]), .cancel(eventId: "e1"))
        XCTAssertEqual(DshEventsFrame(json: ["type": "mystery"]), .other("mystery"))
    }

    func testWaterfalls() {
        let approval = DshEventsFrame(json: ["type": "waterfall", "event": "approval/request", "eventId": "e1", "agentId": "session-a",
                                             "request": ["toolName": "bash", "callId": "call_1", "reason": "escalate sandbox"]])
        XCTAssertEqual(approval, .waterfall(DshWaterfall(eventId: "e1", sessionId: "session-a",
                                                         request: .approval(toolName: "bash", callId: "call_1", reason: "escalate sandbox"))))
        let questions = DshEventsFrame(json: ["type": "waterfall", "event": "user-questions/request", "eventId": "e2", "agentId": "s",
                                              "request": ["questions": [["id": "color", "question": "喜欢哪种颜色？",
                                                                         "options": [["label": "红"], ["label": "蓝"]], "multiSelect": true]]]])
        XCTAssertEqual(questions, .waterfall(DshWaterfall(eventId: "e2", sessionId: "s", request: .questions([
            DshQuestion(id: "color", question: "喜欢哪种颜色？", options: ["红", "蓝"], multiSelect: true),
        ]))))
        XCTAssertEqual(DshEventsFrame(json: ["type": "waterfall", "event": "approval/request"]), .other("waterfall"))
    }

    func testTurnEndReasons() {
        func reason(_ json: JSONValue) -> DshTurnEndReason? {
            DshSessionEvent(json: ["type": "turn/end", "seq": 1, "time": 0, "data": ["turn": 1, "reason": json]])?.turnEndReason
        }
        XCTAssertEqual(reason(["kind": "completed"])?.status, .completed)
        XCTAssertEqual(reason(["kind": "aborted", "reason": ["kind": "user"]])?.status, .interrupted)
        XCTAssertEqual(reason(["kind": "interrupted"])?.status, .interrupted)
        XCTAssertEqual(reason(["kind": "error", "error": ["message": "Model not exist."]]), .error(message: "Model not exist."))
        XCTAssertEqual(reason(["kind": "error"])?.status, .failed)
        XCTAssertEqual(reason(["kind": "blocked"])?.status, .failed)
        XCTAssertEqual(reason(["kind": "max-tokens"])?.status, .failed)
        XCTAssertEqual(reason(["kind": "new-kind"]), .other("new-kind"))
    }

    func testHeaderAndSubagent() {
        let header = DshSessionHeader(json: ["type": "session", "version": 3, "id": "child", "createdAt": 1_000, "cwd": "/x",
                                             "parentSession": "session-a", "origin": "subagent", "delegationDepth": 1, "isSeeded": false])
        XCTAssertEqual(header?.isSubagent, true)
        XCTAssertEqual(header?.createdAt, Date(timeIntervalSince1970: 1))
        let fork = DshSessionHeader(json: ["type": "session", "id": "fork", "createdAt": 1, "parentSession": "session-a",
                                           "isSeeded": true, "delegationDepth": 0])
        XCTAssertEqual(fork?.isSubagent, false, "fork 照常列")
        XCTAssertNil(DshSessionHeader(json: ["type": "turn/start", "id": "x"]))
        XCTAssertNil(DshSessionEvent(json: ["type": "session", "seq": 0, "id": "x"]))
    }
}

final class DshWebLocatorTests: XCTestCase {
    private let paths = DshPaths(home: URL(fileURLWithPath: "/Users/me/.dsh"))

    func testRecognisesDshWebCommandLines() {
        let yes: [[String]] = [
            ["node", "/Users/me/.npm/_npx/1e7f/node_modules/.bin/dsh", "web", "--port", "3181", "--no-open"],
            ["node", "/Users/me/.npm/_npx/1e7f/node_modules/@deepseek-ai/dsh/lib/bin.js", "web"],
            ["/opt/homebrew/bin/dsh", "--profile", "web"],
            ["dsh", "--profile=web"],
            ["/usr/local/bin/node", "/usr/local/bin/dsh", "--verbose", "web"],
        ]
        let no: [[String]] = [
            ["npm", "exec", "@deepseek-ai/dsh", "web"],
            ["node", "/Users/me/.npm/_npx/1e7f/node_modules/.bin/dsh", "--profile", "acp"],
            ["node", "/Users/me/.npm/_npx/1e7f/node_modules/.bin/dsh"],
            ["node", "/Users/me/.npm/_npx/1e7f/node_modules/.bin/dsh", "plugin", "web"],
            ["node", "/Users/me/web/server.js", "web"],
            ["/bin/zsh", "-c", "dsh web"],
        ]
        for argv in yes { XCTAssertTrue(DshWebLocator.isDshWeb(arguments: argv), "\(argv)") }
        for argv in no { XCTAssertFalse(DshWebLocator.isDshWeb(arguments: argv), "\(argv)") }
    }

    func testDshHomeFilter() {
        XCTAssertTrue(DshWebLocator.usesHome(environment: ["HOME": "/Users/me"], paths: paths))
        XCTAssertTrue(DshWebLocator.usesHome(environment: ["HOME": "/Users/me/", "DSH_HOME": ""], paths: paths))
        XCTAssertTrue(DshWebLocator.usesHome(environment: ["DSH_HOME": "/Users/me/.dsh/"], paths: paths))
        XCTAssertFalse(DshWebLocator.usesHome(environment: ["DSH_HOME": "/tmp/other-dsh"], paths: paths))
        // 没设 DSH_HOME 的进程用的是默认主目录：我们指向别的主目录时不能连它。
        XCTAssertFalse(DshWebLocator.usesHome(environment: ["HOME": "/Users/me"], paths: DshPaths(home: URL(fileURLWithPath: "/tmp/lab"))))
        XCTAssertTrue(DshWebLocator.usesHome(environment: ["DSH_HOME": "/tmp/lab"], paths: DshPaths(home: URL(fileURLWithPath: "/tmp/lab"))))
        // 没有 HOME 时按本用户的主目录。
        let mine = DshPaths(home: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dsh"))
        XCTAssertTrue(DshWebLocator.usesHome(environment: [:], paths: mine))
    }

    func testDesktopHostIsLocatedWithoutAcceptingCliOrOtherHomes() {
        let host = "/Applications/DeepSeek Harness.app/Contents/Resources/app.asar/dsh/node_modules/@deepseek-ai/dsh-desktop-host/lib/index.js"
        let cli = host.replacingOccurrences(of: "index.js", with: "cli.js")
        let listing = FakeListing(list: [
            DshProcessInfo(pid: 1, arguments: ["Electron", host, "/runtime", "/project"], environment: ["HOME": "/Users/me"]),
            DshProcessInfo(pid: 2, arguments: ["Electron", host], environment: ["DSH_HOME": "/other"]),
            DshProcessInfo(pid: 3, arguments: ["Electron", cli, "--profile", "acp"], environment: ["HOME": "/Users/me"]),
        ], ports: [1: [19387], 2: [19388], 3: [19389]])
        XCTAssertEqual(DshWebLocator.locate(paths: paths, listing: listing), [DshWebInstance(pid: 1, ports: [19387], isDesktopHost: true)])
    }

    private struct FakeListing: DshProcessListing {
        var list: [DshProcessInfo]
        var ports: [Int32: [Int]]
        func processes() -> [DshProcessInfo] { list }
        func listeningPorts(pid: Int32) -> [Int] { ports[pid] ?? [] }
    }

    func testDesktopHostIsPreferredOverOlderStandaloneWebInSameHome() {
        let listing = FakeListing(list: [
            DshProcessInfo(pid: 1, arguments: ["dsh", "web"], environment: ["HOME": "/Users/me"]),
            DshProcessInfo(pid: 9, arguments: ["Electron", "/x/@deepseek-ai/dsh-desktop-host/lib/index.js"],
                           environment: ["HOME": "/Users/me"]),
        ], ports: [1: [3181], 9: [19387]])
        let found = DshWebLocator.locate(paths: DshPaths(home: URL(fileURLWithPath: "/Users/me/.dsh")), listing: listing)
        XCTAssertEqual(found.map(\.pid), [9, 1])
    }

    func testLocateFiltersAndSortsByPid() {
        let web = ["node", "/x/node_modules/.bin/dsh", "web"]
        let listing = FakeListing(list: [
            DshProcessInfo(pid: 900, arguments: web, environment: ["HOME": "/Users/me"]),
            DshProcessInfo(pid: 300, arguments: web, environment: ["HOME": "/Users/me", "DSH_HOME": "/tmp/lab"]),
            DshProcessInfo(pid: 500, arguments: ["npm", "exec", "@deepseek-ai/dsh", "web"], environment: ["HOME": "/Users/me"]),
            DshProcessInfo(pid: 400, arguments: web, environment: ["HOME": "/Users/me"]),
            DshProcessInfo(pid: 200, arguments: web, environment: ["HOME": "/Users/me"]),
        ], ports: [900: [3080], 300: [3181], 500: [9999], 400: [3090, 3091]])
        let found = DshWebLocator.locate(paths: paths, listing: listing)
        XCTAssertEqual(found, [DshWebInstance(pid: 400, ports: [3090, 3091]), DshWebInstance(pid: 900, ports: [3080])],
                       "别的 DSH_HOME、npm 父进程、没在监听的都不要")
        XCTAssertEqual(found.first?.endpoints.first?.authority, "127.0.0.1:3090")
    }

    func testParseProcArgs() {
        var bytes: [UInt8] = []
        withUnsafeBytes(of: Int32(3).littleEndian) { bytes += $0 }
        bytes += Array("/usr/local/bin/node".utf8) + [0, 0, 0]
        for part in ["node", "/x/dsh", "web", "PATH=/usr/bin", "DSH_HOME=/tmp/lab", "NOEQUALS", "EMPTY="] {
            bytes += Array(part.utf8) + [0]
        }
        bytes += [0, 0] + Array("ptr_munge=".utf8) + [0]
        let parsed = SystemDshProcessListing.parseProcArgs(bytes)
        XCTAssertEqual(parsed?.0, ["node", "/x/dsh", "web"])
        XCTAssertEqual(parsed?.1, ["PATH": "/usr/bin", "DSH_HOME": "/tmp/lab", "EMPTY": ""])
        XCTAssertNil(SystemDshProcessListing.parseProcArgs([1, 0, 0]))
    }

    // Windows 上还没有进程与端口枚举（`SystemDshProcessListing` 返回空，退回磁盘扫描）。
    #if !os(Windows)
    /// 真实枚举能跑通（本进程一定在列表里）；不看别的进程的内容。
    func testSystemListingSeesThisProcess() {
        let me = getpid()
        let processes = SystemDshProcessListing().processes()
        XCTAssertTrue(processes.contains { $0.pid == me })
    }

    /// 本进程自己开一个回环监听，真实枚举要能看见这个端口。
    func testSystemListingSeesOwnLoopbackListener() async throws {
        let server = LocalHookServer(supportDirectory: FileManager.default.temporaryDirectory, portFileName: nil) { _ in
            .now(.noContent)
        }
        let port = try await server.start()
        defer { Task { await server.stop() } }
        XCTAssertTrue(SystemDshProcessListing().listeningPorts(pid: getpid()).contains(Int(port)))
    }
    #endif

    /// Linux 的 `/proc/net/tcp{,6}`：只要 LISTEN、inode 对得上、本地地址是回环或全零的。
    func testParsesProcNetTCP() {
        let v4 = """
          sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
           0: 0100007F:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 111 1 0 100 0 0 10 0
           1: 00000000:0BB8 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 222 1 0 100 0 0 10 0
           2: 0F02000A:0FA0 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 333 1 0 100 0 0 10 0
           3: 0100007F:1F91 0100007F:D431 01 00000000:00000000 00:00000000 00000000  1000        0 444 1 0 100 0 0 10 0
           4: 0100007F:1F92 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 555 1 0 100 0 0 10 0
        """
        XCTAssertEqual(SystemDshProcessListing.listeningPorts(procNetTCP: v4, inodes: ["111", "222", "333", "444"]),
                       [3000, 8080], "10.0.2.15 上的、已建立连接的、别人家 inode 的都不算")
        let v6 = """
          sl  local_address                         remote_address                        st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
           0: 00000000000000000000000001000000:1F90 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 7 1 0 100 0 0 10 0
           1: 0000000000000000FFFF00000100007F:1F91 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 8 1 0 100 0 0 10 0
           2: 000080FE00000000FF00000201000000:1F92 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 9 1 0 100 0 0 10 0
        """
        XCTAssertEqual(SystemDshProcessListing.listeningPorts(procNetTCP: v6, inodes: ["7", "8", "9"]), [8080, 8081],
                       "::1 与 ::ffff:127.0.0.1 算，fe80:: 不算")
    }
}
