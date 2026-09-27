import XCTest
@testable import BotBusConnectorKit
@testable import BotBusConnectors

/// 对本机真实 ~/.codex 的只读冒烟。默认跳过；运行：BOTBUS_REAL_CODEX=1 swift test --filter RealCodexSmokeTests
final class RealCodexSmokeTests: XCTestCase {
    func testReadsRealCodexWithoutCrashing() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BOTBUS_REAL_CODEX"] == "1", "set BOTBUS_REAL_CODEX=1")
        let reader = try XCTUnwrap(CodexThreadReader(paths: CodexPaths()), "本机没有 ~/.codex 数据库")
        let tasks = try reader.readTasks(agentId: "agent-mac-1")
        let projects = try reader.readProjects(agentId: "agent-mac-1")
        print("real codex: \(tasks.count) tasks, \(projects.count) projects")
        for task in tasks.prefix(5) {
            print("  \(task.status.rawValue) | \(task.projectName) | \(task.title.prefix(30)) | \((task.lastMessage ?? "-").prefix(30))")
        }
        XCTAssertFalse(tasks.isEmpty, "最近 7 天应至少有一个 Codex 线程")
        XCTAssertTrue(tasks.allSatisfy { $0.id.hasPrefix("codex:") && !$0.title.isEmpty })
    }
}
