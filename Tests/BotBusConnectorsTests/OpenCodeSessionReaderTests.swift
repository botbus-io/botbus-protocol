import Foundation
import XCTest
import BotBusProtocol
import BotBusConnectorKit
@testable import BotBusConnectors

final class OpenCodeSessionReaderTests: XCTestCase {
    func testReadsAllProjectsAndSkipsArchivedAndSubagents() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try SQLiteDatabase(path: url.path, readOnly: false)
        try db.execute("CREATE TABLE session(id TEXT, directory TEXT, title TEXT, parent_id TEXT, time_archived INTEGER, time_created INTEGER, time_updated INTEGER); CREATE TABLE message(id TEXT, session_id TEXT, time_created INTEGER, data TEXT); CREATE TABLE part(id TEXT, message_id TEXT, session_id TEXT, data TEXT);")
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        try db.execute("INSERT INTO session VALUES ('one','/project/one','Desktop',NULL,NULL,1790000000000,1790000000000), ('two','/project/two','CLI',NULL,NULL,1790000000000,1790000000000), ('child','/project/one','Child','one',NULL,1790000000000,1790000000000), ('old','/project/one','Archived',NULL,1,1790000000000,1790000000000);")
        let tasks = try OpenCodeSessionReader(databaseURL: url).tasks(now: now)
        XCTAssertEqual(Set(tasks.map(\.id)), ["acp:opencode:one", "acp:opencode:two"])
        XCTAssertEqual(Set(tasks.map(\.projectPath)), ["/project/one", "/project/two"])
        XCTAssertTrue(tasks.allSatisfy { $0.source == .acp && $0.connectorId == "opencode" })
    }

    func testReadsStableMessagesWithoutReasoningAndFindsFiles() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try SQLiteDatabase(path: url.path, readOnly: false)
        try db.execute("CREATE TABLE message(id TEXT, session_id TEXT, time_created INTEGER, data TEXT); CREATE TABLE part(id TEXT, message_id TEXT, session_id TEXT, data TEXT);")
        try db.execute("""
            INSERT INTO message VALUES ('u','one',1790000000000,'{"role":"user"}'), ('a','one',1790000001000,'{"role":"assistant","time":{"completed":1790000002000}}');
            INSERT INTO part VALUES ('p1','u','one','{"type":"text","text":"Make a file"}'), ('p2','a','one','{"type":"reasoning","text":"private thinking"}'), ('p3','a','one','{"type":"text","text":"Saved `/project/one/result.pdf`"}');
            """)
        let reader = OpenCodeSessionReader(databaseURL: url)
        let first = try await reader.entries(taskId: "acp:opencode:one", limit: 40)
        let second = try await reader.entries(taskId: "acp:opencode:one", limit: 40)
        XCTAssertEqual(first.entries, second.entries)
        XCTAssertEqual(first.entries.map(\.message.text), ["Make a file", "Saved `/project/one/result.pdf`"])
        XCTAssertEqual(first.entries.last?.pathCandidates, ["/project/one/result.pdf"])
        XCTAssertFalse(first.hasMore)
    }
}

extension OpenCodeSessionReaderTests {
    func testRunningAndFailedStatusComesFromLatestAssistant() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try SQLiteDatabase(path: url.path, readOnly: false)
        try db.execute("CREATE TABLE session(id TEXT, directory TEXT, title TEXT, parent_id TEXT, time_archived INTEGER, time_created INTEGER, time_updated INTEGER); CREATE TABLE message(id TEXT, session_id TEXT, time_created INTEGER, data TEXT); CREATE TABLE part(id TEXT, message_id TEXT, session_id TEXT, data TEXT);")
        try db.execute("INSERT INTO session VALUES ('one','/project','Title',NULL,NULL,1790000000000,1790000000000); INSERT INTO message VALUES ('a','one',1790000000000,'{\"role\":\"assistant\",\"time\":{\"created\":1790000000000}}');")
        let reader = OpenCodeSessionReader(databaseURL: url)
        XCTAssertEqual(try reader.tasks(now: Date(timeIntervalSince1970: 1_790_000_001)).first?.status, .running)
        try db.execute("UPDATE message SET data='{\"role\":\"assistant\",\"error\":{\"name\":\"APIError\"},\"time\":{\"completed\":1790000001000}}'")
        XCTAssertEqual(try reader.tasks(now: Date(timeIntervalSince1970: 1_790_000_002)).first?.status, .failed)
    }
}
