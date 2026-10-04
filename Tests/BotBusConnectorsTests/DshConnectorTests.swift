#if canImport(CryptoKit)
import CryptoKit
#endif
import Foundation
import XCTest
import BotBusProtocol
@testable import BotBusConnectorKit
@testable import BotBusConnectors

/// 假的 `dsh web`：HTTP 一元调用按剧本回（`FakeDshHTTP`），mux 用 `FakeTransport`，测试往流里塞帧。
final class FakeDshWeb: @unchecked Sendable {
    let http = FakeDshHTTP()
    let transport: FakeTransport
    let sessions = Locked<[JSONValue]>([])
    let prompts = Locked<[JSONValue]>([])
    let answers = Locked<[JSONValue]>([])
    let cancels = Locked<[String]>([])
    let pages = Locked<Int>(0)
    let adoptions = Locked<[JSONValue]>([])
    let workspacePaths = Locked<[String]>([])
    let adoptionFailures = Locked<Int>(0)
    /// `$events/result` 的回应（默认成功）。
    let answerError = Locked<String?>(nil)

    init(plans: [FakeTransport.Plan] = []) {
        transport = FakeTransport(plans: plans)
        http.respond = { [unowned self] method, body in
            let args = body.path("payload", "args")
            switch method {
            case "workspace/create":
                self.workspacePaths.withLock { $0.append(args?.path("request", "path")?.stringValue ?? "") }
                return Self.ok(["workspace": ["workspaceId": "workspace-1"], "created": false])
            case "session/create":
                let request = args?["request"] ?? .null
                self.adoptions.withLock { $0.append(request) }
                let fail = self.adoptionFailures.withLock { count in
                    if count == 0 { return false }
                    count -= 1
                    return true
                }
                if fail {
                    return (200, ["result": ["ok": false, "error": ["code": "session/busy", "message": "writer busy"]]])
                }
                return Self.ok(["sessionId": request["sessionId"] ?? .null])
            case "session/list": return Self.ok(["items": .array(self.sessions.current)])
            case "session/prompt":
                self.prompts.withLock { $0.append(args?["request"] ?? .null) }
                return Self.ok(["accepted": true])
            case "session/cancel":
                self.cancels.withLock { $0.append(args?.path("request", "sessionId")?.stringValue ?? "") }
                return Self.ok(.null)
            case "$events/result":
                if let message = self.answerError.current {
                    return (200, ["type": "server-response", "result": ["ok": false, "error": ["code": "x", "message": .string(message)]]])
                }
                self.answers.withLock { $0.append(args ?? .null) }
                return Self.ok(.null)
            case "session/page":
                self.pages.withLock { $0 += 1 }
                let through = args?.path("request", "throughSeq")?.intValue
                if through == DshWebClient.probeSeq {
                    return (200, ["type": "server-response", "result": ["ok": false, "error": [
                        "code": "gateway/bad-request", "message": "session page through seq 1 is past cursor 3"]]])
                }
                return Self.ok(["records": [
                    ["type": "event", "event": ["type": "user/message", "seq": 1, "time": 1_790_000_000_000,
                                                "data": ["id": "u1", "content": [["type": "text", "text": "网页里的提问"]],
                                                         "source": ["kind": "user", "rpcId": "q"]]]],
                    ["type": "event", "event": ["type": "assistant/message", "seq": 2, "time": 1_790_000_001_000,
                                                "data": ["message": ["id": "a1", "content": [["type": "text", "text": "网页里的回答"]]]]]],
                ], "hasMore": false])
            default: return Self.ok(.null)
            }
        }
    }

    static func ok(_ value: JSONValue) -> (Int, JSONValue) {
        (200, ["type": "server-response", "rpcId": "x", "result": ["ok": true, "value": value]])
    }

    var connection: FakeConnection? { transport.connections.last }

    /// mux 上开过的流：endpoint（`$events` / `session/follow`）→ streamId；follow 按会话 id 找。
    func streamId(_ endpoint: String, sessionId: String? = nil) -> String? {
        for text in connection?.sent.current ?? [] {
            guard let frame = try? JSONValue.decode(text), frame["type"] == "open", frame["endpoint"]?.stringValue == endpoint else {
                continue
            }
            if let sessionId, frame.path("payload", "args", "request", "address", "sessionId")?.stringValue != sessionId { continue }
            return frame["streamId"]?.stringValue
        }
        return nil
    }

    func item(_ streamId: String, _ value: JSONValue) {
        let frame: JSONValue = ["type": "item", "streamId": .string(streamId), "value": value]
        connection?.deliver(frame.encodedString())
    }

    func events(_ value: JSONValue) {
        guard let id = streamId("$events") else { return XCTFail("还没开 $events") }
        item(id, value)
    }

    func emit(_ event: String, _ args: [JSONValue]) {
        events(["type": "emit", "event": .string(event), "args": .array(args)])
    }

    func follow(_ sessionId: String, _ value: JSONValue) {
        guard let id = streamId("session/follow", sessionId: sessionId) else { return XCTFail("没 follow \(sessionId)") }
        item(id, value)
    }

    static func summary(_ sessionId: String, cwd: String, updatedAt: Date, running: Bool = false, blank: Bool = false,
                        title: String? = nil, origin: String? = nil) -> JSONValue {
        var object: [String: JSONValue] = [
            "sessionId": .string(sessionId), "updatedAt": .double(updatedAt.timeIntervalSince1970 * 1000),
            "running": .bool(running), "blank": .bool(blank), "cwd": .string(cwd),
            "projections": ["values": ["title": title.map(JSONValue.string) ?? .null]],
        ]
        if let origin { object["origin"] = .string(origin) }
        return .object(object)
    }

    static func event(_ type: String, seq: Int64, at date: Date, _ data: JSONValue) -> JSONValue {
        ["type": "event", "event": ["type": .string(type), "seq": .int(seq), "time": .double(date.timeIntervalSince1970 * 1000),
                                    "data": data]]
    }
}

/// 按时长放行的计时器：连接器每睡一次都挂在这里，测试 `release` 这个时长才醒；被取消的立即醒并摘掉，
/// 所以 `isWaiting` 只看此刻还在等的。
final class DshTimers: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [UUID: (seconds: TimeInterval, box: OneShotContinuation<Void>)] = [:]

    func isWaiting(_ seconds: TimeInterval) -> Bool { lock.withLock { waiting.values.contains { $0.seconds == seconds } } }

    func sleep(_ seconds: TimeInterval) async {
        let key = UUID()
        let box = OneShotContinuation<Void>()
        lock.withLock { waiting[key] = (seconds, box) }
        await withTaskCancellationHandler {
            _ = try? await box.value()
        } onCancel: {
            _ = lock.withLock { waiting.removeValue(forKey: key) }
            box.resume(returning: ())
        }
    }

    /// 放行此刻在等这个时长的（`seconds` 为 nil 时全放）。
    func release(_ seconds: TimeInterval? = nil) {
        let due: [OneShotContinuation<Void>] = lock.withLock {
            let matched = waiting.filter { seconds == nil || $0.value.seconds == seconds }
            for key in matched.keys { waiting.removeValue(forKey: key) }
            return matched.values.map(\.box)
        }
        for box in due { box.resume(returning: ()) }
    }
}

private struct OneProcess: DshProcessListing {
    var home: URL?
    var desktop = false
    func processes() -> [DshProcessInfo] {
        guard let home else { return [] }
        let arguments = desktop ? ["Electron", "/x/@deepseek-ai/dsh-desktop-host/lib/index.js"]
            : ["node", "/x/node_modules/.bin/dsh", "web", "--port", "3181"]
        return [DshProcessInfo(pid: 4242, arguments: arguments,
                               environment: ["HOME": "/Users/nobody", "DSH_HOME": home.path])]
    }
    func listeningPorts(pid: Int32) -> [Int] { pid == 4242 ? [3181] : [] }
}

