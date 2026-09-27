import XCTest
import BotBusConnectorKit
@testable import BotBusConnectorKit
import BotBusProtocol

/// 产物挂在任务上（spec 3.4）：合并进外发记录、不被连接器覆盖、上限、替换、过期与持久化。
final class TaskStoreArtifactTests: XCTestCase {
    private static let agentId = "agent-self-000000000"
    private let clock = Locked(Date(timeIntervalSince1970: 1_789_700_000)) // 2026-09-18T02:53:20Z

    private func makeStore(artifactsURL: URL? = nil, saveDelay: TimeInterval = 0.05) -> TaskStore {
        let registry = ConnectorRegistry(descriptors: ConnectorKind.allCases.map { kind in
            ConnectorDescriptor(kind: kind, displayName: kind.rawValue, defaultEnabled: true) {
                ConnectorProbe(available: true, status: .ok)
            }
        })
        let clock = self.clock
        return TaskStore(identity: AgentIdentity(agentId: Self.agentId, name: "本机", appVersion: "1.0"),
                         connectors: registry, artifactsURL: artifactsURL, artifactSaveDelay: saveDelay,
                         now: { clock.current })
    }

    private func task(_ id: String, _ status: TaskStatus = .running, source: TaskSource = .codex,
                      lastMessage: String? = nil) -> TaskRecord {
        TaskRecord(id: "\(source.rawValue):\(id)", agentId: Self.agentId, source: source, title: "任务 \(id)",
                   projectPath: "/p/\(id)", projectName: id, status: status, lastMessage: lastMessage,
                   origin: .watch, controllable: true, startedAt: "2026-09-18T01:00:00Z",
                   updatedAt: "2026-09-18T02:00:00Z")
    }

    private func image(_ id: String, createdAt: String = "2026-09-18T02:00:00Z", expiresAt: String? = nil) -> Artifact {
        Artifact(id: id, kind: .image, title: "截图 \(id)", createdAt: createdAt, contentType: "image/png",
                 size: 10, expiresAt: expiresAt)
    }

    private func preview(_ id: String, port: Int? = 3000, expiresAt: String = "2026-09-18T04:00:00Z") -> Artifact {
        Artifact(id: id, kind: .preview, title: "预览 \(id)", createdAt: "2026-09-18T02:00:00Z",
                 port: port, expiresAt: expiresAt)
    }

    private func tempURL() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("artifacts-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("artifacts.json")
    }

