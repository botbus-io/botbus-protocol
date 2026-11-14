import XCTest
@testable import BotBusConnectorKit
@testable import BotBusConnectors
import BotBusProtocol

/// 用本机真实的 `claude` 走一遍手机那一轮的审批：新建 → 卡片 → 允许 → 完成。会调用模型、花一点额度。
/// 默认跳过；运行：`BOTBUS_REAL_CLAUDE=<claude 可执行文件> swift test --filter RealClaudeApprovalSmokeTests`。
/// 包一层 `--setting-sources project,local`：不读 `~/.claude/settings.json`，免得本机装的 BotBus hook 把这次审批也报给正在跑的 app。
final class RealClaudeApprovalSmokeTests: XCTestCase {
    /// 问本机真实的 `claude` 它有哪些模型（`ClaudeModels.list`）。不发消息、不花额度，同样默认跳过：
    /// `BOTBUS_REAL_CLAUDE=<claude 可执行文件> swift test --filter RealClaudeApprovalSmokeTests/testModelListWithRealClaude`。
    func testModelListWithRealClaude() async throws {
        let real = ProcessInfo.processInfo.environment["BOTBUS_REAL_CLAUDE"] ?? ""
        try XCTSkipIf(real.isEmpty, "set BOTBUS_REAL_CLAUDE=<path to claude>")
        let fetched = await ClaudeModels.list(binary: real)
        let listed = try XCTUnwrap(fetched, "claude 没有报模型列表（没登录，或版本太老）")
        for model in listed {
            print("real claude model: \(model.option.id) | \(model.option.displayName) | "
                  + "\(model.option.efforts?.joined(separator: ",") ?? "-") | \(model.resolved ?? "-")")
        }
        XCTAssertFalse(listed.isEmpty)
        XCTAssertFalse(listed.contains { $0.option.id == "default" })
        XCTAssertEqual(ConnectorRegistry.sanitized(listed.map(\.option)), listed.map(\.option), "报出去的列表过得了注册表的清洗")
    }

    func testPhoneTurnApprovalWithRealClaude() async throws {
        let real = ProcessInfo.processInfo.environment["BOTBUS_REAL_CLAUDE"] ?? ""
        try XCTSkipIf(real.isEmpty, "set BOTBUS_REAL_CLAUDE=<path to claude>")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-real-\(UUID().uuidString)", isDirectory: true)
        let project = directory.appendingPathComponent("app", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let wrapper = directory.appendingPathComponent("claude")
        try Data("#!/bin/sh\nexec '\(real)' \"$@\" --setting-sources project,local\n".utf8).write(to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)

        let store = TaskStore(identity: AgentIdentity(agentId: "agent-1"),
                              connectors: ConnectorRegistry(descriptors: [
                                  ConnectorDescriptor(kind: .claude, displayName: "Claude Code", defaultEnabled: true) {
                                      ConnectorProbe(available: true, status: .ok)
                                  },
                              ]))
        let connector = ClaudeConnector(store: store,
                                        paths: ClaudePaths(claudeHome: URL(fileURLWithPath: "/nonexistent")),
                                        binary: { wrapper.path })
        let outcome = try await connector.start(
            projectPath: project.path,
            prompt: "Run the command sw_vers with the Bash tool, then reply with just its ProductName line.",
            images: [])
        let taskId = "claude:\(outcome.taskId)"
        await assertEventually(timeout: 120) { await store.task(id: taskId)?.pendingRequest != nil }
        let asked = await store.task(id: taskId)?.pendingRequest
        let pending = try XCTUnwrap(asked)
        print("real claude asked: \(pending.summary) | \(pending.detail ?? "-")")
        XCTAssertEqual(pending.kind, .permission)
        XCTAssertEqual(pending.summary, "Bash")

        _ = try await connector.approve(taskId: taskId, requestId: pending.id, decision: .allow)
        await assertEventually(timeout: 120) { await store.task(id: taskId)?.status == .completed }
        let record = await store.task(id: taskId)
        print("real claude finished: \(record?.lastMessage ?? "-")")
        XCTAssertTrue(record?.lastMessage?.contains("macOS") == true, "sw_vers 跑了才会知道 ProductName")
        await connector.stop()
    }

    /// 无人值守的轮次（团队看板的员工）在后台开了命令：主轮的 `result` 先出来，命令跑完 claude 自己再起一轮，
    /// 那一轮要审批的 `touch` 也得放行。stdin 在第一个 `result` 就关的话，它报 "Stream closed"，文件建不出来。
    func testUnattendedBackgroundWorkWithRealClaude() async throws {
        let real = ProcessInfo.processInfo.environment["BOTBUS_REAL_CLAUDE"] ?? ""
        try XCTSkipIf(real.isEmpty, "set BOTBUS_REAL_CLAUDE=<path to claude>")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-real-\(UUID().uuidString)", isDirectory: true)
        let project = directory.appendingPathComponent("app", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let wrapper = directory.appendingPathComponent("claude")
        try Data("#!/bin/sh\nexec '\(real)' \"$@\" --setting-sources project,local --model haiku\n".utf8).write(to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)

        let store = TaskStore(identity: AgentIdentity(agentId: "agent-1"),
                              connectors: ConnectorRegistry(descriptors: [
                                  ConnectorDescriptor(kind: .claude, displayName: "Claude Code", defaultEnabled: true) {
                                      ConnectorProbe(available: true, status: .ok)
                                  },
                              ]))
        let connector = ClaudeConnector(store: store,
                                        paths: ClaudePaths(claudeHome: URL(fileURLWithPath: "/nonexistent")),
                                        binary: { wrapper.path })
        let outcome = try await AgentRunContext.$current.withValue(AgentRunContext(unattended: true)) {
            try await connector.start(
                projectPath: project.path,
                prompt: "Step 1: call the Bash tool with run_in_background=true and command `sleep 6 && date +%s > stamp.txt`. "
                    + "Step 2: end your turn right away by replying 'started'. Do not wait, poll, sleep or read files. "
                    + "Later, when you are notified the background command finished, call the Bash tool (foreground) "
                    + "with command `cp stamp.txt marker.txt`, then reply 'done'.",
                images: [])
        }
        let taskId = "claude:\(outcome.taskId)"
        await assertEventually(timeout: 180) { await store.task(id: taskId)?.status == .completed }
        let record = await store.task(id: taskId)
        print("real claude finished: \(record?.lastMessage ?? "-")")
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.appendingPathComponent("marker.txt").path),
                      "后台命令跑完之后那一轮的审批没送到")
        await connector.stop()
    }
}
