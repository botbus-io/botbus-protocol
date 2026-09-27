import XCTest
@testable import BotBusConnectorKit
@testable import BotBusConnectors
import BotBusProtocol

/// 假的只读观察源：按脚本给结果或抛错，记录被读了几次。不碰 SQLite。
final class FakeCodexSource: CodexThreadSource, @unchecked Sendable {
    struct ReadFailed: Error {}

    private let lock = NSLock()
    private var tasks: [TaskRecord] = []
    private var projects: [Project] = []
    private var failing = false
    private var readCount = 0

    var reads: Int { lock.withLock { readCount } }

    func report(tasks: [TaskRecord], projects: [Project] = []) {
        lock.withLock {
            self.tasks = tasks
            self.projects = projects
            failing = false
        }
    }

    func startFailing() { lock.withLock { failing = true } }

    func readSnapshot(agentId: String) throws -> (tasks: [TaskRecord], projects: [Project]) {
        try lock.withLock {
            readCount += 1
            if failing { throw ReadFailed() }
            return (tasks.map { var copy = $0; copy.agentId = agentId; return copy }, projects)
        }
    }
}

final class CodexObserverTests: XCTestCase {
    private static let agentId = "agent-self-000000000"

    private func task(_ id: String, _ status: TaskStatus, updatedAt: String = "2026-09-18T02:00:00Z",
                      pending: PendingRequest? = nil, source: TaskSource = .codex,
                      controllable: Bool = true) -> TaskRecord {
        TaskRecord(id: "\(source.rawValue):\(id)", agentId: Self.agentId, source: source, title: "任务 \(id)",
                   projectPath: "/p/\(id)", projectName: id, status: status, lastMessage: nil, pendingRequest: pending,
                   origin: .desktop, controllable: controllable, startedAt: "2026-09-18T01:00:00Z",
                   updatedAt: updatedAt)
    }

    private func makeStore() -> TaskStore {
        let registry = ConnectorRegistry(descriptors: ConnectorKind.allCases.map { kind in
            ConnectorDescriptor(kind: kind, displayName: kind.rawValue.capitalized, defaultEnabled: true) {
                ConnectorProbe(available: true, status: .ok)
            }
        })
        return TaskStore(identity: AgentIdentity(agentId: Self.agentId, name: "本机", appVersion: "1.2.3"),
                         connectors: registry)
    }

    private func makeObserver(store: TaskStore, source: FakeCodexSource,
                              unavailable: String? = nil,
                              interval: TimeInterval = 0.01,
                              statuses: Locked<[CodexObserver.Status]> = Locked([])) -> CodexObserver {
        CodexObserver(store: store,
                      availability: { unavailable.map { .unavailable($0) } ?? .ready(source) },
                      interval: { interval },
                      statusObserver: { status in statuses.withLock { $0.append(status) } })
    }

    /// 观察者只对 .codex 对账：别的来源的任务既不属于它，也不能被它摘掉。
    func testObserverOnlyReconcilesItsOwnSource() async {
        let store = makeStore()
        let source = FakeCodexSource()
        let observer = makeObserver(store: store, source: source)
        _ = await store.upsert(task("c", .running, source: .claude))

        source.report(tasks: [task("a", .running)])
        await observer.pollOnce()
        var ids = await store.snapshot().tasks.map(\.id).sorted()
        XCTAssertEqual(ids, ["claude:c", "codex:a"])

        // Codex 那边空了：只摘自己的，claude 的一动不动
        source.report(tasks: [])
        await observer.pollOnce()
        ids = await store.snapshot().tasks.map(\.id)
        XCTAssertEqual(ids, ["claude:c"])
    }

    /// 待处理计数来自 store 的快照：轮询结果里那条 waitingApproval 已经被实时数据覆盖成 running，不该再算。
    func testPendingCountDerivedFromSnapshotNotFromPollResult() async {
        let store = makeStore()
        let source = FakeCodexSource()
        let statuses = Locked<[CodexObserver.Status]>([])
        let observer = makeObserver(store: store, source: source, statuses: statuses)

        await store.claimLive("codex:b")
        _ = await store.upsert(task("b", .running, updatedAt: "2026-09-18T02:05:00Z"))

        let pending = PendingRequest(id: "req-1", kind: .command, summary: "危险命令")
        source.report(tasks: [task("a", .waitingApproval, pending: pending),
                              task("b", .waitingApproval, pending: pending)])
        await observer.pollOnce()

        XCTAssertEqual(statuses.current.last?.pendingCount, 1,
                       "轮询结果里有两条待审批，但 codex:b 由实时数据拥有且是 running")
        let storeCount = await store.pendingCount()
        XCTAssertEqual(storeCount, 1)
        XCTAssertEqual(statuses.current.last?.text, "Codex：2 个任务（7 天内）")
    }

    /// 找不到数据库时只改菜单栏文案，绝不能当作"该来源报告了空列表"把已有任务全删掉。
    func testMissingDatabaseReportsStatusWithoutTouchingStore() async {
        let store = makeStore()
        let source = FakeCodexSource()
        let statuses = Locked<[CodexObserver.Status]>([])
        _ = await store.reconcile(source: .codex, tasks: [task("a", .running)], projects: [])

        let observer = makeObserver(store: store, source: source, unavailable: "未找到 Codex 数据库：/tmp/nope",
                                    statuses: statuses)
        await observer.pollOnce()

        XCTAssertEqual(statuses.current.last?.text, "未找到 Codex 数据库：/tmp/nope")
        XCTAssertEqual(source.reads, 0)
        let ids = await store.snapshot().tasks.map(\.id)
        XCTAssertEqual(ids, ["codex:a"])
    }