/// web 的开关：测试中途让 web "关掉"。
private final class Switchable: DshProcessListing, @unchecked Sendable {
    let on = Locked(true)
    let home: URL
    init(home: URL) { self.home = home }
    func processes() -> [DshProcessInfo] { on.current ? OneProcess(home: home).processes() : [] }
    func listeningPorts(pid: Int32) -> [Int] { OneProcess(home: home).listeningPorts(pid: pid) }
}

final class DshConnectorTests: XCTestCase {
    /// 节拍照真实时间走（测试靠它去找 web）；其余计时器（等 `ready`、收尾宽限、等续聊开跑）都交给 `Harness.timers`，
    /// 由测试按时长放行，所以几个时长要互不相同。
    private static let timing = DshConnector.Timing(tick: 0.05, authRetry: 0.05, listRefresh: 60, ping: 60, readyTimeout: 5,
                                                    settleGrace: 0.2, promptStartTimeout: 1)
    private var root: URL!
    private var home: URL { root.appendingPathComponent("home", isDirectory: true) }
    private var project: String { root.appendingPathComponent("work", isDirectory: true).path }
    private let installed = DshInstallation(kind: .binary, executable: "/usr/local/bin/dsh", leadingArguments: [],
                                            version: nil, node: nil)
    private static let resumeOnly: JSONValue = [
        "loadSession": false, "promptCapabilities": ["image": false],
        "sessionCapabilities": ["list": [:], "resume": [:], "close": [:]],
    ]

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("dsh-connector-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("sessions"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - 夹具

    private struct Harness {
        let store: TaskStore
        let connector: DshConnector
        let behavior: FakeAcpBehavior
        let queue: FakeAgentQueue
        let web: FakeDshWeb
        let events: Locked<[Event]>
        let health: Locked<[(ConnectorInfo.Status, String?)]>
        let timers: DshTimers

        func task(_ id: String) async -> TaskRecord? { await store.task(id: id) }
        var notifications: [Notify] { events.current.compactMap(\.notify) }

        /// 本连接器认领着、store 里也已经是运行中（认领先于写入）。
        func isLiveAndRunning(_ id: String) async -> Bool {
            let owner = await store.owner(of: id)
            let status = await task(id)?.status
            return owner == .live && status == .running
        }

        /// 等连接器开始睡这么久的计时器，再让它到点。
        func fire(_ seconds: TimeInterval, file: StaticString = #filePath, line: UInt = #line) async {
            await assertEventually(file: file, line: line) { timers.isWaiting(seconds) }
            timers.release(seconds)
        }
    }

    private func makeHarness(listing: any DshProcessListing, installation: DshInstallation?,
                             behavior: FakeAcpBehavior = FakeAcpBehavior(),
                             webPlans: [FakeTransport.Plan] = [], tools: AgentToolsConfiguration? = nil,
                             contexts: TaskContextRegistry = TaskContextRegistry()) async -> Harness {
        let registry = ConnectorRegistry(descriptors: [ConnectorDescriptor.dsh(paths: { [home] in DshPaths(home: home) },
                                                                               installation: { installation })])
        let store = TaskStore(identity: AgentIdentity(agentId: "agent-1", name: "Mac", appVersion: "1.0"), connectors: registry)
        let events = Locked<[Event]>([])
        let stream = await store.events()
        Task { for await event in stream { events.withLock { $0.append(event) } } }
        let queue = FakeAgentQueue([await FakeAcpAgent.make(behavior), await FakeAcpAgent.make(behavior)])
        let web = FakeDshWeb(plans: webPlans)
        let health = Locked<[(ConnectorInfo.Status, String?)]>([])
        let timers = DshTimers()
        // 没放行的计时器在用例结束后放掉，别让挂着的任务留到下一个用例。
        addTeardownBlock { timers.release() }
        let tick = Self.timing.tick
        let connector = DshConnector(
            store: store, paths: DshPaths(home: home), installation: { installation }, launcher: queue.factory,
            tools: { tools }, registry: contexts,
            http: web.http, webSocket: web.transport, listing: listing,
            loadSecret: { _ in SymmetricKey(data: Data(0..<32)) },
            transcriptRunner: { _, _, _ in throw ConnectorError("测试里不跑 node") },
            clientVersion: "1.0",
            sleep: { seconds in
                if seconds == tick { try? await Task.sleep(for: .seconds(seconds)) } else { await timers.sleep(seconds) }
            },
            timing: Self.timing,
            onHealth: { status, message in health.withLock { $0.append((status, message)) } })
        return Harness(store: store, connector: connector, behavior: behavior, queue: queue, web: web, events: events,
                       health: health, timers: timers)
    }

    /// 在 `sessions/` 里写一份不压缩的会话日志（`session.v3.jsonl`，不用 node 就读得了）和投影缓存。
    @discardableResult
    private func writeSession(_ sessionId: String, cwd: String? = nil, title: String? = nil, blank: Bool = false,
                              origin: String? = nil, events: [JSONValue] = [], modified: Date = Date()) throws -> URL {
        let cwd = cwd ?? project
        let directory = home.appendingPathComponent("sessions/--work--/\(sessionId)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var header: [String: JSONValue] = ["type": "session", "version": 3, "id": .string(sessionId),
                                           "createdAt": .double(modified.timeIntervalSince1970 * 1000 - 60_000),
                                           "cwd": .string(cwd), "isSeeded": false, "delegationDepth": 0]
        if let origin {
            header["origin"] = .string(origin)
            header["delegationDepth"] = 1
        }
        let lines = [JSONValue.object(header)] + events
        let file = directory.appendingPathComponent("session.v3.jsonl")
        var rows: [String: JSONValue] = ["turnBoundary": ["val": ["lastTurn": blank ? 0 : 1]]]
        if let title { rows["title"] = ["val": .string(title)] }
        rows["sessionListMetadata"] = ["val": ["blank": .bool(blank)]]
        let cache: JSONValue = ["version": 1, "record": ["identity": ["cwd": .string(cwd),
                                                                       "createdAt": .double(modified.timeIntervalSince1970 * 1000)],
                                                          "rows": .object(rows)]]
        let cacheFile = DshPaths(home: home).projectionCacheFile(sessionId: sessionId)
        try FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        // 缓存先就位：扫盘一见到日志就去读缓存。
        try place(cache.encodedString(), at: cacheFile, modified: modified)
        try place(lines.map { $0.encodedString() }.joined(separator: "\n") + "\n", at: file, modified: modified)
        return file
    }

    /// 在扫盘看不到的地方写好内容、改好修改时间，再一步挪到位。连接器每 50 毫秒扫一次 `sessions/`、会打开日志读头行：
    /// 原地写完再改时间，Windows 上 Foundation 改时间要以写方式重新打开文件，撞上扫盘开着的读句柄就报
    /// `ERROR_SHARING_VIOLATION`（CI 上的 Win32 错误 32）；别的平台上扫盘也可能先看到一个"刚刚改过"的日志。
    private func place(_ text: String, at destination: URL, modified: Date) throws {
        let staging = root.appendingPathComponent("staging-\(UUID().uuidString)")
        try text.write(to: staging, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: staging.path)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: staging, to: destination)
    }

