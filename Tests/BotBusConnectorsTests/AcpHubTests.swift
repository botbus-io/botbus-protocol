import Foundation
import XCTest
import BotBusProtocol
@testable import BotBusConnectorKit
@testable import BotBusConnectors

final class AcpHubTests: XCTestCase {
    /// 临时目录下的子目录，不直接用临时目录：Linux 上它就是 `/tmp`，本身"不算项目"
    /// （`OutsideProjectRule.systemDirectories`），对账不会把它报成项目。
    private let project: String = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("botbus-acp-hub-tests", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }()

    private func spec(_ id: String, origin: AcpAgentSpec.Origin = .registry,
                      arguments: [String] = []) -> AcpAgentSpec {
        AcpAgentSpec(id: id, name: id, executable: "/usr/local/bin/\(id)", arguments: arguments, environment: [:],
                     origin: origin, defaultEnabled: true)
    }

    /// 每个 agent 一条假进程队列（按 id 取）；连接器每拉起一次取队首一个，取完了就报"起不来"。
    private func hub(store: TaskStore, agents: [String: [FakeAcpAgent]]) -> AcpHub {
        AcpHub(store: store) { spec, onHealth, onChanged in
            let queue = FakeAgentQueue(agents[spec.id] ?? [])
            return AcpConnector(spec: spec, store: store, launcher: queue.factory, clientVersion: "1.0",
                                onHealth: onHealth, onTasksChanged: onChanged)
        }
    }

    private func hub(store: TaskStore, agents: [String: FakeAcpAgent]) -> AcpHub {
        hub(store: store, agents: agents.mapValues { [$0] })
    }

    private func info(_ store: TaskStore, _ id: String) -> ConnectorInfo? {
        store.connectors.connectors().first { $0.connectorId == id }
    }

    /// 一个一拉起就退出的假进程（"秒退"）。
    private func deadAgent() async -> FakeAcpAgent {
        let agent = await FakeAcpAgent.make(FakeAcpBehavior())
        agent.crash(reason: "not an ACP agent")
        return agent
    }

    func testRunningAgentIdsReflectProcessExitAndStop() async throws {
        let store = makeAcpStore([])
        let agent = await FakeAcpAgent.make(FakeAcpBehavior())
        let hub = hub(store: store, agents: ["gemini": agent])
        await hub.sync([spec("gemini")])
        _ = try await hub.start(connectorId: "gemini", projectPath: project, prompt: "hi", images: [])
        let running = await hub.runningAgentIds()
        XCTAssertEqual(running, ["gemini"])
        agent.crash(reason: "exited")
        await assertEventually { await hub.runningAgentIds().isEmpty }
        await hub.stop()
        let stopped = await hub.runningAgentIds()
        XCTAssertTrue(stopped.isEmpty)
    }

    func testSyncPublishesRegistryEntries() async {
        let store = makeAcpStore([])
        let hub = hub(store: store, agents: [String: FakeAcpAgent]())
        await hub.sync([spec("gemini"), spec("goose")])
        XCTAssertEqual(store.connectors.acpIds.sorted(), ["gemini", "goose"])
        await hub.sync([spec("gemini")])
        XCTAssertEqual(store.connectors.acpIds, ["gemini"])
    }

    func testStartRoutesByConnectorId() async throws {
        let store = makeAcpStore([])
        let behavior = FakeAcpBehavior()
        let hub = hub(store: store, agents: ["gemini": await FakeAcpAgent.make(behavior)])
        await hub.sync([spec("gemini")])
        let outcome = try await hub.start(connectorId: "gemini", projectPath: project, prompt: "hi", images: [])
        XCTAssertEqual(outcome.taskId, "acp:gemini:sess-1")
        await assertEventually { await store.task(id: outcome.taskId)?.status == .completed }
    }