    func testAddArtifactMergesIntoTaskNewestFirstAndEmitsTaskUpdated() async {
        let store = makeStore()
        await store.upsert(task("t1"))
        let first = await store.addArtifact(taskId: "codex:t1", image("a"))
        XCTAssertEqual(first.events.map(\.kind), [.taskUpdated])
        XCTAssertEqual(first.events.first?.task?.artifacts?.map(\.id), ["a"])
        await store.addArtifact(taskId: "codex:t1", image("b"))

        let record = await store.task(id: "codex:t1")
        XCTAssertEqual(record?.artifacts?.map(\.id), ["b", "a"], "新的在前")
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.tasks.first?.artifacts?.map(\.id), ["b", "a"])
    }

    /// 连接器与观察者根本不知道产物：它们带来的记录没有 artifacts，不能把 store 记的那份冲掉。
    func testConnectorUpsertAndReconcileNeverClobberArtifacts() async {
        let store = makeStore()
        await store.reconcile(source: .codex, tasks: [task("t1")], projects: [])
        await store.addArtifact(taskId: "codex:t1", image("a"))

        let upserted = await store.upsert(task("t1", .completed, lastMessage: "好了"))
        XCTAssertEqual(upserted.first?.task?.artifacts?.map(\.id), ["a"])
        await store.reconcile(source: .codex, tasks: [task("t1", .completed, lastMessage: "再次对账")], projects: [])
        let record = await store.task(id: "codex:t1")
        XCTAssertEqual(record?.artifacts?.map(\.id), ["a"])
        XCTAssertEqual(record?.lastMessage, "再次对账")

        // 同样内容再 upsert 一次不产生事件：比较的是合并后的记录。
        let repeated = await store.upsert(task("t1", .completed, lastMessage: "再次对账"))
        XCTAssertTrue(repeated.isEmpty)
    }

    /// 协议要求没有产物时整个键省略；Swift 对 `[]` 会编出一个空数组键。
    func testArtifactsIsNilNotEmptyAfterRemovalAndKeyIsOmitted() async throws {
        let store = makeStore()
        await store.upsert(task("t1"))
        await store.addArtifact(taskId: "codex:t1", image("a"))
        let removed = await store.removeArtifact(taskId: "codex:t1", id: "a")
        XCTAssertEqual(removed.map(\.kind), [.taskUpdated])
        let stored = await store.task(id: "codex:t1")
        let record = try XCTUnwrap(stored)
        XCTAssertNil(record.artifacts)
        let json = String(decoding: try ProtocolJSON.encoder().encode(record), as: UTF8.self)
        XCTAssertFalse(json.contains("artifacts"), json)
        let again = await store.removeArtifact(taskId: "codex:t1", id: "a")
        XCTAssertTrue(again.isEmpty, "不存在的产物不产生事件")
    }

    func testCapsAtTenAndReportsDisplaced() async {
        let store = makeStore()
        await store.upsert(task("t1"))
        for index in 0..<10 { await store.addArtifact(taskId: "codex:t1", image("a\(index)")) }
        let change = await store.addArtifact(taskId: "codex:t1", image("a10"))
        XCTAssertEqual(change.displaced.map(\.id), ["a0"], "最旧的被挤掉")
        let ids = await store.artifacts(taskId: "codex:t1").map(\.id)
        XCTAssertEqual(ids.count, TaskRecord.maxArtifacts)
        XCTAssertEqual(ids.first, "a10")
    }

    func testResharingSameOriginReplacesOldPreview() async {
        let store = makeStore()
        await store.upsert(task("t1"))
        await store.addArtifact(taskId: "codex:t1", preview("p1", port: 3000), originKey: "port:3000")
        await store.addArtifact(taskId: "codex:t1", preview("p2", port: 5173), originKey: "port:5173")
        await store.addArtifact(taskId: "codex:t1", preview("d1", port: nil), originKey: "dir:/tmp/site")
        // 来源键相同（托管命令最终也转发端口，AgentCore 的 `PreviewOrigin.artifactOriginKey` 给出同一个键）就替换旧预览。
        let replaced = await store.addArtifact(taskId: "codex:t1", preview("p3", port: 3000), originKey: "port:3000")
        XCTAssertEqual(replaced.displaced.map(\.id), ["p1"])
        let dir = await store.addArtifact(taskId: "codex:t1", preview("d2", port: nil), originKey: "dir:/tmp/site")
        XCTAssertEqual(dir.displaced.map(\.id), ["d1"])
        let ids = await store.artifacts(taskId: "codex:t1").map(\.id)
        XCTAssertEqual(ids, ["d2", "p3", "p2"])
        // 别的任务同一端口互不影响。
        await store.addArtifact(taskId: "codex:t2", preview("q1", port: 3000), originKey: "port:3000")
        let still = await store.artifacts(taskId: "codex:t1").map(\.id)
        XCTAssertEqual(still, ["d2", "p3", "p2"])
    }

    func testArtifactForUnknownTaskIsKeptUntilTaskAppears() async {
        let store = makeStore()
        let change = await store.addArtifact(taskId: "claude:s1", image("a"))
        XCTAssertTrue(change.events.isEmpty, "任务还不在 store 里：没有可更新的记录")
        let events = await store.upsert(task("s1", source: .claude))
        XCTAssertEqual(events.first?.task?.artifacts?.map(\.id), ["a"])
    }

    func testTitleIsTruncatedToProtocolLimit() async {
        let store = makeStore()
        var long = image("a")
        long.title = String(repeating: "长", count: 200)
        await store.addArtifact(taskId: "codex:t1", long)
        let stored = await store.artifacts(taskId: "codex:t1")
        XCTAssertEqual(stored.first?.title.count, Artifact.maxTitleLength)
    }

    func testExpiredArtifactsArePrunedOnSnapshotAndOnDemand() async {
        let store = makeStore()
        await store.upsert(task("t1"))
        await store.addArtifact(taskId: "codex:t1", preview("p1", expiresAt: "2026-09-18T03:00:00Z"),
                                originKey: "port:3000")
        await store.addArtifact(taskId: "codex:t1", image("a"))
        var snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.tasks.first?.artifacts?.map(\.id), ["a", "p1"])

        clock.withLock { $0 = $0.addingTimeInterval(10 * 60) } // 03:03:20，预览已过期
        let stream = await store.events()
        let pushed = Locked<[Event]>([])
        let consumer = Task { for await event in stream { pushed.withLock { $0.append(event) } } }
        defer { consumer.cancel() }
        snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.tasks.first?.artifacts?.map(\.id), ["a"])
        await assertEventually { !pushed.current.isEmpty }
        XCTAssertEqual(pushed.current.first?.kind, .taskUpdated, "摘掉过期产物也要告诉 Relay")
        XCTAssertEqual(pushed.current.first?.task?.artifacts?.map(\.id), ["a"])

        let nothing = await store.pruneExpiredArtifacts()
        XCTAssertTrue(nothing.isEmpty)
    }

    func testPersistenceRoundTripDropsPreviewsAndExpired() async throws {
        let url = tempURL()
        let store = makeStore(artifactsURL: url)
        await store.addArtifact(taskId: "codex:t1", image("keep", expiresAt: "2026-09-25T00:00:00Z"))
        await store.addArtifact(taskId: "codex:t1", image("stale", expiresAt: "2026-09-18T01:00:00Z"))
        await store.addArtifact(taskId: "codex:t1", preview("p1"), originKey: "port:3000")
        await store.addArtifact(taskId: "claude:s1",
                                Artifact(id: "l1", kind: .link, title: "文档", createdAt: "2026-09-18T02:00:00Z",
                                         url: "https://example.com"))
        await store.flushArtifacts()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let reloaded = makeStore(artifactsURL: url)
        let codex = await reloaded.artifacts(taskId: "codex:t1").map(\.id)
        XCTAssertEqual(codex, ["keep"], "预览不跨重启，过期的也不留")
        let claude = await reloaded.artifacts(taskId: "claude:s1").map(\.id)
        XCTAssertEqual(claude, ["l1"])
        // 重启后观察者读到任务，产物自然合并上去。
        let events = await reloaded.reconcile(source: .codex, tasks: [task("t1")], projects: [])
        XCTAssertEqual(events.first?.task?.artifacts?.map(\.id), ["keep"])
    }

    func testWritesAreDebounced() async {
        let url = tempURL()
        let store = makeStore(artifactsURL: url, saveDelay: 0.2)
        await store.addArtifact(taskId: "codex:t1", image("a"))
        await store.addArtifact(taskId: "codex:t1", image("b"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "防抖期内还没落盘")
        await assertEventually(timeout: 3) { FileManager.default.fileExists(atPath: url.path) }
        let reloaded = makeStore(artifactsURL: url)
        let ids = await reloaded.artifacts(taskId: "codex:t1").map(\.id)
        XCTAssertEqual(ids, ["b", "a"])
    }

    func testCorruptOrPartiallyUnknownFileIsTolerated() async throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        let empty = makeStore(artifactsURL: url)
        let none = await empty.artifacts(taskId: "codex:t1")
        XCTAssertTrue(none.isEmpty)

        // 一件将来才有的 kind 只丢它自己。
        let json = """
        {"version":1,"tasks":[{"taskId":"codex:t1","artifacts":[
          {"artifact":{"id":"x","kind":"hologram","title":"?","createdAt":"2026-09-18T02:00:00Z"}},
          {"artifact":{"id":"a","kind":"image","title":"截图","createdAt":"2026-09-18T02:00:00Z","contentType":"image/png","size":1}}
        ]}]}
        """
        try Data(json.utf8).write(to: url)
        let lossy = makeStore(artifactsURL: url)
        let ids = await lossy.artifacts(taskId: "codex:t1").map(\.id)
        XCTAssertEqual(ids, ["a"])
    }

    func testTaskCountIsBoundedEvictingOldest() async {
        let store = makeStore()
        await store.upsert(task("oldest"))
        await store.addArtifact(taskId: "codex:oldest", image("o", createdAt: "2026-09-01T00:00:00Z"))
        for index in 0..<TaskStore.maxArtifactTasks {
            await store.addArtifact(taskId: "codex:n\(index)", image("n\(index)", createdAt: "2026-09-18T02:00:00Z"))
        }
        let evicted = await store.artifacts(taskId: "codex:oldest")
        XCTAssertTrue(evicted.isEmpty)
        let record = await store.task(id: "codex:oldest")
        XCTAssertNil(record?.artifacts, "被淘汰的任务要重新盖章")
        let newest = await store.artifacts(taskId: "codex:n199")
        XCTAssertEqual(newest.map(\.id), ["n199"])
    }
}
