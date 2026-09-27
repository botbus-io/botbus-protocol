import XCTest
@testable import BotBusConnectorKit
@testable import BotBusConnectors
import BotBusProtocol

/// `~/.hermes/state.db` → 任务与项目。库是按 spec 列出的 v30 列现造的假数据，另有一份缺列的老库。
final class HermesStateReaderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_789_700_000) // 2026-09-18T02:53:20Z
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("botbus-hermes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { [home] in try? FileManager.default.removeItem(at: home!) }
    }

    /// `now` 往前 `secondsAgo` 秒的 epoch 秒（REAL）。
    private func t(_ secondsAgo: TimeInterval) -> String { String(now.timeIntervalSince1970 - secondsAgo) }

    private var databasePath: String { home.appendingPathComponent("state.db").path }

    private func reader() -> HermesStateReader {
        HermesStateReader(paths: HermesPaths(hermesHome: home), now: { [now] in now })
    }

    static let currentSchema = """
        CREATE TABLE sessions (id TEXT PRIMARY KEY, source TEXT, title TEXT, cwd TEXT, model TEXT,
          parent_session_id TEXT, started_at REAL, ended_at REAL, last_activity_at REAL, end_reason TEXT,
          message_count INTEGER DEFAULT 0, archived INTEGER DEFAULT 0, hidden INTEGER DEFAULT 0);
        CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL, role TEXT NOT NULL,
          content TEXT, tool_calls TEXT, tool_name TEXT, timestamp REAL, finish_reason TEXT,
          active INTEGER DEFAULT 1, reasoning TEXT, reasoning_details TEXT);
        """

    private func makeFixture() throws {
        let db = try SQLiteDatabase(path: databasePath, readOnly: false)
        try db.execute(Self.currentSchema)
        let longPrompt = String(repeating: "长", count: 120)
        try db.execute("""
            INSERT INTO sessions (id, source, title, cwd, parent_session_id, started_at, ended_at, last_activity_at, end_reason, archived, hidden) VALUES
              ('s-running',  'cli',      NULL,        '/Users/me/Projects/shop', NULL, \(t(3600)), NULL,        \(t(20)),  NULL,            0, 0),
              ('s-answered', 'cli',      '已答完',     '/Users/me/Projects/shop', NULL, \(t(3600)), NULL,        \(t(40)),  NULL,            0, 0),
              ('s-json',     'oneshot',  NULL,        '/Users/me/Projects/lab',  NULL, \(t(3600)), \(t(60)),   \(t(60)),  'agent_close',   0, 0),
              ('s-stale',    'cli',      '没关的会话', '/Users/me/Projects/lab',  NULL, \(t(7200)), NULL,        \(t(600)), NULL,            0, 0),
              ('s-done',     'cli',      '命名的标题', '/Users/me/Projects/lab',  NULL, \(t(7200)), \(t(1800)), \(t(1800)), 'agent_close',  0, 0),
              ('s-child',    'cli',      '压缩后的续篇', '/Users/me/Projects/shop', 's-parent', \(t(4000)), \(t(2000)), \(t(2000)), 'tui_shutdown', 0, 0),
              ('s-failed',   'cli',      '炸了',       '/Users/me/Projects/lab',  NULL, \(t(7200)), \(t(3000)), \(t(3000)), 'agent_error',  0, 0),
              ('s-long',     'cli',      '',          '/Users/me/Projects/lab/',  NULL, \(t(7200)), \(t(3500)), \(t(3500)), 'agent_close', 0, 0),
              ('s-untitled', 'cli',      NULL,        '/Users/me/Projects/empty', NULL, \(t(7200)), \(t(3600)), NULL,      NULL,           0, 0),
              ('s-idle',     'cli',      '昨天的',     '/Users/me/Projects/old',  NULL, \(t(200000)), \(t(100000)), \(t(100000)), 'error', 0, 0),
              ('s-parent',   'cli',      '被压缩的',   '/Users/me/Projects/shop', NULL, \(t(5000)), \(t(4000)), \(t(4000)), 'compression', 0, 0),
              ('s-telegram', 'telegram', '私聊',       NULL,                      NULL, \(t(100)), NULL,         \(t(10)),  NULL,           0, 0),
              ('s-blank',    'cli',      '空目录',     '  ',                      NULL, \(t(100)), NULL,         \(t(10)),  NULL,           0, 0),
              ('s-archived', 'cli',      '归档',       '/Users/me/Projects/shop', NULL, \(t(100)), NULL,         \(t(10)),  NULL,           1, 0),
              ('s-hidden',   'cli',      '隐藏',       '/Users/me/Projects/shop', NULL, \(t(100)), NULL,         \(t(10)),  NULL,           0, 1),
              ('s-ancient',  'cli',      '上古',       '/Users/me/Projects/shop', NULL, \(t(900000)), \(t(800000)), \(t(800000)), NULL,     0, 0);
            INSERT INTO messages (session_id, role, content, tool_calls, timestamp, finish_reason, active, reasoning) VALUES
              ('s-running', 'user', '修一下结账页面
            的按钮', NULL, \(t(100)), NULL, 1, NULL),
              ('s-running', 'assistant', '我先看看代码。', '[{"id":"c1","type":"function","function":{"name":"terminal","arguments":"{\\"command\\":\\"ls\\"}"}}]', \(t(90)), 'tool_calls', 1, '内部思考'),
              ('s-running', 'tool', 'Checkout.ts', NULL, \(t(80)), NULL, 1, NULL),
              ('s-answered', 'user', '问一句', NULL, \(t(60)), NULL, 1, NULL),
              ('s-answered', 'assistant', '答完了', NULL, \(t(40)), 'stop', 1, NULL),
              ('s-json', 'user', char(0) || 'json:[{"type":"text","text":"看看这张截图"},{"type":"image_url","image_url":{"url":"data:image/png;base64,AAAA"}}]', NULL, \(t(90)), NULL, 1, NULL),
              ('s-json', 'assistant', char(0) || 'json:[{"type":"text","text":"截图里"},{"type":"text","text":"按钮歪了"}]', NULL, \(t(70)), 'stop', 1, NULL),
              ('s-done', 'user', '做点事', NULL, \(t(2000)), NULL, 1, NULL),
              ('s-done', 'assistant', '最终回答', NULL, \(t(1900)), 'stop', 1, NULL),
              ('s-done', 'assistant', '被回退的回答', NULL, \(t(1850)), 'stop', 0, NULL),
              ('s-done', 'assistant', '   ', NULL, \(t(1840)), 'stop', 1, NULL),
              ('s-long', 'user', '\(longPrompt)', NULL, \(t(3600)), NULL, 1, NULL);
            """)
    }

    func testReadsCodingSessionsWithFiltersAndOrder() throws {
        try makeFixture()
        let snapshot = try reader().readSnapshot(agentId: "agent-mac-1")
        XCTAssertEqual(snapshot.tasks.map(\.id), [
            "hermes:s-running", "hermes:s-answered", "hermes:s-json", "hermes:s-stale", "hermes:s-done",
            "hermes:s-child", "hermes:s-failed", "hermes:s-long", "hermes:s-untitled", "hermes:s-idle",
        ], "没 cwd、空白 cwd、归档、隐藏、被压缩的父会话、7 天前的都不进；按活动时间降序")
        XCTAssertTrue(snapshot.tasks.allSatisfy { $0.agentId == "agent-mac-1" && $0.source == .hermes && $0.origin == .desktop })
    }

    func testStatusPaths() throws {
        try makeFixture()
        let tasks = Dictionary(uniqueKeysWithValues: try reader().readSnapshot(agentId: "a").tasks.map { ($0.id, $0) })
        XCTAssertEqual(tasks["hermes:s-running"]?.status, .running, "没结束、20 秒前还在动、最后一条是工具结果")
        XCTAssertEqual(tasks["hermes:s-running"]?.controllable, false, "桌面上正在跑的会话不可控")
        XCTAssertEqual(tasks["hermes:s-answered"]?.status, .completed, "会话开着但最后一条是答完的回答：不算在跑")
        XCTAssertEqual(tasks["hermes:s-json"]?.status, .completed)
        XCTAssertEqual(tasks["hermes:s-stale"]?.status, .completed, "没写 ended_at 但 10 分钟没动：进程多半已经没了")
        XCTAssertEqual(tasks["hermes:s-done"]?.status, .completed)
        XCTAssertEqual(tasks["hermes:s-done"]?.controllable, true)
        XCTAssertEqual(tasks["hermes:s-failed"]?.status, .failed)
        XCTAssertEqual(tasks["hermes:s-idle"]?.status, .idle, "超过 24 小时一律 idle，出错的也淡出")
    }

    func testStatusMappingTable() {
        let recent = now.addingTimeInterval(-30)
        XCTAssertEqual(HermesStateReader.status(endReason: nil, ended: false, activityAt: recent, now: now), .running)
        XCTAssertEqual(HermesStateReader.status(endReason: nil, ended: false, activityAt: recent, now: now, turnFinished: true), .completed)
        XCTAssertEqual(HermesStateReader.status(endReason: "content_filter", ended: true, activityAt: recent, now: now), .failed)
        XCTAssertEqual(HermesStateReader.status(endReason: "error", ended: false, activityAt: recent, now: now), .failed)
        XCTAssertEqual(HermesStateReader.status(endReason: "branched", ended: true, activityAt: recent, now: now), .completed)
        XCTAssertEqual(HermesStateReader.status(endReason: nil, ended: false, activityAt: now.addingTimeInterval(-121), now: now), .completed)
        XCTAssertEqual(HermesStateReader.status(endReason: "agent_error", ended: true,
                                                activityAt: now.addingTimeInterval(-90_000), now: now), .idle)
    }

    func testTitlePrecedenceAndLastMessage() throws {
        try makeFixture()
        let tasks = Dictionary(uniqueKeysWithValues: try reader().readSnapshot(agentId: "a").tasks.map { ($0.id, $0) })
        XCTAssertEqual(tasks["hermes:s-done"]?.title, "命名的标题", "title 列优先")
        XCTAssertEqual(tasks["hermes:s-running"]?.title, "修一下结账页面 的按钮", "没有 title 用首条 user 消息，压成单行")
        XCTAssertEqual(tasks["hermes:s-long"]?.title, String(repeating: "长", count: 80), "截到 80 字")
        XCTAssertEqual(tasks["hermes:s-untitled"]?.title, "empty", "再没有就用项目名")
        XCTAssertEqual(tasks["hermes:s-long"]?.projectName, "lab", "结尾的 / 不影响项目名")

        XCTAssertEqual(tasks["hermes:s-running"]?.lastMessage, "我先看看代码。")
        XCTAssertEqual(tasks["hermes:s-done"]?.lastMessage, "最终回答", "active=0 的与只有空白的都跳过")
        XCTAssertNil(tasks["hermes:s-untitled"]?.lastMessage)
        XCTAssertFalse(tasks.values.contains { $0.lastMessage?.contains("内部思考") == true }, "reasoning 不外发")
    }

    func testDecodesNulPrefixedJSONContent() throws {
        try makeFixture()
        let task = try XCTUnwrap(try reader().readSnapshot(agentId: "a").tasks.first { $0.id == "hermes:s-json" })
        XCTAssertEqual(task.title, "看看这张截图", "\\0json: 前缀的内容块只拼文本，图片跳过")
        XCTAssertEqual(task.lastMessage, "截图里\n按钮歪了")

        XCTAssertEqual(HermesSQL.decodeContent("plain"), "plain")
        XCTAssertEqual(HermesSQL.decodeContent("\u{0}json:\"就一句\""), "就一句")
        XCTAssertEqual(HermesSQL.decodeContent("\u{0}json:{\"text\":\"对象\"}"), "对象")
        XCTAssertNil(HermesSQL.decodeContent("\u{0}json:not json"))
        XCTAssertNil(HermesSQL.decodeContent("\u{0}json:[{\"type\":\"image_url\"}]"))
    }

    func testTimestampsAndProjects() throws {
        try makeFixture()
        let snapshot = try reader().readSnapshot(agentId: "agent-mac-1")
        let done = try XCTUnwrap(snapshot.tasks.first { $0.id == "hermes:s-done" })
        XCTAssertEqual(done.startedAt, ProtocolJSON.timestamp(now.addingTimeInterval(-7200)))
        XCTAssertEqual(done.updatedAt, ProtocolJSON.timestamp(now.addingTimeInterval(-1800)))
        let untitled = try XCTUnwrap(snapshot.tasks.first { $0.id == "hermes:s-untitled" })
        XCTAssertEqual(untitled.updatedAt, ProtocolJSON.timestamp(now.addingTimeInterval(-3600)),
                       "没有 last_activity_at 时退回 ended_at")

        XCTAssertEqual(snapshot.projects.map(\.path),
                       ["/Users/me/Projects/shop", "/Users/me/Projects/lab", "/Users/me/Projects/lab/",
                        "/Users/me/Projects/empty", "/Users/me/Projects/old"])
        XCTAssertEqual(snapshot.projects.first?.lastUsedAt, ProtocolJSON.timestamp(now.addingTimeInterval(-20)))
        XCTAssertTrue(snapshot.projects.allSatisfy { $0.agentId == "agent-mac-1" })
    }

    func testMissingDatabaseIsUnavailableNotEmpty() {
        XCTAssertThrowsError(try reader().readSnapshot(agentId: "a")) { error in
            let unavailable = error as? SessionSourceUnavailable
            XCTAssertNotNil(unavailable, "库不在必须抛 unavailable，空列表会让对账把任务全摘掉")
            XCTAssertTrue(unavailable?.message.hasPrefix("未找到 Hermes 数据库：") == true)
        }
        XCTAssertThrowsError(try HermesStateSource(paths: HermesPaths(hermesHome: home)).readSnapshot(agentId: "a")) {
            XCTAssertTrue($0 is SessionSourceUnavailable)
        }
    }

    func testMissingSessionsTableIsSchemaError() throws {
        try SQLiteDatabase(path: databasePath, readOnly: false).execute("CREATE TABLE other (x INTEGER)")
        XCTAssertThrowsError(try reader().readSnapshot(agentId: "a")) { XCTAssertTrue($0 is HermesSchemaError) }
    }

    /// 老库：没有 archived / hidden / last_activity_at / end_reason，messages 也没有 active / finish_reason / tool_calls。
    func testOlderSchemaStillReads() throws {
        let db = try SQLiteDatabase(path: databasePath, readOnly: false)
        try db.execute("""
            CREATE TABLE sessions (id TEXT PRIMARY KEY, source TEXT, cwd TEXT, title TEXT, started_at REAL, ended_at REAL);
            CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, role TEXT, content TEXT, timestamp REAL);
            INSERT INTO sessions VALUES
              ('old-open', 'cli', '/tmp/proj', NULL, \(t(30)), NULL),
              ('old-done', 'cli', '/tmp/proj', '旧标题', \(t(5000)), \(t(4000))),
              ('old-chat', 'telegram', NULL, '私聊', \(t(10)), NULL);
            INSERT INTO messages (session_id, role, content, timestamp) VALUES
              ('old-open', 'user', '老库的问题', \(t(30))),
              ('old-open', 'assistant', '老库的回答', \(t(20)));
            """)
        let tasks = try reader().readSnapshot(agentId: "a").tasks
        XCTAssertEqual(tasks.map(\.id), ["hermes:old-open", "hermes:old-done"])
        XCTAssertEqual(tasks[0].title, "老库的问题")
        XCTAssertEqual(tasks[0].lastMessage, "老库的回答")
        XCTAssertEqual(tasks[0].status, .running, "没有 finish_reason 列：退回纯时间判断")
        XCTAssertEqual(tasks[1].status, .completed)
        XCTAssertEqual(tasks[1].title, "旧标题")
    }

    func testSchemaWithoutCwdReportsNothing() throws {
        try SQLiteDatabase(path: databasePath, readOnly: false).execute("""
            CREATE TABLE sessions (id TEXT PRIMARY KEY, title TEXT, started_at REAL);
            INSERT INTO sessions VALUES ('x', 't', \(t(10)));
            """)
        XCTAssertEqual(try reader().readSnapshot(agentId: "a").tasks, [])
    }

    func testCwdLookup() throws {
        try makeFixture()
        XCTAssertEqual(reader().cwd(forSession: "s-done"), "/Users/me/Projects/lab")
        XCTAssertNil(reader().cwd(forSession: "s-telegram"), "没有 cwd 的会话")
        XCTAssertNil(reader().cwd(forSession: "nope"))
        XCTAssertNil(HermesStateReader(databasePath: "/nonexistent/state.db").cwd(forSession: "s-done"))
    }

    func testObserverReconcilesHermesSource() async throws {
        try makeFixture()
        let store = TaskStore(identity: AgentIdentity(agentId: "agent-1"),
                              connectors: ConnectorRegistry(descriptors: [
                                  ConnectorDescriptor(kind: .hermes, displayName: "Hermes", defaultEnabled: true) {
                                      ConnectorProbe(available: true, status: .ok)
                                  },
                              ]))
        let paths = HermesPaths(hermesHome: home)
        let now = self.now
        let observer = SessionObserver(source: .hermes, store: store,
                                       provider: { HermesStateSource(paths: paths, now: { now }) })
        await observer.pollOnce()
        let record = await store.task(id: "hermes:s-done")
        XCTAssertEqual(record?.agentId, "agent-1")
        XCTAssertEqual(record?.status, .completed)
    }
}