    /// WAL 侧文件抖动会让只读打开偶发失败，单次不报警；连续三次才改文案。
    func testFailuresOnlyChangeTheStatusTextAfterThreeInARow() async {
        let store = makeStore()
        let source = FakeCodexSource()
        let statuses = Locked<[CodexObserver.Status]>([])
        let observer = makeObserver(store: store, source: source, statuses: statuses)

        source.report(tasks: [task("a", .running)])
        await observer.pollOnce()
        let healthy = statuses.current.last?.text
        XCTAssertEqual(healthy, "Codex：1 个任务（7 天内）")

        source.startFailing()
        await observer.pollOnce()
        XCTAssertEqual(statuses.current.last?.text, healthy, "第一次失败不改文案")
        XCTAssertEqual(statuses.current.last?.consecutiveFailures, 1)
        await observer.pollOnce()
        XCTAssertEqual(statuses.current.last?.text, healthy, "第二次失败也不改")
        await observer.pollOnce()
        XCTAssertEqual(statuses.current.last?.consecutiveFailures, 3)
        XCTAssertTrue(statuses.current.last?.text.hasPrefix("读取 Codex 失败") == true)

        // 失败期间不能把任务摘掉：读不到不等于没有
        let ids = await store.snapshot().tasks.map(\.id)
        XCTAssertEqual(ids, ["codex:a"])

        source.report(tasks: [task("a", .running)])
        await observer.pollOnce()
        XCTAssertEqual(statuses.current.last?.consecutiveFailures, 0)
        XCTAssertEqual(statuses.current.last?.text, healthy)
    }

    /// 轮询循环归观察者所有：start 之后按间隔自己跑，stop 之后立刻停手。
    func testStartLoopsAndStopHaltsIt() async {
        let store = makeStore()
        let source = FakeCodexSource()
        source.report(tasks: [task("a", .running)])
        let observer = makeObserver(store: store, source: source, interval: 0.01)

        await observer.start()
        await assertEventually { source.reads >= 3 }
        await observer.stop()
        // 停的那一刻可能正好有一轮在飞，等它落地再取基准。
        try? await Task.sleep(for: .milliseconds(60))
        let afterStop = source.reads
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(source.reads, afterStop, "stop 之后不该再读库")
    }

    /// `controllable` 一律沿用数据源给的值（spec 6.2：只出现在 SQLite 里的桌面线程，
    /// 非 running 时可以 resume 接管 → true；running 的接管不了 → false）。
    /// 阶段二 b 之前这里会把它强行抹成 false，现在不许再抹。
    func testObserverKeepsTheControllableFlagFromTheSource() async {
        let store = makeStore()
        let source = FakeCodexSource()
        let observer = makeObserver(store: store, source: source)

        source.report(tasks: [task("done", .completed, controllable: true),
                              task("idle", .idle, controllable: true),
                              task("busy", .running, controllable: false)])
        await observer.pollOnce()

        let byId = await Dictionary(uniqueKeysWithValues: store.snapshot().tasks.map { ($0.id, $0) })
        XCTAssertEqual(byId["codex:done"]?.controllable, true, "跑完的桌面线程可以 resume 接管")
        XCTAssertEqual(byId["codex:idle"]?.controllable, true)
        XCTAssertEqual(byId["codex:busy"]?.controllable, false, "桌面上正在跑的线程接管不了")
    }

    /// 实时驱动中的线程归 `.live`，对账整体跳过它——只读观察那份 `controllable: false` 不能盖上去。
    func testLiveTaskKeepsTheConnectorsControllableFlag() async {
        let store = makeStore()
        let source = FakeCodexSource()
        let observer = makeObserver(store: store, source: source)

        await store.claimLive("codex:a")
        var live = task("a", .running, controllable: true)
        live.title = "连接器在驱动的那个"
        _ = await store.upsert(live)

        source.report(tasks: [task("a", .running, controllable: false)])
        await observer.pollOnce()

        let record = await store.task(id: "codex:a")
        XCTAssertEqual(record?.controllable, true, "实时任务的 controllable 由连接器说了算")
        XCTAssertEqual(record?.title, "连接器在驱动的那个")
    }

    /// 每轮对账产出的事件走 TaskStore 的事件流，观察者自己不转发。
    func testObserverFeedsTheStoreEventStream() async {
        let store = makeStore()
        let source = FakeCodexSource()
        let observer = makeObserver(store: store, source: source)
        let received = Locked<[Event.Kind]>([])
        let stream = await store.events()
        let consumer = Task { for await event in stream { received.withLock { $0.append(event.kind) } } }

        source.report(tasks: [task("a", .running)], projects: [Project(agentId: Self.agentId, path: "/p/a", name: "a",
                                                                       lastUsedAt: "2026-09-18T02:00:00Z", pinned: false)])
        await observer.pollOnce()
        await assertEventually { received.current == [.taskUpdated, .snapshot] }
        consumer.cancel()
    }
}
