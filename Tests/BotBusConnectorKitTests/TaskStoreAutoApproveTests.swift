import XCTest
@testable import BotBusConnectorKit
import BotBusProtocol

/// 协议 3.3 项目级自动批准：TaskStore 的持久化、盖章（任务与项目）、快照补发与给连接器的查询。
final class TaskStoreAutoApproveTests: XCTestCase {
    private static let agentId = "agent-self-000000000"

    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("auto-approve-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    // MARK: - 夹具

    private func makeStore(autoApproveURL: URL? = nil) -> TaskStore {
        TaskStore(identity: AgentIdentity(agentId: Self.agentId, name: "本机", appVersion: "1.2.3"),
                  connectors: ConnectorRegistry(descriptors: ConnectorKind.allCases.map { kind in
                      ConnectorDescriptor(kind: kind, displayName: kind.rawValue, defaultEnabled: true) {
                          ConnectorProbe(available: true, status: .ok)
                      }
                  }),
                  autoApproveURL: autoApproveURL,
                  outsideProjects: OutsideProjectRule(homeDirectory: "/Users/me"))
    }

    private func task(_ id: String, path: String, source: TaskSource = .claude) -> TaskRecord {
        TaskRecord(id: "\(source.rawValue):\(id)", agentId: Self.agentId, source: source, title: id,
                   projectPath: path, projectName: URL(fileURLWithPath: path).lastPathComponent,
                   status: .running, origin: .desktop, controllable: true,
                   startedAt: "2026-09-18T01:00:00Z", updatedAt: "2026-09-18T02:00:00Z")
    }

    private func project(_ path: String) -> Project {
        Project(agentId: Self.agentId, path: path, name: URL(fileURLWithPath: path).lastPathComponent,
                lastUsedAt: "2026-09-18T02:00:00Z", pinned: false)
    }

    // MARK: - 盖章

    func testTasksAndProjectsAreStampedOnlyWhileEnabled() async {
        let store = makeStore()
        await store.reconcile(source: .codex, tasks: [task("a", path: "/work/app", source: .codex),
                                                      task("b", path: "/work/other", source: .codex)],
                              projects: [project("/work/app"), project("/work/other")])

        var snapshot = await store.snapshot()
        XCTAssertTrue(snapshot.tasks.allSatisfy { $0.autoApprove == nil })
        XCTAssertTrue(snapshot.projects.allSatisfy { $0.autoApprove == nil })

        let events = await store.setAutoApprove(true, project: "/work/app")
        // 项目只随快照更新：打开时补一份全量快照，任务上的标记也在里面。
        XCTAssertEqual(events.map(\.kind), [.snapshot])
        snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.tasks.first { $0.id == "codex:a" }?.autoApprove, true)
        XCTAssertNil(snapshot.tasks.first { $0.id == "codex:b" }?.autoApprove)
        XCTAssertEqual(snapshot.projects.first { $0.path == "/work/app" }?.autoApprove, true)
        XCTAssertNil(snapshot.projects.first { $0.path == "/work/other" }?.autoApprove)

        // 连接器之后的 upsert 不带这个字段，照样盖上。
        var again = task("a", path: "/work/app", source: .codex)
        again.lastMessage = "进展"
        let updated = await store.upsert(again)
        XCTAssertEqual(updated.first?.task?.autoApprove, true)

        // 值没变：什么都不发。
        let unchanged = await store.setAutoApprove(true, project: "/work/app")
        XCTAssertTrue(unchanged.isEmpty)

        let off = await store.setAutoApprove(false, project: "/work/app")
        XCTAssertEqual(off.map(\.kind), [.snapshot])
        snapshot = await store.snapshot()
        XCTAssertTrue(snapshot.tasks.allSatisfy { $0.autoApprove == nil })
        XCTAssertTrue(snapshot.projects.allSatisfy { $0.autoApprove == nil })
    }

    func testWorktreeSessionFollowsItsMainRepository() async {
        let store = makeStore()
        let worktree = "/work/app/.claude/worktrees/feature-x"
        await store.upsert(task("w", path: worktree))
        await store.setAutoApprove(true, project: "/work/app")

        let stamped = await store.task(id: "claude:w")
        XCTAssertEqual(stamped?.projectPath, "/work/app")
        XCTAssertEqual(stamped?.autoApprove, true)
        // 还没进 store 的新会话（第一轮）按工作目录归到主仓库再查。
        let fresh = await store.autoApproves(taskId: "claude:new", workingDirectory: "/work/app/.claude/worktrees/other")
        XCTAssertTrue(fresh)
        let project = await store.autoApproveProject(forWorkingDirectory: worktree)
        XCTAssertEqual(project, "/work/app")
    }

