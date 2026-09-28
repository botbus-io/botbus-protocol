import XCTest
@testable import BotBusConnectorKit
import BotBusProtocol

/// 协议 2.7 worktree：解析规则、持久化、TaskStore 改写任务与项目、worktree 删掉后的续聊。
final class WorktreeTests: XCTestCase {
    private static let agentId = "agent-self-000000000"

    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("worktree-tests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    // MARK: - 夹具

    /// 在沙箱里摆出一个 worktree：目录里一个 `.git` 文件，内容就是 `gitdir: …`。只写这一个文件，不需要真的 git。
    @discardableResult
    private func makeWorktree(_ relative: String, gitdir: String) throws -> String {
        let directory = sandbox.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "gitdir: \(gitdir)\n".write(to: directory.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        return directory.path
    }

    private func makeStore(worktrees: WorktreeResolver = WorktreeResolver()) -> TaskStore {
        TaskStore(identity: AgentIdentity(agentId: Self.agentId, name: "本机", appVersion: "1.2.3"),
                  connectors: ConnectorRegistry(descriptors: ConnectorKind.allCases.map { kind in
                      ConnectorDescriptor(kind: kind, displayName: kind.rawValue, defaultEnabled: true) {
                          ConnectorProbe(available: true, status: .ok)
                      }
                  }),
                  worktrees: worktrees)
    }

    private func task(_ id: String, path: String, source: TaskSource = .claude,
                      updatedAt: String = "2026-09-18T02:00:00Z") -> TaskRecord {
        TaskRecord(id: "\(source.rawValue):\(id)", agentId: Self.agentId, source: source, title: id,
                   projectPath: path, projectName: URL(fileURLWithPath: path).lastPathComponent,
                   status: .completed, origin: .desktop, controllable: true,
                   startedAt: "2026-09-18T01:00:00Z", updatedAt: updatedAt)
    }

    private func project(_ path: String, lastUsedAt: String = "2026-09-18T02:00:00Z") -> Project {
        Project(agentId: Self.agentId, path: path, name: URL(fileURLWithPath: path).lastPathComponent,
                lastUsedAt: lastUsedAt, pinned: false)
    }

    // MARK: - 解析

    func testClaudeWorktreeIsResolvedByPathAlone() {
        let resolver = WorktreeResolver()
        // 目录根本不存在也认得出来：Claude app 的 worktree 常被删掉，而且这条路不读盘。
        XCTAssertEqual(resolver.projectRoot(for: "/Users/me/Projects/app/.claude/worktrees/dark-mode-4f2a9c"),
                       "/Users/me/Projects/app")
        // worktree 里的子目录归到主仓库里的同一个子目录，和手机选的子目录项目对得上。
        XCTAssertEqual(resolver.projectRoot(for: "/Users/me/Projects/app/.claude/worktrees/dark-mode-4f2a9c/web/"),
                       "/Users/me/Projects/app/web")
        XCTAssertEqual(resolver.projectRoot(for: "/Users/me/Projects/app/.claude/worktrees/dark-mode-4f2a9c/web/api"),
                       "/Users/me/Projects/app/web/api")
        // `.claude/worktrees` 本身不是 worktree；普通目录原样。
        XCTAssertNil(resolver.projectRoot(for: "/Users/me/Projects/app/.claude/worktrees"))
        XCTAssertNil(resolver.projectRoot(for: "/Users/me/Projects/app"))
        XCTAssertNil(resolver.projectRoot(for: ""))
    }

    func testCodexWorktreeIsResolvedFromItsGitFile() throws {
        let path = try makeWorktree("codex/worktrees/a1b2/app", gitdir: "/Users/me/Projects/app/.git/worktrees/app")
        let resolver = WorktreeResolver()
        XCTAssertEqual(resolver.projectRoot(for: path), "/Users/me/Projects/app")

        // worktree 里的子目录往上找到同一个 `.git`，归到主仓库里的同一个子目录。
        let sub = sandbox.appendingPathComponent("codex/worktrees/a1b2/app/relay/src", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        XCTAssertEqual(resolver.projectRoot(for: sub.path), "/Users/me/Projects/app/relay/src")
    }

    func testRelativeGitdirIsResolvedAgainstTheWorktree() throws {
        // 新版 git 的 `worktree.useRelativePaths` 会写相对路径。
        let path = try makeWorktree("repo/wt/worktrees/feature", gitdir: "../../../.git/worktrees/feature")
        XCTAssertEqual(WorktreeResolver().projectRoot(for: path), sandbox.appendingPathComponent("repo").path)
    }

    func testSubmoduleBareRepoAndPlainRepoAreNotWorktrees() throws {
        let submodule = try makeWorktree("a/worktrees/x/lib", gitdir: "/Users/me/app/.git/modules/lib")
        let bare = try makeWorktree("b/worktrees/x", gitdir: "/Users/me/app.git/worktrees/x")
        let plain = sandbox.appendingPathComponent("c/worktrees/x", isDirectory: true)
        try FileManager.default.createDirectory(at: plain.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let resolver = WorktreeResolver()
        XCTAssertNil(resolver.projectRoot(for: submodule))
        XCTAssertNil(resolver.projectRoot(for: bare))
        XCTAssertNil(resolver.projectRoot(for: plain.path))
    }

    func testPathsWithoutWorktreesDirectoryAreNotRead() throws {
        // 这是个真 worktree，但路径里没有 `worktrees` 这一层：不读盘，原样当项目（免得碰「文稿」里的文件弹授权）。
        let path = try makeWorktree("elsewhere/feature", gitdir: "/Users/me/app/.git/worktrees/feature")
        XCTAssertNil(WorktreeResolver().projectRoot(for: path))
        XCTAssertNil(WorktreeResolver.resolveOnDisk(path))
    }

    func testMissIsRetriedAfterInterval() throws {
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000_000))
        let resolver = WorktreeResolver(now: { clock.now })
        let directory = sandbox.appendingPathComponent("codex/worktrees/z9/app", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertNil(resolver.projectRoot(for: directory.path))

        // `.git` 后写出来：缓存期内仍是 nil，过了重试间隔才认出来。
        try "gitdir: /Users/me/app/.git/worktrees/app\n"
            .write(to: directory.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        XCTAssertNil(resolver.projectRoot(for: directory.path))
        clock.advance(WorktreeResolver.missRetryInterval + 1)
        XCTAssertEqual(resolver.projectRoot(for: directory.path), "/Users/me/app")
    }

    func testResolvedWorktreeSurvivesDeletionAndRestart() throws {
        let archive = sandbox.appendingPathComponent("support/worktrees.json")
        let path = try makeWorktree("codex/worktrees/a1b2/app", gitdir: "/Users/me/app/.git/worktrees/app")
        XCTAssertEqual(WorktreeResolver(archiveURL: archive).projectRoot(for: path), "/Users/me/app")

        // worktree 删了、Agent 重启：靠 worktrees.json 仍归得回去。
        try FileManager.default.removeItem(atPath: path)
        XCTAssertEqual(WorktreeResolver(archiveURL: archive).projectRoot(for: path), "/Users/me/app")
        XCTAssertNil(WorktreeResolver().projectRoot(for: path), "没有持久化就认不出了")
    }

    func testDeletedWorktreeFallsBackToTheOnlySameNamedRoot() throws {
        let resolver = WorktreeResolver()
        let gone = "/Users/me/.codex/worktrees/8417/giggleland"
        XCTAssertNil(resolver.projectRoot(for: gone), "还没见过同名的主仓库")

        // 见过同名的普通项目之后就能归过去（没见过时的那次 miss 不挡它：推断每次重算）。
        XCTAssertNil(resolver.projectRoot(for: "/Users/me/Projects/giggleland"))
        XCTAssertEqual(resolver.projectRoot(for: gone), "/Users/me/Projects/giggleland")

        // 同名的有两个就不猜。
        XCTAssertNil(resolver.projectRoot(for: "/Users/me/Archive/giggleland"))
        XCTAssertNil(resolver.projectRoot(for: gone))
    }

    func testSameNameFallbackUsesResolvedRootsAndSkipsExistingDirectories() throws {
        let resolver = WorktreeResolver()
        // 另一个还在的 worktree 让主仓库被认出来。
        let alive = try makeWorktree("codex/worktrees/6431/giggleland",
                                     gitdir: "/Users/me/Projects/giggleland/.git/worktrees/giggleland3")
        XCTAssertEqual(resolver.projectRoot(for: alive), "/Users/me/Projects/giggleland")
        let gone = sandbox.appendingPathComponent("codex/worktrees/8417/giggleland").path
        XCTAssertEqual(resolver.projectRoot(for: gone), "/Users/me/Projects/giggleland")

        // 目录还在、只是认不出（不是 worktree）的不按名字猜。
        let plain = sandbox.appendingPathComponent("codex/worktrees/9999/giggleland", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        XCTAssertNil(resolver.projectRoot(for: plain.path))
    }

    func testStoreGroupsDeletedCodexWorktreeByName() async {
        let store = makeStore()
        let gone = "/Users/me/.codex/worktrees/8417/giggleland"
        // 同一轮里报上来的项目先盖章，所以主仓库在任务之前就被见过了。
        await store.reconcile(source: .codex, tasks: [task("old", path: gone, source: .codex)],
                              projects: [project("/Users/me/Projects/giggleland"), project(gone)])
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.tasks.first?.projectPath, "/Users/me/Projects/giggleland")
        XCTAssertEqual(snapshot.tasks.first?.worktreePath, gone)
        XCTAssertEqual(snapshot.projects.map(\.path), ["/Users/me/Projects/giggleland"])
    }

    func testCorruptArchiveIsIgnored() throws {
        let archive = sandbox.appendingPathComponent("worktrees.json")
        try Data("不是 JSON".utf8).write(to: archive)
        XCTAssertEqual(WorktreeResolver(archiveURL: archive).projectRoot(for: "/r/.claude/worktrees/x"), "/r")
    }

    // MARK: - TaskStore

    func testStoreGroupsWorktreeSessionsUnderMainRepository() async {
        let store = makeStore()
        let worktree = "/Users/me/Projects/app/.claude/worktrees/dark-mode-4f2a9c"
        await store.reconcile(source: .claude,
                              tasks: [task("wt", path: worktree), task("main", path: "/Users/me/Projects/app")],
                              projects: [project(worktree, lastUsedAt: "2026-09-18T03:00:00Z"),
                                         project("/Users/me/Projects/app")])
        let snapshot = await store.snapshot()
        let byId = Dictionary(uniqueKeysWithValues: snapshot.tasks.map { ($0.id, $0) })

        XCTAssertEqual(byId["claude:wt"]?.projectPath, "/Users/me/Projects/app")
        XCTAssertEqual(byId["claude:wt"]?.projectName, "app")
        XCTAssertEqual(byId["claude:wt"]?.worktreePath, worktree)
        XCTAssertEqual(byId["claude:wt"]?.workingDirectory, worktree)
        // 不在 worktree 里的任务不带这个键。
        XCTAssertNil(byId["claude:main"]?.worktreePath)
        // 两条项目归成一个主仓库，最近使用取较新的那条。
        XCTAssertEqual(snapshot.projects.map(\.path), ["/Users/me/Projects/app"])
        XCTAssertEqual(snapshot.projects.first?.name, "app")
        XCTAssertEqual(snapshot.projects.first?.lastUsedAt, "2026-09-18T03:00:00Z")
        // 存着的也是改写后的：本机其他地方（预览的工作目录）读 `workingDirectory`。
        let stored = await store.task(id: "claude:wt")
        XCTAssertEqual(stored?.workingDirectory, worktree)
    }

    func testRestampingIsIdempotent() async {
        let store = makeStore()
        let worktree = "/Users/me/Projects/app/.claude/worktrees/x-123abc"
        let first = await store.upsert(task("wt", path: worktree))
        XCTAssertEqual(first.first?.task?.worktreePath, worktree)
        // 配对后重新盖章，不能把已经挪进 worktreePath 的目录冲掉。
        await store.setAgentId("agent-new-000000000")
        let stored = await store.task(id: "claude:wt")
        XCTAssertEqual(stored?.agentId, "agent-new-000000000")
        XCTAssertEqual(stored?.projectPath, "/Users/me/Projects/app")
        XCTAssertEqual(stored?.worktreePath, worktree)
        // 连接器再报一次同样的原始记录：没有变化就不发事件。
        let repeated = await store.upsert(task("wt", path: worktree))
        XCTAssertTrue(repeated.isEmpty)
    }

    func testOutsideProjectIsJudgedOnTheMainRepository() async {
        // 主仓库本身不算项目时（这里是主目录），worktree 里的会话同样算「不在项目中」。
        let store = TaskStore(identity: AgentIdentity(agentId: Self.agentId, name: "本机", appVersion: "1.2.3"),
                              outsideProjects: OutsideProjectRule(homeDirectory: "/Users/me"))
        let events = await store.upsert(task("wt", path: "/Users/me/.claude/worktrees/x-123abc"))
        let stamped = events.first?.task
        XCTAssertEqual(stamped?.projectPath, "/Users/me")
        XCTAssertEqual(stamped?.outsideProject, true)
    }
}

private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var now: Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); value.addTimeInterval(seconds); lock.unlock() }
}
