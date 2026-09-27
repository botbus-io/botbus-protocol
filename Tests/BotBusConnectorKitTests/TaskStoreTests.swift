import XCTest
import BotBusConnectorKit
@testable import BotBusConnectorKit
import BotBusProtocol

final class TaskStoreTests: XCTestCase {
    private static let agentId = "agent-self-000000000"
    private var clock = Date(timeIntervalSince1970: 1_789_700_000)

    private func task(_ id: String, _ status: TaskStatus, updatedAt: String = "2026-09-18T02:00:00Z",
                      pending: PendingRequest? = nil, source: TaskSource = .codex,
                      agentId: String = TaskStoreTests.agentId) -> TaskRecord {
        TaskRecord(id: "\(source.rawValue):\(id)", agentId: agentId, source: source, title: "任务 \(id)",
                   projectPath: "/p/\(id)", projectName: id, status: status, lastMessage: nil, pendingRequest: pending,
                   origin: .desktop, controllable: true, startedAt: "2026-09-18T01:00:00Z", updatedAt: updatedAt)
    }

    private func project(_ path: String, _ lastUsedAt: String, agentId: String = TaskStoreTests.agentId) -> Project {
        Project(agentId: agentId, path: path, name: URL(fileURLWithPath: path).lastPathComponent,
                lastUsedAt: lastUsedAt, pinned: false)
    }

    /// 两个 Connector 都探测得到、都启用，便于测禁用前后的差异。
    private func makeRegistry() -> ConnectorRegistry {
        ConnectorRegistry(descriptors: ConnectorKind.allCases.map { kind in
            ConnectorDescriptor(kind: kind, displayName: kind.rawValue.capitalized, defaultEnabled: true) {
                ConnectorProbe(available: true, status: .ok)
            }
        })
    }

    private func makeStore(registry: ConnectorRegistry? = nil) -> TaskStore {
        TaskStore(identity: AgentIdentity(agentId: Self.agentId, name: "本机", appVersion: "1.2.3"),
                  connectors: registry ?? makeRegistry(),
                  now: { [self] in self.clock })
    }

