import XCTest
@testable import BotBusConnectorKit
import BotBusProtocol

/// 项目只改了 `lastUsedAt` 时的快照节流：最多每 `projectActivitySnapshotInterval` 一份，最后一次变化最终会发出去；
/// 其余字段与顺序变化照旧立即发。
final class TaskStoreProjectSnapshotTests: XCTestCase {
    private static let agentId = "agent-self-000000000"
    private let clock = Locked(Date(timeIntervalSince1970: 1_789_700_000))

    private func project(_ path: String, _ lastUsedAt: String, name: String? = nil, pinned: Bool = false) -> Project {
        Project(agentId: Self.agentId, path: path, name: name ?? URL(fileURLWithPath: path).lastPathComponent,
                lastUsedAt: lastUsedAt, pinned: pinned)
    }

    private func makeStore(interval: TimeInterval = 60) -> TaskStore {
        let clock = self.clock
        return TaskStore(identity: AgentIdentity(agentId: Self.agentId, name: "本机", appVersion: "1.2.3"),
                         projectActivitySnapshotInterval: interval,
                         now: { clock.current })
    }

    private func advance(_ seconds: TimeInterval) {
        clock.withLock { $0 = $0.addingTimeInterval(seconds) }
    }

    private func snapshots(_ events: [Event]) -> Int {
        events.filter { $0.kind == .snapshot }.count
    }

    func testActivityOnlyChangeIsThrottledButStructuralChangeIsImmediate() async {
        let store = makeStore()
        var events = await store.reconcile(source: .codex, tasks: [], projects: [project("/p/a", "2026-09-18T02:00:00Z")])
        XCTAssertEqual(snapshots(events), 1, "新项目立即发")

        advance(10)
        events = await store.reconcile(source: .codex, tasks: [], projects: [project("/p/a", "2026-09-18T02:00:10Z")])
        XCTAssertEqual(snapshots(events), 0, "60 秒内只改了 lastUsedAt 不发")

        advance(1)
        events = await store.reconcile(source: .codex, tasks: [],
                                       projects: [project("/p/a", "2026-09-18T02:00:11Z", name: "改名")])
        XCTAssertEqual(snapshots(events), 1, "名称变了立即发")
        XCTAssertEqual(events.last?.snapshot?.projects.first?.lastUsedAt, "2026-09-18T02:00:11Z")

        advance(1)
        events = await store.reconcile(source: .codex, tasks: [],
                                       projects: [project("/p/a", "2026-09-18T02:00:11Z", name: "改名", pinned: true)])
        XCTAssertEqual(snapshots(events), 1, "置顶变了立即发")

        advance(60)
        events = await store.reconcile(source: .codex, tasks: [],
                                       projects: [project("/p/a", "2026-09-18T02:01:12Z", name: "改名", pinned: true)])
        XCTAssertEqual(snapshots(events), 1, "距上一份快照超过 60 秒，只改 lastUsedAt 也立即发")
    }

    func testReorderIsImmediate() async {
        let store = makeStore()
        await store.reconcile(source: .codex, tasks: [],
                              projects: [project("/p/a", "2026-09-18T02:00:02Z"), project("/p/b", "2026-09-18T02:00:01Z")])
        advance(5)
        let events = await store.reconcile(source: .codex, tasks: [],
                                           projects: [project("/p/a", "2026-09-18T02:00:02Z"),
                                                      project("/p/b", "2026-09-18T02:00:05Z")])
        XCTAssertEqual(snapshots(events), 1, "lastUsedAt 改变了顺序，立即发")
        XCTAssertEqual(events.last?.snapshot?.projects.map(\.path), ["/p/b", "/p/a"])
    }

    func testDeferredSnapshotCarriesLatestActivity() async {
        let store = makeStore()
        await store.reconcile(source: .codex, tasks: [], projects: [project("/p/a", "2026-09-18T02:00:00Z")])
        let stream = await store.events()
        advance(5)
        await store.reconcile(source: .codex, tasks: [], projects: [project("/p/a", "2026-09-18T02:00:05Z")])
        advance(5)
        await store.reconcile(source: .codex, tasks: [], projects: [project("/p/a", "2026-09-18T02:00:10Z")])
        await store.flushDeferredProjectSnapshot()
        await store.flushDeferredProjectSnapshot()

        var received: [Event] = []
        let collector = Task {
            for await event in stream { received.append(event); if event.kind == .snapshot { break } }
            return received
        }
        let got = await collector.value
        XCTAssertEqual(got.filter { $0.kind == .snapshot }.count, 1, "节流期间的多次变化合成一份")
        XCTAssertEqual(got.last?.snapshot?.projects.first?.lastUsedAt, "2026-09-18T02:00:10Z", "补发的是最后一次变化")
    }

    func testDeferredSnapshotFiresByTimer() async {
        // 时钟固定不动：节流窗口靠真实定时器结束。
        let store = makeStore(interval: 0.2)
        await store.reconcile(source: .codex, tasks: [], projects: [project("/p/a", "2026-09-18T02:00:00Z")])
        let stream = await store.events()
        await store.reconcile(source: .codex, tasks: [], projects: [project("/p/a", "2026-09-18T02:00:05Z")])
        let collector = Task { () -> Project? in
            for await event in stream where event.kind == .snapshot { return event.snapshot?.projects.first }
            return nil
        }
        let timeout = Task { try? await Task.sleep(for: .seconds(5)); collector.cancel() }
        let latest = await collector.value
        timeout.cancel()
        XCTAssertEqual(latest?.lastUsedAt, "2026-09-18T02:00:05Z", "没有后续事件时定时补发")
    }

    func testOtherSnapshotCancelsDeferred() async {
        let store = makeStore(interval: 0.2)
        await store.reconcile(source: .codex, tasks: [], projects: [project("/p/a", "2026-09-18T02:00:00Z")])
        await store.reconcile(source: .codex, tasks: [], projects: [project("/p/a", "2026-09-18T02:00:05Z")])
        let stream = await store.events()
        let events = await store.setConnectorEnabled(.claude, enabled: false)
        XCTAssertEqual(snapshots(events), 1)
        XCTAssertEqual(events.last?.snapshot?.projects.first?.lastUsedAt, "2026-09-18T02:00:05Z", "别的快照已带上最新项目")
        let collector = Task { () -> Int in
            var count = 0
            for await event in stream where event.kind == .snapshot { count += 1 }
            return count
        }
        try? await Task.sleep(for: .milliseconds(600))
        collector.cancel()
        _ = await store.events() // 结束旧流，让 collector 收尾
        let count = await collector.value
        XCTAssertEqual(count, 1, "挂着的补发被取消，不再重复发")
    }
}