    /// 子目录项目（协议 3.4 的 worktree 会话）：手机选 `/work/app/web` 开的会话跑在 `<wt>/web`，
    /// 归回 `/work/app/web`——设置记在哪个项目，查的时候也得是这个项目，不能漂到主仓库根上。
    func testWorktreeSessionInSubdirectoryProjectMatchesThePickedProject() async {
        let store = makeStore()
        await store.setAutoApprove(true, project: "/work/app/web")
        let cwd = "/work/app/.claude/worktrees/a1b2c3/web"

        let fresh = await store.autoApproves(taskId: "claude:new", workingDirectory: cwd)
        XCTAssertTrue(fresh, "第一轮还没进 store，按工作目录归项目也要对上")
        let project = await store.autoApproveProject(forWorkingDirectory: cwd)
        XCTAssertEqual(project, "/work/app/web")

        await store.upsert(task("sub", path: cwd))
        let stamped = await store.task(id: "claude:sub")
        XCTAssertEqual(stamped?.projectPath, "/work/app/web")
        XCTAssertEqual(stamped?.worktreePath, cwd)
        XCTAssertEqual(stamped?.autoApprove, true)
        // 主仓库根上的设置不外溢到子目录项目。
        await store.setAutoApprove(false, project: "/work/app/web")
        await store.setAutoApprove(true, project: "/work/app")
        let rootOnly = await store.task(id: "claude:sub")
        XCTAssertNil(rootOnly?.autoApprove)
    }

    func testOutsideProjectNeverCarriesAutoApprove() async {
        let store = makeStore()
        await store.upsert(task("home", path: "/Users/me"))
        // 就算设置里有这条路径（旧文件、手改），不在项目中的任务也不带。
        await store.setAutoApprove(true, project: "/Users/me")

        let stamped = await store.task(id: "claude:home")
        XCTAssertEqual(stamped?.outsideProject, true)
        XCTAssertNil(stamped?.autoApprove)
        let asked = await store.autoApproves(taskId: "claude:home", workingDirectory: "/Users/me")
        XCTAssertFalse(asked)
        let unknown = await store.autoApproves(taskId: "claude:nobody", workingDirectory: "/Users/me")
        XCTAssertFalse(unknown)
        let project = await store.autoApproveProject(forWorkingDirectory: "")
        XCTAssertNil(project)
    }

    func testTaskLookupWinsOverWorkingDirectory() async {
        let store = makeStore()
        await store.upsert(task("a", path: "/work/app"))
        await store.setAutoApprove(true, project: "/work/other")

        // store 里有这条任务就按它的项目判，不看调用方给的目录。
        let byTask = await store.autoApproves(taskId: "claude:a", workingDirectory: "/work/other")
        XCTAssertFalse(byTask)
        let byPath = await store.autoApproves(taskId: "claude:missing", workingDirectory: "/work/other")
        XCTAssertTrue(byPath)
    }

    // MARK: - 持久化

    func testSettingSurvivesRestart() async throws {
        let url = sandbox.appendingPathComponent("auto-approve.json")
        let first = makeStore(autoApproveURL: url)
        await first.setAutoApprove(true, project: "/work/app")
        await first.setAutoApprove(true, project: "/work/b")
        await first.setAutoApprove(false, project: "/work/b")
        // 改了立刻落盘，不等退出。
        XCTAssertEqual(AutoApproveArchive.load(from: url), ["/work/app"])

        let second = makeStore(autoApproveURL: url)
        let enabled = await second.isAutoApproveEnabled(project: "/work/app")
        XCTAssertTrue(enabled)
        await second.upsert(task("a", path: "/work/app"))
        let stamped = await second.task(id: "claude:a")
        XCTAssertEqual(stamped?.autoApprove, true)
    }

    func testCorruptOrMissingFileMeansNothingEnabled() async throws {
        let url = sandbox.appendingPathComponent("auto-approve.json")
        XCTAssertEqual(AutoApproveArchive.load(from: url), [])
        try Data("{不是 JSON".utf8).write(to: url)
        let store = makeStore(autoApproveURL: url)
        let enabled = await store.isAutoApproveEnabled(project: "/work/app")
        XCTAssertFalse(enabled)
    }
}
