import Foundation
import XCTest
import BotBusProtocol

/// 协议 2.13：ACP agent 的 connectorId、任务 id 的切法、只在 acp 上出现的字段。
final class AcpProtocolTests: XCTestCase {
    func testAcpIdRules() {
        XCTAssertTrue(ConnectorRef.isValidAcpId("my-agent"))
        XCTAssertTrue(ConnectorRef.isValidAcpId("a"))
        XCTAssertTrue(ConnectorRef.isValidAcpId(String(repeating: "a", count: 32)))
        XCTAssertFalse(ConnectorRef.isValidAcpId(""))
        XCTAssertFalse(ConnectorRef.isValidAcpId(String(repeating: "a", count: 33)))
        XCTAssertFalse(ConnectorRef.isValidAcpId("My-Agent"), "只收小写")
        XCTAssertFalse(ConnectorRef.isValidAcpId("my:agent"), "冒号会让任务 id 切不开")
        XCTAssertFalse(ConnectorRef.isValidAcpId("my_agent"))
    }

    func testAcpTaskIDSplitsOnFirstTwoColons() throws {
        XCTAssertEqual(AcpTaskID.make(connectorId: "my-agent", sessionId: "s1"), "acp:my-agent:s1")
        let parsed = try XCTUnwrap(AcpTaskID.parse("acp:my-agent:agent:main:main"))
        XCTAssertEqual(parsed.connectorId, "my-agent")
        XCTAssertEqual(parsed.sessionId, "agent:main:main", "原生 id 本身可以带冒号")
        XCTAssertNil(AcpTaskID.parse("codex:abc"))
        XCTAssertNil(AcpTaskID.parse("acp:my-agent"))
        XCTAssertNil(AcpTaskID.parse("acp:my-agent:"))
        XCTAssertNil(AcpTaskID.parse("acp:Bad:x"))
        XCTAssertEqual(TaskSource(rawValue: "acp"), .acp)
    }

    func testConnectorRefDropsIdForBuiltinKinds() {
        XCTAssertNil(ConnectorRef(kind: .codex, id: "x").id)
        XCTAssertEqual(ConnectorRef.acp("gemini").id, "gemini")
        XCTAssertEqual(ConnectorRef.acp("gemini").description, "acp:gemini")
        XCTAssertEqual(ConnectorRef(kind: .claude).description, "claude")
        XCTAssertEqual(ConnectorRef("acp:gemini"), .acp("gemini"))
        XCTAssertEqual(ConnectorRef("codex"), ConnectorRef(kind: .codex))
        XCTAssertNil(ConnectorRef("acp"), "acp 必须带 id")
        XCTAssertNil(ConnectorRef("codex:x"), "一档不带 id")
        XCTAssertNil(ConnectorRef("nope"))
    }

    func testAcpTaskRecordRoundTripsConnectorId() throws {
        let task = TaskRecord(id: "acp:my-agent:s1", agentId: "agent", source: .acp, title: "t",
                              projectPath: "/p", projectName: "p", status: .running, origin: .watch,
                              controllable: true, startedAt: "2026-09-26T08:00:00Z",
                              updatedAt: "2026-09-26T08:00:00Z", connectorId: "my-agent")
        let data = try ProtocolJSON.encoder().encode(task)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["connectorId"] as? String, "my-agent")
        XCTAssertEqual(try ProtocolJSON.decoder().decode(TaskRecord.self, from: data), task)
        XCTAssertEqual(task.connectorRef, .acp("my-agent"))
    }

    func testBuiltinTaskMustNotCarryConnectorId() throws {
        let json = Data(#"""
        {"id":"codex:t","agentId":"a","source":"codex","connectorId":"x","title":"t","projectPath":"/p",
         "projectName":"p","status":"idle","origin":"desktop","controllable":false,
         "startedAt":"2026-09-26T08:00:00Z","updatedAt":"2026-09-26T08:00:00Z"}
        """#.utf8)
        XCTAssertThrowsError(try ProtocolJSON.decoder().decode(TaskRecord.self, from: json))
    }

    func testConnectorInfoCanStartTaskIsOmittedWhenTrue() throws {
        let startable = ConnectorInfo(kind: .acp, connectorId: "gemini", displayName: "Gemini CLI", available: true,
                                      enabled: true, status: .ok, taskCount: 0)
        let json = try JSONSerialization.jsonObject(with: ProtocolJSON.encoder().encode(startable)) as! [String: Any]
        XCTAssertFalse(json.keys.contains("canStartTask"))
        XCTAssertEqual(json["connectorId"] as? String, "gemini")
        XCTAssertEqual(startable.id, .acp("gemini"))
    }

    func testStartTaskAndSetConnectorEnabledCarryConnectorId() throws {
        let start = Command.startTask(.init(source: .acp, projectPath: "/p", prompt: "hi", connectorId: "gemini"),
                                      createdAt: "2026-09-26T08:00:00Z", id: "c1", agentId: "a")
        let decoded = try ProtocolJSON.decoder().decode(Command.self, from: ProtocolJSON.encoder().encode(start))
        XCTAssertEqual(decoded.startTask?.connectorId, "gemini")

        let toggle = Command.setConnectorEnabled(.init(connector: .acp, enabled: false, connectorId: "gemini"),
                                                 createdAt: "2026-09-26T08:00:00Z", id: "c2", agentId: "a")
        let again = try ProtocolJSON.decoder().decode(Command.self, from: ProtocolJSON.encoder().encode(toggle))
        XCTAssertEqual(again.setConnectorEnabled?.ref, .acp("gemini"))
    }
}
