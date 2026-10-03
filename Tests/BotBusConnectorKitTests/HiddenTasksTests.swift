import XCTest
@testable import BotBusConnectorKit
import BotBusProtocol

final class HiddenTasksTests: XCTestCase {
    private func store(hiddenURL: URL? = nil, worktrees: Bool = false) -> TaskStore {
        TaskStore(identity: AgentIdentity(agentId: "agent-1", name: "本机", appVersion: "1.0"),
                  connectors: ConnectorRegistry(descriptors: ConnectorKind.allCases.map { kind in
                      ConnectorDescriptor(kind: kind, displayName: kind.rawValue, defaultEnabled: true) {
                          ConnectorProbe(available: true, status: .ok)
                      }
                  }),
                  hiddenTasksURL: hiddenURL, supportsWorktrees: worktrees)
    }

    private func task(_ id: String) -> TaskRecord {
        TaskRecord(id: "claude:\(id)", agentId: "agent-1", source: .claude, title: id, projectPath: "/p",
                   projectName: "p", status: .completed, origin: .desktop, controllable: true,
                   startedAt: "2026-09-28T01:00:00Z", updatedAt: "2026-09-28T02:00:00Z")
    }

    func testProjectRemovalPersistsKeepsLiveOwnershipAndReturnsOnActivity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("removed-project-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.swift")
        try Data("keep source".utf8).write(to: source)
        let hidden = root.appendingPathComponent("hidden-tasks.json")
        let s = store(hiddenURL: hidden)
        var original = task("a"); original.projectPath = root.path
        let project = Project(agentId: "agent-1", path: root.path, name: "test", lastUsedAt: original.updatedAt, pinned: false)
        await s.reconcile(source: .claude, tasks: [original], projects: [project])
        await s.claimLive(original.id)
        try await s.removeProject(path: root.path)
        let after = await s.snapshot()
        XCTAssertTrue(after.projects.isEmpty)
        XCTAssertTrue(after.tasks.isEmpty)
        let owner = await s.owner(of: original.id)
        XCTAssertEqual(owner, .live)
        let raw = await s.task(id: original.id)
        XCTAssertNotNil(raw)
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "keep source")
        await s.upsert(original)
        let unchanged = await s.snapshot()
        XCTAssertTrue(unchanged.tasks.isEmpty)
        let restart = store(hiddenURL: hidden)
        await restart.reconcile(source: .claude, tasks: [original], projects: [project])
        let restarted = await restart.snapshot()
        XCTAssertTrue(restarted.tasks.isEmpty)
        original.updatedAt = "2026-09-28T03:00:00Z"
        original.lastMessage = "new message"
        await restart.upsert(original)
        let restored = await restart.snapshot()
        XCTAssertEqual(restored.tasks.count, 1)
        XCTAssertEqual(restored.projects.count, 1)
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "keep source")
    }

    func testCanRemoveTaskDerivedProjectWithNoReportedProject() async throws {
        let s = store()
        await s.upsert(task("a"))
        try await s.removeProject(path: "/p")
        let result = await s.snapshot()
        XCTAssertTrue(result.tasks.isEmpty)
    }

    func testHiddenTaskLeavesAndStaysOut() async {
        let s = store()
        await s.reconcile(source: .claude, tasks: [task("a"), task("b")], projects: [])
        let events = await s.hide(id: "claude:a")
        XCTAssertEqual(events, [.taskRemoved("claude:a")])
        // 只读观察再报上来也不回来；实时 upsert 同样挡住。
        await s.reconcile(source: .claude, tasks: [task("a"), task("b")], projects: [])
        await s.upsert(task("a"))
        let ids = await s.snapshot().tasks.map(\.id)
        XCTAssertEqual(ids, ["claude:b"])
    }

    func testHidingUnknownTaskStillReportsRemoval() async {
        let s = store()
        let events = await s.hide(id: "claude:gone")
        XCTAssertEqual(events, [.taskRemoved("claude:gone")])
    }

    func testHiddenSetPersists() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hidden-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = store(hiddenURL: url)
        await first.reconcile(source: .claude, tasks: [task("a")], projects: [])
        await first.hide(id: "claude:a")
        await first.flushHiddenTasks()
        let second = store(hiddenURL: url)
        await second.reconcile(source: .claude, tasks: [task("a")], projects: [])
        let count = await second.snapshot().tasks.count
        XCTAssertEqual(count, 0)
    }

    func testTrimKeepsNewestHidden() {
        let tasks = ["claude:old": "2026-09-01T00:00:00Z", "claude:mid": "2026-09-10T00:00:00Z",
                     "claude:new": "2026-09-20T00:00:00Z"]
        XCTAssertEqual(Set(HiddenTaskArchive.trimmed(tasks, limit: 2).keys), ["claude:mid", "claude:new"])
    }

    func testIsHiddenAndClaimLiveSkipsHiddenIds() async {
        let s = store()
        await s.reconcile(source: .claude, tasks: [task("a")], projects: [])
        let before = await s.isHidden("claude:a")
        XCTAssertFalse(before)
        await s.hide(id: "claude:a")
        let after = await s.isHidden("claude:a")
        XCTAssertTrue(after)
        // 连接器（Claude 的 publish）照旧 claimLive：隐藏的 id 不该因此挂上 live 所有权。
        await s.claimLive("claude:a")
        let owner = await s.owner(of: "claude:a")
        XCTAssertEqual(owner, .observer)
    }

    func testHideDropsArtifacts() async {
        let s = store()
        await s.reconcile(source: .claude, tasks: [task("a")], projects: [])
        let artifact = Artifact(id: "img-1", kind: .image, title: "截图", createdAt: ProtocolJSON.timestamp(Date()),
                                contentType: "image/png", size: 10)
        await s.addArtifact(taskId: "claude:a", artifact)
        let added = await s.artifacts(taskId: "claude:a")
        XCTAssertEqual(added.map(\.id), ["img-1"])
        await s.hide(id: "claude:a")
        let left = await s.artifacts(taskId: "claude:a")
        XCTAssertTrue(left.isEmpty)
    }

    func testTasksWorkingInsideAWorktree() async {
        let s = store()
        let worktree = ManagedWorktree(path: "/work/repo/.claude/worktrees/a1b2c3", repository: "/work/repo",
                                       branch: "botbus/a1b2c3", baseBranch: "main", baseCommit: "abc")
        func at(_ id: String, _ path: String) -> TaskRecord {
            var record = task(id)
            record.projectPath = path
            return record
        }
        await s.reconcile(source: .claude, tasks: [at("a", worktree.path), at("b", worktree.path + "/web"),
                                                   at("c", "/work/repo"), at("d", worktree.path + "-other")],
                          projects: [])
        let ids = await s.tasks(workingIn: worktree).map(\.id).sorted()
        XCTAssertEqual(ids, ["claude:a", "claude:b"])
    }

    func testSnapshotReportsWorktreeSupport() async {
        let without = await store().snapshot().agents[0].worktrees
        XCTAssertNil(without)
        let with = await store(worktrees: true).snapshot().agents[0].worktrees
        XCTAssertEqual(with, true)
    }
}