    func testUnknownAndDisabledAgentsAreRejected() async {
        let store = makeAcpStore([])
        let hub = hub(store: store, agents: [String: FakeAcpAgent]())
        await hub.sync([spec("gemini")])
        do {
            _ = try await hub.start(connectorId: "nope", projectPath: project, prompt: "hi", images: [])
            XCTFail("应当失败")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("没有这个 ACP agent"))
        }
        store.connectors.setAcpEnabled(false, for: "gemini")
        do {
            _ = try await hub.followUp(taskId: "acp:gemini:s", prompt: "hi", images: [])
            XCTFail("应当失败")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("已停用"))
        }
        do {
            _ = try await hub.entries(taskId: "acp:gemini:s", limit: 10)
            XCTFail("停用的 agent 也不给对话记录")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("已停用"))
        }
    }

    func testPlainStartWithoutConnectorIdFails() async {
        let hub = hub(store: makeAcpStore([]), agents: [String: FakeAcpAgent]())
        do {
            _ = try await hub.start(projectPath: project, prompt: "hi", images: [])
            XCTFail("应当失败")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("connectorId"))
        }
    }

    func testDispatcherPassesConnectorIdForAcpStartTask() async {
        let store = makeAcpStore([])
        let behavior = FakeAcpBehavior()
        let hub = hub(store: store, agents: ["gemini": await FakeAcpAgent.make(behavior)])
        await hub.sync([spec("gemini")])
        let dispatcher = CommandDispatcher(store: store, connectors: [hub], readers: [hub])
        let ok = await dispatcher.handle(.startTask(.init(source: .acp, projectPath: project, prompt: "hi",
                                                          connectorId: "gemini"),
                                                    createdAt: "2026-09-26T08:00:00Z", id: "c1", agentId: "agent-1"))
        XCTAssertTrue(ok.ok, ok.error ?? "")
        XCTAssertEqual(ok.taskId, "acp:gemini:sess-1")

        let fetched = await dispatcher.handle(.fetchMessages(.init(taskId: "acp:gemini:sess-1"),
                                                             createdAt: "2026-09-26T08:00:00Z", id: "c2",
                                                             agentId: "agent-1"))
        XCTAssertTrue(fetched.ok, fetched.error ?? "")
    }

    func testDispatcherRejectsAcpStartTaskWithoutConnectorId() async {
        let store = makeAcpStore([])
        let hub = hub(store: store, agents: [String: FakeAcpAgent]())
        await hub.sync([spec("gemini")])
        let dispatcher = CommandDispatcher(store: store, connectors: [hub], readers: [hub])
        let result = await dispatcher.handle(.startTask(.init(source: .acp, projectPath: project, prompt: "hi"),
                                                        createdAt: "2026-09-26T08:00:00Z", id: "c1",
                                                        agentId: "agent-1"))
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.error, "ACP 任务缺少 connectorId")
    }

    func testDispatcherRegistersReaderLate() async {
        let store = makeAcpStore([])
        let behavior = FakeAcpBehavior()
        let hub = hub(store: store, agents: ["gemini": await FakeAcpAgent.make(behavior)])
        await hub.sync([spec("gemini")])
        // 分发器先建好，hub 配对之后才有：连接器与读取器都要能后补。
        let dispatcher = CommandDispatcher(store: store, connectors: [], readers: [])
        await dispatcher.register(hub)
        await dispatcher.register(reader: hub)
        let started = await dispatcher.handle(.startTask(.init(source: .acp, projectPath: project, prompt: "hi",
                                                               connectorId: "gemini"),
                                                         createdAt: "2026-09-26T08:00:00Z", id: "c1",
                                                         agentId: "agent-1"))
        XCTAssertTrue(started.ok, started.error ?? "")
        let fetched = await dispatcher.handle(.fetchMessages(.init(taskId: "acp:gemini:sess-1"),
                                                             createdAt: "2026-09-26T08:00:00Z", id: "c2",
                                                             agentId: "agent-1"))
        XCTAssertTrue(fetched.ok, fetched.error ?? "")
    }

    /// agent 不可用时不能先建新项目文件夹再失败：重试会变成"已经存在"。
    func testUnavailableAcpAgentFailsBeforeCreatingNewProjectFolder() async throws {
        let store = makeAcpStore([])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("acp-hub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        await store.setProjectsRoot(root.path)
        let hub = hub(store: store, agents: ["goose": await deadAgent()])
        await hub.sync([spec("gemini"), spec("goose")])
        store.connectors.setAcpEnabled(false, for: "gemini")
        _ = try? await hub.start(connectorId: "goose", projectPath: project, prompt: "hi", images: []) // 藏起来
        let dispatcher = CommandDispatcher(store: store, connectors: [hub], readers: [hub])
        let cases: [(connectorId: String?, error: String)] = [
            ("gemini", "gemini 已停用"),
            ("goose", "本机没有这个 ACP agent：goose"),
            ("nope", "本机没有这个 ACP agent：nope"),
            (nil, "ACP 任务缺少 connectorId"),
        ]
        for (index, item) in cases.enumerated() {
            let name = "foo\(index)"
            let result = await dispatcher.handle(.startTask(.init(source: .acp, projectPath: "", prompt: "hi",
                                                                  newProject: name, connectorId: item.connectorId),
                                                            createdAt: "2026-09-26T08:00:00Z", id: "c\(index)",
                                                            agentId: "agent-1"))
            XCTAssertFalse(result.ok)
            XCTAssertEqual(result.error, item.error)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path),
                           "\(item.connectorId ?? "nil")：失败之前不该建文件夹")
        }
    }

    func testDisablingAgentDropsItsProjects() async throws {
        let store = makeAcpStore([])
        let hub = hub(store: store, agents: ["gemini": await FakeAcpAgent.make(FakeAcpBehavior())])
        await hub.sync([spec("gemini")])
        let outcome = try await hub.start(connectorId: "gemini", projectPath: project, prompt: "hi", images: [])
        await assertEventually { await store.owner(of: outcome.taskId) == .observer }
        await hub.reconcile()
        let before = await store.snapshot().projects.map(\.path)
        XCTAssertEqual(before.count, 1, "对账把任务的项目报上去")
        await store.setAcpConnectorEnabled("gemini", enabled: false)
        await hub.applyEnabledState()
        let after = await store.snapshot().projects
        XCTAssertEqual(after, [], "停用之后它的项目也不再报")
    }

    func testIdleGateSkipsNonRunningAgentWithinWindow() async throws {
        let store = makeAcpStore([])
        let behavior = FakeAcpBehavior()
        behavior.capabilities = ["sessionCapabilities": ["list": [:]], "loadSession": false]
        let queue = FakeAgentQueue([await FakeAcpAgent.make(behavior), await FakeAcpAgent.make(behavior)])
        let made = Locked<AcpConnector?>(nil)
        let hub = AcpHub(store: store) { spec, onHealth, onChanged in
            // 空闲超时设成 0：只为列表拉起的进程刷完就关，好看"没在跑"的那一支。
            let connector = AcpConnector(spec: spec, store: store, launcher: queue.factory, clientVersion: "1.0",
                                         idleTimeout: 0, onHealth: onHealth, onTasksChanged: onChanged)
            made.withLock { $0 = connector }
            return connector
        }
        await hub.sync([spec("gemini")])
        let connector = try XCTUnwrap(made.current)
        let start = Date()
        await hub.refreshLists(now: start)
        XCTAssertEqual(queue.requests.withLock { $0.count }, 1)
        await assertEventually { await connector.isRunning == false }
        await hub.refreshLists(now: start.addingTimeInterval(AcpHub.listInterval))
        XCTAssertEqual(queue.requests.withLock { $0.count }, 1, "没在跑的 agent 在 \(Int(AcpHub.idleListInterval)) 秒内不再拉起")
        await hub.refreshLists(now: start.addingTimeInterval(AcpHub.idleListInterval))
        XCTAssertEqual(queue.requests.withLock { $0.count }, 2, "过了窗口再拉起一次")
    }

    func testDisabledAgentIsNotRefreshed() async {
        let store = makeAcpStore([])
        let queue = FakeAgentQueue([await FakeAcpAgent.make(FakeAcpBehavior())])
        let hub = AcpHub(store: store) { spec, onHealth, onChanged in
            AcpConnector(spec: spec, store: store, launcher: queue.factory, clientVersion: "1.0",
                         onHealth: onHealth, onTasksChanged: onChanged)
        }
        await hub.sync([spec("gemini")])
        store.connectors.setAcpEnabled(false, for: "gemini")
        await hub.refreshLists(now: Date())
        XCTAssertEqual(queue.requests.withLock { $0.count }, 0)
    }

    func testReconcileKeepsTasksAfterTurnEnds() async throws {
        let store = makeAcpStore([])
        let behavior = FakeAcpBehavior()
        let hub = hub(store: store, agents: ["gemini": await FakeAcpAgent.make(behavior)])
        await hub.sync([spec("gemini")])
        let outcome = try await hub.start(connectorId: "gemini", projectPath: project, prompt: "hi", images: [])
        await assertEventually { await store.owner(of: outcome.taskId) == .observer }
        await hub.reconcile()
        let task = await store.task(id: outcome.taskId)
        XCTAssertEqual(task?.status, .completed, "交还之后对账接住，不会消失")
    }

    func testRemovedAgentStopsAndItsTasksLeave() async throws {
        let store = makeAcpStore([])
        let behavior = FakeAcpBehavior()
        let agent = await FakeAcpAgent.make(behavior)
        let hub = hub(store: store, agents: ["gemini": agent])
        await hub.sync([spec("gemini")])
        let outcome = try await hub.start(connectorId: "gemini", projectPath: project, prompt: "hi", images: [])
        await assertEventually { await store.task(id: outcome.taskId)?.status == .completed }
        await hub.sync([])
        XCTAssertTrue(agent.terminated.withLock { $0 }, "发现结果里没了的 agent 要关掉进程")
        XCTAssertEqual(store.connectors.acpIds, [])
        // store 里的记录要等交接宽限过了才摘，但快照里立刻就没了。
        let visible = await store.snapshot().tasks.map(\.id)
        XCTAssertFalse(visible.contains(outcome.taskId))
    }

    // MARK: - 计划补丁 Step 5b：注册表 agent 第一次握手就是验证

    func testRegistryAgentThatFailsHandshakeIsHidden() async {
        let store = makeAcpStore([])
        let hub = hub(store: store, agents: ["goose": await deadAgent()])
        await hub.sync([spec("goose"), spec("gemini")])
        XCTAssertEqual(store.connectors.acpIds.sorted(), ["gemini", "goose"])
        do {
            _ = try await hub.start(connectorId: "goose", projectPath: project, prompt: "hi", images: [])
            XCTFail("应当失败")
        } catch {}
        XCTAssertEqual(store.connectors.acpIds, ["gemini"], "认错了的可执行文件（数据库迁移工具）不显示")
        do {
            _ = try await hub.start(connectorId: "goose", projectPath: project, prompt: "hi", images: [])
            XCTFail("隐藏之后不再接命令")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("没有这个 ACP agent"))
        }
        // 同样的发现结果再来一遍不复活。
        await hub.sync([spec("goose"), spec("gemini")])
        XCTAssertEqual(store.connectors.acpIds, ["gemini"])
    }

    func testRegistryAgentThatCannotSpawnIsHidden() async {
        let store = makeAcpStore([])
        let hub = hub(store: store, agents: [String: FakeAcpAgent]()) // 拉起即报错
        await hub.sync([spec("goose")])
        _ = try? await hub.start(connectorId: "goose", projectPath: project, prompt: "hi", images: [])
        XCTAssertEqual(store.connectors.acpIds, [])
    }

    func testFirstListRefreshVerifiesAndHiddenAgentsAreNotRelaunched() async {
        let store = makeAcpStore([])
        let queue = FakeAgentQueue([await deadAgent()])
        let hub = AcpHub(store: store) { spec, onHealth, onChanged in
            AcpConnector(spec: spec, store: store, launcher: queue.factory, clientVersion: "1.0",
                         onHealth: onHealth, onTasksChanged: onChanged)
        }
        await hub.sync([spec("goose")])
        let start = Date()
        await hub.refreshLists(now: start)
        XCTAssertEqual(store.connectors.acpIds, [], "启动后的第一轮列表刷新就是验证")
        await hub.refreshLists(now: start.addingTimeInterval(AcpHub.idleListInterval + 1))
        XCTAssertEqual(queue.requests.withLock { $0.count }, 1, "藏起来的 agent 不再为刷新列表拉起")
    }

    func testHiddenRegistryAgentReturnsWhenDiscoveryChanges() async {
        let store = makeAcpStore([])
        let hub = hub(store: store, agents: ["goose": await deadAgent()])
        await hub.sync([spec("goose")])
        _ = try? await hub.start(connectorId: "goose", projectPath: project, prompt: "hi", images: [])
        XCTAssertEqual(store.connectors.acpIds, [])
        await hub.sync([spec("goose", arguments: ["acp"])])
        XCTAssertEqual(store.connectors.acpIds, ["goose"], "发现结果变了就重新给一次机会")
        XCTAssertEqual(info(store, "goose")?.status, .ok, "换了启动方式，旧的错误不作数")
    }

    func testInitializeTimeoutKeepsRegistryAgentVisible() async {
        let store = makeAcpStore([])
        let behavior = FakeAcpBehavior()
        let gate = Gate()
        addTeardownBlock { gate.open() }
        behavior.onInitialize = { await gate.wait() }
        let agent = await FakeAcpAgent.make(behavior)
        let hub = AcpHub(store: store) { spec, onHealth, onChanged in
            AcpConnector(spec: spec, store: store, launcher: FakeAgentQueue([agent]).factory, clientVersion: "1.0",
                         initializeTimeout: 0.05, onHealth: onHealth, onTasksChanged: onChanged)
        }
        await hub.sync([spec("gemini")])
        _ = try? await hub.start(connectorId: "gemini", projectPath: project, prompt: "hi", images: [])
        XCTAssertEqual(store.connectors.acpIds, ["gemini"], "冷启动慢的 node agent 不能被藏到 app 重启")
        XCTAssertEqual(info(store, "gemini")?.status, .error)
    }

    func testReverseHelloVerifiesRegistryAgent() async throws {
        let store = makeAcpStore([])
        let hub = hub(store: store, agents: ["goose": [await deadAgent()]])
        await hub.sync([spec("goose")])
        _ = try? await hub.start(connectorId: "goose", projectPath: project, prompt: "hi", images: [])
        XCTAssertEqual(store.connectors.acpIds, [])
        let hello: JSONValue = ["id": "goose", "version": .int(AcpReverseServer.extensionVersion)]
        let reply = try await hub.acceptReverse(UUID(), hello: hello, peer: JSONRPCPeer(send: { _ in }), close: {})
        XCTAssertEqual(reply["accepted"], true)
        XCTAssertEqual(store.connectors.acpIds, ["goose"], "能按扩展握手的就是真的 ACP agent")
        // 验证过了：之后再起不来就照常报错，不再藏。
        _ = try? await hub.start(connectorId: "goose", projectPath: project, prompt: "hi", images: [])
        XCTAssertEqual(store.connectors.acpIds, ["goose"])
        XCTAssertEqual(info(store, "goose")?.status, .error)
    }

    func testManifestAgentThatFailsHandshakeStaysWithError() async {
        let store = makeAcpStore([])
        let hub = hub(store: store, agents: ["mine": await deadAgent()])
        await hub.sync([spec("mine", origin: .manifest)])
        _ = try? await hub.start(connectorId: "mine", projectPath: project, prompt: "hi", images: [])
        XCTAssertEqual(store.connectors.acpIds, ["mine"], "清单是开发者自己登记的：照旧显示，报错对他有用")
        XCTAssertEqual(info(store, "mine")?.status, .error)
        XCTAssertNotNil(info(store, "mine")?.lastError)
    }

    func testAuthRequiredKeepsRegistryAgentVisible() async {
        let store = makeAcpStore([])
        let behavior = FakeAcpBehavior()
        behavior.newSessionError = JSONRPCError(code: AcpProtocol.authRequiredCode, message: "auth_required")
        let hub = hub(store: store, agents: ["gemini": await FakeAcpAgent.make(behavior)])
        await hub.sync([spec("gemini")])
        do {
            _ = try await hub.start(connectorId: "gemini", projectPath: project, prompt: "hi", images: [])
            XCTFail("应当失败")
        } catch {
            XCTAssertEqual(error.localizedDescription, "请在电脑上登录 gemini")
        }
        XCTAssertEqual(store.connectors.acpIds, ["gemini"])
        XCTAssertEqual(info(store, "gemini")?.status, .degraded)
    }

    func testVerifiedRegistryAgentShowsLaterFailuresInsteadOfHiding() async throws {
        let store = makeAcpStore([])
        let behavior = FakeAcpBehavior()
        let agent = await FakeAcpAgent.make(behavior)
        let hub = hub(store: store, agents: ["gemini": agent]) // 只有一个：崩了之后再拉起就起不来
        await hub.sync([spec("gemini")])
        let outcome = try await hub.start(connectorId: "gemini", projectPath: project, prompt: "hi", images: [])
        await assertEventually { await store.task(id: outcome.taskId)?.status == .completed }
        agent.crash()
        await assertEventually { self.info(store, "gemini")?.status == .error }
        _ = try? await hub.start(connectorId: "gemini", projectPath: project, prompt: "again", images: [])
        XCTAssertEqual(store.connectors.acpIds, ["gemini"], "握手成功过就是真的 ACP agent，之后的故障照常报")
        XCTAssertEqual(info(store, "gemini")?.status, .error)
    }

    // MARK: - 退出与开关

    /// App 退出后 hub 是终态：命令失败，已经在途的刷新（或迟到的一轮）也拉不起进程。
    func testShutdownRejectsCommandsAndLaunchesNothing() async {
        let store = makeAcpStore([])
        let queue = FakeAgentQueue([await FakeAcpAgent.make(FakeAcpBehavior())])
        let made = Locked<AcpConnector?>(nil)
        let hub = AcpHub(store: store) { spec, onHealth, onChanged in
            let connector = AcpConnector(spec: spec, store: store, launcher: queue.factory, clientVersion: "1.0",
                                         onHealth: onHealth, onTasksChanged: onChanged)
            made.withLock { $0 = connector }
            return connector
        }
        await hub.sync([spec("gemini")])
        await hub.shutdown()
        do {
            _ = try await hub.start(connectorId: "gemini", projectPath: project, prompt: "hi", images: [])
            XCTFail("退出之后不该再接命令")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("正在退出"), "\(error)")
        }
        do {
            try await hub.checkAvailable(connectorId: "gemini")
            XCTFail("退出之后 checkAvailable 也要失败")
        } catch {}
        // 挂在 `await connector.isRunning` 上的那一轮醒来时 hub 已经退出：hub 这一道拦住。
        await hub.refreshLists(now: Date())
        await hub.startRefreshing()
        await hub.applyEnabledState()
        // 已经越过 hub 的检查、稍后才走到拉起那一步的刷新：连接器那一道拦住。
        await made.current?.refreshList()
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(queue.requests.withLock { $0.count }, 0, "退出之后一个进程都不能再起")
    }

    /// 刚启用的 agent 立刻刷一次列表，不等下一轮；没变的 agent 不跟着刷。
    func testEnablingAgentRefreshesItsListImmediately() async {
        let store = makeAcpStore([])
        let behavior = FakeAcpBehavior()
        behavior.capabilities = ["sessionCapabilities": ["list": [:]], "loadSession": false]
        let queues = ["gemini": FakeAgentQueue([await FakeAcpAgent.make(behavior)]),
                      "goose": FakeAgentQueue([await FakeAcpAgent.make(FakeAcpBehavior())])]
        let hub = AcpHub(store: store) { spec, onHealth, onChanged in
            AcpConnector(spec: spec, store: store, launcher: queues[spec.id]!.factory, clientVersion: "1.0",
                         onHealth: onHealth, onTasksChanged: onChanged)
        }
        await hub.sync([spec("gemini"), spec("goose")])
        await hub.applyEnabledState()
        store.connectors.setAcpEnabled(false, for: "gemini")
        await hub.applyEnabledState()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(queues["gemini"]!.requests.withLock { $0.count }, 0, "停用不刷")
        XCTAssertEqual(queues["goose"]!.requests.withLock { $0.count }, 0, "开关没变的不刷")
        store.connectors.setAcpEnabled(true, for: "gemini")
        await hub.applyEnabledState()
        await assertEventually { behavior.methods().contains("session/list") }
        XCTAssertEqual(queues["goose"]!.requests.withLock { $0.count }, 0, "别的 agent 不跟着刷")
        await hub.stop()
    }

    /// 被藏起来的注册表 agent（第一次握手就失败）启用了也不刷：不能又去拉起一个不是 ACP 的程序。
    func testEnablingHiddenAgentDoesNotRefresh() async {
        let store = makeAcpStore([])
        let queue = FakeAgentQueue([await deadAgent()])
        let hub = AcpHub(store: store) { spec, onHealth, onChanged in
            AcpConnector(spec: spec, store: store, launcher: queue.factory, clientVersion: "1.0",
                         onHealth: onHealth, onTasksChanged: onChanged)
        }
        await hub.sync([spec("gemini")])
        _ = try? await hub.start(connectorId: "gemini", projectPath: project, prompt: "x", images: [])
        await assertEventually { store.connectors.acpIds.isEmpty }
        let launches = queue.requests.withLock { $0.count }
        store.connectors.setAcpEnabled(false, for: "gemini")
        await hub.applyEnabledState()
        store.connectors.setAcpEnabled(true, for: "gemini")
        await hub.applyEnabledState()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(queue.requests.withLock { $0.count }, launches, "藏起来的 agent 不因启用而重新拉起")
    }

    // MARK: - 通知基线（终审回归）

    /// 订阅 store 的事件流，只记通知。流只允许一个订阅者，所以每个测试最多调一次。
    private func collectNotifies(_ store: TaskStore) async -> (Locked<[Notify]>, Task<Void, Never>) {
        let stream = await store.events()
        let collected = Locked<[Notify]>([])
        let task = Task { for await event in stream { if let notify = event.notify { collected.withLock { $0.append(notify) } } } }
        return (collected, task)
    }

    private func listedSessions(_ ids: [String]) -> [JSONValue] {
        let stamp = ProtocolJSON.timestamp(Date())
        return ids.map { ["sessionId": .string($0), "cwd": .string(project), "title": "桌面会话", "updatedAt": .string(stamp)] }
    }

    /// 重启：本机记录先到（`sync` 里的对账），第一次 `session/list` 才拉回一批已完成的桌面会话——一条都不能推。
    func testFirstListAfterRestartDoesNotNotify() async throws {
        let store = makeAcpStore([])
        let (notifies, collector) = await collectNotifies(store)
        defer { collector.cancel() }
        let behavior = FakeAcpBehavior()
        behavior.capabilities = ["sessionCapabilities": ["list": [:]], "loadSession": false]
        behavior.listed = listedSessions(["desk1", "desk2", "desk3"])
        let archive = AcpSessionArchive(url: nil)
        await archive.remember(connectorId: "gemini",
                               record: acpRecord("gemini", "archived", status: .completed,
                                                 updatedAt: ProtocolJSON.timestamp(Date())))
        let queue = FakeAgentQueue([await FakeAcpAgent.make(behavior)])
        let hub = AcpHub(store: store) { spec, onHealth, onChanged in
            AcpConnector(spec: spec, store: store, launcher: queue.factory, archive: archive, clientVersion: "1.0",
                         onHealth: onHealth, onTasksChanged: onChanged)
        }
        await hub.sync([spec("gemini")])
        let archived = await store.task(id: "acp:gemini:archived")
        XCTAssertNotNil(archived, "本机记录在第一次列表之前就进了对账")
        await hub.refreshLists(now: Date())
        await assertEventually { await store.task(id: "acp:gemini:desk3") != nil }
        await hub.reconcile()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(notifies.current.map(\.title), [], "第一次列表拉回来的历史会话是基线，不推「任务完成」")
        await hub.stop()
    }

    /// agent 从发现结果里消失再回来：回来后第一次列表同样是静默基线。
    func testReturningAgentGetsSilentBaselineAgain() async throws {
        let store = makeAcpStore([])
        let (notifies, collector) = await collectNotifies(store)
        defer { collector.cancel() }
        let behavior = FakeAcpBehavior()
        behavior.capabilities = ["sessionCapabilities": ["list": [:]], "loadSession": false]
        behavior.listed = listedSessions(["desk1", "desk2"])
        let queue = FakeAgentQueue([await FakeAcpAgent.make(behavior), await FakeAcpAgent.make(behavior)])
        let hub = AcpHub(store: store) { spec, onHealth, onChanged in
            AcpConnector(spec: spec, store: store, launcher: queue.factory, clientVersion: "1.0",
                         onHealth: onHealth, onTasksChanged: onChanged)
        }
        await hub.sync([spec("gemini")])
        await hub.refreshLists(now: Date())
        await assertEventually { await store.task(id: "acp:gemini:desk2") != nil }
        await hub.sync([])
        await hub.sync([spec("gemini")])
        await hub.refreshLists(now: Date())
        await assertEventually { await store.snapshot().tasks.contains { $0.id == "acp:gemini:desk2" } }
        await hub.reconcile()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(notifies.current.map(\.title), [], "回来的 agent 要重新静默一轮")
        await hub.stop()
    }

    /// 被容量挤掉的 agent 经反向扩展连进来：拒绝原因要说实话，不能说"用户停用了"。
    func testReverseHelloFromAgentDroppedByCapacityExplainsWhy() async throws {
        let store = makeAcpStore([])
        let capacity = store.connectors.acpCapacity
        let ids = (0...capacity).map { String(format: "agent-%02d", $0) }
        let hub = hub(store: store, agents: [String: FakeAcpAgent]())
        await hub.sync(ids.map { spec($0) })
        let dropped = try XCTUnwrap(ids.last)
        XCTAssertFalse(store.connectors.acpIds.contains(dropped))
        let hello: JSONValue = ["id": .string(dropped), "version": .int(AcpReverseServer.extensionVersion)]
        let reply = try await hub.acceptReverse(UUID(), hello: hello, peer: JSONRPCPeer(send: { _ in }), close: {})
        XCTAssertEqual(reply["accepted"], false)
        XCTAssertEqual(reply["reason"]?.stringValue, "BotBus 最多同时接入 \(capacity) 个 ACP agent，这个没排上")
    }

    /// 没有启动命令、也没有能新建会话的反向连接：在建项目文件夹之前就失败。
    func testAgentThatCannotStartTasksFailsBeforeCreatingNewProjectFolder() async throws {
        let store = makeAcpStore([])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("acp-hub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        await store.setProjectsRoot(root.path)
        let hub = hub(store: store, agents: [String: FakeAcpAgent]())
        await hub.sync([AcpAgentSpec(id: "daemon", name: "Daemon", executable: nil, arguments: [], environment: [:],
                                     origin: .manifest, defaultEnabled: true)])
        let dispatcher = CommandDispatcher(store: store, connectors: [hub], readers: [hub])
        let result = await dispatcher.handle(.startTask(.init(source: .acp, projectPath: "", prompt: "hi",
                                                              newProject: "foo", connectorId: "daemon"),
                                                        createdAt: "2026-09-26T08:00:00Z", id: "c1",
                                                        agentId: "agent-1"))
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.error, "这个 Agent 只能在电脑上发起任务")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("foo").path))
    }
}
