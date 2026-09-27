import XCTest
@testable import BotBusConnectorKit
@testable import BotBusConnectors
import BotBusProtocol

final class CodexThreadReaderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_789_700_000) // 2026-09-18T02:53:20Z
    private var stateDir: URL!

    override func setUpWithError() throws {
        stateDir = FileManager.default.temporaryDirectory.appendingPathComponent("botbus-codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    }

    private func ms(_ secondsAgo: TimeInterval) -> Int64 {
        Int64((now.timeIntervalSince1970 - secondsAgo) * 1000)
    }

    /// 造两个最小库：state_7.sqlite 与 thread_history_3.sqlite（故意用非 1 的版本号验证取最新号）。
    private func makeFixture() throws -> CodexPaths {
        try SQLiteDatabase(path: stateDir.appendingPathComponent("state_2.sqlite").path, readOnly: false)
            .execute("CREATE TABLE threads (id TEXT)")
        let state = try SQLiteDatabase(path: stateDir.appendingPathComponent("state_7.sqlite").path, readOnly: false)
        try state.execute("""
            CREATE TABLE threads (id TEXT PRIMARY KEY, cwd TEXT NOT NULL, name TEXT, title TEXT NOT NULL DEFAULT '',
              first_user_message TEXT NOT NULL DEFAULT '', source TEXT NOT NULL, archived INTEGER NOT NULL DEFAULT 0,
              created_at_ms INTEGER, updated_at_ms INTEGER, model TEXT, reasoning_effort TEXT);
            CREATE TABLE projects (id TEXT PRIMARY KEY, name TEXT NOT NULL, position INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL);
            CREATE TABLE project_roots (project_id TEXT NOT NULL, position INTEGER NOT NULL, path TEXT NOT NULL);
            """)
        try state.execute("""
            INSERT INTO threads (id, cwd, name, title, first_user_message, source, archived, created_at_ms, updated_at_ms) VALUES
              ('t-running',  '/Users/me/Projects/shop',   NULL, '重构支付模块', '重构支付模块', 'vscode', 0, \(ms(3600)), \(ms(60))),
              ('t-done',     '/Users/me/Projects/lab',    '命名的标题', '首条消息', '首条消息', 'vscode', 0, \(ms(7200)), \(ms(1800))),
              ('t-failed',   '/Users/me/Projects/lab',    NULL, '', '很长的首条消息' || substr(replace(hex(zeroblob(60)), '0', 'x'), 1, 120), 'cli', 0, \(ms(7200)), \(ms(3000))),
              ('t-idle',     '/Users/me/Projects/old',    NULL, '昨天的实验', '昨天的实验', 'vscode', 0, \(ms(200_000)), \(ms(100_000))),
              ('t-subagent', '/Users/me/Projects/shop',   NULL, 'sub', 'sub', '{"subagent":{"other":"guardian"}}', 0, \(ms(100)), \(ms(50))),
              ('t-archived', '/Users/me/Projects/shop',   NULL, 'arch', 'arch', 'vscode', 1, \(ms(100)), \(ms(50))),
              ('t-ancient',  '/Users/me/Projects/shop',   NULL, 'anc', 'anc', 'vscode', 0, \(ms(900_000)), \(ms(800_000)));
            INSERT INTO projects VALUES ('p1', 'shop', 0, \(ms(60))), ('p2', 'lab', 1, \(ms(1800))), ('p3', 'noroot', 2, \(ms(10)));
            INSERT INTO project_roots VALUES ('p1', 0, '/Users/me/Projects/shop'), ('p2', 0, '/Users/me/Projects/lab'), ('p2', 1, '/Users/me/Projects/lab-extra');
            """)

        let history = try SQLiteDatabase(path: stateDir.appendingPathComponent("thread_history_3.sqlite").path, readOnly: false)
        try history.execute("""
            CREATE TABLE thread_turns (thread_id TEXT NOT NULL, turn_id TEXT NOT NULL, rollout_ordinal INTEGER NOT NULL, status TEXT NOT NULL);
            CREATE TABLE thread_items (thread_id TEXT NOT NULL, turn_id TEXT NOT NULL, item_id TEXT NOT NULL, rollout_ordinal INTEGER NOT NULL,
              item_json TEXT NOT NULL, item_type TEXT NOT NULL DEFAULT '', updated_at_ordinal INTEGER NOT NULL DEFAULT 0);
            INSERT INTO thread_turns VALUES
              ('t-running', 'u1', 10, 'completed'), ('t-running', 'u2', 20, 'inProgress'),
              ('t-done', 'u1', 10, 'completed'),
              ('t-failed', 'u1', 10, 'failed'),
              ('t-idle', 'u1', 10, 'completed');
            INSERT INTO thread_items VALUES
              ('t-running', 'u1', 'i1', 11, '{"type":"agentMessage","id":"i1","text":"旧回答","phase":"final_answer"}', 'agentMessage', 0),
              ('t-running', 'u2', 'i2', 21, '{"type":"commandExecution","id":"i2","command":"ls"}', 'commandExecution', 0),
              ('t-running', 'u2', 'i3', 22, '{"type":"agentMessage","id":"i3","text":"正在检查 Checkout.ts","phase":"commentary"}', 'agentMessage', 0),
              ('t-done', 'u1', 'i1', 11, 'not json at all', 'agentMessage', 0),
              ('t-failed', 'u1', 'i1', 11, '{"type":"agentMessage","id":"i1","text":"' || replace(hex(zeroblob(300)), '0', 'y') || '"}', 'agentMessage', 0);
            """)
        return CodexPaths(codexHome: stateDir)
    }

    func testPicksHighestVersionedDatabases() throws {
        let paths = try makeFixture()
        XCTAssertEqual(paths.stateDatabase?.lastPathComponent, "state_7.sqlite")
        XCTAssertEqual(paths.historyDatabase?.lastPathComponent, "thread_history_3.sqlite")
        XCTAssertNil(CodexPaths(codexHome: URL(fileURLWithPath: "/nonexistent")).stateDatabase)
    }

    func testReadsTasksWithStatusTitleAndLastMessage() throws {
        let paths = try makeFixture()
        let state = try SQLiteDatabase(path: paths.stateDatabase!.path, readOnly: false)
        try state.execute("UPDATE threads SET model = 'gpt-6-sol', reasoning_effort = 'high' WHERE id = 't-done'")
        try state.execute("UPDATE threads SET model = '-bad', reasoning_effort = 'High' WHERE id = 't-failed'")
        let reader = try XCTUnwrap(CodexThreadReader(paths: paths, now: { self.now }))
        let tasks = try reader.readTasks(agentId: "agent-mac-1")

        XCTAssertEqual(tasks.map(\.id), ["codex:t-running", "codex:t-done", "codex:t-failed", "codex:t-idle"])
        XCTAssertTrue(tasks.allSatisfy { $0.agentId == "agent-mac-1" }, "归属由调用方注入，reader 不该自己去碰凭据")
        let running = tasks[0]
        XCTAssertEqual(running.status, .running)
        XCTAssertEqual(running.title, "重构支付模块")
        XCTAssertEqual(running.projectName, "shop")
        XCTAssertEqual(running.lastMessage, "正在检查 Checkout.ts")
        XCTAssertFalse(running.controllable)
        XCTAssertEqual(running.origin, .desktop)
        XCTAssertEqual(running.updatedAt, "2026-09-18T02:52:20Z")

        let done = tasks[1]
        XCTAssertEqual(done.status, .completed)
        XCTAssertEqual(done.title, "命名的标题")
        XCTAssertNil(done.lastMessage, "坏 JSON 只能让 lastMessage 为空，不能抛错")
        XCTAssertTrue(done.controllable)
        XCTAssertEqual(done.model, "gpt-6-sol", "协议 3.2：线程上记着的模型报给手机")
        XCTAssertEqual(done.effort, "high")
        XCTAssertNil(running.model, "没记模型的线程省略")

        let failed = tasks[2]
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.title.count, 80)
        XCTAssertEqual(failed.lastMessage?.count, 500)
        XCTAssertNil(failed.model, "不合法的模型 id 不报，免得对端整条拒收")
        XCTAssertNil(failed.effort)

        XCTAssertEqual(tasks[3].status, .idle)
    }

    func testReadsRecentProjectsWithFirstRootOnly() throws {
        let paths = try makeFixture()
        let reader = try XCTUnwrap(CodexThreadReader(paths: paths, now: { self.now }))
        let projects = try reader.readProjects(agentId: "agent-mac-1")
        XCTAssertEqual(projects.map(\.path), ["/Users/me/Projects/shop", "/Users/me/Projects/lab"])
        XCTAssertEqual(projects.map(\.name), ["shop", "lab"])
        XCTAssertEqual(projects[0].lastUsedAt, "2026-09-18T02:52:20Z")
        XCTAssertFalse(projects[0].pinned)
        XCTAssertTrue(projects.allSatisfy { $0.agentId == "agent-mac-1" })
        XCTAssertEqual(projects[0].id, "agent-mac-1//Users/me/Projects/shop", "项目标识是 (agentId, path)")
    }

    func testStatusMapping() {
        let recent = now.addingTimeInterval(-60)
        let stale = now.addingTimeInterval(-2 * 24 * 3600)
        XCTAssertEqual(CodexThreadReader.status(turnStatus: "inProgress", updatedAt: recent, now: now), .running)
        XCTAssertEqual(CodexThreadReader.status(turnStatus: "failed", updatedAt: recent, now: now), .failed)
        XCTAssertEqual(CodexThreadReader.status(turnStatus: "interrupted", updatedAt: recent, now: now), .interrupted)
        XCTAssertEqual(CodexThreadReader.status(turnStatus: "completed", updatedAt: recent, now: now), .completed)
        // 超过 24 小时一律 idle，不管最后一轮是什么结果
        XCTAssertEqual(CodexThreadReader.status(turnStatus: "inProgress", updatedAt: stale, now: now), .idle)
        XCTAssertEqual(CodexThreadReader.status(turnStatus: "failed", updatedAt: stale, now: now), .idle)
        XCTAssertEqual(CodexThreadReader.status(turnStatus: "interrupted", updatedAt: stale, now: now), .idle)
        XCTAssertEqual(CodexThreadReader.status(turnStatus: "completed", updatedAt: stale, now: now), .idle)
        // 没有任何轮次记录：还没跑过
        XCTAssertEqual(CodexThreadReader.status(turnStatus: nil, updatedAt: recent, now: now), .idle)
        XCTAssertEqual(CodexThreadReader.status(turnStatus: nil, updatedAt: stale, now: now), .idle)
    }

    func testThreadWithoutTurnsIsIdleAndMultilineMessageBecomesSingleLineTitle() throws {
        let paths = try makeFixture()
        let state = try SQLiteDatabase(path: try XCTUnwrap(paths.stateDatabase).path, readOnly: false)
        try state.execute("INSERT INTO threads (id, cwd, name, title, first_user_message, source, archived, created_at_ms, updated_at_ms) VALUES ('t-fresh', '/Users/me/Projects/fresh/', NULL, '', 'Implement Task 1.\n\nYou own only   these files', 'vscode', 0, \(ms(30)), \(ms(20)))")
        let reader = try XCTUnwrap(CodexThreadReader(paths: paths, now: { self.now }))
        let fresh = try XCTUnwrap(reader.readTasks(agentId: "agent-mac-1").first { $0.id == "codex:t-fresh" })
        XCTAssertEqual(fresh.status, .idle, "没有任何轮次记录不算完成")
        XCTAssertEqual(fresh.title, "Implement Task 1. You own only these files")
        XCTAssertEqual(fresh.projectName, "fresh")
        XCTAssertNil(fresh.lastMessage)
    }

    func testMissingHistoryTableThrows() throws {
        let paths = try makeFixture()
        let history = try SQLiteDatabase(path: try XCTUnwrap(paths.historyDatabase).path, readOnly: false)
        try history.execute("DROP TABLE thread_turns")
        let reader = try XCTUnwrap(CodexThreadReader(paths: paths, now: { self.now }))
        XCTAssertThrowsError(try reader.readTasks(agentId: "agent-mac-1"), "history 库 schema 漂移必须让整次轮询失败，而不是静默把所有任务显示成 idle")
    }

    /// 端到端回归：两个库都是 WAL 模式、已被干净关闭、侧文件都不在了，轮询必须照常出任务。
    ///
    /// 这就是菜单栏"一个 Codex 任务都没有"的真实成因：ChatGPT.app 退出并 checkpoint 之后，
    /// ~/.codex/thread_history_1.sqlite 只剩主文件，只读打开报 SQLite error 14，
    /// 而 readTasks 一开头就打开两个库，history 一挂整轮轮询就挂。
    /// 全程只动 temp 目录里的 fixture，不碰真实的 ~/.codex。
    func testReadsTasksFromCleanlyClosedWALDatabases() throws {
        let paths = try makeFixture()
        let databases = [try XCTUnwrap(paths.stateDatabase), try XCTUnwrap(paths.historyDatabase)]

        for url in databases {
            // 切到 WAL 并关掉；Apple 自带的 SQLite 会把 -wal 截成 0 字节留着，
            // 真实的 Codex 库则是连侧文件都没有，所以显式删掉侧文件复现那个状态。
            var writer: SQLiteDatabase? = try SQLiteDatabase(path: url.path, readOnly: false)
            try writer?.execute("PRAGMA journal_mode=WAL")
            writer = nil
            for suffix in ["-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }

            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + "-wal"),
                           "\(url.lastPathComponent) 的 -wal 必须不存在，否则没测到回归场景")
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + "-shm"))
            let header = try XCTUnwrap(Data(contentsOf: url).prefix(19))
            XCTAssertEqual(header[18], 2, "\(url.lastPathComponent) 必须仍是 WAL 模式")
        }

        let reader = try XCTUnwrap(CodexThreadReader(paths: paths, now: { self.now }))
        let tasks = try reader.readTasks(agentId: "agent-mac-1")
        XCTAssertEqual(tasks.map(\.id), ["codex:t-running", "codex:t-done", "codex:t-failed", "codex:t-idle"])
        XCTAssertEqual(tasks[0].status, .running, "status 来自 history 库，必须真读到了")
        XCTAssertEqual(tasks[0].lastMessage, "正在检查 Checkout.ts")
        XCTAssertEqual(try reader.readProjects(agentId: "agent-mac-1").count, 2)
    }

    func testDetectCodexBinaryPrefersChatGPTBundle() {
        let order = CodexPaths.knownBinaries
        XCTAssertEqual(order.first, "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex")
        XCTAssertTrue(order.contains("/Applications/ChatGPT.app/Contents/Resources/codex"))
        XCTAssertTrue(order.contains("/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex"))
        XCTAssertEqual(order.last, "/Applications/Codex.app/Contents/Resources/codex")
    }
}
