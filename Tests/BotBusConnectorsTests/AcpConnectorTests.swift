import Foundation
import XCTest
import BotBusProtocol
@testable import BotBusConnectorKit
@testable import BotBusConnectors

final class AcpConnectorTests: XCTestCase {
    private let project = FileManager.default.temporaryDirectory.path

    /// 挂住假 agent 的一扇门，测试结束时自动打开：不让 agent 那头的处理器多活几秒。
    private func heldGate() -> Gate {
        let gate = Gate()
        addTeardownBlock { gate.open() }
        return gate
    }

    func testStartRunsATurnAndReleasesOwnership() async throws {
        let h = await AcpHarness.make()
        let outcome = try await h.connector.start(projectPath: project, prompt: "你好", images: [])
        XCTAssertEqual(outcome.taskId, "acp:my-agent:sess-1")
        XCTAssertTrue(outcome.retainsLiveOwnership)
        await assertEventually { await h.task(outcome.taskId)?.status == .completed }
        let record = await h.task(outcome.taskId)
        XCTAssertEqual(record?.lastMessage, "好的")
        XCTAssertEqual(record?.origin, .watch)
        XCTAssertEqual(record?.title, "你好")
        XCTAssertEqual(h.behavior.methods(), ["initialize", "session/new", "session/prompt"])
        await assertEventually { await h.store.owner(of: outcome.taskId) == .observer }
        XCTAssertEqual(h.queue.requests.withLock { $0.first?.arguments }, ["--acp"])
    }

    func testInitializeDeclaresNoFsOrTerminal() async throws {
        let h = await AcpHarness.make()
        _ = try await h.connector.start(projectPath: project, prompt: "x", images: [])
        let params = h.behavior.params.withLock { $0["initialize"] }
        XCTAssertEqual(params?.path("clientCapabilities", "terminal"), false)
        XCTAssertEqual(params?.path("clientCapabilities", "fs", "writeTextFile"), false)
    }

    func testStartInjectsBotBusMcpServer() async throws {
        let tools = AgentToolsConfiguration(cliPath: "/bin/sh", toolsURL: "http://127.0.0.1:1")
        let h = await AcpHarness.make(tools: tools)
        _ = try await h.connector.start(projectPath: project, prompt: "x", images: [])
        let server = h.behavior.params.withLock { $0["session/new"] }?["mcpServers"]?[0]
        XCTAssertEqual(server?["name"], "botbus")
        XCTAssertEqual(server?["command"], "/bin/sh")
        let envNames = server?["env"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
        XCTAssertTrue(envNames.contains(AgentToolsInjection.taskTokenVariable))
    }

    func testPermissionRoundTrip() async throws {
        let behavior = FakeAcpBehavior()
        let answer = Locked<JSONValue>(.null)
        behavior.onPrompt = { agent, sessionId in
            let result = try await agent.request("session/request_permission", params: [
                "sessionId": .string(sessionId),
                "toolCall": ["toolCallId": "call-1", "title": "npm test", "kind": "execute"],
                "options": [
                    ["optionId": "always", "name": "总是", "kind": "allow_always"],
                    ["optionId": "once", "name": "一次", "kind": "allow_once"],
                    ["optionId": "no", "name": "拒绝", "kind": "reject_once"],
                ],
            ])
            answer.withLock { $0 = result }
            return "end_turn"
        }
        let h = await AcpHarness.make(behavior: behavior)
        let outcome = try await h.connector.start(projectPath: project, prompt: "跑测试", images: [])
        await assertEventually { await h.task(outcome.taskId)?.status == .waitingApproval }
        let pending = await h.task(outcome.taskId)?.pendingRequest
        XCTAssertEqual(pending?.id, "call-1")
        XCTAssertEqual(pending?.kind, .command)
        XCTAssertEqual(pending?.summary, "npm test")
        XCTAssertEqual(pending?.questions?.first?.options.map(\.label), ["一次", "总是"], "允许范围按 once、always 列")

        _ = try await h.connector.approve(taskId: outcome.taskId, requestId: "call-1", decision: .allow)
        await assertEventually { await h.task(outcome.taskId)?.status == .completed }
        XCTAssertEqual(answer.withLock { $0 }, ["outcome": ["outcome": "selected", "optionId": "once"]])
    }

    /// 协议 2.14：手机在「允许范围」里明确选了「总是」才发 allow_always。
    func testApproveWithAnswersPicksThatOption() async throws {
        let behavior = FakeAcpBehavior()
        let answer = Locked<JSONValue>(.null)
        behavior.onPrompt = { agent, sessionId in
            let result = try await agent.request("session/request_permission", params: [
                "sessionId": .string(sessionId),
                "toolCall": ["toolCallId": "call-2", "title": "npm test", "kind": "execute"],
                "options": [
                    ["optionId": "always", "name": "总是", "kind": "allow_always"],
                    ["optionId": "once", "name": "一次", "kind": "allow_once"],
                ],
            ])
            answer.withLock { $0 = result }
            return "end_turn"
        }
        let h = await AcpHarness.make(behavior: behavior)
        let outcome = try await h.connector.start(projectPath: project, prompt: "跑测试", images: [])
        await assertEventually { await h.task(outcome.taskId)?.status == .waitingApproval }
        _ = try await h.connector.approve(taskId: outcome.taskId, requestId: "call-2", decision: .allow,
                                          answers: ["scope": ["总是"]])
        await assertEventually { await h.task(outcome.taskId)?.status == .completed }
        XCTAssertEqual(answer.withLock { $0 }, ["outcome": ["outcome": "selected", "optionId": "always"]])
    }

    func testApproveWithoutPendingFails() async throws {
        let h = await AcpHarness.make()
        let outcome = try await h.connector.start(projectPath: project, prompt: "x", images: [])
        await assertEventually { await h.task(outcome.taskId)?.status == .completed }
        do {
            _ = try await h.connector.approve(taskId: outcome.taskId, requestId: "call-1", decision: .allow)
            XCTFail("应当失败")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("没有待审批"))
        }
    }

