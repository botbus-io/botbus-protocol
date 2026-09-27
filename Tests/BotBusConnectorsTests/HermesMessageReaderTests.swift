import XCTest
@testable import BotBusConnectorKit
@testable import BotBusConnectors
import BotBusProtocol

/// `state.db` 的 `messages` → 对话记录：一问一答、工具调用摘要、跳过工具结果与思考、翻页与 hasMore。
final class HermesMessageReaderTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("botbus-hermes-msg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { [home] in try? FileManager.default.removeItem(at: home!) }
    }

    private func database() throws -> SQLiteDatabase {
        try SQLiteDatabase(path: home.appendingPathComponent("state.db").path, readOnly: false)
    }

    private func reader() -> HermesMessageReader {
        let paths = HermesPaths(hermesHome: home)
        return HermesMessageReader(paths: { paths })
    }

    private func makeFixture() throws {
        let db = try database()
        try db.execute(HermesStateReaderTests.currentSchema)
        try db.execute("""
            INSERT INTO messages (id, session_id, role, content, tool_calls, timestamp, finish_reason, active, reasoning) VALUES
              (1, 's1', 'user', '帮我跑一下测试', NULL, 1789700000, NULL, 1, NULL),
              (2, 's1', 'assistant', '好的，我先跑测试。', '[{"id":"c1","type":"function","function":{"name":"terminal","arguments":"{\\"command\\":\\"swift test\\"}"}}]', 1789700001, 'tool_calls', 1, '内部思考'),
              (3, 's1', 'tool', 'Test Suite passed', NULL, 1789700002, NULL, 1, NULL),
              (4, 's1', 'assistant', NULL, '[{"function":{"name":"read_file","arguments":"{\\"path\\":\\"Sources/App.swift\\"}"}},{"function":{"name":"web_search","arguments":"{\\"q\\":\\"x\\",\\"n\\":3}"}}]', 1789700003, 'tool_calls', 1, '更多思考'),
              (5, 's1', 'assistant', '被回退的回答', NULL, 1789700004, 'stop', 0, NULL),
              (6, 's1', 'assistant', char(0) || 'json:[{"type":"text","text":"全部通过"}]', NULL, 1789700005, 'stop', 1, NULL),
              (7, 's1', 'system', '系统提示', NULL, 1789700006, NULL, 1, NULL),
              (8, 's2', 'user', '别的会话', NULL, 1789700007, NULL, 1, NULL),
              (9, 's1', 'assistant', '坏掉的工具调用', 'not json', 1789700008, 'stop', 1, NULL);
            """)
    }

    func testMapsUserAgentAndToolCalls() async throws {
        try makeFixture()
        let (messages, hasMore) = try await reader().messages(taskId: "hermes:s1", limit: 40)
        XCTAssertFalse(hasMore)
        XCTAssertEqual(messages.map(\.id), ["1", "2", "2#1", "4#1", "4#2", "6", "9"])
        XCTAssertEqual(messages.map(\.role), [.user, .agent, .tool, .tool, .tool, .agent, .agent])
        XCTAssertEqual(messages.map(\.text), [
            "帮我跑一下测试", "好的，我先跑测试。", "terminal: swift test", "read_file(Sources/App.swift)",
            #"web_search({"n":3,"q":"x"})"#, "全部通过", "坏掉的工具调用",
        ])
        XCTAssertEqual(messages[0].createdAt, ProtocolJSON.timestamp(Date(timeIntervalSince1970: 1_789_700_000)))
        XCTAssertFalse(messages.contains { $0.text.contains("思考") }, "reasoning 列不读")
        XCTAssertFalse(messages.contains { $0.text.contains("Test Suite") }, "role='tool' 的结果跳过")
        XCTAssertFalse(messages.contains { $0.text.contains("被回退") }, "只收 active=1")
        XCTAssertFalse(messages.contains { $0.text.contains("系统提示") || $0.text.contains("别的会话") })
    }

    func testLimitKeepsNewestAndReportsHasMore() async throws {
        try makeFixture()
        let (messages, hasMore) = try await reader().messages(taskId: "hermes:s1", limit: 3)
        XCTAssertTrue(hasMore)
        XCTAssertEqual(messages.map(\.id), ["2", "2#1", "4#1", "4#2", "6", "9"],
                       "limit 只数对话（2、6、9），夹在中间的工具行一并带上；截的是最旧的，结果仍按时间升序")
    }

    /// 新的 105 行全是空白正文（展开出 0 条），得翻到第二页才凑得够。
    func testPagesThroughRowsThatExpandToNothing() async throws {
        let db = try database()
        try db.execute(HermesStateReaderTests.currentSchema)
        try db.execute("""
            WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 150)
            INSERT INTO messages (id, session_id, role, content, timestamp, active)
            SELECT i, 'big', 'assistant', CASE WHEN i <= 45 THEN '第 ' || i || ' 条' ELSE '   ' END, 1789700000 + i, 1 FROM n;
            """)
        let (messages, hasMore) = try await reader().messages(taskId: "hermes:big", limit: 500)
        XCTAssertEqual(messages.count, TaskMessages.maxMessages, "limit 最多 40")
        XCTAssertTrue(hasMore)
        XCTAssertEqual(messages.first?.id, "6")
        XCTAssertEqual(messages.last?.id, "45")

        let (few, more) = try await reader().messages(taskId: "hermes:big", limit: 45)
        XCTAssertEqual(few.count, 40)
        XCTAssertTrue(more)
    }

    func testOlderSchemaWithoutOptionalColumns() async throws {
        try database().execute("""
            CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, role TEXT, content TEXT);
            INSERT INTO messages (session_id, role, content) VALUES ('s', 'user', '问'), ('s', 'assistant', '答');
            """)
        let (messages, hasMore) = try await reader().messages(taskId: "hermes:s", limit: 10)
        XCTAssertFalse(hasMore)
        XCTAssertEqual(messages.map(\.text), ["问", "答"])
        XCTAssertEqual(messages[0].createdAt, ProtocolJSON.timestamp(Date(timeIntervalSince1970: 0)))
    }

    func testErrors() async throws {
        do {
            _ = try await reader().messages(taskId: "hermes:s1", limit: 10)
            XCTFail("库不在必须报错")
        } catch {}
        try makeFixture()
        do {
            _ = try await reader().messages(taskId: "codex:s1", limit: 10)
            XCTFail("别的来源的 id 不收")
        } catch {}
    }

    /// `\0json:` 内容块里的 `image_url`（data URL）收成图片；只有图也是一条，文字为空。
    func testUserImagesFromJSONContent() async throws {
        let db = try database()
        try db.execute(HermesStateReaderTests.currentSchema)
        let url = TestImage.pngDataURL
        try db.execute("""
            INSERT INTO messages (id, session_id, role, content, timestamp, active) VALUES
              (1, 'img', 'user', char(0) || 'json:[{"type":"text","text":"看"},{"type":"image_url","image_url":{"url":"\(url)"}}]', 1789700000, 1),
              (2, 'img', 'user', char(0) || 'json:[{"type":"image_url","image_url":"\(url)"}]', 1789700001, 1),
              (3, 'img', 'assistant', char(0) || 'json:[{"type":"text","text":"收到"},{"type":"image_url","image_url":{"url":"\(url)"}}]', 1789700002, 1),
              (4, 'img', 'user', char(0) || 'json:[{"type":"image_url","image_url":{"url":"https://example.com/a.png"}}]', 1789700003, 1),
              (5, 'img', 'user', '纯文字', 1789700004, 1);
            """)
        let (entries, hasMore) = try await reader().entries(taskId: "hermes:img", limit: 10)
        XCTAssertFalse(hasMore)
        XCTAssertEqual(entries.map(\.message.id), ["1", "2", "3", "5"], "远程图片拿不到字节，又没字，整条不出")
        XCTAssertEqual(entries.map(\.message.text), ["看", "", "收到", "纯文字"])
        XCTAssertEqual(entries[0].images, [.data(TestImage.png, contentType: "image/png")])
        XCTAssertEqual(entries[1].images, [.data(TestImage.png, contentType: "image/png")], "image_url 直接是字符串也认")
        XCTAssertEqual(entries[2].images, [], "只取 user 的图")
        XCTAssertEqual(entries[3].images, [])
        XCTAssertTrue(entries.allSatisfy { $0.pathCandidates.isEmpty })
    }

    func testToolCallSummaries() {
        let calls = HermesToolCalls.parse("""
            [{"function":{"name":"terminal","arguments":{"command":"  npm run build  "}}},
             {"function":{"name":"patch","arguments":"{}"}},
             {"function":{"name":"todo","arguments":"not json"}},
             {"function":{"name":""}},
             {"name":"flat","arguments":{"url":"https://example.com"}}]
            """)
        XCTAssertEqual(calls.map { $0.summary(argumentLimit: 80) },
                       ["terminal: npm run build", "patch()", "todo(not json)", "flat(https://example.com)"])
        let long = HermesToolCalls.Call(name: "write_file", arguments: ["path": String(repeating: "a", count: 100)])
        XCTAssertEqual(long.summary(argumentLimit: 10), "write_file(aaaaaaaaaa…)")
        XCTAssertEqual(HermesToolCalls.parse("{}").count, 0)
    }

    /// 只有 assistant 的正文带路径候选；用户消息与工具调用摘要不带。
    func testAssistantContentCarriesPathCandidates() async throws {
        let db = try database()
        try db.execute(HermesStateReaderTests.currentSchema)
        try db.execute("""
            INSERT INTO messages (id, session_id, role, content, tool_calls, timestamp, active) VALUES
              (1, 'p', 'user', '看 `in/u.png`', NULL, 1789700000, 1),
              (2, 'p', 'assistant', '图已保存到 `out/a.png`', '[{"function":{"name":"read_file","arguments":"{\\"path\\":\\"out/b.png\\"}"}}]', 1789700001, 1);
            """)
        let (entries, _) = try await reader().entries(taskId: "hermes:p", limit: 10)
        XCTAssertEqual(entries.map(\.message.id), ["1", "2", "2#1"])
        XCTAssertEqual(entries.map(\.pathCandidates), [[], ["out/a.png"], []])
    }
}
