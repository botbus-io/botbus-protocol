import Foundation
import XCTest
import BotBusProtocol
import BotBusConnectorKit
@testable import BotBusConnectors

final class OpenCodeIntegrationTests: XCTestCase {
    func testLocalRefreshDiscoversDesktopWithoutLaunchingACPAndRespectsDisabled() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try SQLiteDatabase(path: url.path, readOnly: false)
        try db.execute("CREATE TABLE session(id TEXT, directory TEXT, title TEXT, parent_id TEXT, time_archived INTEGER, time_created INTEGER, time_updated INTEGER); CREATE TABLE message(id TEXT, session_id TEXT, time_created INTEGER, data TEXT); CREATE TABLE part(id TEXT, message_id TEXT, session_id TEXT, data TEXT);")
        let ms = Int64(Date().timeIntervalSince1970 * 1000)
        try db.execute("INSERT INTO session VALUES ('desktop','/project/desktop','Desktop',NULL,NULL,\(ms),\(ms)); INSERT INTO message VALUES ('u','desktop',\(ms),'{\"role\":\"user\"}'); INSERT INTO part VALUES ('p','u','desktop','{\"type\":\"text\",\"text\":\"hello\"}');")
        let store = makeAcpStore([])
        let queue = FakeAgentQueue([])
        let hub = AcpHub(store: store) { spec, health, changed in
            AcpConnector(spec: spec, store: store, launcher: queue.factory,
                         openCodeReader: OpenCodeSessionReader(databaseURL: url),
                         onHealth: health, onTasksChanged: changed)
        }
        let spec = AcpAgentSpec(id: "opencode", name: "OpenCode", executable: "/fake/opencode", arguments: ["acp"], environment: [:], origin: .builtin, defaultEnabled: true)
        await hub.sync([spec])
        await hub.refreshLocalSessions()
        let task = await store.task(id: "acp:opencode:desktop")
        XCTAssertEqual(task?.title, "Desktop")
        let entries = try await hub.entries(taskId: "acp:opencode:desktop", limit: 40)
        XCTAssertEqual(entries.entries.first?.message.text, "hello")
        // 如果任何读取拉起 ACP，空队列就会报错；读取必须成功。
        var live = try XCTUnwrap(task)
        live.status = .waitingApproval
        await store.claimLive(live.id)
        await store.upsert(live)
        try db.execute("UPDATE session SET title='Changed', time_updated=\(ms + 1000)")
        await hub.refreshLocalSessions()
        let preserved = await store.task(id: live.id)
        XCTAssertEqual(preserved?.status, .waitingApproval)
        store.connectors.setAcpEnabled(false, for: "opencode")
        await hub.applyEnabledState()
        let snapshot = await store.snapshot()
        XCTAssertFalse(snapshot.tasks.contains { $0.connectorId == "opencode" })
        await hub.shutdown()
    }
}

extension OpenCodeIntegrationTests {
    func testBuiltInDiscoveryAndTerminalResume() throws {
        let entry = AcpRegistryEntry(id: "opencode", name: "OpenCode", binaries: ["opencode"], args: ["acp"], defaultEnabled: true)
        let result = AcpDiscovery.discover(manifestDirectory: URL(fileURLWithPath: "/nonexistent"), catalog: [entry], locate: { _ in "/test/.opencode/bin/opencode" })
        XCTAssertEqual(result.agents.first?.origin, .builtin)
        XCTAssertEqual(result.agents.first?.arguments, ["acp"])
        var task = TaskRecord(id: "acp:opencode:ses_one", agentId: "a", source: .acp, title: "OpenCode", projectPath: "/project", projectName: "project", status: .completed, origin: .watch, controllable: true, startedAt: "2026-10-01T00:00:00Z", updatedAt: "2026-10-01T00:00:00Z", connectorId: "opencode")
        let command = DesktopResume.command(for: task, executable: "/test/opencode")
        XCTAssertEqual(command?.arguments, ["--session", "ses_one"])
        task.connectorId = "other"
        XCTAssertNil(DesktopResume.command(for: task, executable: "/test/opencode"))
    }
}

extension OpenCodeIntegrationTests {
    func testDesktopRunningTurnCannotBeResumedInAnotherProcess() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try SQLiteDatabase(path: url.path, readOnly: false)
        try db.execute("CREATE TABLE session(id TEXT, directory TEXT, title TEXT, parent_id TEXT, time_archived INTEGER, time_created INTEGER, time_updated INTEGER); CREATE TABLE message(id TEXT, session_id TEXT, time_created INTEGER, data TEXT); CREATE TABLE part(id TEXT, message_id TEXT, session_id TEXT, data TEXT);")
        let ms = Int64(Date().timeIntervalSince1970 * 1000)
        try db.execute("INSERT INTO session VALUES ('one','/project','Title',NULL,NULL,\(ms),\(ms)); INSERT INTO message VALUES ('a','one',\(ms),'{\"role\":\"assistant\",\"time\":{\"created\":\(ms)}}');")
        let store = makeAcpStore(["opencode"])
        let queue = FakeAgentQueue([])
        let spec = AcpAgentSpec(id: "opencode", name: "OpenCode", executable: "/fake/opencode", arguments: ["acp"], environment: [:], origin: .builtin, defaultEnabled: true)
        let connector = AcpConnector(spec: spec, store: store, launcher: queue.factory, openCodeReader: OpenCodeSessionReader(databaseURL: url))
        await connector.refreshLocalSessions()
        do {
            _ = try await connector.followUp(taskId: "acp:opencode:one", prompt: "continue", images: [])
            XCTFail("Running desktop turn must be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("电脑上运行"), error.localizedDescription)
        }
        await connector.shutdown()
    }
}