    func testFirstReconcileEmitsUpdatesButNoNotifications() async {
        let store = makeStore()
        let events = await store.reconcile(source: .codex, tasks: [task("a", .completed), task("b", .failed)], projects: [])
        XCTAssertEqual(events.map(\.kind), [.taskUpdated, .taskUpdated])
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.tasks.map(\.id), ["codex:a", "codex:b"])
    }

    func testStatusTransitionNotifiesAndDedupesWithinThirtySeconds() async {
        let store = makeStore()
        _ = await store.reconcile(source: .codex, tasks: [task("a", .running)], projects: [])

        var events = await store.reconcile(source: .codex, tasks: [task("a", .completed, updatedAt: "2026-09-18T02:01:00Z")], projects: [])
        XCTAssertEqual(events.map(\.kind), [.taskUpdated, .notify])
        XCTAssertEqual(events[1].notify?.category, .taskDone)
        XCTAssertEqual(events[1].notify?.taskId, "codex:a")

        // 同一任务同一状态 30 秒内再次变化（例如 lastMessage 更新）只有 taskUpdated，没有通知
        clock = clock.addingTimeInterval(10)
        var again = task("a", .completed, updatedAt: "2026-09-18T02:01:30Z")
        again.lastMessage = "更多输出"
        events = await store.reconcile(source: .codex, tasks: [again], projects: [])
        XCTAssertEqual(events.map(\.kind), [.taskUpdated])

        // 状态来回：running 再 completed，间隔超过 30 秒 → 再次通知
        clock = clock.addingTimeInterval(40)
        _ = await store.reconcile(source: .codex, tasks: [task("a", .running, updatedAt: "2026-09-18T02:02:00Z")], projects: [])
        events = await store.reconcile(source: .codex, tasks: [task("a", .completed, updatedAt: "2026-09-18T02:03:00Z")], projects: [])
        XCTAssertEqual(events.map(\.kind), [.taskUpdated, .notify])
    }

    func testApprovalNotificationCarriesRequestIdAndSummary() async {
        let store = makeStore()
        _ = await store.reconcile(source: .codex, tasks: [task("a", .running)], projects: [])
        let pending = PendingRequest(id: "req-1", kind: .command, summary: "执行 rm -rf build/")
        let events = await store.reconcile(source: .codex, tasks: [task("a", .waitingApproval, pending: pending)], projects: [])
        let notify = events.last?.notify
        XCTAssertEqual(notify?.category, .taskApproval)
        XCTAssertEqual(notify?.requestId, "req-1")
        XCTAssertEqual(notify?.body, "执行 rm -rf build/")
        XCTAssertEqual(notify?.title, "Codex 等待审批")
    }

    func testWaitingApprovalWithoutRequestIsNotNotified() async {
        let store = makeStore()
        _ = await store.reconcile(source: .codex, tasks: [task("a", .running)], projects: [])
        let events = await store.reconcile(source: .codex, tasks: [task("a", .waitingApproval)], projects: [])
        XCTAssertEqual(events.map(\.kind), [.taskUpdated])
    }

    func testReconcileRemovesTasksMissingFromTheSameSourceOnly() async {
        let store = makeStore()
        _ = await store.reconcile(source: .codex, tasks: [task("a", .completed), task("b", .completed)], projects: [])
        _ = await store.reconcile(source: .claude, tasks: [task("c", .completed, source: .claude)], projects: [])
        let events = await store.reconcile(source: .codex, tasks: [task("a", .completed)], projects: [])
        XCTAssertEqual(events.map(\.kind), [.taskRemoved])
        XCTAssertEqual(events[0].taskId, "codex:b")
        let ids = await store.snapshot().tasks.map(\.id).sorted()
        XCTAssertEqual(ids, ["claude:c", "codex:a"])
    }

    func testUnchangedTasksProduceNoEvents() async {
        let store = makeStore()
        let tasks = [task("a", .completed)]
        _ = await store.reconcile(source: .codex, tasks: tasks, projects: [])
        let events = await store.reconcile(source: .codex, tasks: tasks, projects: [])
        XCTAssertTrue(events.isEmpty)
    }

    func testSnapshotSortsByUpdatedAtDescAndMergesProjects() async {
        let store = makeStore()
        let codexProjects = [project("/p/shop", "2026-09-18T02:00:00Z")]
        let claudeProjects = [project("/p/shop", "2026-09-18T01:00:00Z"), project("/p/lab", "2026-09-18T02:30:00Z")]
        _ = await store.reconcile(source: .codex, tasks: [task("old", .completed, updatedAt: "2026-09-18T01:00:00Z")], projects: codexProjects)
        _ = await store.reconcile(source: .claude, tasks: [task("new", .completed, updatedAt: "2026-09-18T02:30:00Z", source: .claude)], projects: claudeProjects)
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.tasks.map(\.id), ["claude:new", "codex:old"])
        XCTAssertEqual(snapshot.projects.map(\.path), ["/p/lab", "/p/shop"], "按 lastUsedAt 降序、按 (agentId, path) 去重保留较新的")
        XCTAssertEqual(snapshot.generatedAt, "2026-09-18T02:53:20Z")
        XCTAssertEqual(snapshot.seq, 0)
        XCTAssertTrue(snapshot.recentResults.isEmpty)
    }

    // MARK: - 协议 v2：单元素 agents 与归属

    func testSnapshotReportsOnlySelfAsSingleAgent() async {
        let store = makeStore()
        _ = await store.reconcile(source: .codex, tasks: [task("a", .running)],
                                  projects: [project("/p/a", "2026-09-18T02:00:00Z")])
        let snapshot = await store.snapshot()

        XCTAssertEqual(snapshot.agents.count, 1, "Agent 发出的快照里只能有自己一台")
        let me = snapshot.agents[0]
        XCTAssertEqual(me.agentId, Self.agentId)
        XCTAssertEqual(me.name, "本机")
        XCTAssertEqual(me.appVersion, "1.2.3")
        XCTAssertEqual(me.platform, .macos)
        XCTAssertTrue(me.online, "自己上报时 online 固定 true")
        XCTAssertEqual(me.lastSeenAt, "2026-09-18T02:53:20Z")
        XCTAssertEqual(me.connectors.map(\.kind), ConnectorKind.allCases)
        XCTAssertEqual(me.connectors.first { $0.kind == .codex }?.taskCount, 1)
        XCTAssertEqual(me.connectors.first { $0.kind == .claude }?.taskCount, 0)

        XCTAssertTrue(snapshot.tasks.allSatisfy { $0.agentId == Self.agentId })
        XCTAssertTrue(snapshot.projects.allSatisfy { $0.agentId == Self.agentId })
    }

    /// 来源报上来的 agentId 一律以本机为准：连接器不该有能力把任务记到别的电脑名下。
    func testForeignAgentIdIsRestampedWithThisMachine() async {
        let store = makeStore()
        let events = await store.reconcile(source: .codex, tasks: [task("a", .running, agentId: "别人家的电脑")],
                                           projects: [project("/p/a", "2026-09-18T02:00:00Z", agentId: "别人家的电脑")])
        XCTAssertEqual(events.first?.task?.agentId, Self.agentId)
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.tasks.map(\.agentId), [Self.agentId])
        XCTAssertEqual(snapshot.projects.map(\.agentId), [Self.agentId])
    }

    func testSetAgentIdRestampsEverythingAlreadyStored() async {
        let store = makeStore()
        _ = await store.reconcile(source: .codex, tasks: [task("a", .running)],
                                  projects: [project("/p/a", "2026-09-18T02:00:00Z")])
        await store.setAgentId("agent-renamed-00000")
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.agents.map(\.agentId), ["agent-renamed-00000"])
        XCTAssertEqual(snapshot.tasks.map(\.agentId), ["agent-renamed-00000"])
        XCTAssertEqual(snapshot.projects.map(\.agentId), ["agent-renamed-00000"])
    }

    // MARK: - Connector 开关

    func testDisablingConnectorDropsItsTasksFromSnapshot() async {
        let registry = makeRegistry()
        let store = makeStore(registry: registry)
        _ = await store.reconcile(source: .codex, tasks: [task("a", .running), task("b", .completed)],
                                  projects: [project("/p/a", "2026-09-18T02:00:00Z")])
        _ = await store.reconcile(source: .claude, tasks: [task("c", .running, source: .claude)], projects: [])

        let events = await store.setConnectorEnabled(.codex, enabled: false)
        XCTAssertEqual(events.filter { $0.kind == .taskRemoved }.compactMap(\.taskId).sorted(), ["codex:a", "codex:b"])
        XCTAssertEqual(events.last?.kind, .snapshot, "开关变化必须补一份全量快照")

        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.tasks.map(\.id), ["claude:c"], "被禁用的 Connector 的任务不进快照")
        XCTAssertTrue(snapshot.projects.isEmpty, "项目同样按来源摘掉")
        let codex = snapshot.agents[0].connectors.first { $0.kind == .codex }
        XCTAssertEqual(codex?.enabled, false)
        XCTAssertEqual(codex?.taskCount, 0)
        XCTAssertEqual(events.last?.snapshot, snapshot)

        // 禁用期间继续轮询：视为该来源什么都没报，不会把任务塞回来。
        let whileDisabled = await store.reconcile(source: .codex, tasks: [task("a", .running)],
                                                  projects: [project("/p/a", "2026-09-18T02:00:00Z")])
        XCTAssertTrue(whileDisabled.isEmpty)
        let stillEmpty = await store.snapshot().tasks.map(\.id)
        XCTAssertEqual(stillEmpty, ["claude:c"])
    }

    /// 重新启用后第一次对账是静默基线：不能把积压的 waitingApproval 一次性全推成通知。
    func testReenablingConnectorResyncsSilently() async {
        let store = makeStore()
        _ = await store.reconcile(source: .codex, tasks: [task("a", .running)], projects: [])
        _ = await store.setConnectorEnabled(.codex, enabled: false)
        _ = await store.setConnectorEnabled(.codex, enabled: true)

        let pending = PendingRequest(id: "req-1", kind: .command, summary: "危险命令")
        let events = await store.reconcile(source: .codex, tasks: [task("a", .waitingApproval, pending: pending)], projects: [])
        XCTAssertEqual(events.map(\.kind), [.taskUpdated], "重新启用后的首次全量对账仍是静默基线")
        let ids = await store.snapshot().tasks.map(\.id)
        XCTAssertEqual(ids, ["codex:a"])
    }

    func testSetConnectorEnabledIsIdempotentButStillReportsState() async {
        let store = makeStore()
        _ = await store.reconcile(source: .codex, tasks: [task("a", .running)], projects: [])
        let events = await store.setConnectorEnabled(.codex, enabled: true)
        XCTAssertEqual(events.map(\.kind), [.snapshot], "值没变也要回一份快照，让客户端看到确认")
        XCTAssertEqual(events[0].snapshot?.tasks.map(\.id), ["codex:a"], "没变就不能顺手把任务摘了")
    }

    // MARK: - 命令

    func testSetConnectorEnabledCommandReturnsOkResult() async {
        let store = makeStore()
        _ = await store.reconcile(source: .codex, tasks: [task("a", .running)], projects: [])
        let command = Command.setConnectorEnabled(.init(connector: .codex, enabled: false),
                                                  createdAt: "2026-09-18T02:00:00Z", id: "cmd-1",
                                                  agentId: Self.agentId)
        let (result, events) = await store.handle(command)
        XCTAssertEqual(result.commandId, "cmd-1")
        XCTAssertTrue(result.ok)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.finishedAt, "2026-09-18T02:53:20Z")
        XCTAssertEqual(events.last?.kind, .snapshot, "开关命令必须触发一次新的全量快照")
        XCTAssertTrue(events.last?.snapshot?.tasks.isEmpty == true)
        XCTAssertEqual(events.last?.snapshot?.agents[0].connectors.first { $0.kind == .codex }?.enabled, false)
    }

    func testCommandAimedAtAnotherAgentIsRejected() async {
        let store = makeStore()
        let command = Command.setConnectorEnabled(.init(connector: .codex, enabled: false),
                                                  createdAt: "2026-09-18T02:00:00Z", id: "cmd-2",
                                                  agentId: "另一台电脑")
        let (result, events) = await store.handle(command)
        XCTAssertFalse(result.ok)
        XCTAssertNotNil(result.error)
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(store.connectors.isEnabled(.codex), "别人的命令不能改本机开关")
    }

    func testUnsupportedCommandKindReturnsFailureWithoutEvents() async {
        let store = makeStore()
        let command = Command.interrupt(.init(taskId: "codex:a"), createdAt: "2026-09-18T02:00:00Z", id: "cmd-3",
                                        agentId: Self.agentId)
        let (result, events) = await store.handle(command)
        XCTAssertFalse(result.ok)
        XCTAssertTrue(events.isEmpty)
    }

    // MARK: - 既有行为

    func testProjectChangeEmitsFullSnapshot() async {
        let store = makeStore()
        let shop = project("/p/shop", "2026-09-18T02:00:00Z")
        let lab = project("/p/lab", "2026-09-18T02:30:00Z")

        // 协议没有项目事件，Relay 只从全量快照更新 projects：项目一变就要补发快照
        var events = await store.reconcile(source: .codex, tasks: [task("a", .completed)], projects: [shop])
        XCTAssertEqual(events.last?.kind, .snapshot)
        let merged = await store.snapshot().projects
        XCTAssertEqual(merged.map(\.path), ["/p/shop"])
        XCTAssertEqual(events.last?.snapshot?.projects, merged)

        // 项目没变：不发快照
        events = await store.reconcile(source: .codex, tasks: [task("a", .completed)], projects: [shop])
        XCTAssertFalse(events.contains { $0.kind == .snapshot })

        // 新项目出现：再发快照
        events = await store.reconcile(source: .codex, tasks: [task("a", .completed)], projects: [shop, lab])
        XCTAssertEqual(events.last?.kind, .snapshot)
        XCTAssertEqual(events.last?.snapshot?.projects.map(\.path), ["/p/lab", "/p/shop"])
    }

    func testUpsertSingleTaskNotifiesOnStatusChange() async {
        let store = makeStore()
        _ = await store.upsert(task("a", .running))
        let events = await store.upsert(task("a", .failed))
        XCTAssertEqual(events.map(\.kind), [.taskUpdated, .notify])
        XCTAssertEqual(events[1].notify?.category, .taskFailed)
    }

    func testNewApprovalRequestWithSameStatusNotifiesAgain() async {
        let store = makeStore()
        _ = await store.reconcile(source: .codex, tasks: [task("a", .running)], projects: [])
        let first = PendingRequest(id: "req-1", kind: .command, summary: "第一条命令")
        _ = await store.reconcile(source: .codex, tasks: [task("a", .waitingApproval, pending: first)], projects: [])

        clock = clock.addingTimeInterval(5)
        let second = PendingRequest(id: "req-2", kind: .command, summary: "第二条命令")
        let events = await store.reconcile(source: .codex, tasks: [task("a", .waitingApproval, pending: second)], projects: [])
        XCTAssertEqual(events.map(\.kind), [.taskUpdated, .notify], "换了请求就要再提醒，即使状态没变、也在 30 秒内")
        XCTAssertEqual(events[1].notify?.requestId, "req-2")

        // 同一个请求只是文案或 lastMessage 变了：不再提醒
        var same = task("a", .waitingApproval, pending: PendingRequest(id: "req-2", kind: .command, summary: "第二条命令（改）"))
        same.lastMessage = "更多输出"
        let again = await store.reconcile(source: .codex, tasks: [same], projects: [])
        XCTAssertEqual(again.map(\.kind), [.taskUpdated])
    }

    func testUpsertBeforeFirstReconcileDoesNotPolluteBaseline() async {
        let store = makeStore()
        _ = await store.upsert(task("live", .running))
        let events = await store.reconcile(source: .codex, tasks: [task("live", .completed), task("old", .failed)], projects: [])
        XCTAssertEqual(events.map(\.kind), [.taskUpdated, .taskUpdated], "首次全量对账仍是静默基线")
    }

    /// id 前缀和来源对不上时只记日志丢弃，不能 trap：upsert 是 public，Debug 构建下 trap 会打死菜单栏进程。
    func testMismatchedIdPrefixIsDroppedWithoutTrapping() async {
        let store = makeStore()
        var malformed = task("a", .completed, source: .codex)
        malformed.id = "claude:a"       // 前缀写成了另一个来源
        let events = await store.upsert(malformed)
        XCTAssertTrue(events.isEmpty, "畸形 id 不该产生任何事件")
        let snapshot = await store.snapshot()
        XCTAssertTrue(snapshot.tasks.isEmpty, "畸形 id 不该进字典，否则不同来源会互相覆盖")
    }

    // MARK: - owner 追踪（阶段二 b：只读观察与实时数据描述同一个线程）

    /// observer 的报告里没有这个 id 也不能删：reconcile 每 2 秒跑一次，删一次就是每 2 秒抖一下。
    func testLiveOwnedTaskSurvivesObserverReconcile() async {
        let store = makeStore()
        _ = await store.reconcile(source: .codex, tasks: [task("a", .running), task("b", .running)], projects: [])
        await store.claimLive("codex:b")
        let pending = PendingRequest(id: "req-1", kind: .command, summary: "执行 rm -rf build/")
        _ = await store.upsert(task("b", .waitingApproval, updatedAt: "2026-09-18T02:05:00Z", pending: pending))

        for _ in 0..<3 {
            let events = await store.reconcile(source: .codex, tasks: [task("a", .running)], projects: [])
            XCTAssertTrue(events.isEmpty, "live 拥有的 id 缺席不算消失，不能发 taskRemoved")
        }
        let ids = await store.snapshot().tasks.map(\.id).sorted()
        XCTAssertEqual(ids, ["codex:a", "codex:b"])
        let live = await store.task(id: "codex:b")
        XCTAssertEqual(live?.status, .waitingApproval)
    }

    /// 同一个 id：只读观察还停在旧状态，实时数据说了算。
    func testLiveOwnershipOverridesObserverData() async {
        let store = makeStore()
        _ = await store.reconcile(source: .codex, tasks: [task("a", .running)], projects: [])
        await store.claimLive("codex:a")
        _ = await store.upsert(task("a", .completed, updatedAt: "2026-09-18T02:05:00Z"))

        let events = await store.reconcile(source: .codex, tasks: [task("a", .running)], projects: [])
        XCTAssertTrue(events.isEmpty, "live 拥有的 id 不该被只读结果 upsert 回去")
        let current = await store.task(id: "codex:a")
        XCTAssertEqual(current?.status, .completed)
        XCTAssertEqual(current?.updatedAt, "2026-09-18T02:05:00Z")
        let owner = await store.owner(of: "codex:a")
        XCTAssertEqual(owner, .live)
    }

    /// 命令结束后交还给 observer：SQLite 还没落盘的那几轮既不能删也不能把状态抖回去。
    func testReleasingOwnershipLetsObserverTakeOverAgain() async {
        let store = makeStore()
        _ = await store.reconcile(source: .codex, tasks: [task("a", .running)], projects: [])
        await store.claimLive("codex:a")
        let finished = task("a", .completed, updatedAt: "2026-09-18T02:05:00Z")
        _ = await store.upsert(finished)
        await store.releaseLive("codex:a")
        let owner = await store.owner(of: "codex:a")
        XCTAssertEqual(owner, .observer)

        // 只读观察还没赶上：这一轮它根本没报这个 id
        var events = await store.reconcile(source: .codex, tasks: [], projects: [])
        XCTAssertTrue(events.isEmpty, "交接宽限期内缺席不算消失")

        // 观察终于看到同一份数据：交接完成，也没有任何事件
        events = await store.reconcile(source: .codex, tasks: [finished], projects: [])
        XCTAssertTrue(events.isEmpty, "数据一致就不该有 taskUpdated")

        // 交接完成之后，任务真的消失才发 taskRemoved
        events = await store.reconcile(source: .codex, tasks: [], projects: [])
        XCTAssertEqual(events.map(\.kind), [.taskRemoved])
        XCTAssertEqual(events[0].taskId, "codex:a")
    }

    /// 宽限期不是永久豁免：observer 始终看不到它，到期后照常摘掉。
    func testHandoffGraceExpiresAndThenTheTaskIsRemoved() async {
        let store = makeStore()
        await store.claimLive("codex:a")
        _ = await store.upsert(task("a", .running))
        await store.releaseLive("codex:a")

        var events = await store.reconcile(source: .codex, tasks: [], projects: [])
        XCTAssertTrue(events.isEmpty)
        clock = clock.addingTimeInterval(TaskStore.liveHandoffGrace + 1)
        events = await store.reconcile(source: .codex, tasks: [], projects: [])
        XCTAssertEqual(events.map(\.kind), [.taskRemoved])
    }

    /// 停用 Connector 等于"这个来源什么都没有了"，实时任务也一并交还并摘掉。
    func testDisablingConnectorAlsoDropsLiveOwnedTasks() async {
        let store = makeStore()
        await store.claimLive("codex:live")
        _ = await store.upsert(task("live", .running))
        _ = await store.reconcile(source: .codex, tasks: [task("observed", .running)], projects: [])

        let events = await store.setConnectorEnabled(.codex, enabled: false)
        XCTAssertEqual(events.filter { $0.kind == .taskRemoved }.compactMap(\.taskId).sorted(),
                       ["codex:live", "codex:observed"])
        let owner = await store.owner(of: "codex:live")
        XCTAssertEqual(owner, .observer, "停用后所有权一并交还，重新启用时不会留下没人认领的 id")
        let ids = await store.snapshot().tasks.map(\.id)
        XCTAssertTrue(ids.isEmpty)
    }

    /// 待处理计数是从 store 的可见任务里数出来的，不是轮询结果的副产品。
    func testPendingCountCountsVisibleTasksOnly() async {
        let store = makeStore()
        let pending = PendingRequest(id: "req-1", kind: .command, summary: "危险命令")
        _ = await store.reconcile(source: .codex, tasks: [task("a", .waitingApproval, pending: pending), task("b", .running)], projects: [])
        _ = await store.reconcile(source: .claude, tasks: [task("c", .waitingInput, source: .claude)], projects: [])
        var count = await store.pendingCount()
        XCTAssertEqual(count, 2)

        _ = await store.setConnectorEnabled(.claude, enabled: false)
        count = await store.pendingCount()
        XCTAssertEqual(count, 1, "被停用的 Connector 的任务不算在内，和 snapshot() 的可见性一致")
    }

    // MARK: - 事件流

    /// TaskStore 只认一个订阅者（RelayClient）：再订阅一次会顶掉上一条流，事件绝不分叉。
    func testEventStreamDeliversToSingleSubscriber() async {
        let store = makeStore()
        let firstEvents = Locked<[Event.Kind]>([])
        let firstFinished = Locked(false)
        let stream = await store.events()
        let firstConsumer = Task {
            for await event in stream { firstEvents.withLock { $0.append(event.kind) } }
            firstFinished.withLock { $0 = true }
        }

        _ = await store.reconcile(source: .codex, tasks: [task("a", .running)], projects: [])
        await assertEventually { firstEvents.current == [.taskUpdated] }

        let secondEvents = Locked<[Event.Kind]>([])
        let replacement = await store.events()
        let secondConsumer = Task {
            for await event in replacement { secondEvents.withLock { $0.append(event.kind) } }
        }
        await assertEventually { firstFinished.current }

        _ = await store.reconcile(source: .codex, tasks: [task("a", .completed, updatedAt: "2026-09-18T02:05:00Z")], projects: [])
        await assertEventually { secondEvents.current.contains(.taskUpdated) }
        XCTAssertEqual(firstEvents.current, [.taskUpdated], "被顶掉的订阅者不该再收到任何事件")
        XCTAssertTrue(secondEvents.current.contains(.notify))

        firstConsumer.cancel()
        secondConsumer.cancel()
    }

    /// 没人订阅时事件直接丢弃，不攒着：新订阅者连上后拿到的是全量快照，不需要补历史增量。
    func testEventStreamDoesNotReplayWhatHappenedBeforeSubscribing() async {
        let store = makeStore()
        _ = await store.reconcile(source: .codex, tasks: [task("a", .running)], projects: [])

        let received = Locked<[Event.Kind]>([])
        let stream = await store.events()
        let consumer = Task { for await event in stream { received.withLock { $0.append(event.kind) } } }
        _ = await store.upsert(task("a", .completed, updatedAt: "2026-09-18T02:05:00Z"))
        await assertEventually { received.current.contains(.taskUpdated) }
        XCTAssertFalse(received.current.isEmpty)
        XCTAssertEqual(received.current.filter { $0 == .taskUpdated }.count, 1, "订阅之前的事件不补发")
        consumer.cancel()
    }

    /// 命令产出的事件同样走这条流，AgentModel 不再手工转发一遍。
    func testCommandEventsGoThroughTheEventStream() async {
        let store = makeStore()
        let received = Locked<[Event.Kind]>([])
        let stream = await store.events()
        let consumer = Task { for await event in stream { received.withLock { $0.append(event.kind) } } }

        let command = Command.setConnectorEnabled(.init(connector: .codex, enabled: false),
                                                  createdAt: "2026-09-18T02:00:00Z", id: "cmd-9",
                                                  agentId: Self.agentId)
        let (result, events) = await store.handle(command)
        XCTAssertTrue(result.ok)
        await assertEventually { received.current == events.map(\.kind) }
        consumer.cancel()
    }

    func testSnapshotOrderIsDeterministicForEqualTimestamps() async {
        let store = makeStore()
        let same = "2026-09-18T02:00:00Z"
        _ = await store.reconcile(source: .codex, tasks: [task("b", .completed, updatedAt: same), task("a", .completed, updatedAt: same), task("c", .completed, updatedAt: same)], projects: [])
        for _ in 0..<5 {
            let ids = await store.snapshot().tasks.map(\.id)
            XCTAssertEqual(ids, ["codex:a", "codex:b", "codex:c"])
        }
    }
}
