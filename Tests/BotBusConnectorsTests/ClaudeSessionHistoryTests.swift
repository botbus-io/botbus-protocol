import XCTest
@testable import BotBusConnectorKit
@testable import BotBusConnectors
import BotBusProtocol

/// 启动补历史：transcript → 会话摘要，以及连接器如何把它们并进 hook 的会话。
/// 用的是按真实 transcript 形状手写的 JSONL，不读本机 `~/.claude`。
final class ClaudeSessionHistoryTests: XCTestCase {
    private var claudeHome: URL!
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUpWithError() throws {
        claudeHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: projectsDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: claudeHome)
    }

    private var projectsDirectory: URL { claudeHome.appendingPathComponent("projects", isDirectory: true) }

    // MARK: - 夹具

    private func json(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private func user(_ content: Any, cwd: String = "/Users/me/Projects/alpha", entrypoint: String = "claude-desktop",
                      extra: [String: Any] = [:]) -> String {
        json(["type": "user", "message": ["role": "user", "content": content],
              "timestamp": "2026-09-20T08:00:00.123Z", "entrypoint": entrypoint, "cwd": cwd,
              "isSidechain": false].merging(extra) { _, new in new })
    }

    private func assistant(_ text: String, cwd: String = "/Users/me/Projects/alpha",
                           entrypoint: String = "claude-desktop") -> String {
        json(["type": "assistant", "message": ["role": "assistant", "content": [["type": "text", "text": text]]],
              "timestamp": "2026-09-20T08:01:00.000Z", "entrypoint": entrypoint, "cwd": cwd])
    }

    @discardableResult
    private func write(_ lines: [String], session: String, directory: String = "-Users-me-Projects-alpha",
                       modifiedAt: Date? = nil) throws -> URL {
        let folder = projectsDirectory.appendingPathComponent(directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(session).jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt ?? now.addingTimeInterval(-60)],
                                              ofItemAtPath: url.path)
        return url
    }

    private func recent(limit: Int = 200) -> [ClaudeSessionHistory.Entry] {
        ClaudeSessionHistory.recentSessions(in: projectsDirectory, now: now, limit: limit)
    }

    // MARK: - 单个 transcript

    func testDesktopSessionPrefersCustomTitle() throws {
        try write([
            json(["type": "queue-operation", "operation": "enqueue", "sessionId": "s1"]),
            user("把导航那一层去掉"),
            assistant("好的，先看看结构"),
            json(["type": "custom-title", "customTitle": "去掉导航层", "sessionId": "s1"]),
            assistant("改完了"),
        ], session: "s1")

        let entry = try XCTUnwrap(recent().first)
        XCTAssertEqual(entry.sessionID, "s1", "session id 就是文件名")
        XCTAssertEqual(entry.projectPath, "/Users/me/Projects/alpha")
        XCTAssertEqual(entry.title, "去掉导航层", "桌面端给会话起的标题优先，和侧栏一致")
        XCTAssertEqual(entry.lastMessage, "改完了")
        XCTAssertEqual(entry.startedAt, ClaudeSessionHistory.date("2026-09-20T08:00:00.123Z"))
        XCTAssertEqual(entry.updatedAt, now.addingTimeInterval(-60), "最近活动取文件修改时间")
    }

    func testCommandLineSessionUsesAITitle() throws {
        try write([
            user("把当前网站在本地运行一下", entrypoint: "cli"),
            json(["type": "ai-title", "aiTitle": "本地运行网站", "sessionId": "s1"]),
            assistant("跑起来了", entrypoint: "cli"),
        ], session: "s1")

        let entry = try XCTUnwrap(recent().first)
        XCTAssertEqual(entry.title, "本地运行网站")
        XCTAssertEqual(entry.titleSource, .generated)
    }

    func testFirstRealPromptSkipsMetaCommandAndToolResultLines() throws {
        try write([
            user("<command-name>/clear</command-name>"),
            user([["type": "text", "text": "系统注入的提醒"]], extra: ["isMeta": true]),
            user([["type": "tool_result", "tool_use_id": "t1", "content": "文件内容"]]),
            user([["type": "image", "source": ["type": "base64", "data": "AAAA"]],
                  ["type": "text", "text": "  看看这个截图  "]]),
            user("第二条"),
        ], session: "s1")

        XCTAssertEqual(recent().first?.title, "看看这个截图")
    }

    /// 桌面 app 的首条消息以 `<system-reminder>` 开头，正文跟在后面：剥掉注入块取正文，不整条跳过。
    func testFirstPromptStripsLeadingSystemReminders() throws {
        try write([
            user([["type": "text", "text": "<system-reminder>\nworktree\n</system-reminder>\n修一下侧滑返回"]]),
            user("第二条"),
        ], session: "s1")

        XCTAssertEqual(recent().first?.title, "修一下侧滑返回")
    }

    func testAgentSDKSessionsAreSkippedButClaudeDashPIsKept() throws {
        try write([user("Market context JSON", entrypoint: "sdk-py"), assistant("ok", entrypoint: "sdk-py")],
                  session: "script")
        try write([user("手机上起的任务", entrypoint: "sdk-cli"), assistant("好", entrypoint: "sdk-cli")],
                  session: "phone")

        XCTAssertEqual(recent().map(\.sessionID), ["phone"])
    }

    func testSessionWithoutAnyPromptIsSkipped() throws {
        try write([json(["type": "queue-operation", "operation": "enqueue", "sessionId": "s1"]),
                   json(["type": "attachment", "cwd": "/tmp/alpha", "entrypoint": "cli"])], session: "empty")
        XCTAssertTrue(recent().isEmpty)
    }

    /// 首条消息带一张大截图，整行超出头部读取范围：entrypoint / cwd 要从末尾那段补，标题退回 last-prompt。
    func testHugeFirstLineFallsBackToTailForCwdAndTitle() throws {
        let image = String(repeating: "A", count: ClaudeSessionHistory.headBytes * 2)
        var lines = [user([["type": "image", "source": ["type": "base64", "data": image]],
                           ["type": "text", "text": "截图里的按钮歪了"]], cwd: "/Users/me/Projects/beta")]
        lines += (0..<10).map { _ in assistant("处理中", cwd: "/Users/me/Projects/beta") }
        lines.append(json(["type": "last-prompt", "lastPrompt": "再对齐一下", "sessionId": "s1"]))
        try write(lines, session: "s1")

        let entry = try XCTUnwrap(recent().first)
        XCTAssertEqual(entry.projectPath, "/Users/me/Projects/beta")
        XCTAssertEqual(entry.title, "再对齐一下")
        XCTAssertEqual(entry.lastMessage, "处理中")
    }

    func testSDKSessionWithHugeFirstLineIsStillSkipped() throws {
        let prompt = String(repeating: "x", count: ClaudeSessionHistory.headBytes * 2)
        try write([user(prompt, entrypoint: "sdk-ts"), assistant("ok", entrypoint: "sdk-ts")], session: "script")
        XCTAssertTrue(recent().isEmpty)
    }

    func testRawStringValueHandlesEscapes() {
        let data = Data(#"{"cwd":"/tmp/a\"b","x":1} {"cwd":"/tmp/\u4e2d"}"#.utf8)
        XCTAssertEqual(ClaudeSessionHistory.rawStringValue(forKey: "cwd", in: data, last: false), "/tmp/a\"b")
        XCTAssertEqual(ClaudeSessionHistory.rawStringValue(forKey: "cwd", in: data, last: true), "/tmp/中")
        XCTAssertNil(ClaudeSessionHistory.rawStringValue(forKey: "entrypoint", in: data, last: false))
    }

    // MARK: - 枚举

    func testRecentSessionsWindowOrderLimitAndSubagents() throws {
        try write([user("旧的")], session: "old", modifiedAt: now.addingTimeInterval(-8 * 24 * 3600))
        try write([user("较早")], session: "earlier", modifiedAt: now.addingTimeInterval(-3600))
        try write([user("最新")], session: "newest", directory: "-Users-me-Projects-beta",
                  modifiedAt: now.addingTimeInterval(-10))
        // 子代理记录在 `<sessionId>/subagents/` 下，不是会话。
        try write([user("子代理")], session: "agent-1", directory: "-Users-me-Projects-alpha/newest/subagents")

        XCTAssertEqual(recent().map(\.sessionID), ["newest", "earlier"], "7 天外的不要，最新的在前")
        XCTAssertEqual(recent(limit: 1).map(\.sessionID), ["newest"])
    }

    func testMissingProjectsDirectoryIsEmpty() {
        let missing = claudeHome.appendingPathComponent("nope", isDirectory: true)
        XCTAssertTrue(ClaudeSessionHistory.recentSessions(in: missing, now: now, limit: 10).isEmpty)
    }

    // MARK: - 并进连接器

    private func makeStore() -> TaskStore {
        TaskStore(identity: AgentIdentity(agentId: "agent-1"),
                  connectors: ConnectorRegistry(descriptors: [
                      ConnectorDescriptor(kind: .claude, displayName: "Claude Code", defaultEnabled: true) {
                          ConnectorProbe(available: true, status: .ok)
                      },
                  ]))
    }

    private func makeConnector(store: TaskStore) -> ClaudeConnector {
        ClaudeConnector(store: store, paths: ClaudePaths(claudeHome: claudeHome), binary: { nil }, now: { [now] in now })
    }

    /// `XCTUnwrap` 的 autoclosure 不支持 await，所以 await 必须在它外面先落地。
    private func requireTask(_ store: TaskStore, _ sessionID: String,
                             file: StaticString = #filePath, line: UInt = #line) async throws -> TaskRecord {
        let record = await store.task(id: "claude:\(sessionID)")
        return try XCTUnwrap(record, file: file, line: line)
    }

    private func hook(_ connector: ClaudeConnector, _ object: [String: Any]) async {
        _ = await connector.handleHook(LocalHookServer.Request(
            method: "POST", target: "/hooks/claude", path: "/hooks/claude",
            headers: ["content-type": "application/json"],
            body: try! JSONSerialization.data(withJSONObject: object)))
    }

    func testRestoreBuildsTasksAndProjectsWithoutNotifications() async throws {
        try write([user("最近的会话"), assistant("做完了")], session: "recent")
        try write([user("两天前", cwd: "/Users/me/Projects/beta")], session: "stale",
                  directory: "-Users-me-Projects-beta", modifiedAt: now.addingTimeInterval(-2 * 24 * 3600))
        let store = makeStore()
        let stream = await store.events()
        let notifications = Locked<[Notify]>([])
        let collector = Task {
            for await event in stream {
                guard let notify = event.notify else { continue }
                notifications.withLock { $0.append(notify) }
            }
        }
        defer { collector.cancel() }

        await makeConnector(store: store).restoreRecentSessions()

        let recent = try await requireTask(store, "recent")
        XCTAssertEqual(recent.title, "最近的会话")
        XCTAssertEqual(recent.status, .completed)
        XCTAssertEqual(recent.lastMessage, "做完了")
        XCTAssertEqual(recent.origin, .desktop)
        XCTAssertTrue(recent.controllable, "补回来的会话一样可以 --resume 续聊")
        XCTAssertEqual(recent.updatedAt, ProtocolJSON.timestamp(now.addingTimeInterval(-60)))
        let stale = try await requireTask(store, "stale")
        XCTAssertEqual(stale.status, .idle, "超过 24 小时没动静按协议记 idle")
        let owner = await store.owner(of: "claude:recent")
        XCTAssertEqual(owner, .live, "连接器仍是唯一权威")

        let projects = await store.snapshot().projects.map(\.path)
        XCTAssertEqual(projects, ["/Users/me/Projects/alpha", "/Users/me/Projects/beta"])
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(notifications.current.count, 0, "补回来的是基线，不能逐条推“任务完成”")

        // 之后的 hook 落在同一个任务上。
        let connector = makeConnector(store: store)
        await connector.restoreRecentSessions()
        await hook(connector, ["hook_event_name": "UserPromptSubmit", "session_id": "recent",
                               "cwd": "/Users/me/Projects/alpha", "prompt": "再改一下"])
        let resumed = try await requireTask(store, "recent")
        XCTAssertEqual(resumed.status, .running)
        XCTAssertEqual(resumed.title, "最近的会话", "已有标题不被后面的 prompt 顶掉")
    }

    /// 扫描期间 hook 抢先建了同一个会话：状态以 hook 为准，只补占位标题和最后一条消息。
    func testRestoreDoesNotOverrideLiveHookState() async throws {
        try write([user("修好登录"), assistant("上一轮的结论")], session: "s1")
        let store = makeStore()
        let connector = makeConnector(store: store)
        // 负载里没取到 prompt（字段名变了之类）：标题仍是项目名占位。
        await hook(connector, ["hook_event_name": "UserPromptSubmit", "session_id": "s1",
                               "cwd": "/Users/me/Projects/alpha"])

        await connector.restoreRecentSessions()

        let record = try await requireTask(store, "s1")
        XCTAssertEqual(record.status, .running, "hook 报的状态比 transcript 新")
        XCTAssertEqual(record.title, "修好登录", "项目名占位被真实标题替换")
        XCTAssertEqual(record.lastMessage, "上一轮的结论")
    }
}
