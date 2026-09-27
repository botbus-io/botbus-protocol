import XCTest
@testable import BotBusConnectorKit
@testable import BotBusConnectors
import BotBusProtocol

/// Mac 菜单「手机发起的会话」：TaskStore 记住 origin 为 watch 的任务、跨重启保留，以及「在电脑上继续」的命令。
final class PhoneStartedTasksTests: XCTestCase {
    private static let agentId = "agent-self-000000000"

    private func makeStore(phoneTasksURL: URL? = nil) -> TaskStore {
        let registry = ConnectorRegistry(descriptors: ConnectorKind.allCases.map { kind in
            ConnectorDescriptor(kind: kind, displayName: kind.rawValue, defaultEnabled: true) {
                ConnectorProbe(available: true, status: .ok)
            }
        })
        return TaskStore(identity: AgentIdentity(agentId: Self.agentId, name: "本机", appVersion: "1.0"),
                         connectors: registry, phoneTasksURL: phoneTasksURL, artifactSaveDelay: 0.05)
    }

    private func task(_ id: String, source: TaskSource = .claude, origin: TaskOrigin,
                      updatedAt: String = "2026-09-26T02:00:00Z", worktreePath: String? = nil) -> TaskRecord {
        TaskRecord(id: "\(source.rawValue):\(id)", agentId: Self.agentId, source: source, title: "任务 \(id)",
                   projectPath: "/Users/me/p", projectName: "p", status: .completed, origin: origin,
                   controllable: true, startedAt: "2026-09-26T01:00:00Z", updatedAt: updatedAt,
                   worktreePath: worktreePath)
    }

    private func tempURL() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("phone-tasks-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("phone-tasks.json")
    }

    func testListsOnlyPhoneStartedTasksNewestFirst() async {
        let store = makeStore()
        await store.upsert(task("a", origin: .watch, updatedAt: "2026-09-26T01:00:00Z"))
        await store.upsert(task("b", origin: .desktop))
        await store.upsert(task("c", source: .codex, origin: .watch, updatedAt: "2026-09-26T03:00:00Z"))

        let ids = await store.phoneStartedTasks().map(\.id)
        XCTAssertEqual(ids, ["codex:c", "claude:a"])
    }

    func testStaysPhoneStartedWhenOriginLaterReportedAsDesktop() async {
        let store = makeStore()
        await store.upsert(task("a", origin: .watch))
        // 重启或交还观察者后，读回来的同一条记录 origin 是 desktop。
        await store.reconcile(source: .claude, tasks: [task("a", origin: .desktop, updatedAt: "2026-09-26T04:00:00Z")],
                              projects: [])

        let listed = await store.phoneStartedTasks()
        XCTAssertEqual(listed.map(\.id), ["claude:a"])
        XCTAssertEqual(listed.first?.origin, .desktop, "不改写 origin：连接器靠它判断电脑上是否正开着")
    }

    func testPersistsAcrossRestart() async throws {
        let url = tempURL()
        let first = makeStore(phoneTasksURL: url)
        await first.upsert(task("a", origin: .watch))
        await first.flushArtifacts()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let second = makeStore(phoneTasksURL: url)
        await second.reconcile(source: .claude, tasks: [task("a", origin: .desktop), task("b", origin: .desktop)],
                               projects: [])
        let ids = await second.phoneStartedTasks().map(\.id)
        XCTAssertEqual(ids, ["claude:a"])
    }

    func testCorruptArchiveIsIgnored() async throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        let store = makeStore(phoneTasksURL: url)
        await store.upsert(task("a", origin: .desktop))
        let listed = await store.phoneStartedTasks()
        XCTAssertTrue(listed.isEmpty)
    }

    func testTrimDropsEarliestSeen() {
        let trimmed = PhoneTaskArchive.trimmed(["x": "2026-09-26T03:00:00Z", "y": "2026-09-26T01:00:00Z",
                                                "z": "2026-09-26T02:00:00Z"], limit: 2)
        XCTAssertEqual(Set(trimmed.keys), ["x", "z"])
    }

    // MARK: - 在电脑上继续

    func testResumeCommandPerSource() {
        let claude = DesktopResume.command(for: task("s1", origin: .watch, worktreePath: "/Users/me/p/.claude/worktrees/w"),
                                           executable: "/bin/claude")
        XCTAssertEqual(claude?.arguments, ["--resume", "s1"])
        XCTAssertEqual(claude?.workingDirectory, "/Users/me/p/.claude/worktrees/w", "在 worktree 里续，不退回主仓库")

        XCTAssertEqual(DesktopResume.command(for: task("t1", source: .codex, origin: .watch), executable: "/c")?.arguments,
                       ["resume", "t1"])
        XCTAssertEqual(DesktopResume.command(for: task("h1", source: .hermes, origin: .watch), executable: "/h")?.arguments,
                       ["--resume", "h1"])
        XCTAssertEqual(DesktopResume.command(for: task("agent:main:x", source: .openclaw, origin: .watch),
                                             executable: "/o")?.arguments,
                       ["tui", "--session", "agent:main:x"], "sessionKey 自己带冒号，只切来源前缀")
        XCTAssertNil(DesktopResume.command(for: task("p1", source: .pi, origin: .watch), executable: "/pi"),
                     "Pi 没有记录文件就拼不出来")
        XCTAssertEqual(DesktopResume.command(for: task("p1", source: .pi, origin: .watch), executable: "/pi",
                                             piSessionFile: "/s/x_p1.jsonl")?.arguments,
                       ["--session", "/s/x_p1.jsonl"])
    }

    func testNodeScriptAgentsGetTheirOwnDirectoryFirstOnPath() {
        let pi = DesktopResume.command(for: task("p1", source: .pi, origin: .watch), executable: "/opt/homebrew/bin/pi",
                                       piSessionFile: "/s/x_p1.jsonl")
        XCTAssertEqual(pi?.pathDirectories.first, "/opt/homebrew/bin")
        XCTAssertTrue(pi?.shellLine.contains("PATH='/opt/homebrew/bin") == true)
        XCTAssertTrue(pi?.shellLine.contains(":\"$PATH\" '/opt/homebrew/bin/pi' '--session'") == true)

        let codex = DesktopResume.command(for: task("t1", source: .codex, origin: .watch),
                                          executable: "/Applications/Codex.app/Contents/Resources/codex")
        XCTAssertEqual(codex?.pathDirectories, [], "不把 App 包的 Resources 塞进 PATH")
        XCTAssertFalse(codex?.shellLine.contains("PATH=") == true)
    }

    func testShellLineQuotesEverySegment() {
        let command = DesktopResumeCommand(executable: "/Users/me/.local/bin/claude", arguments: ["--resume", "abc"],
                                           workingDirectory: "/Users/me/it's here")
        XCTAssertEqual(command.shellLine,
                       "cd '/Users/me/it'\\''s here' && '/Users/me/.local/bin/claude' '--resume' 'abc'")
    }
}