    private static func userMessage(_ text: String, seq: Int64, at date: Date) -> JSONValue {
        ["type": "user/message", "seq": .int(seq), "time": .double(date.timeIntervalSince1970 * 1000),
         "data": ["id": .string("u\(seq)"), "content": [["type": "text", "text": .string(text)]], "source": ["kind": "user"]]]
    }

    private static func reply(_ text: String, seq: Int64, at date: Date) -> JSONValue {
        ["type": "assistant/message", "seq": .int(seq), "time": .double(date.timeIntervalSince1970 * 1000),
         "data": ["message": ["id": .string("a\(seq)"), "content": [["type": "text", "text": .string(text)]]]]]
    }

    /// 连上假 web：等 `$events` 打开、回 `ready`、等列表拉完。
    private func connectWeb(_ h: Harness) async {
        await assertEventually { h.web.streamId("$events") != nil }
        h.web.events(["type": "ready", "clientId": "client-1", "host": ["home": "/Users/nobody"]])
        await assertEventually { await h.connector.isWebConnected }
    }

    // MARK: - 扫盘

    func testScansDiskWhenWebIsAbsentAndBaselineIsSilent() async throws {
        let recent = Date().addingTimeInterval(-600)
        try writeSession("s-done", title: "修 bug", modified: recent)
        try writeSession("s-old", title: "上周的", modified: Date().addingTimeInterval(-3 * 86_400))
        try writeSession("s-blank", blank: true, modified: recent)
        try writeSession("s-child", title: "子 agent", origin: "subagent", modified: recent)
        try writeSession("s-ancient", title: "太老了", modified: Date().addingTimeInterval(-9 * 86_400))
        let h = await makeHarness(listing: OneProcess(home: nil), installation: installed)
        await h.connector.start()
        await assertEventually { await h.task("dsh:s-done") != nil }
        let done = await h.task("dsh:s-done")
        XCTAssertEqual(done?.status, .completed)
        XCTAssertEqual(done?.title, "修 bug")
        XCTAssertEqual(done?.origin, .desktop)
        XCTAssertEqual(done?.controllable, true, "有可执行文件就能 resume")
        let old = await h.task("dsh:s-old")
        XCTAssertEqual(old?.status, .idle)
        for skipped in ["dsh:s-blank", "dsh:s-child", "dsh:s-ancient"] {
            let record = await h.task(skipped)
            XCTAssertNil(record, skipped)
        }
        XCTAssertTrue(h.notifications.isEmpty, "第一次对账是静默基线")
        await h.connector.stop()
    }

