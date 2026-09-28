import XCTest
@testable import BotBusConnectorKit
@testable import BotBusConnectors
import BotBusProtocol

/// 协议 3.3 项目级自动批准在 Claude 这边：本连接器自己起的那一轮里 `PermissionRequest` 直接回 allow；
/// 电脑上的轮次与 `AskUserQuestion` 照旧挂起等手机。
final class ClaudeAutoApproveTests: XCTestCase {
    private func tempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-auto-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    /// 假 `claude`：吐出 init（session id 固定）后一直跑到被 stop 掉，这段时间都算本连接器自己的轮次。
    private func fakeClaude(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("claude")
        let script = """
        #!/bin/sh
        if [ "$1" = "--help" ]; then
          echo '  --effort <level>  Effort level (low, medium, high, max)'
          exit 0
        fi
        echo '{"type":"system","subtype":"init","session_id":"sess-auto"}'
        sleep 30
        echo '{"type":"result","subtype":"success","result":"done"}'
        """
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func makeRig() throws -> (TaskStore, ClaudeConnector, URL) {
        let directory = try tempDirectory()
        let project = directory.appendingPathComponent("app", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let claude = try fakeClaude(in: directory)
        let store = TaskStore(identity: AgentIdentity(agentId: "agent-1"),
                              connectors: ConnectorRegistry(descriptors: [
                                  ConnectorDescriptor(kind: .claude, displayName: "Claude Code", defaultEnabled: true) {
                                      ConnectorProbe(available: true, status: .ok)
                                  },
                              ]))
        let connector = ClaudeConnector(store: store,
                                        paths: ClaudePaths(claudeHome: URL(fileURLWithPath: "/nonexistent")),
                                        binary: { claude.path })
        return (store, connector, project)
    }

    private func send(_ connector: ClaudeConnector, _ object: [String: Any]) async -> LocalHookServer.Reply {
        let body = try! JSONSerialization.data(withJSONObject: object)
        return await connector.handleHook(LocalHookServer.Request(method: "POST", target: "/hooks/claude",
                                                                  path: "/hooks/claude", headers: [:], body: body))
    }

    private func permission(_ connector: ClaudeConnector, session: String, cwd: String,
                            tool: String = "Bash", id: String = "req-1",
                            input: [String: Any] = ["command": "make test"]) async -> LocalHookServer.Reply {
        await send(connector, ["hook_event_name": "PermissionRequest", "session_id": session, "cwd": cwd,
                               "tool_name": tool, "tool_use_id": id, "tool_input": input])
    }

    private func behavior(_ response: LocalHookServer.Response) throws -> String? {
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        let decision = (payload["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        return decision?["behavior"] as? String
    }

    func testOwnTurnInAutoApprovedProjectIsAllowedAtOnce() async throws {
        let (store, connector, project) = try makeRig()
        await store.setAutoApprove(true, project: project.path)
        let events = await store.events()
        let notified = Locked<[Notify]>([])
        let collector = Task {
            for await event in events { if let notify = event.notify { notified.withLock { $0.append(notify) } } }
        }
        defer { collector.cancel() }

        let outcome = try await connector.start(projectPath: project.path, prompt: "跑测试", images: [])
        XCTAssertEqual(outcome.taskId, "sess-auto")

        let reply = await permission(connector, session: "sess-auto", cwd: project.path)
        guard case .now(let response) = reply else { return XCTFail("开了自动批准的手机轮次不该挂起") }
        XCTAssertEqual(try behavior(response), "allow")
        let record = await store.task(id: "claude:sess-auto")
        XCTAssertEqual(record?.status, .running)
        XCTAssertNil(record?.pendingRequest)
        XCTAssertEqual(record?.autoApprove, true)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(notified.current.contains { $0.category == .taskApproval }, "放行的审批不推通知")
        await connector.stop()
    }

    func testAskUserQuestionStillGoesToThePhone() async throws {
        let (store, connector, project) = try makeRig()
        await store.setAutoApprove(true, project: project.path)
        _ = try await connector.start(projectPath: project.path, prompt: "问我", images: [])

        let reply = await permission(connector, session: "sess-auto", cwd: project.path, tool: "AskUserQuestion",
                                     id: "toolu-ask", input: ["questions": [
                                         ["question": "选哪个？", "header": "", "multiSelect": false,
                                          "options": [["label": "A"], ["label": "B"]]],
                                     ]])
        guard case .hold = reply else { return XCTFail("提问照旧交给手机") }
        let record = await store.task(id: "claude:sess-auto")
        XCTAssertEqual(record?.status, .waitingInput)
        XCTAssertEqual(record?.pendingRequest?.kind, .input)
        await connector.stop()
    }

    func testOwnTurnWithoutTheSettingStillHolds() async throws {
        let (store, connector, project) = try makeRig()
        _ = try await connector.start(projectPath: project.path, prompt: "跑测试", images: [])

        let reply = await permission(connector, session: "sess-auto", cwd: project.path)
        guard case .hold = reply else { return XCTFail("项目没开自动批准就照常挂起") }
        let record = await store.task(id: "claude:sess-auto")
        XCTAssertEqual(record?.status, .waitingApproval)
        await connector.stop()
    }

    func testDesktopTurnInAutoApprovedProjectStillHolds() async throws {
        let (store, connector, project) = try makeRig()
        await store.setAutoApprove(true, project: project.path)
        // 电脑上自己跑的会话：只有 hook，没有本连接器的子进程。
        _ = await send(connector, ["hook_event_name": "UserPromptSubmit", "session_id": "desk", "cwd": project.path,
                                   "prompt": "在电脑上跑"])

        let reply = await permission(connector, session: "desk", cwd: project.path)
        guard case .hold = reply else { return XCTFail("电脑上的轮次不受自动批准影响") }
        let record = await store.task(id: "claude:desk")
        XCTAssertEqual(record?.status, .waitingApproval)
        XCTAssertEqual(record?.autoApprove, true, "项目开着，任务照样带标记；只是这一轮不是手机起的")
        await connector.stop()
    }
}
