import XCTest
@testable import BotBusConnectorKit
@testable import BotBusConnectors
import BotBusProtocol

/// hook 负载 → Task 状态的映射。子进程那一半（`claude -p`）不在这里测，
/// 它要真的起 claude；这里盯的是"看见"这一侧，也是用户每天都会碰到的那一侧。
final class ClaudeConnectorTests: XCTestCase {
    private func makeStore() -> TaskStore {
        TaskStore(identity: AgentIdentity(agentId: "agent-1"),
                  connectors: ConnectorRegistry(descriptors: [
                      ConnectorDescriptor(kind: .claude, displayName: "Claude Code", defaultEnabled: true) {
                          ConnectorProbe(available: true, status: .ok)
                      },
                  ]))
    }

    private func makeConnector(store: TaskStore, binary: String? = nil, titleRetryDelays: [TimeInterval] = [0],
                               turnEndCheckInterval: TimeInterval = 3600) -> ClaudeConnector {
        ClaudeConnector(store: store, paths: ClaudePaths(claudeHome: URL(fileURLWithPath: "/nonexistent")),
                        binary: { binary }, titleRetryDelays: titleRetryDelays, turnEndCheckInterval: turnEndCheckInterval)
    }

    /// 只会回答 `--help` 的假 `claude`：连接器从这里读强度，读到了才报模型列表。
    private func fakeClaudeWithHelp() throws -> String {
        let binary = FileManager.default.temporaryDirectory.appendingPathComponent("claude-help-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: binary) }
        try "#!/bin/sh\nprintf '%s\\n' '  --effort <level>  Effort level (low, medium, high, xhigh, max)'\n"
            .write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        return binary.path
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// transcript 里的时间戳，和 Claude Code 写的一样带毫秒。
    private func stamp(_ date: Date = Date()) -> String { Self.timestampFormatter.string(from: date) }

    /// 按真实形状手写的 transcript：一行一个 JSON。返回路径，测试结束自动删。
    private func transcript(_ objects: [[String: Any]]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("claude-\(UUID().uuidString).jsonl")
        try appendLines(objects, to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func appendLines(_ objects: [[String: Any]], to url: URL) throws {
        let text = objects.map { String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self) + "\n" }
            .joined()
        if let handle = try? FileHandle(forWritingTo: url) {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
            try handle.close()
        } else {
            try Data(text.utf8).write(to: url)
        }
    }

    private func request(_ object: [String: Any]) -> LocalHookServer.Request {
        LocalHookServer.Request(method: "POST", target: "/hooks/claude", path: "/hooks/claude",
                                headers: ["content-type": "application/json"],
                                body: try! JSONSerialization.data(withJSONObject: object))
    }

    @discardableResult
    private func send(_ connector: ClaudeConnector, _ object: [String: Any]) async -> LocalHookServer.Reply {
        await connector.handleHook(request(object))
    }

    /// `XCTUnwrap` 的 autoclosure 不支持 await，所以 await 必须在它外面先落地。
    private func requireTask(_ store: TaskStore, _ sessionID: String,
                             file: StaticString = #filePath, line: UInt = #line) async throws -> TaskRecord {
        let record = await store.task(id: "claude:\(sessionID)")
        return try XCTUnwrap(record, file: file, line: line)
    }

    func testUserPromptSubmitCreatesTaskWithProjectNameTitleUntilPrompted() async throws {
        let store = makeStore()
        let connector = makeConnector(store: store)

        await send(connector, ["hook_event_name": "UserPromptSubmit", "session_id": "s1",
                               "cwd": "/Users/me/Projects/botbus", "prompt": "   "])

        let record = try await requireTask(store, "s1")
        XCTAssertEqual(record.title, "botbus", "还没有带字的 prompt 时用项目名占位")
        XCTAssertEqual(record.projectPath, "/Users/me/Projects/botbus")
        XCTAssertEqual(record.projectName, "botbus")
        XCTAssertEqual(record.source, .claude)
        XCTAssertEqual(record.origin, .desktop, "hook 建出来的会话是电脑上开的")
        XCTAssertTrue(record.controllable)
        XCTAssertEqual(record.status, .running)
    }

    // MARK: - 会话什么时候算在跑

    /// 桌面 app 里点开一个旧会话、`/clear`、新开一个空会话都会发 SessionStart。它不是开始干活：
    /// 没见过的不建，见过的状态与更新时间都不动——否则点开过的会话会一直挂着"运行中"。
    func testSessionStartNeitherCreatesNorRevivesSessions() async throws {
        let store = makeStore()
        let connector = makeConnector(store: store)
        await send(connector, ["hook_event_name": "SessionStart", "session_id": "fresh",
                               "cwd": "/tmp/proj", "source": "startup"])
        let fresh = await store.task(id: "claude:fresh")
        XCTAssertNil(fresh, "还没人说话的会话不进列表，和补历史一致")

        await send(connector, ["hook_event_name": "UserPromptSubmit", "session_id": "s1", "cwd": "/tmp/proj", "prompt": "看看"])
        await send(connector, ["hook_event_name": "Stop", "session_id": "s1", "cwd": "/tmp/proj", "last_assistant_message": "好了"])
        let done = try await requireTask(store, "s1")

        await send(connector, ["hook_event_name": "SessionStart", "session_id": "s1", "cwd": "/tmp/proj", "source": "resume"])
        let reopened = try await requireTask(store, "s1")
        XCTAssertEqual(reopened.status, .completed)
        XCTAssertEqual(reopened.updatedAt, done.updatedAt, "只是点开看看，不算有动静")
    }

    /// 压缩上下文发生在一轮中间，也发 SessionStart（source = compact）：这一轮照样在跑。
    func testSessionStartDuringATurnKeepsItRunning() async throws {
        let store = makeStore()
        let connector = makeConnector(store: store)
        await send(connector, ["hook_event_name": "UserPromptSubmit", "session_id": "s1", "cwd": "/tmp/proj", "prompt": "重构"])
        await send(connector, ["hook_event_name": "SessionStart", "session_id": "s1", "cwd": "/tmp/proj", "source": "compact"])
        let record = try await requireTask(store, "s1")
        XCTAssertEqual(record.status, .running)
    }

    /// 一轮跑到一半关掉窗口 / 退出 app：没有 Stop，只有 SessionEnd。
    func testSessionEndInterruptsATurnInProgress() async throws {
        let store = makeStore()
        let connector = makeConnector(store: store)
        await send(connector, ["hook_event_name": "UserPromptSubmit", "session_id": "s1", "cwd": "/tmp/proj", "prompt": "跑测试"])
        await send(connector, ["hook_event_name": "SessionEnd", "session_id": "s1", "cwd": "/tmp/proj", "reason": "other"])
        let record = try await requireTask(store, "s1")
        XCTAssertEqual(record.status, .interrupted)
    }

    /// 挂着审批时会话被关：审批作废，挂起的 hook 脚本放掉，不再干等 120 秒。
    func testSessionEndReleasesAPendingApproval() async throws {
        let store = makeStore()
        let connector = makeConnector(store: store)
        let reply = await send(connector, ["hook_event_name": "PermissionRequest", "session_id": "s1", "cwd": "/tmp/proj",
                                           "tool_name": "Bash", "tool_use_id": "req-1"])
        guard case .hold(let hold) = reply else { return XCTFail("应当挂起") }
        let released = Task { await hold.value() }

        await send(connector, ["hook_event_name": "SessionEnd", "session_id": "s1", "cwd": "/tmp/proj"])
        let response = await released.value
        XCTAssertTrue(response.body.isEmpty, "回空 = 没有意见")
        let record = try await requireTask(store, "s1")
        XCTAssertEqual(record.status, .interrupted)
        XCTAssertNil(record.pendingRequest)
        do {
            _ = try await connector.approve(taskId: "claude:s1", requestId: "req-1", decision: .allow)
            XCTFail("会话已经关了，审批不能再生效")
        } catch {}
    }

    /// 空闲等输入的会话被关：没人在等了，记完成；已经收尾的不动。
    func testSessionEndClosesIdleSessionsAndLeavesFinishedOnesAlone() async throws {
        let store = makeStore()
        let connector = makeConnector(store: store)
        await send(connector, ["hook_event_name": "Notification", "session_id": "idle", "cwd": "/tmp/proj",
                               "notification_type": "idle_prompt"])
        await send(connector, ["hook_event_name": "SessionEnd", "session_id": "idle", "cwd": "/tmp/proj"])
        let idle = try await requireTask(store, "idle")
        XCTAssertEqual(idle.status, .completed)

        await send(connector, ["hook_event_name": "Stop", "session_id": "done", "cwd": "/tmp/proj"])
        let before = try await requireTask(store, "done")
        await send(connector, ["hook_event_name": "SessionEnd", "session_id": "done", "cwd": "/tmp/proj"])
        let after = try await requireTask(store, "done")
        XCTAssertEqual(after.status, .completed)
        XCTAssertEqual(after.updatedAt, before.updatedAt)

        await send(connector, ["hook_event_name": "SessionEnd", "session_id": "unknown", "cwd": "/tmp/proj"])
        let unknown = await store.task(id: "claude:unknown")
        XCTAssertNil(unknown)
    }

    /// API 报错（限流、没登录）结束一轮时发的是 StopFailure 而不是 Stop。
    func testStopFailureMarksTheTurnFailed() async throws {
        let store = makeStore()
        let connector = makeConnector(store: store)
        await send(connector, ["hook_event_name": "UserPromptSubmit", "session_id": "s1", "cwd": "/tmp/proj", "prompt": "继续"])
        await send(connector, ["hook_event_name": "StopFailure", "session_id": "s1", "cwd": "/tmp/proj",
                               "error": "rate_limit", "error_details": "429 Too Many Requests"])
        let record = try await requireTask(store, "s1")
        XCTAssertEqual(record.status, .failed)
        XCTAssertEqual(record.lastMessage, "429 Too Many Requests")
    }

    // MARK: - 电脑上按停止

    /// 中断不发任何 hook，只往 transcript 写一行 "[Request interrupted by user]"。
    func testInterruptMarkerInTranscriptEndsTheTurn() async throws {
        let store = makeStore()
        let connector = makeConnector(store: store)
        let url = try transcript([["type": "user", "timestamp": stamp(), "message": ["role": "user", "content": "跑一遍"]]])
        await send(connector, ["hook_event_name": "UserPromptSubmit", "session_id": "s1", "cwd": "/tmp/proj",
                               "transcript_path": url.path, "prompt": "跑一遍"])
        let watching = await connector.isCheckingTurnEndings
        XCTAssertTrue(watching, "电脑上的会话在跑，得盯着")

        try appendLines([["type": "assistant", "timestamp": stamp(),
                          "message": ["role": "assistant", "content": [["type": "tool_use", "name": "Bash"]]]]], to: url)
        await connector.checkTurnEndingsNow()
        var record = try await requireTask(store, "s1")
        XCTAssertEqual(record.status, .running, "还在跑")

        try appendLines([["type": "user", "timestamp": stamp(),
                          "message": ["role": "user", "content": [["type": "text", "text": "[Request interrupted by user]"]]]],
                         ["type": "last-prompt", "lastPrompt": "跑一遍", "sessionId": "s1"],
                         ["type": "cost-state", "sessionId": "s1"]], to: url)
        await connector.checkTurnEndingsNow()
        record = try await requireTask(store, "s1")
        XCTAssertEqual(record.status, .interrupted)
    }

    /// 在电脑的权限框里点拒绝也是这条路：挂着的审批一并作废。
    func testRejectingOnTheDesktopEndsAPendingApproval() async throws {
        let store = makeStore()
        let connector = makeConnector(store: store)
        let url = try transcript([["type": "user", "timestamp": stamp(), "message": ["role": "user", "content": "删掉 build"]]])
        await send(connector, ["hook_event_name": "UserPromptSubmit", "session_id": "s1", "cwd": "/tmp/proj",
                               "transcript_path": url.path, "prompt": "删掉 build"])
        let reply = await send(connector, ["hook_event_name": "PermissionRequest", "session_id": "s1", "cwd": "/tmp/proj",
                                           "transcript_path": url.path, "tool_name": "Bash", "tool_use_id": "req-1"])
        guard case .hold(let hold) = reply else { return XCTFail("应当挂起") }
        let released = Task { await hold.value() }

        try appendLines([["type": "user", "timestamp": stamp(),
                          "message": ["role": "user", "content": "[Request interrupted by user for tool use]"]]], to: url)
        await connector.checkTurnEndingsNow()
        let response = await released.value
        XCTAssertTrue(response.body.isEmpty)
        let record = try await requireTask(store, "s1")
        XCTAssertEqual(record.status, .interrupted)
        XCTAssertNil(record.pendingRequest)
    }

    /// 上一轮留下的中断标记不算：新 prompt 还没落盘时文件末尾仍是它。
    func testInterruptMarkerFromAnEarlierTurnIsIgnored() async throws {
        let store = makeStore()
        let connector = makeConnector(store: store)
        let url = try transcript([["type": "user", "timestamp": stamp(Date().addingTimeInterval(-600)),
                                   "message": ["role": "user", "content": "[Request interrupted by user]"]]])
        await send(connector, ["hook_event_name": "UserPromptSubmit", "session_id": "s1", "cwd": "/tmp/proj",
                               "transcript_path": url.path, "prompt": "接着来"])
        await connector.checkTurnEndingsNow()
        let record = try await requireTask(store, "s1")
        XCTAssertEqual(record.status, .running)
    }

    /// Stop hook 没送到（Agent 当时没在听）时，transcript 里的 `stop_hook_summary` 补上完成。
    func testStopHookSummaryCompletesAMissedStop() async throws {
        let store = makeStore()
        let connector = makeConnector(store: store)
        let url = try transcript([["type": "user", "timestamp": stamp(), "message": ["role": "user", "content": "看看"]]])
        await send(connector, ["hook_event_name": "UserPromptSubmit", "session_id": "s1", "cwd": "/tmp/proj",
                               "transcript_path": url.path, "prompt": "看看"])
        try appendLines([["type": "assistant", "timestamp": stamp(),
                          "message": ["role": "assistant", "content": [["type": "text", "text": "看完了"]]]],
                         ["type": "system", "subtype": "stop_hook_summary", "timestamp": stamp()]], to: url)
        await connector.checkTurnEndingsNow()
        let record = try await requireTask(store, "s1")
        XCTAssertEqual(record.status, .completed)
    }

    /// 定时器真的会跑，没有要盯的会话后自己停下。
    func testTurnEndCheckRunsOnItsOwnAndStopsWhenIdle() async throws {
        let store = makeStore()
        let connector = makeConnector(store: store, turnEndCheckInterval: 0.05)
        let url = try transcript([["type": "user", "timestamp": stamp(), "message": ["role": "user", "content": "跑"]]])
        await send(connector, ["hook_event_name": "UserPromptSubmit", "session_id": "s1", "cwd": "/tmp/proj",
                               "transcript_path": url.path, "prompt": "跑"])
        try appendLines([["type": "user", "timestamp": stamp(),
                          "message": ["role": "user", "content": "[Request interrupted by user]"]]], to: url)

        for _ in 0..<100 {
            let record = await store.task(id: "claude:s1")
            let watching = await connector.isCheckingTurnEndings
            if record?.status == .interrupted, !watching { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("两秒内应当自己发现中断并停下定时器")
    }

    func testTurnEndingReadsOnlyTheLastConversationLine() throws {
        let now = Date()
        let interrupted = try transcript([
            ["type": "user", "timestamp": stamp(now), "message": ["role": "user", "content": "[Request interrupted by user]"]],
            ["type": "queue-operation", "operation": "enqueue"],
            ["type": "custom-title", "customTitle": "标题"],
        ])
        guard case .interrupted(let at)? = ClaudeSessionHistory.turnEnding(inTranscriptAt: interrupted.path) else {
            return XCTFail("元数据行之前的中断标记要认出来")
        }
        XCTAssertEqual(at.timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 0.01)

        let resumed = try transcript([
            ["type": "user", "timestamp": stamp(now), "message": ["role": "user", "content": "[Request interrupted by user]"]],
            ["type": "user", "timestamp": stamp(now), "message": ["role": "user", "content": "换个思路"]],
        ])
        XCTAssertNil(ClaudeSessionHistory.turnEnding(inTranscriptAt: resumed.path), "之后又说了话就是新一轮")

        let apiRetry = try transcript([
            ["type": "assistant", "timestamp": stamp(now), "message": ["role": "assistant", "content": [["type": "text", "text": "…"]]]],
            ["type": "system", "subtype": "api_error", "timestamp": stamp(now)],
        ])
        XCTAssertNil(ClaudeSessionHistory.turnEnding(inTranscriptAt: apiRetry.path), "重试中的报错不是收尾")
        XCTAssertNil(ClaudeSessionHistory.turnEnding(inTranscriptAt: "/nonexistent/x.jsonl"))
    }

    func testUserPromptSubmitSetsRunningAndTakesFirstPromptAsTitle() async throws {
        let store = makeStore()
        let connector = makeConnector(store: store)

        await send(connector, ["hook_event_name": "UserPromptSubmit", "session_id": "s1",
                               "cwd": "/tmp/proj", "prompt": "把导航那一层去掉"])
        var record = try await requireTask(store, "s1")
        XCTAssertEqual(record.status, .running)
        XCTAssertEqual(record.title, "把导航那一层去掉", "第一条 prompt 顶掉占位标题")

        // 第二条不再改标题：标题是"这个会话在干什么"，不是"最后一句话"。
        await send(connector, ["hook_event_name": "UserPromptSubmit", "session_id": "s1",
                               "cwd": "/tmp/proj", "prompt": "再顺手改个文案"])
        record = try await requireTask(store, "s1")
        XCTAssertEqual(record.title, "把导航那一层去掉")
    }

    /// Claude 桌面 app 在人敲的话前面拼 `<system-reminder>`（worktree 路径、上下文），
    /// hook 的 prompt 是拼好的整串——标题只能取剥掉之后的那句。
    func testUserPromptSubmitTitleSkipsInjectedReminders() async throws {
        let store = makeStore()
        let connector = makeConnector(store: store)
        let prompt = "<system-reminder>\nYou are operating in a git worktree.\n</system-reminder>"
            + "<system-reminder>\nAs you answer…\n</system-reminder>\n\n为什么标题还是 system-reminder"
        await send(connector, ["hook_event_name": "UserPromptSubmit", "session_id": "s3",
                               "cwd": "/tmp/proj", "prompt": prompt])
        let record = try await requireTask(store, "s3")
        XCTAssertEqual(record.title, "为什么标题还是 system-reminder")
    }

    /// 桌面 app 在第一条 prompt 之后异步起名、写进 transcript；hook 负载里没有它，得去文件里取。
    func testDesktopTitleFromTranscriptReplacesPromptTitle() async throws {
        let store = makeStore()
        let connector = makeConnector(store: store, titleRetryDelays: [0, 0.2])
        let url = try transcript([["type": "user", "message": ["role": "user", "content": "把导航那一层去掉"]]])

        await send(connector, ["hook_event_name": "UserPromptSubmit", "session_id": "s1", "cwd": "/tmp/proj",
                               "transcript_path": url.path, "prompt": "把导航那一层去掉"])
        // 起名晚于 hook 落盘：第一次没看到，后面的重试接住。
        try appendLines([["type": "custom-title", "customTitle": "去掉导航层", "sessionId": "s1"],
                         ["type": "agent-name", "agentName": "去掉导航层", "sessionId": "s1"]], to: url)
        await connector.waitForTitleRefreshes()

        let record = try await requireTask(store, "s1")
        XCTAssertEqual(record.title, "去掉导航层", "和桌面 app 侧栏一致")
    }

    func testRenameInDesktopAppIsPickedUpOnStop() async throws {
        let store = makeStore()
        let connector = makeConnector(store: store)
        let url = try transcript([["type": "custom-title", "customTitle": "旧名字", "sessionId": "s1"]])
        await send(connector, ["hook_event_name": "UserPromptSubmit", "session_id": "s1", "cwd": "/tmp/proj",
                               "transcript_path": url.path, "prompt": "随便问问"])
        await connector.waitForTitleRefreshes()
        var record = try await requireTask(store, "s1")
        XCTAssertEqual(record.title, "旧名字")

        try appendLines([["type": "custom-title", "customTitle": "新名字", "sessionId": "s1"]], to: url)
        await send(connector, ["hook_event_name": "Notification", "session_id": "s1", "cwd": "/tmp/proj",
                               "transcript_path": url.path, "notification_type": "idle_prompt"])
        await connector.waitForTitleRefreshes()
        record = try await requireTask(store, "s1")
        XCTAssertEqual(record.title, "旧名字", "有了 app 标题之后只在 Stop 时再读文件")

        await send(connector, ["hook_event_name": "Stop", "session_id": "s1", "cwd": "/tmp/proj",
                               "transcript_path": url.path, "last_assistant_message": "好了"])
        await connector.waitForTitleRefreshes()
        record = try await requireTask(store, "s1")
        XCTAssertEqual(record.title, "新名字")
    }

    /// 别名升级到新模型后，Stop 时从 transcript 认出版本，手机上的模型列表跟着换显示名。
    func testStopPicksUpANewerModelVersionForTheModelList() async throws {
        let store = makeStore()
        let connector = makeConnector(store: store, binary: try fakeClaudeWithHelp())
        XCTAssertEqual(store.connectors.models(for: .claude)?.first { $0.id == "opus" }?.displayName, "Opus")
        let url = try transcript([["type": "assistant",
                                   "message": ["model": "claude-opus-6", "content": [["type": "text", "text": "好了"]]]]])
        await send(connector, ["hook_event_name": "UserPromptSubmit", "session_id": "s1", "cwd": "/tmp/proj",
                               "transcript_path": url.path, "prompt": "看看"])
        await send(connector, ["hook_event_name": "Stop", "session_id": "s1", "cwd": "/tmp/proj",
                               "transcript_path": url.path, "last_assistant_message": "好了"])
        await connector.waitForTitleRefreshes()
        XCTAssertEqual(store.connectors.models(for: .claude)?.first { $0.id == "opus" }?.displayName, "Opus 6")
        let record = try await requireTask(store, "s1")
        XCTAssertEqual(record.model, "opus", "任务上记的仍是别名")
    }

    /// 命令行与 `claude -p` 会话没有 custom-title，只有 Claude Code 生成的 ai-title；两者都在时桌面标题优先。
    func testTranscriptTitlePrefersCustomOverAITitle() throws {
        let generated = try transcript([["type": "ai-title", "aiTitle": "本地运行网站", "sessionId": "s1"]])
        XCTAssertEqual(ClaudeSessionHistory.appTitle(inTranscriptAt: generated.path)?.title, "本地运行网站")
        XCTAssertEqual(ClaudeSessionHistory.appTitle(inTranscriptAt: generated.path)?.source, .generated)

        let both = try transcript([["type": "custom-title", "customTitle": "侧栏标题", "sessionId": "s1"],
                                   ["type": "ai-title", "aiTitle": "生成的标题", "sessionId": "s1"],
                                   ["type": "user", "message": ["role": "user", "content": "聊聊 \"custom-title\" 这个字段"]]])
        XCTAssertEqual(ClaudeSessionHistory.appTitle(inTranscriptAt: both.path)?.title, "侧栏标题")
        XCTAssertEqual(ClaudeSessionHistory.appTitle(inTranscriptAt: both.path)?.source, .named)

        let none = try transcript([["type": "user", "message": ["role": "user", "content": "还没起名"]]])
        XCTAssertNil(ClaudeSessionHistory.appTitle(inTranscriptAt: none.path))
        XCTAssertNil(ClaudeSessionHistory.appTitle(inTranscriptAt: "/nonexistent/x.jsonl"))
    }

    /// 字段名在不同 Claude Code 版本上不一样（2.1.273 是 `prompt`，文档写的是 `user_prompt`）。
    /// 少认一个键的后果是标题永远停在项目名，所以两个都得认。
    func testUserPromptSubmitAcceptsBothFieldNames() async throws {
        let store = makeStore()
        let connector = makeConnector(store: store)
        await send(connector, ["hook_event_name": "UserPromptSubmit", "session_id": "s2",
                               "cwd": "/tmp/proj", "user_prompt": "文档里那个字段名"])
        let titled = try await requireTask(store, "s2")
        XCTAssertEqual(titled.title, "文档里那个字段名")
    }

    func testPermissionRequestHoldsResponseUntilApprove() async throws {
        let store = makeStore()
        let connector = makeConnector(store: store)
        await send(connector, ["hook_event_name": "UserPromptSubmit", "session_id": "s1", "cwd": "/tmp/proj"])

        let reply = await send(connector, [
            "hook_event_name": "PermissionRequest", "session_id": "s1", "cwd": "/tmp/proj",
            "tool_name": "Bash", "tool_use_id": "req-1",
            "tool_input": ["command": "rm -rf build"],
        ])
        guard case .hold(let hold) = reply else { return XCTFail("PermissionRequest 必须挂起等人点头") }

        let record = try await requireTask(store, "s1")
        XCTAssertEqual(record.status, .waitingApproval)
        XCTAssertEqual(record.pendingRequest?.id, "req-1")
        XCTAssertEqual(record.pendingRequest?.kind, .permission)
        XCTAssertEqual(record.pendingRequest?.summary, "Bash")
        XCTAssertEqual(record.pendingRequest?.detail, "rm -rf build", "命令行比一坨 JSON 好看得多")

        // 手机上点允许 → 那条挂着的 HTTP 响应拿到 allow。
        let answered = Task { await hold.value() }
        _ = try await connector.approve(taskId: "claude:s1", requestId: "req-1", decision: .allow)
        let response = await answered.value

        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        let specific = try XCTUnwrap(payload["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(specific["hookEventName"] as? String, "PermissionRequest")
        // 是个带 behavior 判别式的对象，不是字符串——写成字符串会被整条忽略然后回落到弹窗。
        let decision = try XCTUnwrap(specific["decision"] as? [String: Any])
        XCTAssertEqual(decision["behavior"] as? String, "allow")

        let after = try await requireTask(store, "s1")
        XCTAssertNil(after.pendingRequest)
        XCTAssertEqual(after.status, .running)
    }

    func testDenyAnswersWithDenyBehavior() async throws {
        let store = makeStore()
        let connector = makeConnector(store: store)
        let reply = await send(connector, ["hook_event_name": "PermissionRequest", "session_id": "s1",
                                           "cwd": "/tmp/proj", "tool_name": "Write", "tool_use_id": "req-9"])
        guard case .hold(let hold) = reply else { return XCTFail("应当挂起") }

        let answered = Task { await hold.value() }
        _ = try await connector.approve(taskId: "claude:s1", requestId: "req-9", decision: .deny)
        let body = await answered.value.body
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let decision = try XCTUnwrap((payload["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any])
        XCTAssertEqual(decision["behavior"] as? String, "deny")
        let denied = try await requireTask(store, "s1")
        XCTAssertEqual(denied.status, .interrupted)
    }

    // MARK: - AskUserQuestion（协议 2.14）

    /// 形状取自本机 Claude Code 2.1.273 的真实 PermissionRequest 负载。
    private func askUserQuestion(_ connector: ClaudeConnector, id: String = "toolu-ask") async -> LocalHookServer.Reply {
        await send(connector, [
            "hook_event_name": "PermissionRequest", "session_id": "s1", "cwd": "/tmp/proj",
            "tool_name": "AskUserQuestion", "tool_use_id": id,
            "tool_input": ["questions": [
                ["question": "要处理什么？", "header": "要处理什么", "multiSelect": false,
                 "options": [["label": "发新版", "description": "跑发版 workflow"],
                             ["label": "先本机验证", "description": ""]]],
                ["question": "测哪些？", "header": "", "multiSelect": true,
                 "options": [["label": "手机"], ["label": "手表"]]],
            ]],
        ])
    }

    private func hookDecision(_ response: LocalHookServer.Response) throws -> [String: Any] {
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        return try XCTUnwrap((payload["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any])
    }

    func testAskUserQuestionBecomesInputWithOptions() async throws {
        let store = makeStore()
        let connector = makeConnector(store: store)
        guard case .hold = await askUserQuestion(connector) else { return XCTFail("提问同样要挂起等手机") }

        let record = try await requireTask(store, "s1")
        XCTAssertEqual(record.status, .waitingInput, "是在等人选，不是等人批准")
        let request = try XCTUnwrap(record.pendingRequest)
        XCTAssertEqual(request.kind, .input)
        XCTAssertEqual(request.summary, "要处理什么")
        XCTAssertNil(request.detail, "原始 JSON 不再塞给手机")
        let questions = try XCTUnwrap(request.questions)
        XCTAssertEqual(questions.map(\.id), ["0", "1"])
        XCTAssertEqual(questions[0].options, [PendingOption(label: "发新版", description: "跑发版 workflow"),
                                              PendingOption(label: "先本机验证")])
        XCTAssertFalse(questions[0].allowsMultiple)
        XCTAssertTrue(questions[1].allowsMultiple)
        XCTAssertNil(questions[1].header, "空标签省略")
        // 旧手机只画 question：选项得写在里面。
        XCTAssertEqual(request.question, "要处理什么？\n1. 发新版 — 跑发版 workflow\n2. 先本机验证\n\n测哪些？（可多选）\n1. 手机\n2. 手表")
    }

    func testApproveWithAnswersFillsUpdatedInput() async throws {
        let store = makeStore()
        let connector = makeConnector(store: store)
        guard case .hold(let hold) = await askUserQuestion(connector) else { return XCTFail("应当挂起") }

        let answered = Task { await hold.value() }
        _ = try await connector.approve(taskId: "claude:s1", requestId: "toolu-ask", decision: .allow,
                                        answers: ["0": ["发新版"], "1": ["手机", "手表"], "9": ["没这题"]])
        let response = await answered.value
        let decision = try hookDecision(response)
        XCTAssertEqual(decision["behavior"] as? String, "allow")
        let input = try XCTUnwrap(decision["updatedInput"] as? [String: Any])
        // updatedInput 整份替换入参：原来的 questions 必须原样带回去。
        XCTAssertEqual((input["questions"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(input["answers"] as? [String: String], ["要处理什么？": "发新版", "测哪些？": "手机, 手表"])

        let after = try await requireTask(store, "s1")
        XCTAssertNil(after.pendingRequest)
        XCTAssertEqual(after.status, .running)
    }

    func testApproveWithoutAnswersKeepsTheQuestionOpen() async throws {
        let store = makeStore()
        let connector = makeConnector(store: store)
        guard case .hold(let hold) = await askUserQuestion(connector) else { return XCTFail("应当挂起") }
        do {
            _ = try await connector.approve(taskId: "claude:s1", requestId: "toolu-ask", decision: .allow, answers: nil)
            XCTFail("没选就批准不能当成回答")
        } catch {}
        let still = try await requireTask(store, "s1")
        XCTAssertEqual(still.pendingRequest?.id, "toolu-ask")

        // 之后照样能答。
        let answered = Task { await hold.value() }
        _ = try await connector.approve(taskId: "claude:s1", requestId: "toolu-ask", decision: .allow,
                                        answers: ["0": ["先本机验证"]])
        let response = await answered.value
        XCTAssertEqual(try hookDecision(response)["behavior"] as? String, "allow")
    }

    func testSkippingAQuestionDeniesButKeepsRunning() async throws {
        let store = makeStore()
        let connector = makeConnector(store: store)
        guard case .hold(let hold) = await askUserQuestion(connector) else { return XCTFail("应当挂起") }
        let answered = Task { await hold.value() }
        _ = try await connector.approve(taskId: "claude:s1", requestId: "toolu-ask", decision: .deny)
        let response = await answered.value
        XCTAssertEqual(try hookDecision(response)["behavior"] as? String, "deny")
        let after = try await requireTask(store, "s1")
        XCTAssertEqual(after.status, .running, "不回答不是中断，Claude 会接着做")
        XCTAssertNil(after.pendingRequest)
    }

    /// 旧手机只有输入框：打的那句话就是所有问题的答案，不另起一轮 `claude -p`（本测试里根本没有 claude 可执行文件）。
    func testFollowUpAnswersAPendingQuestion() async throws {
        let store = makeStore()
        let connector = makeConnector(store: store)
        guard case .hold(let hold) = await askUserQuestion(connector) else { return XCTFail("应当挂起") }

        do {
            _ = try await connector.followUp(taskId: "claude:s1", prompt: "看这张",
                                             images: [URL(fileURLWithPath: "/tmp/x.png")])
            XCTFail("提问挂着时带图续聊会把图丢掉，应当拒绝")
        } catch {
            XCTAssertTrue("\(error)".contains("先回答"), "\(error)")
        }

        let answered = Task { await hold.value() }
        let outcome = try await connector.followUp(taskId: "claude:s1", prompt: "  都先别动  ", images: [])
        XCTAssertEqual(outcome.taskId, "s1")
        let response = await answered.value
        let input = try XCTUnwrap(try hookDecision(response)["updatedInput"] as? [String: Any])
        XCTAssertEqual(input["answers"] as? [String: String], ["要处理什么？": "都先别动", "测哪些？": "都先别动"])
        let after = try await requireTask(store, "s1")
        XCTAssertNil(after.pendingRequest)
        XCTAssertEqual(after.status, .running)
    }

    /// 挂起的请求只活 120 秒。过期之后再点允许，得给用户一句人话，而不是静默什么都不发生。
    func testApproveAfterTheHoldIsGoneFails() async throws {
        let store = makeStore()
        let connector = makeConnector(store: store)
        await send(connector, ["hook_event_name": "UserPromptSubmit", "session_id": "s1", "cwd": "/tmp/proj"])
        do {
            _ = try await connector.approve(taskId: "claude:s1", requestId: "nope", decision: .allow)
            XCTFail("不存在的审批应当报错")
        } catch {
            XCTAssertTrue("\(error)".contains("过期"), "报错要说清楚原因：\(error)")
        }
    }

    func testIdleNotificationSetsWaitingInputAndOthersAreIgnored() async throws {
        let store = makeStore()
        let connector = makeConnector(store: store)
        await send(connector, ["hook_event_name": "UserPromptSubmit", "session_id": "s1", "cwd": "/tmp/proj"])

        await send(connector, ["hook_event_name": "Notification", "session_id": "s1", "cwd": "/tmp/proj",
                               "notification_type": "idle_prompt", "message": "等你回复"])
        let idle = try await requireTask(store, "s1")
        XCTAssertEqual(idle.status, .waitingInput)

        // permission_prompt 说的是 PermissionRequest 已经说过的事，再动一次只会多推一条通知。
        await send(connector, ["hook_event_name": "Notification", "session_id": "s1", "cwd": "/tmp/proj",
                               "notification_type": "permission_prompt", "message": "要权限"])
        let unchanged = try await requireTask(store, "s1")
        XCTAssertEqual(unchanged.status, .waitingInput, "不该被无关通知改掉")
    }

    func testStopUsesLastAssistantMessageFromPayload() async throws {
        let store = makeStore()
        let connector = makeConnector(store: store)
        await send(connector, ["hook_event_name": "UserPromptSubmit", "session_id": "s1", "cwd": "/tmp/proj"])
        await send(connector, ["hook_event_name": "Stop", "session_id": "s1", "cwd": "/tmp/proj",
                               "stop_hook_active": false, "last_assistant_message": "改完了，三端都过了。"])

        let record = try await requireTask(store, "s1")
        XCTAssertEqual(record.status, .completed)
        XCTAssertEqual(record.lastMessage, "改完了，三端都过了。")
        XCTAssertNil(record.pendingRequest)
    }

    /// 负载里没带 `last_assistant_message`（旧版本）时回落去读 transcript；
    /// 中间夹着读不懂的行也不能让整条 hook 白跑。
    func testStopReadsLastAssistantTextFromTranscriptTolerantly() async throws {
        let transcript = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("transcript-\(UUID().uuidString).jsonl")
        let lines = [
            #"{"type":"user","message":{"content":"帮我看看"}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"看到了"}]}}"#,
            "这一行根本不是 JSON",
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"最后一句"}]}}"#,
            #"{"type":"system","subtype":"noise"}"#,
        ]
        try Data(lines.joined(separator: "\n").utf8).write(to: transcript)
        defer { try? FileManager.default.removeItem(at: transcript) }

        let store = makeStore()
        let connector = makeConnector(store: store)
        await send(connector, ["hook_event_name": "Stop", "session_id": "s1", "cwd": "/tmp/proj",
                               "transcript_path": transcript.path])
        let stopped = try await requireTask(store, "s1")
        XCTAssertEqual(stopped.lastMessage, "最后一句")
    }

    func testStopWithUnreadableTranscriptLeavesLastMessageEmpty() async throws {
        let store = makeStore()
        let connector = makeConnector(store: store)
        await send(connector, ["hook_event_name": "Stop", "session_id": "s1", "cwd": "/tmp/proj",
                               "transcript_path": "/nonexistent/transcript.jsonl"])
        let record = try await requireTask(store, "s1")
        XCTAssertEqual(record.status, .completed, "读不到 transcript 不该让这条 hook 失败")
        XCTAssertNil(record.lastMessage)
    }

    /// 不认识的事件（PreToolUse 之类）与缺 session_id 的负载一律安静忽略，不能建出空任务。
    func testUnknownEventsAreIgnored() async throws {
        let store = makeStore()
        let connector = makeConnector(store: store)
        await send(connector, ["hook_event_name": "PreToolUse", "session_id": "s1", "cwd": "/tmp"])
        await send(connector, ["hook_event_name": "SessionStart", "cwd": "/tmp"])
        let snapshot = await store.snapshot()
        XCTAssertTrue(snapshot.tasks.isEmpty)
    }

    /// 会话的 cwd 就是项目列表的来源（`~/.claude/projects` 的目录名反解不回原路径）。
    func testSessionsBecomeProjects() async throws {
        let store = makeStore()
        let connector = makeConnector(store: store)
        await send(connector, ["hook_event_name": "UserPromptSubmit", "session_id": "s1", "cwd": "/tmp/alpha"])
        await send(connector, ["hook_event_name": "UserPromptSubmit", "session_id": "s2", "cwd": "/tmp/beta"])
        await send(connector, ["hook_event_name": "UserPromptSubmit", "session_id": "s3", "cwd": "/tmp/alpha"])

        let snapshot = await store.snapshot()
        XCTAssertEqual(Set(snapshot.projects.map(\.path)), ["/tmp/alpha", "/tmp/beta"], "同一路径只算一个项目")
        XCTAssertEqual(Set(snapshot.projects.map(\.name)), ["alpha", "beta"])
    }

    /// `tool_input` 是任意结构，只给人看：命令类工具摘命令行，其余压成一行 JSON。
    func testToolInputSummary() {
        XCTAssertEqual(ClaudeHookEvent.summarize(["command": "ls -la"]), "ls -la")
        XCTAssertEqual(ClaudeHookEvent.summarize(["file_path": "/tmp/a.swift", "content": "…"]), "/tmp/a.swift")
        XCTAssertEqual(ClaudeHookEvent.summarize(["weird": 1]), #"{"weird":1}"#)
        XCTAssertNil(ClaudeHookEvent.summarize(nil))
    }
}
