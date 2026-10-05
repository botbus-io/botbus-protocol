import XCTest
import BotBusProtocol
import BotBusConnectorKit
@testable import BotBusConnectors

/// 电脑上删掉的 ACP 会话：本机记录（`acp-sessions.json`）与内存状态不再把它补回列表（`AcpConnector.forgetDeleted`）。
final class AcpDeletedSessionsTests: XCTestCase {
    private let project = FileManager.default.temporaryDirectory.path
    private static let spec = AcpAgentSpec(id: "my-agent", name: "My Agent", executable: "/usr/local/bin/my-agent",
                                           arguments: [], environment: [:], origin: .manifest, defaultEnabled: true)

    private func listed(_ sessionId: String, at date: Date) -> JSONValue {
        ["sessionId": .string(sessionId), "cwd": .string(project), "title": "电脑上的",
         "updatedAt": .string(ProtocolJSON.timestamp(date))]
    }

    func testRecordMissingFromCompleteListIsForgotten() async throws {
        let behavior = FakeAcpBehavior()
        behavior.capabilities = ["sessionCapabilities": ["list": [:]]]
        let now = Date()
        behavior.listed = [listed("s1", at: now)]
        let archive = AcpSessionArchive(url: nil)
        for id in ["s1", "never-listed"] {
            var record = acpRecord("my-agent", id, updatedAt: ProtocolJSON.timestamp(now.addingTimeInterval(-60)), cwd: project)
            record.origin = .watch
            await archive.remember(connectorId: "my-agent", record: record)
        }
        // 只为列表拉起的进程刷完就关：两次列表要两个进程。
        let queue = FakeAgentQueue([await FakeAcpAgent.make(behavior), await FakeAcpAgent.make(behavior)])
        let connector = AcpConnector(spec: Self.spec, store: makeAcpStore(), launcher: queue.factory,
                                     archive: archive, clientVersion: "1.0")
        await connector.refreshList()
        var ids = Set(await connector.staticTasks().map { $0.id })
        XCTAssertEqual(ids, ["acp:my-agent:s1", "acp:my-agent:never-listed"])

        behavior.listed = []
        await connector.refreshList()
        ids = Set(await connector.staticTasks().map { $0.id })
        XCTAssertEqual(ids, ["acp:my-agent:never-listed"],
                       "列表里见过又没了的是电脑上删了；从没列出过的（agent 不列 BotBus 建的会话）不算")
        let remembered = await archive.records(connectorId: "my-agent").map(\.id)
        XCTAssertEqual(remembered, ["acp:my-agent:never-listed"], "本机记录也忘掉，重启后不再补回来")
        await connector.shutdown()
    }

    func testIncompleteListForgetsNothing() async throws {
        let behavior = FakeAcpBehavior()
        behavior.capabilities = ["sessionCapabilities": ["list": [:]]]
        let now = Date()
        behavior.listed = [listed("s1", at: now)]
        let archive = AcpSessionArchive(url: nil)
        await archive.remember(connectorId: "my-agent",
                               record: acpRecord("my-agent", "s1", updatedAt: ProtocolJSON.timestamp(now.addingTimeInterval(-60)),
                                                 cwd: project))
        let queue = FakeAgentQueue([await FakeAcpAgent.make(behavior)])
        let connector = AcpConnector(spec: Self.spec, store: makeAcpStore(), launcher: queue.factory,
                                     archive: archive, clientVersion: "1.0")
        await connector.refreshList()
        let forgot = await connector.forgetDeleted(notIn: [], updatedAfter: .distantPast,
                                                   updatedBefore: now.addingTimeInterval(-120))
        XCTAssertFalse(forgot, "读那一刻之后才更新过的不算")
        let ids = await connector.staticTasks().map { $0.id }
        XCTAssertEqual(ids, ["acp:my-agent:s1"])
        await connector.shutdown()
    }

    /// 内置 OpenCode 以数据库为准：手机续聊过的会话在电脑上删掉或归档，本机记录不再补回来。
    func testOpenCodeSessionDeletedOrArchivedInDatabaseIsForgotten() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try SQLiteDatabase(path: url.path, readOnly: false)
        try db.execute("CREATE TABLE session(id TEXT, directory TEXT, title TEXT, parent_id TEXT, time_archived INTEGER, time_created INTEGER, time_updated INTEGER); CREATE TABLE message(id TEXT, session_id TEXT, time_created INTEGER, data TEXT); CREATE TABLE part(id TEXT, message_id TEXT, session_id TEXT, data TEXT);")
        let ms = Int64(Date().timeIntervalSince1970 * 1000)
        try db.execute("INSERT INTO session VALUES ('gone','/project','要删的',NULL,NULL,\(ms),\(ms)); INSERT INTO session VALUES ('kept','/project','留着的',NULL,NULL,\(ms),\(ms)); INSERT INTO session VALUES ('shelved','/project','要归档的',NULL,NULL,\(ms),\(ms));")
        let archive = AcpSessionArchive(url: nil)
        for id in ["gone", "kept", "shelved"] {
            var record = acpRecord("opencode", id, updatedAt: ProtocolJSON.timestamp(Date().addingTimeInterval(-60)), cwd: "/project")
            record.origin = .watch
            await archive.remember(connectorId: "opencode", record: record)
        }
        let spec = AcpAgentSpec(id: "opencode", name: "OpenCode", executable: "/fake/opencode", arguments: ["acp"],
                                environment: [:], origin: .builtin, defaultEnabled: true)
        let connector = AcpConnector(spec: spec, store: makeAcpStore(["opencode"]), launcher: FakeAgentQueue([]).factory,
                                     archive: archive, openCodeReader: OpenCodeSessionReader(databaseURL: url),
                                     clientVersion: "1.0")
        await connector.refreshLocalSessions()
        var ids = Set(await connector.staticTasks().map { $0.id })
        XCTAssertEqual(ids, ["acp:opencode:gone", "acp:opencode:kept", "acp:opencode:shelved"])

        try db.execute("DELETE FROM session WHERE id = 'gone'; UPDATE session SET time_archived = \(ms) WHERE id = 'shelved';")
        await connector.refreshLocalSessions()
        ids = Set(await connector.staticTasks().map { $0.id })
        XCTAssertEqual(ids, ["acp:opencode:kept"])
        let remembered = await archive.records(connectorId: "opencode").map(\.id)
        XCTAssertEqual(remembered, ["acp:opencode:kept"])
        await connector.shutdown()
    }
}