    func testNoExecutableMeansReadOnlyAndCannotStart() async throws {
        try writeSession("s-done", title: "只读", modified: Date().addingTimeInterval(-60))
        let h = await makeHarness(listing: OneProcess(home: nil), installation: nil)
        await h.connector.start()
        await assertEventually { await h.task("dsh:s-done") != nil }
        let record = await h.task("dsh:s-done")
        XCTAssertEqual(record?.controllable, false)
        do {
            _ = try await h.connector.start(projectPath: project, prompt: "hi", images: [])
            XCTFail("没有可执行文件不能新建")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("可执行文件"), error.localizedDescription)
        }
        do {
            _ = try await h.connector.followUp(taskId: "dsh:s-done", prompt: "hi", images: [])
            XCTFail("web 不在、也没有可执行文件时不能续聊")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("网页端没有运行"), error.localizedDescription)
        }
        XCTAssertTrue(h.queue.requests.current.isEmpty, "没起任何进程")
        await assertEventually { h.health.current.last?.0 == .degraded }
        XCTAssertEqual(h.health.current.last?.1?.contains("只能看"), true)
        let info = h.store.connectors.connectors().first { $0.kind == .dsh }
        XCTAssertEqual(info?.canStartTask, false)
        await h.connector.stop()
    }

    // MARK: - 新建与续聊（ACP）

    func testCompletedPhoneTurnReleasesAcpWriterAndHistoryReadsDesktopContinuation() async throws {
        let behavior = FakeAcpBehavior()
        behavior.capabilities = Self.resumeOnly
        let h = await makeHarness(listing: OneProcess(home: nil), installation: installed, behavior: behavior)
        await h.connector.start()
        let outcome = try await h.connector.start(projectPath: project, prompt: "手机首轮", images: [])
        await assertEventually { await h.task(outcome.taskId)?.status == .completed }
        await assertEventually { await h.connector.acp.isInProcess(taskId: outcome.taskId) == false }
        try writeSession("sess-1", events: [Self.userMessage("电脑续聊", seq: 1, at: Date()),
                                             Self.reply("电脑的新回复", seq: 2, at: Date())], modified: Date())
        let history = try await h.connector.transcript(taskId: outcome.taskId, limit: 40)
        XCTAssertEqual(history.entries.map(\.message.text), ["电脑续聊", "电脑的新回复"])
        await h.connector.stop()
    }

    func testImmediateIdleTimeoutKeepsActiveTurnAndConcurrentSessionPreparation() async throws {
        let turn = Gate()
        let preparation = Gate()
        addTeardownBlock { turn.open(); preparation.open() }
        let behavior = FakeAcpBehavior()
        behavior.capabilities = Self.resumeOnly
        behavior.onPrompt = { _, _ in await turn.wait(); return "end_turn" }
        let h = await makeHarness(listing: OneProcess(home: nil), installation: installed, behavior: behavior)
        await h.connector.start()
        let first = try await h.connector.start(projectPath: project, prompt: "第一轮", images: [])
        await assertEventually { behavior.methods().contains("session/prompt") }
        await h.connector.tick()
        let running = await h.connector.acp.isInProcess(taskId: first.taskId)
        XCTAssertTrue(running)
        behavior.onNewSession = { await preparation.wait() }
        let second = Task { try await h.connector.start(projectPath: project, prompt: "另一会话", images: []) }
        await assertEventually { behavior.methods().filter { $0 == "session/new" }.count == 2 }
        turn.open()
        await assertEventually { await h.task(first.taskId)?.status == .completed }
        let preparingProcess = await h.connector.acp.isRunning
        XCTAssertTrue(preparingProcess, "仍在处理 session/new 时不能退出进程")
        preparation.open()
        let other = try await second.value
        await assertEventually { await h.task(other.taskId)?.status == .completed }
        await assertEventually { await h.connector.acp.isRunning == false }
        await h.connector.stop()
    }

    func testAcpDelayedReleaseDoesNotReleaseNextWebTurn() async throws {
        let behavior = FakeAcpBehavior()
        behavior.capabilities = Self.resumeOnly
        let h = await makeHarness(listing: OneProcess(home: home), installation: installed, behavior: behavior)
        h.web.sessions.withLock { $0 = [FakeDshWeb.summary("sess-1", cwd: project, updatedAt: Date())] }
        await h.connector.start()
        await connectWeb(h)
        let outcome = try await h.connector.start(projectPath: project, prompt: "手机首轮", images: [])
        await assertEventually { await h.task(outcome.taskId)?.status == .completed }
        h.web.emit("api-session/status", ["sess-1", true])
        await assertEventually { h.web.streamId("session/follow", sessionId: "sess-1") != nil }
        h.web.follow("sess-1", ["type": "snapshot", "header": ["id": "sess-1"], "cursor": 1,
                                "hasMore": false, "records": [FakeDshWeb.event("turn/start", seq: 1, at: Date(), ["turn": 2])]])
        await assertEventually { await h.isLiveAndRunning(outcome.taskId) }
        h.web.events(["type": "waterfall", "event": "approval/request", "eventId": "next-approval", "agentId": "sess-1",
                      "request": ["toolName": "bash", "callId": "next", "reason": "下一轮的审批"]])
        await assertEventually { await h.task(outcome.taskId)?.status == .waitingApproval }
        try await Task.sleep(for: .seconds(AcpConnector.releaseRetryDelay + 0.1))
        await h.connector.tick()
        let owner = await h.store.owner(of: outcome.taskId)
        let task = await h.task(outcome.taskId)
        XCTAssertEqual(owner, .live)
        XCTAssertEqual(task?.status, .waitingApproval)
        XCTAssertEqual(task?.pendingRequest?.id, "next-approval")
        await h.connector.stop()
    }

    func testResumeAfterHandoffInvalidatesPreviouslyCompleteTranscript() async throws {
        let behavior = FakeAcpBehavior()
        behavior.capabilities = Self.resumeOnly
        let h = await makeHarness(listing: OneProcess(home: nil), installation: installed, behavior: behavior)
        await h.connector.start()
        let first = try await h.connector.start(projectPath: project, prompt: "手机首轮", images: [])
        await assertEventually { await h.connector.acp.isInProcess(taskId: first.taskId) == false }
        let gate = Gate()
        addTeardownBlock { gate.open() }
        behavior.onPrompt = { _, _ in await gate.wait(); return "end_turn" }
        _ = try await h.connector.followUp(taskId: first.taskId, prompt: "电脑续聊后手机接上", images: [])
        await assertEventually { behavior.methods().filter { $0 == "session/prompt" }.count == 2 }
        let cached = await h.connector.acp.completeTranscript(taskId: first.taskId, limit: 40)
        XCTAssertNil(cached, "resume 不重放桌面期间的历史，不能认为旧缓存完整")
        gate.open()
        await h.connector.stop()
    }

    func testStartGoesThroughAcpAndFollowUpResumesAfterHandoff() async throws {
        let behavior = FakeAcpBehavior()
        behavior.capabilities = Self.resumeOnly
        let h = await makeHarness(listing: OneProcess(home: nil), installation: installed, behavior: behavior)
        await h.connector.start()
        let outcome = try await h.connector.start(projectPath: project, prompt: "你好", images: [])
        XCTAssertEqual(outcome.taskId, "dsh:sess-1")
        await assertEventually { await h.task("dsh:sess-1")?.status == .completed }
        let record = await h.task("dsh:sess-1")
        XCTAssertEqual(record?.origin, .watch)
        XCTAssertEqual(record?.source, .dsh)
        XCTAssertEqual(h.queue.requests.current.first?.environment["DSH_HOME"], home.path)
        XCTAssertEqual(h.queue.requests.current.first?.arguments, ["--profile", "acp"])
        await assertEventually { await h.connector.acp.isInProcess(taskId: outcome.taskId) == false }

        _ = try await h.connector.followUp(taskId: "dsh:sess-1", prompt: "再来", images: [])
        await assertEventually { h.behavior.methods().filter { $0 == "session/prompt" }.count == 2 }
        XCTAssertTrue(h.behavior.methods().contains("session/resume"), "交还后重新接上同一个会话")
        XCTAssertTrue(h.web.prompts.current.isEmpty)
        await assertEventually { await h.connector.acp.isInProcess(taskId: outcome.taskId) == false }
        try writeSession("sess-1", events: [Self.userMessage("你好", seq: 1, at: Date()),
                                             Self.reply("好的", seq: 2, at: Date())])
        // 交还之后的记录从持久层读取。
        let (entries, _) = try await h.connector.transcript(taskId: "dsh:sess-1", limit: 40)
        XCTAssertEqual(entries.first?.message.text, "你好")
        do {
            _ = try await h.connector.start(projectPath: project, prompt: "图", images: [URL(fileURLWithPath: "/tmp/x.png")])
            XCTFail("不收图")
        } catch {}
        await h.connector.stop()
    }

    func testNewPhoneSessionJoinsDesktopWorkspaceOnlyAfterAcpReleasesWriter() async throws {
        let gate = Gate()
        addTeardownBlock { gate.open() }
        let behavior = FakeAcpBehavior()
        behavior.capabilities = Self.resumeOnly
        behavior.onPrompt = { _, _ in await gate.wait(); return "end_turn" }
        let h = await makeHarness(listing: OneProcess(home: home, desktop: true), installation: installed, behavior: behavior)
        h.web.sessions.withLock { $0 = [FakeDshWeb.summary("desktop-old", cwd: project, updatedAt: Date())] }
        await h.connector.start()
        await connectWeb(h)
        let outcome = try await h.connector.start(projectPath: project, prompt: "手机新会话", images: [])
        await assertEventually { behavior.methods().contains("session/prompt") }
        await h.connector.tick()
        XCTAssertTrue(h.web.adoptions.current.isEmpty, "首轮运行时不能让桌面争抢 ACP 写锁")
        gate.open()
        await assertEventually { await h.connector.acp.isInProcess(taskId: outcome.taskId) == false }
        await h.connector.tick()
        await assertEventually { h.web.adoptions.current.count == 1 }
        XCTAssertEqual(h.web.adoptions.current, [["sessionId": "sess-1", "workspaceId": "workspace-1"]])
        XCTAssertEqual(h.web.workspacePaths.current, [try XCTUnwrap(TranscriptFileRefs.realPath(project))], "按真实 cwd 接入工作区")
        XCTAssertNil(h.web.streamId("session/follow", sessionId: "sess-1"), "接入空闲会话不打开历史 follow")
        await h.connector.tick()
        XCTAssertEqual(h.web.adoptions.current.count, 1, "不重复接入，也不载入其他桌面会话")
        await h.connector.stop()
    }

    func testDesktopHandoffRetriesBusyWriterWithoutFailingCompletedPhoneTask() async throws {
        let behavior = FakeAcpBehavior()
        behavior.capabilities = Self.resumeOnly
        let h = await makeHarness(listing: OneProcess(home: home, desktop: true), installation: installed, behavior: behavior)
        h.web.adoptionFailures.withLock { $0 = 1 }
        await h.connector.start()
        await connectWeb(h)
        let outcome = try await h.connector.start(projectPath: project, prompt: "手机新会话", images: [])
        await assertEventually { h.web.adoptions.current.count == 2 }
        let record = await h.task(outcome.taskId)
        XCTAssertEqual(record?.status, .completed)
        await h.connector.tick()
        XCTAssertEqual(h.web.adoptions.current.count, 2)
        await h.connector.stop()
    }

    func testStandaloneWebDoesNotAdoptPhoneSessionIntoDesktopWorkspace() async throws {
        let behavior = FakeAcpBehavior()
        behavior.capabilities = Self.resumeOnly
        let h = await makeHarness(listing: OneProcess(home: home), installation: installed, behavior: behavior)
        await h.connector.start()
        await connectWeb(h)
        let outcome = try await h.connector.start(projectPath: project, prompt: "手机新会话", images: [])
        await assertEventually { await h.connector.acp.isInProcess(taskId: outcome.taskId) == false }
        await h.connector.tick()
        XCTAssertTrue(h.web.adoptions.current.isEmpty)
        XCTAssertTrue(h.web.workspacePaths.current.isEmpty)
        await h.connector.stop()
    }

    func testDesktopHandoffUsesSameRealDirectoryAsAcpForSymlinkProject() async throws {
        let alias = root.appendingPathComponent("alias")
        try makeSymbolicLink(at: alias, withDestinationURL: URL(fileURLWithPath: project, isDirectory: true))
        let real = try XCTUnwrap(TranscriptFileRefs.realPath(project))
        let behavior = FakeAcpBehavior()
        behavior.capabilities = Self.resumeOnly
        let h = await makeHarness(listing: OneProcess(home: home, desktop: true), installation: installed, behavior: behavior)
        await h.connector.start()
        await connectWeb(h)
        _ = try await h.connector.start(projectPath: alias.path, prompt: "软链接项目", images: [])
        await assertEventually { h.web.adoptions.current.count == 1 }
        XCTAssertEqual(behavior.params.current["session/new"]?["cwd"]?.stringValue, real)
        XCTAssertEqual(h.web.workspacePaths.current, [real], "桌面严格比较 session header cwd 与工作区 realpath")
        await h.connector.stop()
    }

    /// 本机记过的 BotBus 会话在扫盘结果里也有：来源 `.watch`、标题以本机记录为准。
    func testReconcileMergesBotBusSessionsFromAcp() async throws {
        let behavior = FakeAcpBehavior()
        behavior.capabilities = Self.resumeOnly
        let h = await makeHarness(listing: OneProcess(home: nil), installation: installed, behavior: behavior)
        await h.connector.start()
        _ = try await h.connector.start(projectPath: project, prompt: "手机上开的", images: [])
        await assertEventually { await h.task("dsh:sess-1")?.status == .completed }
        // 盘上也出现了这个会话（dsh 自己起的标题），再对一次账。
        try writeSession("sess-1", title: "dsh 起的标题", modified: Date())
        await h.connector.tick()
        let record = await h.task("dsh:sess-1")
        XCTAssertEqual(record?.origin, .watch)
        XCTAssertEqual(record?.title, "手机上开的")
        XCTAssertEqual(record?.lastMessage, "好的", "最后一条消息来自 BotBus 自己跑的那一轮")
        await h.connector.stop()
    }

    /// 不在进程里的会话：web 不在就 `session/resume`；撞锁且 web 找得到就改走 web。
    func testFollowUpResumesAndFallsBackToWebWhenLocked() async throws {
        try writeSession("s-desk", title: "桌面上的", modified: Date().addingTimeInterval(-60))
        let behavior = FakeAcpBehavior()
        behavior.capabilities = Self.resumeOnly
        behavior.resumeError = JSONRPCError(code: -32603, message: "Internal error", data: [
            "details": "session s-desk is already owned by an active write handle",
        ])
        let listing = Switchable(home: home)
        listing.on.withLock { $0 = false }
        let h = await makeHarness(listing: listing, installation: installed, behavior: behavior)
        await h.connector.start()
        await assertEventually { await h.task("dsh:s-desk") != nil }
        // 撞锁，而且 web 也不在：报错。
        do {
            _ = try await h.connector.followUp(taskId: "dsh:s-desk", prompt: "继续", images: [])
            XCTFail("应当失败")
        } catch let error as AcpConnectorError {
            XCTAssertEqual(error.reason, .sessionBusyElsewhere)
        }
        // web 开起来了（还没被节拍找到）：撞锁之后立刻找一次，经它续聊。
        h.web.sessions.withLock { $0 = [FakeDshWeb.summary("s-desk", cwd: project, updatedAt: Date().addingTimeInterval(-60))] }
        listing.on.withLock { $0 = true }
        let answered = Task { try await h.connector.followUp(taskId: "dsh:s-desk", prompt: "继续", images: []) }
        await connectWeb(h)
        let outcome = try await answered.value
        XCTAssertTrue(outcome.retainsLiveOwnership)
        XCTAssertEqual(h.web.prompts.current.first?["sessionId"], "s-desk")
        XCTAssertEqual(h.web.prompts.current.first?["content"]?[0]?["text"]?.stringValue, "继续")
        let record = await h.task("dsh:s-desk")
        XCTAssertEqual(record?.status, .running)
        let owner = await h.store.owner(of: "dsh:s-desk")
        XCTAssertEqual(owner, .live)
        // 一直没开跑：超时后交还。
        await h.fire(Self.timing.promptStartTimeout)
        await assertEventually { await h.store.owner(of: "dsh:s-desk") == .observer }
        await h.connector.stop()
    }

    // MARK: - web

    func testWebFollowUpSuppliesPrivateCLIContextAndReusesTheTaskToken() async throws {
        #if os(Windows)
        throw XCTSkip("DSH CLI context pipes require POSIX")
        #else
        let contexts = TaskContextRegistry()
        let tools = AgentToolsConfiguration(cliPath: "/bin/sh", toolsURL: "http://127.0.0.1:1234")
        let h = await makeHarness(listing: OneProcess(home: home), installation: installed,
                                  tools: tools, contexts: contexts)
        h.web.sessions.withLock { $0 = [FakeDshWeb.summary("s-desk", cwd: project, updatedAt: Date())] }
        await h.connector.start()
        await connectWeb(h)
        let before = await contexts.token(for: "dsh:s-desk")
        XCTAssertNil(before, "观察电脑会话不能签发工具凭据")

        _ = try await h.connector.followUp(taskId: "dsh:s-desk", prompt: "分享网页", images: [])
        let prompt = try XCTUnwrap(h.web.prompts.current.first?["content"]?[0]?["text"]?.stringValue)
        XCTAssertTrue(prompt.contains("BOTBUS_CONTEXT_PIPE="), "网页续聊需要可调用的 CLI 上下文")
        let issued = await contexts.token(for: "dsh:s-desk")
        let token = try XCTUnwrap(issued)
        XCTAssertFalse(prompt.contains(token), "任务 token 不进提示词 / 会话记录")
        let pipe = try XCTUnwrap(prompt.components(separatedBy: "BOTBUS_CONTEXT_PIPE='").dropFirst().first?
            .components(separatedBy: "'").first)
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: pipe))
        let data = handle.availableData
        try handle.close()
        let line = try XCTUnwrap(data.split(separator: 10).first)
        let environment = try JSONDecoder().decode([String: String].self, from: Data(line))
        XCTAssertEqual(environment[AgentToolsInjection.taskTokenVariable], token)
        XCTAssertEqual(environment[AgentToolsInjection.toolsURLVariable], tools.toolsURL)
        let bound = await contexts.taskId(for: token)
        XCTAssertEqual(bound, "dsh:s-desk")
        _ = try await h.connector.followUp(taskId: "dsh:s-desk", prompt: "再分享文件", images: [])
        let reused = await contexts.token(for: "dsh:s-desk")
        XCTAssertEqual(reused, token)
        await h.connector.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: pipe))
        #endif
    }

    func testConcurrentWebFollowUpsShareOneLiveCLIContext() async throws {
        #if !os(Windows)
        let contexts = TaskContextRegistry()
        let tools = AgentToolsConfiguration(cliPath: "/bin/sh", toolsURL: "http://127.0.0.1:1234")
        let h = await makeHarness(listing: OneProcess(home: home), installation: installed,
                                  tools: tools, contexts: contexts)
        h.web.sessions.withLock { $0 = [FakeDshWeb.summary("s-desk", cwd: project, updatedAt: Date())] }
        await h.connector.start()
        await connectWeb(h)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask { _ = try await h.connector.followUp(taskId: "dsh:s-desk", prompt: "分享", images: []) }
            }
            try await group.waitForAll()
        }
        let count = await contexts.tokenCount
        XCTAssertEqual(count, 1, "同任务并发续聊不能签发多份凭据")
        let paths = Set(h.web.prompts.current.compactMap { request in
            request["content"]?[0]?["text"]?.stringValue?.components(separatedBy: "BOTBUS_CONTEXT_PIPE='")
                .dropFirst().first?.components(separatedBy: "'").first
        })
        XCTAssertEqual(paths.count, 1)
        XCTAssertTrue(paths.allSatisfy { FileManager.default.fileExists(atPath: $0) })
        // 凭据淘汰后，换掉旧管道的 shutdown 也会让出 actor；并发续聊仍只能建一份。
        for i in 0..<TaskContextRegistry.maxTokens { _ = await contexts.issue(for: "other-\(i)") }
        let promptCount = h.web.prompts.current.count
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask { _ = try await h.connector.followUp(taskId: "dsh:s-desk", prompt: "再分享", images: []) }
            }
            try await group.waitForAll()
        }
        let replacementPaths = Set(h.web.prompts.current.dropFirst(promptCount).compactMap { request in
            request["content"]?[0]?["text"]?.stringValue?.components(separatedBy: "BOTBUS_CONTEXT_PIPE='")
                .dropFirst().first?.components(separatedBy: "'").first
        })
        XCTAssertEqual(replacementPaths.count, 1)
        XCTAssertTrue(replacementPaths.allSatisfy { FileManager.default.fileExists(atPath: $0) })
        XCTAssertTrue(paths.allSatisfy { !FileManager.default.fileExists(atPath: $0) })
        await h.connector.stopSubprocesses()
        XCTAssertTrue(replacementPaths.allSatisfy { !FileManager.default.fileExists(atPath: $0) })
        await h.connector.stop()
        #endif
    }

    func testUnpairInvalidatesSuspendedWebToolsContextCreation() async throws {
        #if !os(Windows)
        let entered = Locked(false)
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let contexts = TaskContextRegistry(generateToken: {
            entered.withLock { $0 = true }
            _ = gate.wait(timeout: .now() + 5)
            return "synthetic-dsh-token"
        })
        let tools = AgentToolsConfiguration(cliPath: "/bin/sh", toolsURL: "http://127.0.0.1:1234")
        let h = await makeHarness(listing: OneProcess(home: home), installation: installed,
                                  tools: tools, contexts: contexts)
        h.web.sessions.withLock { $0 = [FakeDshWeb.summary("s-desk", cwd: project, updatedAt: Date())] }
        await h.connector.start()
        await connectWeb(h)
        let follow = Task { try await h.connector.followUp(taskId: "dsh:s-desk", prompt: "分享", images: []) }
        await assertEventually { entered.current }
        await h.connector.stopSubprocesses()
        gate.signal()
        do {
            _ = try await follow.value
            XCTFail("解除配对后不能补建管道、继续下发提示词")
        } catch {}
        XCTAssertTrue(h.web.prompts.current.isEmpty)
        await h.connector.stop()
        #endif
    }

    func testWebListFollowsRunningSessionsAndSettles() async throws {
        let now = Date()
        let h = await makeHarness(listing: OneProcess(home: home), installation: installed)
        h.web.sessions.withLock {
            $0 = [
                FakeDshWeb.summary("session-a", cwd: project, updatedAt: now.addingTimeInterval(-30), title: "网页会话"),
                FakeDshWeb.summary("session-blank", cwd: project, updatedAt: now, blank: true),
                FakeDshWeb.summary("child", cwd: project, updatedAt: now, origin: "subagent"),
            ]
        }
        await h.connector.start()
        await connectWeb(h)
        await assertEventually { await h.task("dsh:session-a") != nil }
        let blank = await h.task("dsh:session-blank")
        XCTAssertNil(blank)
        let child = await h.task("dsh:child")
        XCTAssertNil(child)
        XCTAssertNil(h.web.streamId("session/follow"), "没在跑的会话不 follow（会锁住它）")

        // 电脑上开跑：status true → follow → 实时认领。
        h.web.emit("api-session/status", ["session-a", true])
        await assertEventually { h.web.streamId("session/follow", sessionId: "session-a") != nil }
        h.web.follow("session-a", ["type": "snapshot", "header": ["id": "session-a", "cwd": .string(project)], "cursor": 3,
                                   "records": [FakeDshWeb.event("turn/start", seq: 1, at: now, ["turn": 1])], "hasMore": false])
        await assertEventually { await h.task("dsh:session-a")?.status == .running }
        let owner = await h.store.owner(of: "dsh:session-a")
        XCTAssertEqual(owner, .live)

        // status false 比 turn/end 先到；随后 follow 流里收尾。
        h.web.emit("api-session/status", ["session-a", false])
        h.web.follow("session-a", FakeDshWeb.event("assistant/message", seq: 2, at: now.addingTimeInterval(1),
                                                   ["message": ["id": "m2", "content": [["type": "text", "text": "搞定了"]]]]))
        h.web.follow("session-a", FakeDshWeb.event("turn/end", seq: 3, at: now.addingTimeInterval(2),
                                                   ["turn": 1, "reason": ["kind": "completed"]]))
        await assertEventually { await h.task("dsh:session-a")?.status == .completed }
        let done = await h.task("dsh:session-a")
        XCTAssertEqual(done?.lastMessage, "搞定了")
        await assertEventually { await h.store.owner(of: "dsh:session-a") == .observer }
        // 事件由另一个任务从 store 的事件流收集，状态先变、通知后到。
        await assertEventually { h.notifications.map(\.taskId) == ["dsh:session-a"] }
        // follow 已关（发了 cancel）。
        let followId = try XCTUnwrap(h.web.streamId("session/follow", sessionId: "session-a"))
        await assertEventually {
            h.web.connection?.sent.current.contains { (try? JSONValue.decode($0)) == ["type": "cancel", "streamId": .string(followId)] } == true
        }
        await h.connector.stop()
    }

    func testWebApprovalWaterfallMapsToCommandAndAnswers() async throws {
        let now = Date()
        let h = await makeHarness(listing: OneProcess(home: home), installation: installed)
        h.web.sessions.withLock { $0 = [FakeDshWeb.summary("session-a", cwd: project, updatedAt: now, running: true)] }
        await h.connector.start()
        await connectWeb(h)
        await assertEventually { h.web.streamId("session/follow", sessionId: "session-a") != nil }
        h.web.follow("session-a", ["type": "snapshot", "header": ["id": "session-a"], "cursor": 2, "hasMore": false, "records": [
            FakeDshWeb.event("turn/start", seq: 1, at: now, ["turn": 1]),
            FakeDshWeb.event("tool/call", seq: 2, at: now, ["callId": "call_1", "name": "bash",
                                                            "arguments": #"{"command": "touch ~/probe.txt", "description": "x"}"#]),
            FakeDshWeb.event("approval/asked", seq: 3, at: now, ["id": "ap-1", "toolName": "bash", "callId": "call_1",
                                                                 "reason": "escalate sandbox"]),
        ]])
        // snapshot 与 waterfall 走两条流：等 snapshot 进来（审批卡片要用它的 tool/call 参数）再发 waterfall。
        await assertEventually { await h.isLiveAndRunning("dsh:session-a") }
        h.web.events(["type": "waterfall", "event": "approval/request", "eventId": "ev-1", "agentId": "session-a",
                      "request": ["toolName": "bash", "callId": "call_1", "reason": "escalate sandbox"]])
        await assertEventually { await h.task("dsh:session-a")?.status == .waitingApproval }
        let waiting = await h.task("dsh:session-a")
        XCTAssertEqual(waiting?.pendingRequest?.id, "ev-1")
        XCTAssertEqual(waiting?.pendingRequest?.kind, .command)
        XCTAssertEqual(waiting?.pendingRequest?.summary, "执行命令：touch ~/probe.txt")
        XCTAssertEqual(waiting?.pendingRequest?.detail, "escalate sandbox")
        XCTAssertNil(waiting?.pendingRequest?.questions)
        await assertEventually { h.notifications.first?.taskId == "dsh:session-a" }

        do {
            _ = try await h.connector.approve(taskId: "dsh:session-a", requestId: "wrong", decision: .allow)
            XCTFail("对不上的请求 id")
        } catch {}
        let outcome = try await h.connector.approve(taskId: "dsh:session-a", requestId: "ev-1", decision: .allow)
        XCTAssertTrue(outcome.retainsLiveOwnership)
        XCTAssertEqual(h.web.answers.current, [["clientId": "client-1", "eventId": "ev-1",
                                                "outcome": ["kind": "result", "value": "allowed-once"]]])
        await assertEventually { await h.task("dsh:session-a")?.status == .running }

        // 新的一次审批被电脑上先答掉：cancel 帧清掉挂起。
        h.web.events(["type": "waterfall", "event": "approval/request", "eventId": "ev-2", "agentId": "session-a",
                      "request": ["toolName": "write_file", "callId": "call_9", "reason": "写到工作区外"]])
        await assertEventually { await h.task("dsh:session-a")?.pendingRequest?.id == "ev-2" }
        let second = await h.task("dsh:session-a")
        XCTAssertEqual(second?.pendingRequest?.kind, .permission)
        XCTAssertEqual(second?.pendingRequest?.summary, "写到工作区外")
        h.web.events(["type": "cancel", "eventId": "ev-2"])
        await assertEventually { await h.task("dsh:session-a")?.status == .running }
        do {
            _ = try await h.connector.approve(taskId: "dsh:session-a", requestId: "ev-2", decision: .deny)
            XCTFail("已经在电脑上处理过了")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("没有待审批"), error.localizedDescription)
        }
        await h.connector.stop()
    }

    func testWebQuestionsMapToPendingQuestionsAndAnswers() async throws {
        let now = Date()
        let h = await makeHarness(listing: OneProcess(home: home), installation: installed)
        h.web.sessions.withLock { $0 = [FakeDshWeb.summary("session-q", cwd: project, updatedAt: now, running: true)] }
        await h.connector.start()
        await connectWeb(h)
        await assertEventually { h.web.streamId("session/follow", sessionId: "session-q") != nil }
        h.web.follow("session-q", ["type": "snapshot", "header": ["id": "session-q"], "cursor": 1, "hasMore": false,
                                   "records": [FakeDshWeb.event("turn/start", seq: 1, at: now, ["turn": 1])]])
        let waterfall: JSONValue = ["type": "waterfall", "event": "user-questions/request", "eventId": "ev-q", "agentId": "session-q",
                                    "request": ["questions": [
                                        ["id": "color", "question": "喜欢哪种颜色？", "header": "颜色",
                                         "options": [["label": "红"], ["label": "蓝"]]],
                                        ["id": "extras", "question": "还要什么？", "multiSelect": true,
                                         "options": [["label": "糖"], ["label": "奶"]]],
                                    ]]]
        h.web.events(waterfall)
        await assertEventually { await h.task("dsh:session-q")?.status == .waitingInput }
        let current = await h.task("dsh:session-q")
        let waiting = try XCTUnwrap(current?.pendingRequest)
        XCTAssertEqual(waiting.kind, .input)
        XCTAssertEqual(waiting.summary, "颜色")
        XCTAssertEqual(waiting.questions?.map(\.id), ["color", "extras"])
        XCTAssertEqual(waiting.questions?.first?.options.map(\.label), ["红", "蓝"])
        XCTAssertEqual(waiting.questions?.last?.multiSelect, true)
        XCTAssertEqual(waiting.question?.contains("1. 红"), true)

        do {
            _ = try await h.connector.approve(taskId: "dsh:session-q", requestId: "ev-q", decision: .allow, answers: [:])
            XCTFail("没答不能允许")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("选一个选项"), error.localizedDescription)
        }
        XCTAssertTrue(h.web.answers.current.isEmpty)
        _ = try await h.connector.approve(taskId: "dsh:session-q", requestId: "ev-q", decision: .allow,
                                          answers: ["color": ["蓝"], "extras": ["糖", "少冰"]])
        XCTAssertEqual(h.web.answers.current.last?.path("outcome", "value"), ["answers": [
            ["id": "color", "selected": ["蓝"]],
            ["id": "extras", "selected": ["糖"], "custom": "少冰"],
        ]])

        // 拒绝 = 跳过：每题都不选。
        h.web.events(waterfall.replacing("eventId", with: "ev-q2"))
        await assertEventually { await h.task("dsh:session-q")?.pendingRequest?.id == "ev-q2" }
        _ = try await h.connector.approve(taskId: "dsh:session-q", requestId: "ev-q2", decision: .deny)
        XCTAssertEqual(h.web.answers.current.last?.path("outcome", "value"), ["answers": [
            ["id": "color", "selected": []], ["id": "extras", "selected": []],
        ]])
        await assertEventually { await h.task("dsh:session-q")?.status == .running }

        // 挂着提问时续聊 = 用这句话回答所有题。
        h.web.events(waterfall.replacing("eventId", with: "ev-q3"))
        await assertEventually { await h.task("dsh:session-q")?.pendingRequest?.id == "ev-q3" }
        _ = try await h.connector.followUp(taskId: "dsh:session-q", prompt: "随便", images: [])
        XCTAssertEqual(h.web.answers.current.last?.path("outcome", "value"), ["answers": [
            ["id": "color", "selected": [], "custom": "随便"], ["id": "extras", "selected": [], "custom": "随便"],
        ]])
        XCTAssertTrue(h.web.prompts.current.isEmpty, "不是新的一条消息")
        await h.connector.stop()
    }

    func testInterruptAndFollowUpOverWeb() async throws {
        let now = Date()
        let h = await makeHarness(listing: OneProcess(home: home), installation: installed)
        h.web.sessions.withLock { $0 = [FakeDshWeb.summary("session-a", cwd: project, updatedAt: now.addingTimeInterval(-60))] }
        await h.connector.start()
        await connectWeb(h)
        await assertEventually { await h.task("dsh:session-a") != nil }
        do {
            _ = try await h.connector.interrupt(taskId: "dsh:session-a")
            XCTFail("没在跑")
        } catch {}

        // web 连着：不在 ACP 进程里的会话续聊走 web，不起进程。
        let outcome = try await h.connector.followUp(taskId: "dsh:session-a", prompt: "接着", images: [])
        XCTAssertTrue(outcome.retainsLiveOwnership)
        XCTAssertEqual(h.web.prompts.current.first?["mode"], "queue")
        XCTAssertTrue(h.queue.requests.current.isEmpty, "没起 ACP 进程")
        h.web.emit("api-session/status", ["session-a", true])
        await assertEventually { h.web.streamId("session/follow", sessionId: "session-a") != nil }
        _ = try await h.connector.interrupt(taskId: "dsh:session-a")
        XCTAssertEqual(h.web.cancels.current, ["session-a"])
        h.web.follow("session-a", ["type": "snapshot", "header": ["id": "session-a"], "cursor": 2, "hasMore": false, "records": [
            FakeDshWeb.event("turn/start", seq: 1, at: now, ["turn": 1]),
            FakeDshWeb.event("turn/end", seq: 2, at: now.addingTimeInterval(1), ["turn": 1, "reason": ["kind": "aborted"]]),
        ]])
        h.web.emit("api-session/status", ["session-a", false])
        await assertEventually { await h.task("dsh:session-a")?.status == .interrupted }
        await assertEventually { await h.store.owner(of: "dsh:session-a") == .observer }
        await h.connector.stop()
    }

    /// status false 之后一直等不到 `turn/end`（实测：cancel 打在两步之间时 web 不写收尾）：宽限过后按被打断算。
    func testMissingTurnEndAfterStatusFalseCountsAsInterrupted() async throws {
        let now = Date()
        let h = await makeHarness(listing: OneProcess(home: home), installation: installed)
        h.web.sessions.withLock { $0 = [FakeDshWeb.summary("session-a", cwd: project, updatedAt: now, running: true)] }
        await h.connector.start()
        await connectWeb(h)
        await assertEventually { h.web.streamId("session/follow", sessionId: "session-a") != nil }
        h.web.follow("session-a", ["type": "snapshot", "header": ["id": "session-a"], "cursor": 1, "hasMore": false,
                                   "records": [FakeDshWeb.event("turn/start", seq: 1, at: now, ["turn": 1])]])
        // 列表说在跑，对账早就记成运行中了；认领了才说明 snapshot 已经进来。
        await assertEventually { await h.isLiveAndRunning("dsh:session-a") }
        h.web.emit("api-session/status", ["session-a", false])
        await assertEventually { h.timers.isWaiting(Self.timing.settleGrace) }
        let waiting = await h.task("dsh:session-a")
        XCTAssertEqual(waiting?.status, .running, "宽限期内还等着 turn/end")
        h.timers.release(Self.timing.settleGrace)
        await assertEventually { await h.task("dsh:session-a")?.status == .interrupted }
        await assertEventually { await h.store.owner(of: "dsh:session-a") == .observer }
        await h.connector.stop()
    }

    /// `$events` 与 follow 是两条流：status false 可能比 snapshot 先到。照样等 snapshot（或宽限），不能当场按"没在跑"收掉。
    func testStatusFalseBeforeSnapshotStillWaitsForTurnEnd() async throws {
        let now = Date()
        let h = await makeHarness(listing: OneProcess(home: home), installation: installed)
        h.web.sessions.withLock { $0 = [FakeDshWeb.summary("session-a", cwd: project, updatedAt: now, running: true)] }
        await h.connector.start()
        await connectWeb(h)
        await assertEventually { h.web.streamId("session/follow", sessionId: "session-a") != nil }
        h.web.emit("api-session/status", ["session-a", false])
        await assertEventually { h.timers.isWaiting(Self.timing.settleGrace) }
        h.web.follow("session-a", ["type": "snapshot", "header": ["id": "session-a"], "cursor": 1, "hasMore": false,
                                   "records": [FakeDshWeb.event("turn/start", seq: 1, at: now, ["turn": 1])]])
        await assertEventually { await h.store.owner(of: "dsh:session-a") == .live }
        h.timers.release(Self.timing.settleGrace)
        await assertEventually { await h.task("dsh:session-a")?.status == .interrupted }
        await assertEventually { await h.store.owner(of: "dsh:session-a") == .observer }
        await h.connector.stop()
    }

    /// web 断了：任务留着，认领交还，退回扫盘；`controllable` 跟着"还有没有路"走。
    func testWebDisconnectFallsBackToScanner() async throws {
        let now = Date()
        try writeSession("session-a", title: "盘上的标题", modified: now.addingTimeInterval(-120))
        let listing = Switchable(home: home)
        let h = await makeHarness(listing: listing, installation: nil)
        h.web.sessions.withLock { $0 = [FakeDshWeb.summary("session-a", cwd: project, updatedAt: now, running: true,
                                                           title: "网页标题")] }
        await h.connector.start()
        await connectWeb(h)
        await assertEventually { h.web.streamId("session/follow", sessionId: "session-a") != nil }
        h.web.follow("session-a", ["type": "snapshot", "header": ["id": "session-a"], "cursor": 1, "hasMore": false,
                                   "records": [FakeDshWeb.event("turn/start", seq: 1, at: now, ["turn": 1])]])
        // 等 snapshot 进来、认领了再断：只看状态的话，列表带来的"运行中"在 snapshot 之前就有了。
        await assertEventually { await h.isLiveAndRunning("dsh:session-a") }
        let connected = await h.task("dsh:session-a")
        XCTAssertEqual(connected?.status, .running)
        XCTAssertEqual(connected?.controllable, true, "web 连着就能控制")

        listing.on.withLock { $0 = false }
        h.web.connection?.closeFromServer(code: 1006)
        await assertEventually { await h.connector.isWebConnected == false }
        await assertEventually { await h.store.owner(of: "dsh:session-a") == .observer }
        await assertEventually { await h.task("dsh:session-a")?.controllable == false }
        let record = await h.task("dsh:session-a")
        XCTAssertNotNil(record, "断开不清任务")
        XCTAssertNotEqual(record?.status, .running)
        await h.connector.stop()
    }

    func testUnauthorizedWebIsReportedAndScannerStillWorks() async throws {
        try writeSession("s-done", title: "盘上的", modified: Date().addingTimeInterval(-60))
        let h = await makeHarness(listing: OneProcess(home: home), installation: installed,
                                  webPlans: Array(repeating: .reject(status: 401), count: 200))
        await h.connector.start()
        await assertEventually { await h.task("dsh:s-done") != nil }
        await assertEventually { h.health.current.last?.1?.contains("拒绝了 BotBus 的登录") == true }
        XCTAssertEqual(h.health.current.last?.0, .degraded)
        await h.connector.stop()
    }

    // MARK: - 对话记录

    func testReaderOrderDiskThenWeb() async throws {
        let now = Date()
        try writeSession("s-disk", title: "盘上的", events: [
            Self.userMessage("盘上的问题", seq: 1, at: now.addingTimeInterval(-100)),
            ["type": "user/message", "seq": 2, "time": 0, "data": ["content": [["type": "text", "text": "运行时上下文"]],
                                                                   "source": ["kind": "plugin"]]],
            Self.reply("盘上的回答", seq: 3, at: now.addingTimeInterval(-90)),
        ], modified: now.addingTimeInterval(-60))
        let h = await makeHarness(listing: OneProcess(home: home), installation: installed)
        h.web.sessions.withLock { $0 = [FakeDshWeb.summary("s-web", cwd: project, updatedAt: now)] }
        let reader = DshMessageReader(connector: h.connector)
        XCTAssertEqual(reader.kind, .dsh)

        // web 还没连上：盘上有就读盘。
        let disk = try await reader.entries(taskId: "dsh:s-disk", limit: 40)
        XCTAssertEqual(disk.entries.map(\.message.text), ["盘上的问题", "盘上的回答"])
        // 盘上没有、web 也不在：报错。
        do {
            _ = try await reader.entries(taskId: "dsh:s-web", limit: 40)
            XCTFail("应当失败")
        } catch {}

        await h.connector.start()
        await connectWeb(h)
        let web = try await reader.entries(taskId: "dsh:s-web", limit: 40)
        XCTAssertEqual(web.entries.map(\.message.text), ["网页里的提问", "网页里的回答"])
        XCTAssertEqual(h.web.pages.current, 2, "先探游标再取页")
        XCTAssertNil(h.web.streamId("session/follow"), "读记录不 follow")
        // 盘上有的仍然读盘，不问 web。
        _ = try await reader.entries(taskId: "dsh:s-disk", limit: 40)
        XCTAssertEqual(h.web.pages.current, 2)
        await h.connector.stop()
    }
}

private extension JSONValue {
    func replacing(_ key: String, with value: JSONValue) -> JSONValue {
        guard case .object(var object) = self else { return self }
        object[key] = value
        return .object(object)
    }
}
