import XCTest
@testable import BotBusConnectorKit
@testable import BotBusConnectors
import BotBusProtocol

/// 电脑上删掉、归档的会话从列表里摘掉（`ClaudeConnector.sweepPresence`）。
/// transcript 与桌面 App 的会话记录都是临时目录里手写的，不读本机 `~/.claude` 与 Claude 桌面 App 的数据。
final class ClaudeSessionPresenceTests: XCTestCase {
    private var root: URL!
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-presence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: projectsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: accountDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var claudeHome: URL { root.appendingPathComponent("claude-home", isDirectory: true) }
    private var projectsDirectory: URL { claudeHome.appendingPathComponent("projects", isDirectory: true) }
    private var desktopSessions: URL { root.appendingPathComponent("claude-code-sessions", isDirectory: true) }
    private var accountDirectory: URL { desktopSessions.appendingPathComponent("org/account", isDirectory: true) }

    // MARK: - 夹具

    @discardableResult
    private func writeTranscript(_ session: String, prompt: String = "修一下登录") throws -> URL {
        let folder = projectsDirectory.appendingPathComponent("-Users-me-Projects-alpha", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(session).jsonl")
        let line = try JSONSerialization.data(withJSONObject: [
            "type": "user", "message": ["role": "user", "content": prompt],
            "timestamp": "2026-09-20T08:00:00.000Z", "entrypoint": "claude-desktop",
            "cwd": "/Users/me/Projects/alpha", "isSidechain": false,
        ])
        try (line + Data("\n".utf8)).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-60)], ofItemAtPath: url.path)
        return url
    }

    private func writeRecord(_ session: String, archived: Bool = false) throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "sessionId": "local_\(session)", "cliSessionId": session, "isArchived": archived,
        ])
        try data.write(to: recordURL(session))
    }

    private func recordURL(_ session: String) -> URL { accountDirectory.appendingPathComponent("local_\(session).json") }

    private func makeStore() -> TaskStore {
        TaskStore(identity: AgentIdentity(agentId: "agent-1"),
                  connectors: ConnectorRegistry(descriptors: [
                      ConnectorDescriptor(kind: .claude, displayName: "Claude Code", defaultEnabled: true) {
                          ConnectorProbe(available: true, status: .ok)
                      },
                  ]))
    }

    private func makeConnector(store: TaskStore) -> ClaudeConnector {
        ClaudeConnector(store: store,
                        paths: ClaudePaths(claudeHome: claudeHome, desktopSessionsDirectories: [desktopSessions]),
                        binary: { nil }, now: { [now] in now }, presenceSweepInterval: 3600)
    }

    private func hook(_ connector: ClaudeConnector, _ object: [String: Any]) async {
        _ = await connector.handleHook(LocalHookServer.Request(
            method: "POST", target: "/hooks/claude", path: "/hooks/claude",
            headers: ["content-type": "application/json"],
            body: try! JSONSerialization.data(withJSONObject: object)))
    }

    private func hasTask(_ store: TaskStore, _ session: String) async -> Bool {
        await store.task(id: "claude:\(session)") != nil
    }

    // MARK: - transcript

    func testDeletedTranscriptIsRemovedAfterTwoSweeps() async throws {
        let transcript = try writeTranscript("s1")
        try writeTranscript("s2")
        let store = makeStore()
        let connector = makeConnector(store: store)
        await connector.restoreRecentSessions()
        let sweeping = await connector.isSweepingPresence
        XCTAssertTrue(sweeping, "补完历史就开始核对")
        var hasS1 = await hasTask(store, "s1")
        XCTAssertTrue(hasS1)

        try FileManager.default.removeItem(at: transcript)
        await connector.sweepPresence()
        hasS1 = await hasTask(store, "s1")
        XCTAssertTrue(hasS1, "只不在一轮不算：正在写的会话删了文件会被重新建出来")

        await connector.sweepPresence()
        hasS1 = await hasTask(store, "s1")
        XCTAssertFalse(hasS1, "transcript 连着两轮不在，手机上跟着消失")
        let hasS2 = await hasTask(store, "s2")
        XCTAssertTrue(hasS2, "别的会话不动")
        let hidden = await store.isHidden("claude:s1")
        XCTAssertFalse(hidden, "transcript 没了只是摘掉，不永久隐藏")

        // 会话又有动静（transcript 会被重新写出来）就照常回来。
        await hook(connector, ["hook_event_name": "UserPromptSubmit", "session_id": "s1",
                               "cwd": "/Users/me/Projects/alpha", "prompt": "继续"])
        hasS1 = await hasTask(store, "s1")
        XCTAssertTrue(hasS1)
    }

    func testTranscriptBackBeforeSecondSweepKeepsSession() async throws {
        let transcript = try writeTranscript("s1")
        let store = makeStore()
        let connector = makeConnector(store: store)
        await connector.restoreRecentSessions()

        try FileManager.default.removeItem(at: transcript)
        await connector.sweepPresence()
        try writeTranscript("s1")
        await connector.sweepPresence()
        await connector.sweepPresence()
        let hasS1 = await hasTask(store, "s1")
        XCTAssertTrue(hasS1)
    }

    /// hook 刚建的会话还没写 transcript：没见过 transcript 的不摘。
    func testSessionWithoutTranscriptYetIsKept() async throws {
        let store = makeStore()
        let connector = makeConnector(store: store)
        await connector.restoreRecentSessions()
        await hook(connector, ["hook_event_name": "UserPromptSubmit", "session_id": "fresh",
                               "cwd": "/Users/me/Projects/alpha", "prompt": "新会话"])
        await hook(connector, ["hook_event_name": "Stop", "session_id": "fresh", "cwd": "/Users/me/Projects/alpha"])
        await connector.sweepPresence()
        await connector.sweepPresence()
        let hasFresh = await hasTask(store, "fresh")
        XCTAssertTrue(hasFresh)
    }

    /// 读不了 projects 目录（不在了、没权限）不等于会话都删了。
    func testUnreadableProjectsDirectoryRemovesNothing() async throws {
        try writeTranscript("s1")
        let store = makeStore()
        let connector = makeConnector(store: store)
        await connector.restoreRecentSessions()

        try FileManager.default.removeItem(at: projectsDirectory)
        await connector.sweepPresence()
        await connector.sweepPresence()
        let hasS1 = await hasTask(store, "s1")
        XCTAssertTrue(hasS1)
    }

    // MARK: - Claude 桌面 App

    func testArchivedInDesktopAppIsNotListed() async throws {
        try writeTranscript("kept")
        try writeTranscript("archived")
        try writeTranscript("later")
        try writeRecord("kept")
        try writeRecord("archived", archived: true)
        try writeRecord("later")
        let store = makeStore()
        let connector = makeConnector(store: store)
        await connector.restoreRecentSessions()
        var hasArchived = await hasTask(store, "archived")
        XCTAssertFalse(hasArchived, "同 Codex，归档的不补进列表")
        var hasLater = await hasTask(store, "later")
        XCTAssertTrue(hasLater)

        try writeRecord("later", archived: true)
        await connector.sweepPresence()
        hasLater = await hasTask(store, "later")
        XCTAssertFalse(hasLater, "之后归档的下一轮摘掉")

        await hook(connector, ["hook_event_name": "UserPromptSubmit", "session_id": "archived",
                               "cwd": "/Users/me/Projects/alpha", "prompt": "终端里接着聊"])
        hasArchived = await hasTask(store, "archived")
        XCTAssertFalse(hasArchived, "归档期间 hook 不收")

        try writeRecord("archived")
        await connector.sweepPresence()
        await hook(connector, ["hook_event_name": "UserPromptSubmit", "session_id": "archived",
                               "cwd": "/Users/me/Projects/alpha", "prompt": "取消归档了"])
        hasArchived = await hasTask(store, "archived")
        XCTAssertTrue(hasArchived, "取消归档后有动静就回来")
        let hasKept = await hasTask(store, "kept")
        XCTAssertTrue(hasKept)
    }

    /// 桌面 App 删了会话、transcript 被别的进程写过而留着：记录连着两轮没了就当删除，永久隐藏。
    func testDeletedInDesktopAppWithTranscriptKeptIsHidden() async throws {
        try writeTranscript("s1")
        try writeTranscript("s2")
        try writeRecord("s1")
        try writeRecord("s2")
        let store = makeStore()
        let connector = makeConnector(store: store)
        await connector.restoreRecentSessions()

        try FileManager.default.removeItem(at: recordURL("s1"))
        await connector.sweepPresence()
        var hasS1 = await hasTask(store, "s1")
        XCTAssertTrue(hasS1, "只没一轮不算")
        await connector.sweepPresence()
        hasS1 = await hasTask(store, "s1")
        XCTAssertFalse(hasS1)
        let hidden = await store.isHidden("claude:s1")
        XCTAssertTrue(hidden, "和手机上删一样永久隐藏")
        let hasS2 = await hasTask(store, "s2")
        XCTAssertTrue(hasS2)

        // 桌面上的 hook 不再把它拉回来，重启后补历史也补不回来。
        await hook(connector, ["hook_event_name": "UserPromptSubmit", "session_id": "s1",
                               "cwd": "/Users/me/Projects/alpha", "prompt": "又来了"])
        let restarted = makeConnector(store: store)
        await restarted.restoreRecentSessions()
        hasS1 = await hasTask(store, "s1")
        XCTAssertFalse(hasS1)
    }

    /// 整个账号目录没了（退出登录、卸载桌面 App）不是逐条删除，不隐藏。
    func testRemovedAccountDirectoryHidesNothing() async throws {
        try writeTranscript("s1")
        try writeRecord("s1")
        let store = makeStore()
        let connector = makeConnector(store: store)
        await connector.restoreRecentSessions()

        try FileManager.default.removeItem(at: accountDirectory)
        await connector.sweepPresence()
        await connector.sweepPresence()
        let hasS1 = await hasTask(store, "s1")
        XCTAssertTrue(hasS1)
    }

    /// 记录正在写（解析不了）这一轮整个不算，不会把别的会话当成删了。
    func testUnreadableRecordSkipsDesktopRules() async throws {
        try writeTranscript("s1")
        try writeRecord("s1")
        let store = makeStore()
        let connector = makeConnector(store: store)
        await connector.restoreRecentSessions()

        try FileManager.default.removeItem(at: recordURL("s1"))
        try Data("{\"cliSess".utf8).write(to: recordURL("other"))
        await connector.sweepPresence()
        await connector.sweepPresence()
        let hasS1 = await hasTask(store, "s1")
        XCTAssertTrue(hasS1)
    }

    func testIndexReadsRecordsAndReusesCache() throws {
        try writeRecord("a")
        try writeRecord("b", archived: true)
        try Data("{\"sessionId\":\"local_new\"}".utf8).write(to: accountDirectory.appendingPathComponent("local_new.json"))
        try Data("not json".utf8).write(to: accountDirectory.appendingPathComponent("notes.txt"))
        var cache: [String: ClaudeDesktopSessionIndex.Record] = [:]
        let index = try XCTUnwrap(ClaudeDesktopSessionIndex.read(roots: [desktopSessions], cache: &cache))
        XCTAssertEqual(Set(index.recorded.keys), ["a", "b"], "没有 cliSessionId 的记录不对应会话")
        XCTAssertEqual(index.archived, ["b"])
        XCTAssertEqual(index.accounts, [accountDirectory.path])
        XCTAssertEqual(cache.count, 3)

        let missing = root.appendingPathComponent("no-desktop-app")
        XCTAssertEqual(ClaudeDesktopSessionIndex.read(roots: [missing], cache: &cache), ClaudeDesktopSessionIndex(),
                       "没装桌面 App 不是错")
        XCTAssertTrue(cache.isEmpty)
    }
}
