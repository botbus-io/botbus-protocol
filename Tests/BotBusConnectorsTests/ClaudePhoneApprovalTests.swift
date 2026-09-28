import XCTest
@testable import BotBusConnectorKit
@testable import BotBusConnectors
import BotBusProtocol

/// 手机那一轮（本连接器自己起的 `claude -p`）的审批走控制协议：claude 在 stdout 写 `can_use_tool`，
/// 回答写回 stdin。老版本 Claude Code（2.1.268 之前）的 `-p` 根本不发 PermissionRequest hook，
/// 所以这里一概不靠 hook。协议 3.3 的项目级自动批准也在这条路上判；电脑上的轮次照旧走 hook 挂起。
final class ClaudePhoneApprovalTests: XCTestCase {
    private func tempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-approval-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    /// 假 `claude`：读一行 user 消息，吐 init，再吐 `request.json` 里的那行控制请求，读一行回答存进 `answer`，
    /// 然后吐 result，像真 claude 一样等 stdin 关了才退出（连接器读到 result 就关）。
    private func fakeClaude(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("claude")
        let dir = directory.path
        let script = """
        #!/bin/sh
        if [ "$1" = "--help" ]; then
          echo '  --effort <level>  Effort level (low, medium, high, max)'
          exit 0
        fi
        read -r first
        echo '{"type":"system","subtype":"init","session_id":"sess-auto"}'
        sleep 0.2
        cat "\(dir)/request.json"
        echo
        read -r answer
        printf '%s\\n' "$answer" > "\(dir)/answer.tmp" && mv "\(dir)/answer.tmp" "\(dir)/answer"
        echo '{"type":"result","subtype":"success","result":"done"}'
        cat > /dev/null
        """
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private struct Rig {
        var store: TaskStore
        var connector: ClaudeConnector
        var project: URL
        var directory: URL
    }

    private func makeRig(tool: String = "Bash", input: [String: Any] = ["command": "sw_vers"],
                         approvalTimeout: TimeInterval? = nil) throws -> Rig {
        let directory = try tempDirectory()
        let project = directory.appendingPathComponent("app", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let request: [String: Any] = [
            "type": "control_request", "request_id": "ctl-1",
            "request": ["subtype": "can_use_tool", "tool_name": tool, "input": input, "tool_use_id": "toolu-1",
                        "decision_reason": "This command requires approval"] as [String: Any],
        ]
        try JSONSerialization.data(withJSONObject: request).write(to: directory.appendingPathComponent("request.json"))
        let claude = try fakeClaude(in: directory)
        let store = TaskStore(identity: AgentIdentity(agentId: "agent-1"),
                              connectors: ConnectorRegistry(descriptors: [
                                  ConnectorDescriptor(kind: .claude, displayName: "Claude Code", defaultEnabled: true) {
                                      ConnectorProbe(available: true, status: .ok)
                                  },
                              ]))
        let connector = ClaudeConnector(store: store,
                                        paths: ClaudePaths(claudeHome: URL(fileURLWithPath: "/nonexistent")),
                                        binary: { claude.path }, approvalTimeout: approvalTimeout)
        return Rig(store: store, connector: connector, project: project, directory: directory)
    }

    /// 连接器写回 stdin 的那行 `control_response` 里的 `response`。
    private func answer(_ rig: Rig) async throws -> [String: Any] {
        let url = rig.directory.appendingPathComponent("answer")
        await assertEventually(timeout: 5) { FileManager.default.fileExists(atPath: url.path) }
        let line = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(line["type"] as? String, "control_response")
        let response = try XCTUnwrap(line["response"] as? [String: Any])
        XCTAssertEqual(response["subtype"] as? String, "success")
        XCTAssertEqual(response["request_id"] as? String, "ctl-1", "回答对的是 claude 的 request_id，不是 tool_use_id")
        return try XCTUnwrap(response["response"] as? [String: Any])
    }

    private func waitForPending(_ rig: Rig) async -> TaskRecord? {
        await assertEventually(timeout: 5) { await rig.store.task(id: "claude:sess-auto")?.pendingRequest != nil }
        return await rig.store.task(id: "claude:sess-auto")
    }

    private func send(_ connector: ClaudeConnector, _ object: [String: Any]) async -> LocalHookServer.Reply {
        let body = try! JSONSerialization.data(withJSONObject: object)
        return await connector.handleHook(LocalHookServer.Request(method: "POST", target: "/hooks/claude",
                                                                  path: "/hooks/claude", headers: [:], body: body))
    }

    private func permissionHook(_ connector: ClaudeConnector, session: String, cwd: String) async -> LocalHookServer.Reply {
        await send(connector, ["hook_event_name": "PermissionRequest", "session_id": session, "cwd": cwd,
                               "tool_name": "Bash", "tool_use_id": "toolu-1", "tool_input": ["command": "sw_vers"]])
    }

    // MARK: - 审批送到手机

    func testPhoneTurnApprovalReachesThePhoneAndAllowIsWrittenToStdin() async throws {
        let rig = try makeRig()
        let events = await rig.store.events()
        let notified = Locked<[Notify]>([])
        let collector = Task {
            for await event in events { if let notify = event.notify { notified.withLock { $0.append(notify) } } }
        }
        defer { collector.cancel() }

        let outcome = try await rig.connector.start(projectPath: rig.project.path, prompt: "看看系统版本", images: [])
        XCTAssertEqual(outcome.taskId, "sess-auto")
        let record = await waitForPending(rig)
        XCTAssertEqual(record?.status, .waitingApproval)
        XCTAssertEqual(record?.origin, .watch)
        XCTAssertEqual(record?.pendingRequest?.id, "toolu-1")
        XCTAssertEqual(record?.pendingRequest?.kind, .permission)
        XCTAssertEqual(record?.pendingRequest?.summary, "Bash")
        XCTAssertEqual(record?.pendingRequest?.detail, "sw_vers")
        await assertEventually { notified.current.contains { $0.category == .taskApproval } }

        _ = try await rig.connector.approve(taskId: "claude:sess-auto", requestId: "toolu-1", decision: .allow)
        let response = try await answer(rig)
        XCTAssertEqual(response["behavior"] as? String, "allow")
        XCTAssertEqual(response["updatedInput"] as? [String: String], ["command": "sw_vers"], "原入参整份带回")
        let running = await rig.store.task(id: "claude:sess-auto")
        XCTAssertNil(running?.pendingRequest)
        await assertEventually(timeout: 5) { await rig.store.task(id: "claude:sess-auto")?.status == .completed }
        await rig.connector.stop()
    }

    /// `-p` 里拒绝只是这个工具没执行，Claude 接着往下做：任务仍在跑，不是中断。
    func testDenyIsWrittenToStdinAndTheTurnKeepsRunning() async throws {
        let rig = try makeRig()
        _ = try await rig.connector.start(projectPath: rig.project.path, prompt: "看看系统版本", images: [])
        _ = await waitForPending(rig)

        _ = try await rig.connector.approve(taskId: "claude:sess-auto", requestId: "toolu-1", decision: .deny)
        let record = await rig.store.task(id: "claude:sess-auto")
        XCTAssertEqual(record?.status, .running)
        XCTAssertNil(record?.pendingRequest)
        let response = try await answer(rig)
        XCTAssertEqual(response["behavior"] as? String, "deny")
        XCTAssertNotNil(response["message"] as? String)
        await rig.connector.stop()
    }

    /// 手机一直不回：到点按拒绝回，绝不能变成允许；卡片收掉，迟到的回答报过期。
    func testUnansweredApprovalTimesOutAsDenyNeverAllow() async throws {
        let rig = try makeRig(approvalTimeout: 0.3)
        _ = try await rig.connector.start(projectPath: rig.project.path, prompt: "看看系统版本", images: [])
        _ = await waitForPending(rig)

        let response = try await answer(rig)
        XCTAssertEqual(response["behavior"] as? String, "deny")
        await assertEventually { await rig.store.task(id: "claude:sess-auto")?.pendingRequest == nil }
        do {
            _ = try await rig.connector.approve(taskId: "claude:sess-auto", requestId: "toolu-1", decision: .allow)
            XCTFail("超时之后的回答送不到")
        } catch let error as ConnectorError {
            XCTAssertTrue(error.message.contains("过期"), error.message)
        }
        await rig.connector.stop()
    }

    /// 停机时挂着的审批按拒绝回、进程随即终止：来得及读到的只能是拒绝，不能放行。
    func testStopNeverAllowsAPendingApproval() async throws {
        let rig = try makeRig()
        _ = try await rig.connector.start(projectPath: rig.project.path, prompt: "看看系统版本", images: [])
        _ = await waitForPending(rig)
        await rig.connector.stop()
        try await Task.sleep(for: .milliseconds(300))
        let url = rig.directory.appendingPathComponent("answer")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let response = try await answer(rig)
        XCTAssertEqual(response["behavior"] as? String, "deny")
    }

    /// 装了 hooks 时 PermissionRequest 与控制协议并行到达：自己的轮次里 hook 立刻回空，只留控制协议那一张卡。
    func testPermissionHookDuringOwnTurnStaysOutOfTheWay() async throws {
        let rig = try makeRig()
        _ = try await rig.connector.start(projectPath: rig.project.path, prompt: "看看系统版本", images: [])
        let reply = await permissionHook(rig.connector, session: "sess-auto", cwd: rig.project.path)
        guard case .now(let response) = reply else { return XCTFail("自己的轮次里 hook 不挂起") }
        XCTAssertEqual(response.status, 204)
        _ = await waitForPending(rig)
        _ = try await rig.connector.approve(taskId: "claude:sess-auto", requestId: "toolu-1", decision: .allow)
        let answered = try await answer(rig)
        XCTAssertEqual(answered["behavior"] as? String, "allow")
        await rig.connector.stop()
    }

    // MARK: - 提问

    /// `-p` 带了 permission host 才有 AskUserQuestion：同样经控制协议来，回答带 `answers`。
    func testAskUserQuestionOverStdinIsAnsweredWithAnswers() async throws {
        let rig = try makeRig(tool: "AskUserQuestion", input: ["questions": [
            ["question": "选哪个？", "header": "方案", "multiSelect": false,
             "options": [["label": "A"], ["label": "B"]]],
        ]])
        // 自动批准不放提问。
        await rig.store.setAutoApprove(true, project: rig.project.path)
        _ = try await rig.connector.start(projectPath: rig.project.path, prompt: "问我", images: [])
        let record = await waitForPending(rig)
        XCTAssertEqual(record?.status, .waitingInput)
        XCTAssertEqual(record?.pendingRequest?.kind, .input)
        XCTAssertEqual(record?.pendingRequest?.questions?.first?.options.map(\.label), ["A", "B"])

        _ = try await rig.connector.approve(taskId: "claude:sess-auto", requestId: "toolu-1", decision: .allow,
                                            answers: ["0": ["B"]])
        let response = try await answer(rig)
        XCTAssertEqual(response["behavior"] as? String, "allow")
        let updated = try XCTUnwrap(response["updatedInput"] as? [String: Any])
        XCTAssertEqual(updated["answers"] as? [String: String], ["选哪个？": "B"])
        XCTAssertNotNil(updated["questions"], "updatedInput 整份替换入参，原来的问题要带回去")
        await rig.connector.stop()
    }

    // MARK: - 协议 3.3 项目级自动批准

    func testAutoApprovedProjectAllowsAtOnceWithoutACard() async throws {
        let rig = try makeRig()
        await rig.store.setAutoApprove(true, project: rig.project.path)
        let events = await rig.store.events()
        let notified = Locked<[Notify]>([])
        let pending = Locked(false)
        let collector = Task {
            for await event in events {
                if let notify = event.notify { notified.withLock { $0.append(notify) } }
                if event.task?.pendingRequest != nil { pending.withLock { $0 = true } }
            }
        }
        defer { collector.cancel() }

        _ = try await rig.connector.start(projectPath: rig.project.path, prompt: "跑测试", images: [])
        let response = try await answer(rig)
        XCTAssertEqual(response["behavior"] as? String, "allow")
        XCTAssertEqual(response["updatedInput"] as? [String: String], ["command": "sw_vers"])
        await assertEventually(timeout: 5) { await rig.store.task(id: "claude:sess-auto")?.status == .completed }
        let record = await rig.store.task(id: "claude:sess-auto")
        XCTAssertEqual(record?.autoApprove, true)
        XCTAssertFalse(pending.current, "放行的审批不建 pendingRequest")
        XCTAssertFalse(notified.current.contains { $0.category == .taskApproval }, "放行的审批不推通知")
        await rig.connector.stop()
    }

    func testDesktopTurnInAutoApprovedProjectStillHolds() async throws {
        let rig = try makeRig()
        await rig.store.setAutoApprove(true, project: rig.project.path)
        // 电脑上自己跑的会话：只有 hook，没有本连接器的子进程。
        _ = await send(rig.connector, ["hook_event_name": "UserPromptSubmit", "session_id": "desk",
                                       "cwd": rig.project.path, "prompt": "在电脑上跑"])

        let reply = await permissionHook(rig.connector, session: "desk", cwd: rig.project.path)
        guard case .hold = reply else { return XCTFail("电脑上的轮次不受自动批准影响") }
        let record = await rig.store.task(id: "claude:desk")
        XCTAssertEqual(record?.status, .waitingApproval)
        XCTAssertEqual(record?.autoApprove, true, "项目开着，任务照样带标记；只是这一轮不是手机起的")
        await rig.connector.stop()
    }

    // MARK: - 编解码

    func testControlRequestParsing() throws {
        let line = Data(#"{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"ls"},"tool_use_id":"t1"}}"#.utf8)
        guard case .canUseTool(let id, let tool, let input, let toolUseID)? = ClaudeControlRequest(line: line) else {
            return XCTFail("认得 can_use_tool")
        }
        XCTAssertEqual([id, tool, toolUseID], ["r1", "Bash", "t1"])
        XCTAssertEqual(try JSONSerialization.jsonObject(with: input) as? [String: String], ["command": "ls"])
        XCTAssertEqual(ClaudeControlRequest(line: Data(#"{"type":"control_cancel_request","request_id":"r1"}"#.utf8)),
                       .cancel(requestID: "r1"))
        XCTAssertEqual(ClaudeControlRequest(line: Data(#"{"type":"control_request","request_id":"r2","request":{"subtype":"hook_callback"}}"#.utf8)),
                       .unsupported(requestID: "r2", subtype: "hook_callback"))
        XCTAssertNil(ClaudeControlRequest(line: Data(#"{"type":"assistant"}"#.utf8)))
    }

    func testControlResponsesAreSingleLines() throws {
        let original = Data(#"{"command":"ls"}"#.utf8)
        for decision in [ClaudePermissionDecision.allow(updatedInput: nil), .deny(message: "不行")] {
            let data = ClaudeControlOutput.response(requestID: "r1", decision: decision, originalInput: original)
            XCTAssertEqual(data.last, 0x0A)
            XCTAssertEqual(data.filter { $0 == 0x0A }.count, 1)
        }
        let error = ClaudeControlOutput.error(requestID: "r2", message: "no")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: error) as? [String: Any])
        XCTAssertEqual(object["response"] as? [String: String], ["subtype": "error", "request_id": "r2", "error": "no"])
    }
}
