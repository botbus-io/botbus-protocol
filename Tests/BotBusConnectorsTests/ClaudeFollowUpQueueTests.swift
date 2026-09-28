import XCTest
@testable import BotBusConnectorKit
@testable import BotBusConnectors
import BotBusProtocol

/// 手机在 Claude 还没答完时又发了一条：连接器排队，等自己那一轮结束再 `--resume`，
/// 不同时起两个 `claude -p --resume`（那会把 transcript 分叉成两支）。
final class ClaudeFollowUpQueueTests: XCTestCase {
    private func tempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-queue-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    /// 假 `claude`：session id 固定（`--resume` 不分叉），每次调用在 `calls.log` 记 `start <prompt>` / `end <prompt>`。
    /// init 行晚 0.3 秒才吐，让第二条续聊正好落在"已起进程、还没拿到 id"的空当里；prompt 含 slow 时这一轮跑 1.5 秒。
    private func fakeClaude(in directory: URL) throws -> URL {
        let log = directory.appendingPathComponent("calls.log").path
        let url = directory.appendingPathComponent("claude")
        let script = """
        #!/bin/sh
        if [ "$1" = "--help" ]; then
          echo '  --effort <level>  Effort level (low, medium, high, max)'
          exit 0
        fi
        prompt=""
        prev=""
        for a in "$@"; do [ "$prev" = "sess-q" ] && prompt="$a"; prev="$a"; done
        echo "start $prompt" >> "\(log)"
        sleep 0.3
        echo '{"type":"system","subtype":"init","session_id":"sess-q"}'
        case "$prompt" in *slow*) sleep 1.5 ;; *) sleep 0.2 ;; esac
        echo "end $prompt" >> "\(log)"
        echo '{"type":"result","subtype":"success","result":"'"$prompt"'"}'
        """
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func calls(_ directory: URL) -> [String] {
        let text = (try? String(contentsOf: directory.appendingPathComponent("calls.log"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
    }

    private func makeRig() async throws -> (TaskStore, ClaudeConnector, URL) {
        let directory = try tempDirectory()
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
        // 电脑上已有的会话（hook 报过），项目目录就是临时目录。
        let body = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "Stop", "session_id": "sess-q", "cwd": directory.path,
        ])
        _ = await connector.handleHook(LocalHookServer.Request(method: "POST", target: "/hooks/claude",
                                                               path: "/hooks/claude", headers: [:], body: body))
        return (store, connector, directory)
    }

    func testFollowUpWhileRunningIsQueuedAndRunsAfterward() async throws {
        let (store, connector, directory) = try await makeRig()
        let events = await store.events()
        let statuses = Locked<[TaskStatus]>([])
        let collector = Task {
            for await event in events where event.kind == .taskUpdated {
                if let task = event.task, statuses.current.last != task.status { statuses.withLock { $0.append(task.status) } }
            }
        }
        defer { collector.cancel() }

        // 两条几乎同时到：第二条落在第一条"起了进程、还没拿到 id"的空当里。
        async let first = connector.followUp(taskId: "claude:sess-q", prompt: "slow one", images: [])
        try await Task.sleep(for: .milliseconds(100))
        let startedSecond = Date()
        let second = try await connector.followUp(taskId: "claude:sess-q", prompt: "second", images: [])
        XCTAssertLessThan(Date().timeIntervalSince(startedSecond), 0.2, "排队的续聊立刻回执，不等上一轮")
        XCTAssertEqual(second.taskId, "sess-q")
        _ = try await first
        // 第三条在第一轮跑着时到。
        _ = try await connector.followUp(taskId: "claude:sess-q", prompt: "third", images: [])

        await assertEventually(timeout: 8) { self.calls(directory).count == 6 }
        XCTAssertEqual(calls(directory), ["start slow one", "end slow one", "start second", "end second",
                                          "start third", "end third"], "一轮结束才起下一轮，按到达顺序")
        await assertEventually(timeout: 2) { await store.task(id: "claude:sess-q")?.status == .completed }
        let record = await store.task(id: "claude:sess-q")
        XCTAssertEqual(record?.lastMessage, "third")
        // 中间两轮结束时还排着队，一直是 running，不在两轮之间报"完成"（否则手机会多一条完成通知）。
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(statuses.current, [.running, .completed])
        await connector.stop()
    }

    func testInterruptDropsQueuedFollowUps() async throws {
        let (store, connector, directory) = try await makeRig()
        _ = try await connector.followUp(taskId: "claude:sess-q", prompt: "slow one", images: [])
        _ = try await connector.followUp(taskId: "claude:sess-q", prompt: "queued", images: [])
        _ = try await connector.interrupt(taskId: "claude:sess-q")

        try await Task.sleep(for: .seconds(2.5))
        XCTAssertFalse(calls(directory).contains("start queued"), "中断后排着的续聊不再跑")
        let status = await store.task(id: "claude:sess-q")?.status
        XCTAssertEqual(status, .interrupted)
        await connector.stop()
    }
}
