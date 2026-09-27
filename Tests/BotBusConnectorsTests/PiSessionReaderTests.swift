import XCTest
@testable import BotBusConnectorKit
@testable import BotBusConnectors
import BotBusProtocol

/// 在临时目录里搭一个假的 `~/.pi/agent`：会话文件、修改时间都由测试决定。内容全是编的。
final class PiFixture {
    let agentDirectory: URL
    var paths: PiPaths { PiPaths(agentDirectory: agentDirectory) }
    var sessionsDirectory: URL { paths.sessionsDirectory }

    init() throws {
        agentDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: agentDirectory.appendingPathComponent("sessions"),
                                                withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: agentDirectory) }

    static func header(id: String, cwd: String, timestamp: String = "2026-09-20T01:00:00.000Z") -> [String: Any] {
        ["type": "session", "version": 3, "id": id, "timestamp": timestamp, "cwd": cwd]
    }

    static func user(_ id: String, parent: String?, _ text: Any, at timestamp: String = "2026-09-20T01:00:01.000Z") -> [String: Any] {
        entry(id, parent: parent, timestamp: timestamp, message: ["role": "user", "content": text])
    }

    static func assistant(_ id: String, parent: String?, text: String? = nil, stop: String = "stop",
                          content: [[String: Any]]? = nil, at timestamp: String = "2026-09-20T01:00:02.000Z",
                          extra: [String: Any] = [:]) -> [String: Any] {
        var blocks = content ?? []
        if let text { blocks.insert(["type": "text", "text": text], at: 0) }
        var message: [String: Any] = ["role": "assistant", "content": blocks, "stopReason": stop]
        message.merge(extra) { _, new in new }
        return entry(id, parent: parent, timestamp: timestamp, message: message)
    }

    static func toolResult(_ id: String, parent: String?, at timestamp: String = "2026-09-20T01:00:03.000Z") -> [String: Any] {
        entry(id, parent: parent, timestamp: timestamp,
              message: ["role": "toolResult", "toolCallId": "call-1", "toolName": "bash",
                        "content": [["type": "text", "text": "很长的输出"]], "isError": false])
    }

    static func entry(_ id: String, parent: String?, timestamp: String, message: [String: Any]) -> [String: Any] {
        var object: [String: Any] = ["type": "message", "id": id, "timestamp": timestamp, "message": message]
        if let parent { object["parentId"] = parent }
        return object
    }

    static func line(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    /// 写一份会话：`sessions/<dir>/2026-09-20T01-00-00-000Z_<id>.jsonl`。`raw` 里的字符串原样成行（造坏行用）。
    @discardableResult
    func write(id: String, directory: String = "--Users-me-demo--", lines: [Any],
               modifiedAt: Date) throws -> URL {
        let folder = sessionsDirectory.appendingPathComponent(directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("2026-09-20T01-00-00-000Z_\(id).jsonl")
        let text = lines.map { item -> String in
            if let raw = item as? String { return raw }
            return Self.line(item as! [String: Any])
        }.joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: url)
        try touch(url, modifiedAt)
        return url
    }

    func touch(_ url: URL, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
}

final class PiSessionReaderTests: XCTestCase {
    /// 2026-09-24T00:00:00Z 附近的一个固定"现在"。
    private let now = Date(timeIntervalSince1970: 1_790_208_000)
    private var fixture: PiFixture!

    override func setUpWithError() throws { fixture = try PiFixture() }
    override func tearDown() { fixture.remove() }

    private func iso(_ secondsAgo: TimeInterval) -> String {
        ProtocolJSON.timestamp(now.addingTimeInterval(-secondsAgo))
    }

    private func reader() -> PiSessionReader {
        let now = self.now
        return PiSessionReader(paths: fixture.paths, now: { now })
    }

    private func onlyTask(file: StaticString = #filePath, line: UInt = #line) throws -> TaskRecord {
        let tasks = try reader().readTasks(agentId: "agent-1")
        XCTAssertEqual(tasks.count, 1, file: file, line: line)
        return try XCTUnwrap(tasks.first, file: file, line: line)
    }

    // MARK: - 基本映射

    func testHeaderGivesCwdAndCompletedTask() throws {
        try fixture.write(id: "0199aaaa-1111", lines: [
            PiFixture.header(id: "0199aaaa-1111", cwd: "/Users/me/Projects/demo", timestamp: iso(3600)),
            PiFixture.user("a1", parent: nil, "把首页的按钮换个颜色", at: iso(3000)),
            PiFixture.assistant("a2", parent: "a1", text: "改好了，换成了琥珀色。", at: iso(2900)),
        ], modifiedAt: now.addingTimeInterval(-2900))

        let task = try onlyTask()
        XCTAssertEqual(task.id, "pi:0199aaaa-1111")
        XCTAssertEqual(task.agentId, "agent-1")
        XCTAssertEqual(task.source, .pi)
        XCTAssertEqual(task.projectPath, "/Users/me/Projects/demo", "cwd 以 header 为准，不从目录名反解")
        XCTAssertEqual(task.projectName, "demo")
        XCTAssertEqual(task.status, .completed)
        XCTAssertEqual(task.title, "把首页的按钮换个颜色")
        XCTAssertEqual(task.lastMessage, "改好了，换成了琥珀色。")
        XCTAssertEqual(task.origin, .desktop)
        XCTAssertTrue(task.controllable)
        XCTAssertEqual(task.startedAt, iso(3600))
        XCTAssertEqual(task.updatedAt, iso(2900))
    }

    /// `/tree` 回到 a1 之后再说话：u2/a2 那一支被丢下，现状只看 a1 → u3 → a3。
    func testCurrentBranchIgnoresAbandonedFork() throws {
        try fixture.write(id: "s-fork", lines: [
            PiFixture.header(id: "s-fork", cwd: "/p/fork"),
            PiFixture.user("u1", parent: nil, "第一个问题", at: iso(600)),
            PiFixture.assistant("a1", parent: "u1", text: "第一个回答", at: iso(590)),
            PiFixture.user("u2", parent: "a1", "被放弃的问题", at: iso(580)),
            PiFixture.assistant("a2", parent: "u2", text: "被放弃的回答", stop: "error", at: iso(570)),
            PiFixture.user("u3", parent: "a1", "换个方向", at: iso(560)),
            PiFixture.assistant("a3", parent: "u3", text: "第二个回答", at: iso(550)),
        ], modifiedAt: now.addingTimeInterval(-550))

        let task = try onlyTask()
        XCTAssertEqual(task.status, .completed, "被放弃分支上的 error 不算")
        XCTAssertEqual(task.lastMessage, "第二个回答")
        XCTAssertEqual(task.title, "第一个问题")
    }

    func testBranchWalkStopsAtMissingParent() throws {
        let data = Data([
            PiFixture.line(PiFixture.header(id: "s", cwd: "/p")),
            PiFixture.line(PiFixture.user("u1", parent: nil, "别的分支")),
            PiFixture.line(PiFixture.user("u2", parent: "gone", "断链之后")),
            PiFixture.line(PiFixture.assistant("a2", parent: "u2", text: "好")),
        ].joined(separator: "\n").utf8)
        let file = try XCTUnwrap(PiSessionFile.parse(data))
        XCTAssertEqual(file.branch.compactMap(\.id), ["u2", "a2"])
    }

    // MARK: - 状态推断

    private func status(lines: [[String: Any]], modifiedSecondsAgo: TimeInterval,
                        file: StaticString = #filePath, line: UInt = #line) throws -> TaskRecord {
        fixture.remove()
        fixture = try PiFixture()
        try fixture.write(id: "s", lines: [PiFixture.header(id: "s", cwd: "/p/demo")] + lines,
                          modifiedAt: now.addingTimeInterval(-modifiedSecondsAgo))
        return try onlyTask(file: file, line: line)
    }

    func testStopReasonMapping() throws {
        let cases: [(String, TaskStatus)] = [("stop", .completed), ("length", .completed),
                                             ("error", .failed), ("aborted", .interrupted)]
        for (reason, expected) in cases {
            let task = try status(lines: [
                PiFixture.user("u", parent: nil, "问", at: iso(40)),
                PiFixture.assistant("a", parent: "u", text: "答", stop: reason, at: iso(30)),
            ], modifiedSecondsAgo: 30)
            XCTAssertEqual(task.status, expected, reason)
            XCTAssertTrue(task.controllable, reason)
        }
    }

    /// 停在"还在等模型"的位置：文件 2 分钟内被写过 → running（桌面会话，不可控）；更久 → interrupted。
    func testOpenTailUsesModificationTime() throws {
        let openTails: [[[String: Any]]] = [
            [PiFixture.user("u", parent: nil, "问", at: iso(30))],
            [PiFixture.user("u", parent: nil, "问", at: iso(40)),
             PiFixture.assistant("a", parent: "u", text: "我先看看", stop: "toolUse", at: iso(35)),
             PiFixture.toolResult("r", parent: "a", at: iso(30))],
            [PiFixture.user("u", parent: nil, "问", at: iso(40)),
             PiFixture.assistant("a", parent: "u", stop: "toolUse",
                                 content: [["type": "toolCall", "id": "c", "name": "bash", "arguments": ["command": "ls"]]],
                                 at: iso(30))],
        ]
        for lines in openTails {
            let running = try status(lines: lines, modifiedSecondsAgo: 30)
            XCTAssertEqual(running.status, .running)
            XCTAssertFalse(running.controllable, "桌面上正在跑的会话我们没有它的进程")

            let stale = try status(lines: lines, modifiedSecondsAgo: 300)
            XCTAssertEqual(stale.status, .interrupted, "超过 2 分钟没动静，进程多半已经没了")
            XCTAssertTrue(stale.controllable)
        }
    }

    func testIdleAfterADayWithoutActivity() throws {
        let task = try status(lines: [
            PiFixture.user("u", parent: nil, "问", at: iso(2 * 86400 + 10)),
            PiFixture.assistant("a", parent: "u", text: "答", stop: "error", at: iso(2 * 86400)),
        ], modifiedSecondsAgo: 2 * 86400)
        XCTAssertEqual(task.status, .idle, "24 小时无活动一律 idle，旧的 failed 自然淡出")
    }

    func testHeaderOnlySessionIsIdle() throws {
        let task = try status(lines: [], modifiedSecondsAgo: 10)
        XCTAssertEqual(task.status, .idle)
        XCTAssertEqual(task.title, "demo", "一条消息都没有时用项目名")
        XCTAssertNil(task.lastMessage)
    }

    /// 用户在 pi 里敲的 `!命令` 不代表 agent 在跑，状态看它前面那条。
    func testBashExecutionDoesNotCountAsOpenTail() throws {
        let task = try status(lines: [
            PiFixture.user("u", parent: nil, "问", at: iso(40)),
            PiFixture.assistant("a", parent: "u", text: "答", at: iso(35)),
            PiFixture.entry("b", parent: "a", timestamp: iso(30),
                            message: ["role": "bashExecution", "command": "git status", "output": "clean"]),
        ], modifiedSecondsAgo: 30)
        XCTAssertEqual(task.status, .completed)
    }

    // MARK: - 标题

    func testSessionNameWinsOverFirstPrompt() throws {
        try fixture.write(id: "s", lines: [
            PiFixture.header(id: "s", cwd: "/p/demo"),
            PiFixture.user("u", parent: nil, "第一句话", at: iso(40)),
            ["type": "session_info", "id": "n1", "parentId": "u", "timestamp": iso(35), "name": "旧名字"],
            PiFixture.assistant("a", parent: "n1", text: "答", at: iso(30)),
            ["type": "session_info", "id": "n2", "parentId": "a", "timestamp": iso(20), "name": "  新\n名字  "],
        ], modifiedAt: now.addingTimeInterval(-20))
        XCTAssertEqual(try onlyTask().title, "新 名字", "最后一次命名为准，压成单行")
    }

    func testFirstUserTextIsSingleLineAndTruncated() throws {
        let long = String(repeating: "长", count: 120)
        try fixture.write(id: "s", lines: [
            PiFixture.header(id: "s", cwd: "/p/demo"),
            // 块数组形式的 user content：图片块不算文本。
            PiFixture.user("u", parent: nil, [["type": "image", "data": "xx"], ["type": "text", "text": "第一行\n\(long)"]],
                           at: iso(40)),
        ], modifiedAt: now.addingTimeInterval(-600))
        let title = try onlyTask().title
        XCTAssertEqual(title.count, 80)
        XCTAssertTrue(title.hasPrefix("第一行 长"))
    }

    // MARK: - 容错

    func testMalformedLinesAndUnknownEntriesAreSkipped() throws {
        try fixture.write(id: "s", lines: [
            PiFixture.header(id: "s", cwd: "/p/demo"),
            "{这不是 JSON",
            "[1,2,3]",
            ["type": "model_change", "id": "m", "timestamp": iso(50), "provider": "x", "modelId": "y"],
            ["type": "something_new", "id": "z", "parentId": "m", "timestamp": iso(45), "payload": ["a": 1]],
            ["type": "message", "id": "bad", "parentId": "z", "timestamp": iso(44), "message": ["content": "没有 role"]],
            PiFixture.user("u", parent: "bad", "正常的问题", at: iso(40)),
            PiFixture.assistant("a", parent: "u", text: "正常的回答", at: iso(30)),
        ], modifiedAt: now.addingTimeInterval(-30))
        let task = try onlyTask()
        XCTAssertEqual(task.status, .completed)
        XCTAssertEqual(task.title, "正常的问题")
        XCTAssertEqual(task.lastMessage, "正常的回答")
    }

    func testFileWithoutHeaderIsSkipped() throws {
        try fixture.write(id: "no-header", lines: [PiFixture.user("u", parent: nil, "问")],
                          modifiedAt: now.addingTimeInterval(-10))
        try fixture.write(id: "empty", lines: [], modifiedAt: now.addingTimeInterval(-10))
        XCTAssertEqual(try reader().readTasks(agentId: "a"), [])
    }

    func testMissingSessionsDirectoryIsUnavailable() throws {
        let missing = PiSessionReader(paths: PiPaths(agentDirectory: URL(fileURLWithPath: "/nonexistent/pi-agent")))
        XCTAssertThrowsError(try missing.readTasks(agentId: "a")) { error in
            let unavailable = error as? SessionSourceUnavailable
            XCTAssertNotNil(unavailable, "读不到必须抛 SessionSourceUnavailable，不能返回空列表")
            XCTAssertTrue(unavailable?.message.hasPrefix("未找到 Pi 会话目录：") ?? false)
        }
    }

    // MARK: - 窗口、排序与时间

    func testSevenDayWindowAndNewestFirst() throws {
        try fixture.write(id: "old", directory: "--p-a--",
                          lines: [PiFixture.header(id: "old", cwd: "/p/a")], modifiedAt: now.addingTimeInterval(-8 * 86400))
        try fixture.write(id: "mid", directory: "--p-a--",
                          lines: [PiFixture.header(id: "mid", cwd: "/p/a")], modifiedAt: now.addingTimeInterval(-3 * 86400))
        try fixture.write(id: "new", directory: "--p-b--",
                          lines: [PiFixture.header(id: "new", cwd: "/p/b")], modifiedAt: now.addingTimeInterval(-60))
        let ids = try reader().readTasks(agentId: "a").map(\.id)
        XCTAssertEqual(ids, ["pi:new", "pi:mid"], "8 天前的不进快照，新的在前")
    }

    /// entry 的 ISO 时间可能缺，消息里的毫秒数兜底；输出一律是秒精度 UTC。
    func testEpochMillisecondTimestamps() throws {
        let ms = (now.timeIntervalSince1970 - 100) * 1000 + 456
        try fixture.write(id: "s", lines: [
            ["type": "session", "id": "s", "cwd": "/p/demo"],
            ["type": "message", "id": "u", "message": ["role": "user", "content": "问", "timestamp": ms - 5000]],
            ["type": "message", "id": "a", "parentId": "u",
             "message": ["role": "assistant", "content": [["type": "text", "text": "答"]], "stopReason": "stop", "timestamp": ms]],
        ], modifiedAt: now.addingTimeInterval(-10))
        let task = try onlyTask()
        XCTAssertEqual(task.updatedAt, iso(100))
        XCTAssertFalse(task.updatedAt.contains("."), "协议时间是秒精度")
    }

    func testSessionFileLookupBySuffix() throws {
        let url = try fixture.write(id: "0199-target", directory: "--p-x--",
                                    lines: [PiFixture.header(id: "0199-target", cwd: "/p/x")], modifiedAt: now)
        try fixture.write(id: "0199-other", directory: "--p-y--",
                          lines: [PiFixture.header(id: "0199-other", cwd: "/p/y")], modifiedAt: now)
        XCTAssertEqual(reader().sessionFile(for: "0199-target")?.standardizedFileURL, url.standardizedFileURL)
        XCTAssertNil(reader().sessionFile(for: "target"), "只认 `_<id>.jsonl` 整段后缀")
        XCTAssertNil(reader().sessionFile(for: "../x"))
        XCTAssertEqual(PiSessionFile.header(atPath: url.path)?.cwd, "/p/x")
    }

    // MARK: - 观察者数据源

    func testSessionSourceBuildsProjectsAndPicksUpChanges() throws {
        let url = try fixture.write(id: "s1", directory: "--p-a--", lines: [
            PiFixture.header(id: "s1", cwd: "/p/a"),
            PiFixture.user("u", parent: nil, "问", at: iso(300)),
        ], modifiedAt: now.addingTimeInterval(-300))
        try fixture.write(id: "s2", directory: "--p-b--", lines: [
            PiFixture.header(id: "s2", cwd: "/p/b"),
            PiFixture.user("u", parent: nil, "问", at: iso(100)),
            PiFixture.assistant("a", parent: "u", text: "答", at: iso(90)),
        ], modifiedAt: now.addingTimeInterval(-90))

        let now = self.now
        let source = PiSessionSource(paths: fixture.paths, now: { now })
        var snapshot = try source.readSnapshot(agentId: "agent-1")
        XCTAssertEqual(snapshot.tasks.map(\.id), ["pi:s2", "pi:s1"])
        XCTAssertEqual(snapshot.projects.map(\.path), ["/p/b", "/p/a"])
        XCTAssertEqual(snapshot.projects.first?.agentId, "agent-1")
        XCTAssertEqual(snapshot.tasks.last?.status, .interrupted)

        // 文件被续写（内容、大小、修改时间都变了）：缓存必须失效。
        try Data([
            PiFixture.line(PiFixture.header(id: "s1", cwd: "/p/a")),
            PiFixture.line(PiFixture.user("u", parent: nil, "问", at: iso(300))),
            PiFixture.line(PiFixture.assistant("a", parent: "u", text: "终于答了", at: iso(5))),
        ].joined(separator: "\n").utf8).write(to: url)
        try fixture.touch(url, now.addingTimeInterval(-5))
        snapshot = try source.readSnapshot(agentId: "agent-1")
        XCTAssertEqual(snapshot.tasks.first?.id, "pi:s1")
        XCTAssertEqual(snapshot.tasks.first?.status, .completed)
        XCTAssertEqual(snapshot.tasks.first?.lastMessage, "终于答了")
    }

    func testSessionObserverReconcilesPiSource() async throws {
        try fixture.write(id: "s1", lines: [
            PiFixture.header(id: "s1", cwd: "/p/a"),
            PiFixture.user("u", parent: nil, "问", at: iso(100)),
            PiFixture.assistant("a", parent: "u", text: "答", at: iso(90)),
        ], modifiedAt: now.addingTimeInterval(-90))
        let store = TaskStore(identity: AgentIdentity(agentId: "agent-1"),
                              connectors: ConnectorRegistry(descriptors: [
                                  ConnectorDescriptor(kind: .pi, displayName: "Pi", defaultEnabled: true) {
                                      ConnectorProbe(available: true, status: .ok)
                                  },
                              ]))
        let now = self.now
        let paths = fixture.paths
        let source = PiSessionSource(paths: paths, now: { now })
        let observer = SessionObserver(source: .pi, store: store, provider: { source })
        await observer.pollOnce()
        let task = await store.task(id: "pi:s1")
        XCTAssertEqual(task?.status, .completed)
        XCTAssertEqual(task?.agentId, "agent-1")
    }
}