    func testInterruptCancelsTheTurn() async throws {
        let behavior = FakeAcpBehavior()
        behavior.onPrompt = { _, sessionId in
            while !behavior.cancelled.withLock({ $0.contains(sessionId) }) {
                try await Task.sleep(for: .milliseconds(5))
            }
            return "cancelled"
        }
        let h = await AcpHarness.make(behavior: behavior)
        let outcome = try await h.connector.start(projectPath: project, prompt: "长任务", images: [])
        await assertEventually { await h.task(outcome.taskId)?.status == .running }
        _ = try await h.connector.interrupt(taskId: outcome.taskId)
        await assertEventually { await h.task(outcome.taskId)?.status == .interrupted }
    }

    func testFollowUpWhileRunningIsRejected() async throws {
        let behavior = FakeAcpBehavior()
        let gate = heldGate()
        behavior.onPrompt = { _, _ in await gate.wait(); return "end_turn" }
        let h = await AcpHarness.make(behavior: behavior)
        let outcome = try await h.connector.start(projectPath: project, prompt: "x", images: [])
        do {
            _ = try await h.connector.followUp(taskId: outcome.taskId, prompt: "再来", images: [])
            XCTFail("应当拒绝")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("正在运行"))
        }
        await h.connector.stop()
    }

    func testFollowUpInSameProcessPromptsDirectly() async throws {
        let h = await AcpHarness.make()
        let outcome = try await h.connector.start(projectPath: project, prompt: "第一句", images: [])
        await assertEventually { await h.task(outcome.taskId)?.status == .completed }
        _ = try await h.connector.followUp(taskId: outcome.taskId, prompt: "第二句", images: [])
        await assertEventually { h.behavior.methods().filter { $0 == "session/prompt" }.count == 2 }
        XCTAssertFalse(h.behavior.methods().contains("session/load"))
        let (entries, _) = try await h.connector.entries(taskId: outcome.taskId, limit: 40)
        XCTAssertEqual(entries.filter { $0.message.role == .user }.map(\.message.text), ["第一句", "第二句"])
    }

    func testFollowUpOnUnknownSessionNeedsLoadSession() async throws {
        let h = await AcpHarness.make()
        await h.store.upsert(acpRecord("my-agent", "old", status: .completed, cwd: project))
        do {
            _ = try await h.connector.followUp(taskId: "acp:my-agent:old", prompt: "继续", images: [])
            XCTFail("应当拒绝")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("不支持续聊"))
        }
    }

    func testFollowUpLoadsSessionAndReplaysHistory() async throws {
        let behavior = FakeAcpBehavior()
        behavior.capabilities = ["loadSession": true]
        behavior.onLoad = { agent, sessionId in
            await agent.notify("session/update", params: ["sessionId": .string(sessionId),
                "update": ["sessionUpdate": "user_message_chunk", "content": ["type": "text", "text": "以前的问题"]]])
            await agent.notify("session/update", params: ["sessionId": .string(sessionId),
                "update": ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "以前的回答"]]])
        }
        let h = await AcpHarness.make(behavior: behavior)
        await h.store.upsert(acpRecord("my-agent", "old", status: .completed, cwd: project))
        _ = try await h.connector.followUp(taskId: "acp:my-agent:old", prompt: "继续", images: [])
        await assertEventually { await h.task("acp:my-agent:old")?.status == .completed }
        XCTAssertEqual(h.behavior.methods(), ["initialize", "session/load", "session/prompt"])
        let (entries, _) = try await h.connector.entries(taskId: "acp:my-agent:old", limit: 40)
        XCTAssertEqual(entries.map(\.message.text), ["以前的问题", "以前的回答", "继续", "好的"])
    }

    func testEntriesLoadHistoryOnDemand() async throws {
        let behavior = FakeAcpBehavior()
        behavior.capabilities = ["loadSession": true]
        behavior.onLoad = { agent, sessionId in
            await agent.notify("session/update", params: ["sessionId": .string(sessionId),
                "update": ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "历史"]]])
        }
        let h = await AcpHarness.make(behavior: behavior)
        await h.store.upsert(acpRecord("my-agent", "old", cwd: project))
        let (entries, _) = try await h.connector.entries(taskId: "acp:my-agent:old", limit: 40)
        XCTAssertEqual(entries.map(\.message.text), ["历史"])
    }

    func testImagesNeedCapability() async throws {
        let h = await AcpHarness.make()
        let image = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: image)
        do {
            _ = try await h.connector.start(projectPath: project, prompt: "看图", images: [image])
            XCTFail("应当拒绝")
        } catch {
            XCTAssertEqual(error.localizedDescription, "这个 Agent 暂不支持发图")
        }
    }

    func testAuthRequiredReportsDegraded() async {
        let behavior = FakeAcpBehavior()
        behavior.newSessionError = JSONRPCError(code: AcpProtocol.authRequiredCode, message: "auth_required")
        let h = await AcpHarness.make(behavior: behavior)
        do {
            _ = try await h.connector.start(projectPath: project, prompt: "x", images: [])
            XCTFail("应当失败")
        } catch {
            XCTAssertEqual(error.localizedDescription, "请在电脑上登录 My Agent")
        }
        XCTAssertTrue(h.health.withLock { $0 }.contains { $0.0 == .degraded })
        XCTAssertEqual(h.handshakeFailures.current, 0, "要登录不是握手失败")
    }

    func testCrashFailsTheRunningTurn() async throws {
        let behavior = FakeAcpBehavior()
        let gate = heldGate()
        behavior.onPrompt = { _, _ in await gate.wait(); return "end_turn" }
        let h = await AcpHarness.make(behavior: behavior)
        let outcome = try await h.connector.start(projectPath: project, prompt: "x", images: [])
        h.agent.crash()
        await assertEventually { await h.task(outcome.taskId)?.status == .failed }
        await assertEventually { h.health.withLock { $0 }.contains { $0.0 == .error } }
        XCTAssertEqual(h.handshakeFailures.current, 0, "握手成功之后的崩溃不是握手失败")
    }

    func testInitializeTimeoutReportsError() async {
        let silent = FakeAcpBehavior()
        let h = await AcpHarness.make(behavior: silent, initializeTimeout: 0.05)
        let gate = heldGate()
        await h.agent.peer.setHandlers(request: { _, _ in
            await gate.wait()
            return .null
        }, notification: nil)
        do {
            _ = try await h.connector.start(projectPath: project, prompt: "x", images: [])
            XCTFail("应当超时")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("超时"))
        }
        XCTAssertTrue(h.health.withLock { $0 }.contains { $0.0 == .error })
        XCTAssertEqual(h.handshakeFailures.current, 0, "超时可能只是冷启动慢，不算握手失败")
    }

    func testExitBeforeHandshakeFlagsHandshakeFailure() async {
        let h = await AcpHarness.make()
        h.agent.crash(reason: "usage: my-agent migrate")
        do {
            _ = try await h.connector.start(projectPath: project, prompt: "x", images: [])
            XCTFail("应当失败")
        } catch {}
        XCTAssertEqual(h.health.withLock { $0.last?.0 }, .error)
        XCTAssertEqual(h.handshakeFailures.current, 1)
    }

    func testStopDuringHandshakeIsNotAHandshakeFailure() async {
        let behavior = FakeAcpBehavior()
        let gate = heldGate()
        behavior.onInitialize = { await gate.wait() }
        let h = await AcpHarness.make(behavior: behavior)
        let start = Task { try await h.connector.start(projectPath: project, prompt: "x", images: []) }
        await assertEventually { behavior.methods().contains("initialize") }
        await h.connector.stop()
        gate.open()
        do {
            _ = try await start.value
            XCTFail("被停掉的那一代不该起来")
        } catch {}
        XCTAssertEqual(h.handshakeFailures.current, 0, "我们自己作废的一代不算握手失败")
        XCTAssertFalse(h.health.withLock { $0 }.contains { $0.0 == .error })
    }

    func testSpawnErrorFlagsHandshakeFailure() async throws {
        let h = await AcpHarness.make()
        _ = try h.queue.next() // 把唯一的假进程拿走：下一次拉起直接报错
        do {
            _ = try await h.connector.start(projectPath: project, prompt: "x", images: [])
            XCTFail("应当失败")
        } catch {}
        XCTAssertEqual(h.handshakeFailures.current, 1)
    }

    func testStaticTasksIncludeListedSessions() async throws {
        let behavior = FakeAcpBehavior()
        behavior.capabilities = ["sessionCapabilities": ["list": [:]], "loadSession": true]
        behavior.listed = [["sessionId": "desk", "cwd": .string(project), "title": "电脑上开的",
                            "updatedAt": .string(ProtocolJSON.timestamp(Date()))]]
        let h = await AcpHarness.make(behavior: behavior)
        await h.connector.refreshList()
        let tasks = await h.connector.staticTasks()
        let desk = try XCTUnwrap(tasks.first { $0.id == "acp:my-agent:desk" })
        XCTAssertEqual(desk.origin, .desktop)
        XCTAssertEqual(desk.title, "电脑上开的")
        XCTAssertEqual(desk.status, .completed)
        XCTAssertTrue(desk.controllable, "支持 loadSession 就能续聊")
    }

    func testIdleProcessIsStopped() async throws {
        let h = await AcpHarness.make(idleTimeout: 0.05)
        let outcome = try await h.connector.start(projectPath: project, prompt: "x", images: [])
        await assertEventually { await h.task(outcome.taskId)?.status == .completed }
        await assertEventually { h.agent.terminated.withLock { $0 } }
        let health = h.health.withLock { $0 }
        XCTAssertFalse(health.contains { $0.0 == .error }, "空闲关掉是正常退出，不报错")
    }

    func testNoCommandMeansNoSubprocess() async {
        let h = await AcpHarness.make(executable: nil)
        do {
            _ = try await h.connector.start(projectPath: project, prompt: "x", images: [])
            XCTFail("应当失败")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("没法从手机新建任务"))
        }
        XCTAssertEqual(h.queue.requests.withLock { $0.count }, 0)
    }

    // MARK: - 并发与进程生命周期（计划之外补的回归）

    func testIdleTimerDoesNotKillProcessDuringSessionNew() async throws {
        let behavior = FakeAcpBehavior()
        behavior.onNewSession = { try? await Task.sleep(for: .milliseconds(150)) }
        let h = await AcpHarness.make(behavior: behavior, idleTimeout: 0.02)
        let outcome = try await h.connector.start(projectPath: project, prompt: "x", images: [])
        await assertEventually { await h.task(outcome.taskId)?.status == .completed }
        XCTAssertEqual(h.behavior.methods(), ["initialize", "session/new", "session/prompt"])
    }

    func testStopInterruptsRunningTurnWithoutReportingError() async throws {
        let behavior = FakeAcpBehavior()
        let gate = heldGate()
        behavior.onPrompt = { _, _ in await gate.wait(); return "end_turn" }
        let h = await AcpHarness.make(behavior: behavior)
        let outcome = try await h.connector.start(projectPath: project, prompt: "x", images: [])
        await h.connector.stop()
        await assertEventually { await h.task(outcome.taskId)?.status == .interrupted }
        await assertEventually { await h.store.owner(of: outcome.taskId) == .observer }
        let running = await h.connector.isRunning
        XCTAssertFalse(running)
        XCTAssertFalse(h.health.withLock { $0 }.contains { $0.0 == .error }, "主动停掉不是故障")
    }

    func testCrashedProcessIsRelaunchedForTheNextCommand() async throws {
        let store = makeAcpStore()
        let behavior = FakeAcpBehavior()
        let first = await FakeAcpAgent.make(behavior)
        let second = await FakeAcpAgent.make(behavior)
        let queue = FakeAgentQueue([first, second])
        let spec = AcpAgentSpec(id: "my-agent", name: "My Agent", executable: "/usr/local/bin/my-agent",
                                arguments: [], environment: [:], origin: .manifest, defaultEnabled: true)
        let connector = AcpConnector(spec: spec, store: store, launcher: queue.factory, clientVersion: "1.0")
        let one = try await connector.start(projectPath: project, prompt: "一", images: [])
        await assertEventually { await store.task(id: one.taskId)?.status == .completed }
        first.crash()
        await assertEventually { await !connector.isRunning }
        let two = try await connector.start(projectPath: project, prompt: "二", images: [])
        await assertEventually { await store.task(id: two.taskId)?.status == .completed }
        XCTAssertEqual(queue.requests.withLock { $0.count }, 2)
    }

    func testConcurrentReadAndFollowUpShareOneLoad() async throws {
        let behavior = FakeAcpBehavior()
        behavior.capabilities = ["loadSession": true]
        behavior.onLoad = { agent, sessionId in
            try? await Task.sleep(for: .milliseconds(50))
            await agent.notify("session/update", params: ["sessionId": .string(sessionId),
                "update": ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "历史"]]])
        }
        let h = await AcpHarness.make(behavior: behavior)
        await h.store.upsert(acpRecord("my-agent", "old", status: .completed, cwd: project))
        async let read = h.connector.entries(taskId: "acp:my-agent:old", limit: 40)
        async let follow = h.connector.followUp(taskId: "acp:my-agent:old", prompt: "继续", images: [])
        _ = try await (read, follow)
        await assertEventually { await h.task("acp:my-agent:old")?.status == .completed }
        XCTAssertEqual(h.behavior.methods().filter { $0 == "session/load" }.count, 1)
        let (entries, _) = try await h.connector.entries(taskId: "acp:my-agent:old", limit: 40)
        XCTAssertEqual(entries.map(\.message.text), ["历史", "继续", "好的"])
    }

    func testSpecChangeRelaunchesWithNewCommand() async throws {
        let store = makeAcpStore()
        let behavior = FakeAcpBehavior()
        let queue = FakeAgentQueue([await FakeAcpAgent.make(behavior), await FakeAcpAgent.make(behavior)])
        var spec = AcpAgentSpec(id: "my-agent", name: "My Agent", executable: "/usr/local/bin/my-agent",
                                arguments: [], environment: [:], origin: .manifest, defaultEnabled: true)
        let health = Locked<[ConnectorInfo.Status]>([])
        let connector = AcpConnector(spec: spec, store: store, launcher: queue.factory, clientVersion: "1.0",
                                     onHealth: { _, status, _, _ in health.withLock { $0.append(status) } })
        let one = try await connector.start(projectPath: project, prompt: "一", images: [])
        await assertEventually { await store.task(id: one.taskId)?.status == .completed }
        spec.arguments = ["--acp"]
        await connector.update(spec: spec)
        _ = try await connector.start(projectPath: project, prompt: "二", images: [])
        XCTAssertEqual(queue.requests.withLock { $0.map(\.arguments) }, [[], ["--acp"]])
        XCTAssertFalse(health.withLock { $0 }.contains(.error))
    }

    // MARK: - 评审补的回归（fix-agentcore: harden ACP connector lifecycle）

    /// hub 每分钟刷一次列表：列表刷新不能把空闲计时一直往后推。
    func testListRefreshDoesNotKeepIdleProcessAlive() async throws {
        let behavior = FakeAcpBehavior()
        behavior.capabilities = ["sessionCapabilities": ["list": [:]]]
        let h = await AcpHarness.make(behavior: behavior, idleTimeout: 0.2)
        let outcome = try await h.connector.start(projectPath: project, prompt: "x", images: [])
        await assertEventually { await h.task(outcome.taskId)?.status == .completed }
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline, !h.agent.terminated.withLock({ $0 }) {
            await h.connector.refreshList()
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(h.agent.terminated.withLock { $0 }, "只有列表刷新时进程应按空闲关掉")
    }

    /// 握手期间反向连接接管了会话：不能再对子进程 `session/load`，也不能清掉反向连接报的记录。
    func testReverseTakeoverDuringLaunchAbortsFollowUpLoad() async throws {
        let gate = heldGate()
        let behavior = FakeAcpBehavior()
        behavior.capabilities = ["loadSession": true]
        behavior.onInitialize = { await gate.wait() }
        let h = await AcpHarness.make(behavior: behavior)
        await h.store.upsert(acpRecord("my-agent", "old", status: .completed, cwd: project))
        let follow = Task { try await h.connector.followUp(taskId: "acp:my-agent:old", prompt: "继续", images: []) }
        await assertEventually { h.behavior.methods().contains("initialize") }
        await h.connector.takeOverForTesting("old", record: acpRecord("my-agent", "old", cwd: project), text: "电脑上的")
        gate.open()
        do {
            _ = try await follow.value
            XCTFail("应当走反向连接")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("请在电脑上继续"), error.localizedDescription)
        }
        XCTAssertEqual(h.behavior.methods(), ["initialize"], "不能对子进程发 session/load 或 prompt")
        let (entries, _) = try await h.connector.entries(taskId: "acp:my-agent:old", limit: 40)
        XCTAssertEqual(entries.map(\.message.text), ["电脑上的"])
    }

    func testReverseTakeoverDuringLaunchReturnsReverseTranscript() async throws {
        let gate = heldGate()
        let behavior = FakeAcpBehavior()
        behavior.capabilities = ["loadSession": true]
        behavior.onInitialize = { await gate.wait() }
        let h = await AcpHarness.make(behavior: behavior)
        await h.store.upsert(acpRecord("my-agent", "old", status: .completed, cwd: project))
        let read = Task { try await h.connector.entries(taskId: "acp:my-agent:old", limit: 40) }
        await assertEventually { h.behavior.methods().contains("initialize") }
        await h.connector.takeOverForTesting("old", record: acpRecord("my-agent", "old", cwd: project), text: "电脑上的")
        gate.open()
        let (entries, _) = try await read.value
        XCTAssertEqual(entries.map(\.message.text), ["电脑上的"])
        XCTAssertFalse(h.behavior.methods().contains("session/load"))
    }

    /// 重新载入失败（要登录）时，原来那份对话记录要留着，读记录退回它。
    func testFailedReloadKeepsTheOldTranscript() async throws {
        let store = makeAcpStore()
        let behavior = FakeAcpBehavior()
        behavior.capabilities = ["loadSession": true]
        let first = await FakeAcpAgent.make(behavior)
        let queue = FakeAgentQueue([first, await FakeAcpAgent.make(behavior)])
        let connector = AcpConnector(spec: Self.spec, store: store, launcher: queue.factory, clientVersion: "1.0")
        let outcome = try await connector.start(projectPath: project, prompt: "x", images: [])
        await assertEventually { await store.task(id: outcome.taskId)?.status == .completed }
        first.crash()
        await assertEventually { await !connector.isRunning }
        behavior.loadError = JSONRPCError(code: AcpProtocol.authRequiredCode, message: "auth_required")
        let (entries, _) = try await connector.entries(taskId: outcome.taskId, limit: 40)
        XCTAssertEqual(entries.map(\.message.text), ["x", "好的"])
        do {
            _ = try await connector.followUp(taskId: outcome.taskId, prompt: "再来", images: [])
            XCTFail("应当失败")
        } catch {
            XCTAssertEqual(error.localizedDescription, "请在电脑上登录 My Agent")
        }
        let (again, _) = try await connector.entries(taskId: outcome.taskId, limit: 40)
        XCTAssertEqual(again.count, 2)
    }

    /// 登录过期报了 degraded 之后，再有请求成功就要报回 ok。
    func testDegradedRecoversAfterASuccessfulRequest() async throws {
        let behavior = FakeAcpBehavior()
        behavior.newSessionError = JSONRPCError(code: AcpProtocol.authRequiredCode, message: "auth_required")
        let h = await AcpHarness.make(behavior: behavior)
        _ = try? await h.connector.start(projectPath: project, prompt: "x", images: [])
        XCTAssertEqual(h.health.withLock { $0.last?.0 }, .degraded)
        behavior.newSessionError = nil
        let outcome = try await h.connector.start(projectPath: project, prompt: "x", images: [])
        await assertEventually { await h.task(outcome.taskId)?.status == .completed }
        XCTAssertEqual(h.health.withLock { $0.last?.0 }, .ok)
    }

    /// 停用后 hub 立刻丢掉连接器：在跑的一轮必须在 stop() 里就收尾，不能卡在 live / running。
    func testStopFinalisesRunningTurnEvenIfConnectorIsDropped() async throws {
        let gate = heldGate()
        let store = makeAcpStore()
        let behavior = FakeAcpBehavior()
        behavior.onPrompt = { _, _ in await gate.wait(); return "end_turn" }
        let queue = FakeAgentQueue([await FakeAcpAgent.make(behavior)])
        var connector: AcpConnector? = AcpConnector(spec: Self.spec, store: store, launcher: queue.factory,
                                                    clientVersion: "1.0")
        let outcome = try await connector!.start(projectPath: project, prompt: "x", images: [])
        await connector?.stop()
        connector = nil
        let status = await store.task(id: outcome.taskId)?.status
        let owner = await store.owner(of: outcome.taskId)
        XCTAssertEqual(status, .interrupted)
        XCTAssertEqual(owner, .observer)
    }

    func testArchiveKeepsNoConversationContent() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("acp-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        // 时间用现在：超出最近窗口的记录存盘时会被剪掉。
        var record = acpRecord("my-agent", "s1", updatedAt: ProtocolJSON.timestamp(Date()))
        record.lastMessage = "机密回复"
        record.pendingRequest = PendingRequest(id: "call-1", kind: .command, summary: "rm -rf", detail: "rm -rf /")
        await AcpSessionArchive(url: url).remember(connectorId: "my-agent", record: record)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("机密回复"))
        XCTAssertFalse(text.contains("rm -rf"))
        let reloaded = await AcpSessionArchive(url: url).records(connectorId: "my-agent")
        XCTAssertEqual(reloaded.map(\.id), [record.id])
        XCTAssertNil(reloaded.first?.lastMessage)
    }

    /// BotBus 拉起的会话以本机记录为准（来源、状态），列表里更新的标题与时间照收。
    func testArchivedRecordWinsOverListing() async throws {
        let behavior = FakeAcpBehavior()
        behavior.capabilities = ["sessionCapabilities": ["list": [:]]]
        let listedAt = Date()
        behavior.listed = [["sessionId": "s1", "cwd": .string(project), "title": "电脑上改的名",
                            "updatedAt": .string(ProtocolJSON.timestamp(listedAt))]]
        let archive = AcpSessionArchive(url: nil)
        var record = acpRecord("my-agent", "s1", status: .interrupted,
                               updatedAt: ProtocolJSON.timestamp(listedAt.addingTimeInterval(-60)), cwd: project)
        record.origin = .watch
        await archive.remember(connectorId: "my-agent", record: record)
        let queue = FakeAgentQueue([await FakeAcpAgent.make(behavior)])
        let connector = AcpConnector(spec: Self.spec, store: makeAcpStore(), launcher: queue.factory,
                                     archive: archive, clientVersion: "1.0")
        await connector.refreshList()
        let tasks = await connector.staticTasks()
        let task = try XCTUnwrap(tasks.first { $0.id == record.id })
        XCTAssertEqual(task.origin, .watch)
        XCTAssertEqual(task.status, .interrupted)
        XCTAssertEqual(task.title, "电脑上改的名")
        XCTAssertEqual(task.updatedAt, ProtocolJSON.timestamp(listedAt))
    }

    /// 起 `limit + 1` 个跑完的会话（时钟每次 +1 秒，好按时间排出先后），返回连接器与假 agent 的行为。
    private func cappedConnector(limit: Int, loadSession: Bool) async throws -> (AcpConnector, FakeAcpBehavior) {
        let clock = Locked(0)
        let behavior = FakeAcpBehavior()
        behavior.capabilities = ["loadSession": .bool(loadSession)]
        let queue = FakeAgentQueue([await FakeAcpAgent.make(behavior)])
        let connector = AcpConnector(spec: Self.spec, store: makeAcpStore(), launcher: queue.factory,
                                     clientVersion: "1.0",
                                     now: { Date(timeIntervalSince1970: 1_800_000_000 + Double(clock.withLock { $0 += 1; return $0 })) })
        await connector.setTranscriptLimitForTesting(limit)
        for _ in 0...limit {
            let id = try await connector.start(projectPath: project, prompt: "x", images: []).taskId
            await assertEventually { await connector.sessions[AcpTaskID.parse(id)!.sessionId].map { !$0.running } ?? false }
        }
        return (connector, behavior)
    }

    func testTranscriptsAreCappedInMemory() async throws {
        let (connector, behavior) = try await cappedConnector(limit: 2, loadSession: true)
        let kept = await connector.sessions.values.filter { !$0.transcript.isEmpty }.count
        XCTAssertEqual(kept, 2)
        let oldest = await connector.sessions["sess-1"]
        XCTAssertEqual(oldest?.transcript.isEmpty, true, "最久没动的会话丢掉对话记录")
        XCTAssertNotNil(oldest?.record, "任务记录还在")
        let newest = await connector.sessions["sess-3"]
        XCTAssertEqual(newest?.transcript.isEmpty, false)
        // 支持 session/load：被丢的会话要看时重新载入。
        _ = try await connector.entries(taskId: "acp:my-agent:sess-1", limit: 40)
        XCTAssertTrue(behavior.methods().contains("session/load"))
    }

    /// 不支持 `session/load` 的 agent：丢掉对话记录的会话在当前进程里仍能续聊，不去载入。
    func testEvictionKeepsSessionsContinuableWithoutLoadSession() async throws {
        let (connector, behavior) = try await cappedConnector(limit: 1, loadSession: false)
        let evicted = await connector.sessions["sess-1"]
        XCTAssertEqual(evicted?.transcript.isEmpty, true)
        _ = try await connector.followUp(taskId: "acp:my-agent:sess-1", prompt: "继续", images: [])
        await assertEventually { behavior.methods().filter { $0 == "session/prompt" }.count == 3 }
        XCTAssertFalse(behavior.methods().contains("session/load"))
    }

    /// stop() 收尾之后分发器才 claim（start 刚回执、agent 就被停用）：延迟补放要把它放掉，连接器已被丢掉也一样。
    func testStopReleaseSurvivesLateDispatcherClaim() async throws {
        let gate = heldGate()
        let store = makeAcpStore()
        let behavior = FakeAcpBehavior()
        behavior.onPrompt = { _, _ in await gate.wait(); return "end_turn" }
        let queue = FakeAgentQueue([await FakeAcpAgent.make(behavior)])
        var connector: AcpConnector? = AcpConnector(spec: Self.spec, store: store, launcher: queue.factory,
                                                    clientVersion: "1.0")
        let outcome = try await connector!.start(projectPath: project, prompt: "x", images: [])
        await connector?.stop()
        connector = nil
        await store.claimLive(outcome.taskId)
        await assertEventually(timeout: 3) { await store.owner(of: outcome.taskId) == .observer }
    }

    func testNoCommandFollowUpAndEntriesExplainThemselves() async {
        let h = await AcpHarness.make(executable: nil)
        await h.store.upsert(acpRecord("my-agent", "old", cwd: project))
        do {
            _ = try await h.connector.followUp(taskId: "acp:my-agent:old", prompt: "x", images: [])
            XCTFail("应当失败")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("只能在电脑上继续"), error.localizedDescription)
        }
        do {
            _ = try await h.connector.entries(taskId: "acp:my-agent:old", limit: 40)
            XCTFail("应当失败")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("读不到对话记录"), error.localizedDescription)
        }
    }

    /// 本机记录和 `session/list` 一样只显示最近窗口（7 天）内的会话。
    func testArchivedRecordsOutsideRecentWindowAreNotListed() async {
        let archive = AcpSessionArchive(url: nil)
        await archive.remember(connectorId: "my-agent",
                               record: acpRecord("my-agent", "old", updatedAt: "2025-01-01T00:00:00Z"))
        await archive.remember(connectorId: "my-agent",
                               record: acpRecord("my-agent", "fresh", updatedAt: ProtocolJSON.timestamp(Date())))
        let connector = AcpConnector(spec: Self.spec, store: makeAcpStore(), archive: archive, clientVersion: "1.0")
        let ids = await connector.staticTasks().map(\.id)
        XCTAssertEqual(ids, ["acp:my-agent:fresh"])
    }

    /// 超出最近窗口的记录存盘时就剪掉，不在本机文件里一直攒着。
    func testArchivePrunesRecordsOutsideRecentWindowOnSave() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("acp-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let archive = AcpSessionArchive(url: url)
        await archive.remember(connectorId: "my-agent",
                               record: acpRecord("my-agent", "old", updatedAt: "2025-01-01T00:00:00Z"))
        await archive.remember(connectorId: "my-agent",
                               record: acpRecord("my-agent", "fresh", updatedAt: ProtocolJSON.timestamp(Date())))
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("acp:my-agent:old"))
        let reloaded = await AcpSessionArchive(url: url).records(connectorId: "my-agent").map(\.id)
        XCTAssertEqual(reloaded, ["acp:my-agent:fresh"])
    }

    /// 公开日志里只记错误类别：进程退出原因里的 stderr、agent 回的文本都不能进去。
    func testLogCategoryCarriesNoMessageText() {
        XCTAssertEqual(AcpConnector.logCategory(JSONRPCPeerError.closed(reason: "agent 进程退出了：API_KEY=secret")), "closed")
        XCTAssertEqual(AcpConnector.logCategory(JSONRPCError(code: -32000, message: "secret prompt")), "rpc error -32000")
        XCTAssertFalse(AcpConnector.logCategory(ConnectorError("secret")).contains("secret"))
    }

    /// 进程在握手前退出：失败原因（带 stderr）照样回给手机，但标成不进公开日志。
    func testLaunchFailureCarryingStderrIsMarkedPrivate() async throws {
        let h = await AcpHarness.make()
        h.agent.crash(reason: "Error: missing API key sk-xxx")
        do {
            _ = try await h.connector.start(projectPath: project, prompt: "x", images: [])
            XCTFail("应当失败")
        } catch let error as ConnectorError {
            XCTAssertTrue(error.containsPrivateDetail, error.message)
        }
    }

    private static let spec = AcpAgentSpec(id: "my-agent", name: "My Agent", executable: "/usr/local/bin/my-agent",
                                           arguments: [], environment: [:], origin: .manifest, defaultEnabled: true)
}

extension AcpConnector {
    func setTranscriptLimitForTesting(_ limit: Int) { transcriptLimit = limit }

    /// 测试用：模拟一条反向连接接管了会话（不经反向扩展的 `_botbus/session`，直接改状态）。
    func takeOverForTesting(_ sessionId: String, record: TaskRecord, text: String) {
        var state = AcpSessionState(record: record)
        state.apply(.agentMessage(text: text, images: []), at: record.updatedAt)
        sessions[sessionId] = state
        reverseOwner[sessionId] = UUID()
        loaded.remove(sessionId)
    }
}
