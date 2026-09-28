import XCTest
@testable import BotBusConnectorKit
@testable import BotBusConnectors
import BotBusProtocol

/// 用本机真实的 `claude` 走一遍手机那一轮的审批：新建 → 卡片 → 允许 → 完成。会调用模型、花一点额度。
/// 默认跳过；运行：`BOTBUS_REAL_CLAUDE=<claude 可执行文件> swift test --filter RealClaudeApprovalSmokeTests`。
/// 包一层 `--setting-sources project,local`：不读 `~/.claude/settings.json`，免得本机装的 BotBus hook 把这次审批也报给正在跑的 app。
final class RealClaudeApprovalSmokeTests: XCTestCase {
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
}
