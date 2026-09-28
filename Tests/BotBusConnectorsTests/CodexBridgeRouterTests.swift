import XCTest
@testable import BotBusConnectorKit
@testable import BotBusConnectors

final class CodexBridgeRouterTests: XCTestCase {
    func testDesktopInitializeSuccessMakesBridgeReadyWithoutOptionalNotification() throws {
        var router = CodexBridgeRouter()
        let sent = try XCTUnwrap(router.desktop(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "desktop"]]]).first?.message)
        XCTAssertFalse(router.ready)
        _ = router.upstream(["id": sent["id"]!, "result": ["userAgent": "codex"]])
        XCTAssertTrue(router.ready)
        XCTAssertEqual(router.initializeResult, ["userAgent": "codex"])
        _ = router.attach("phone")
        XCTAssertThrowsError(try router.agent(["id": 1, "method": "initialize"], session: "phone"))
        XCTAssertNoThrow(try router.agent(["id": 2, "method": "thread/loaded/list"], session: "phone"))
    }

    func testAgentMayArchiveThreadsButNotCallOtherMethods() throws {
        var router = readyRouter()
        _ = router.attach("phone")
        // 协议 3.4：合并并结束后归档线程要经桥发出去。
        XCTAssertNoThrow(try router.agent(["id": 1, "method": "thread/archive", "params": ["threadId": "t"]], session: "phone"))
        XCTAssertThrowsError(try router.agent(["id": 2, "method": "thread/unarchive", "params": ["threadId": "t"]], session: "phone"))
    }

    func testOptionalInitializedNotificationPassesThroughButDoesNotMakeFailedHandshakeReady() throws {
        var router = CodexBridgeRouter()
        let sent = try XCTUnwrap(router.desktop(["id": 1, "method": "initialize"]).first?.message)
        let notification: JSONValue = ["method": "initialized"]
        XCTAssertEqual(router.desktop(notification), [.upstream(notification)])
        XCTAssertFalse(router.ready)
        _ = router.upstream(["id": sent["id"]!, "error": ["code": -32600, "message": "invalid client"]])
        XCTAssertFalse(router.ready)
        XCTAssertNil(router.initializeResult)
    }

    func testOptionalInitializedNotificationAfterSuccessStillPassesThrough() throws {
        var router = readyRouter()
        let notification: JSONValue = ["method": "initialized"]
        XCTAssertEqual(router.desktop(notification), [.upstream(notification)])
        XCTAssertTrue(router.ready)
    }

    func testRequestIDsAreIsolatedAndResultsReturnToCorrectPeer() throws {
        var router = readyRouter()
        _ = router.attach("phone")
        let desktop = try XCTUnwrap(router.desktop(["id": 7, "method": "thread/read", "params": ["threadId": "a"]]).first?.message)
        let phone = try XCTUnwrap(router.agent(["id": 7, "method": "thread/read", "params": ["threadId": "b"]], session: "phone").first?.message)
        XCTAssertNotEqual(desktop["id"], phone["id"])
        XCTAssertEqual(router.upstream(["id": phone["id"]!, "result": ["thread": ["id": "b"]]]), [.agent("phone", ["id": 7, "result": ["thread": ["id": "b"]]])])
        XCTAssertEqual(router.upstream(["id": desktop["id"]!, "result": ["thread": ["id": "a"]]]), [.desktop(["id": 7, "result": ["thread": ["id": "a"]]])])
    }

    func testNotificationsFanOutButDesktopToolCallsStayOnDesktop() {
        var router = readyRouter()
        _ = router.attach("phone")
        let event: JSONValue = ["method": "turn/started", "params": ["threadId": "t", "turn": ["id": "turn"]]]
        XCTAssertEqual(router.upstream(event), [.desktop(event), .agent("phone", event)])
        let tool: JSONValue = ["id": "tool", "method": "item/tool/call", "params": ["threadId": "t"]]
        XCTAssertEqual(router.upstream(tool), [.desktop(tool)])
    }

    func testPhoneApprovalWinsAndDesktopLateAnswerIsIgnored() throws {
        var router = readyRouter()
        _ = router.attach("phone")
        let approval: JSONValue = ["id": "a", "method": "item/commandExecution/requestApproval", "params": ["threadId": "t", "turnId": "turn"]]
        _ = router.upstream(approval)
        let answer: JSONValue = ["id": "a", "result": ["decision": "accept"]]
        let sent = try router.agent(answer, session: "phone")
        XCTAssertEqual(sent.filter { if case .upstream = $0 { return true }; return false }, [.upstream(answer)])
        XCTAssertTrue(router.desktop(answer).isEmpty)
        XCTAssertThrowsError(try router.agent(answer, session: "phone"))
    }

    func testDesktopApprovalWinsAndPhoneReceivesResolution() throws {
        var router = readyRouter()
        _ = router.attach("phone")
        _ = router.upstream(["id": 8, "method": "item/fileChange/requestApproval", "params": ["threadId": "t"]])
        let outputs = router.desktop(["id": 8, "result": ["decision": "decline"]])
        XCTAssertTrue(outputs.contains { $0.message["method"] == "serverRequest/resolved" })
        XCTAssertThrowsError(try router.agent(["id": 8, "result": ["decision": "accept"]], session: "phone"))
    }

    func testNewAgentGetsPendingApprovalsButNotOldResponses() throws {
        var router = readyRouter()
        _ = router.attach("old")
        let sent = try XCTUnwrap(router.agent(["id": 1, "method": "thread/read"], session: "old").first?.message)
        let approval: JSONValue = ["id": 2, "method": "item/tool/requestUserInput", "params": ["threadId": "t"]]
        _ = router.upstream(approval)
        XCTAssertEqual(router.attach("new"), [approval])
        XCTAssertTrue(router.upstream(["id": sent["id"]!, "result": [:]]).isEmpty)
        XCTAssertThrowsError(try router.agent(["id": 3, "method": "turn/start"], session: "old"))
    }

    func testCompletedTurnInvalidatesPendingApproval() throws {
        var router = readyRouter()
        _ = router.attach("phone")
        _ = router.upstream(["id": 2, "method": "item/tool/requestUserInput", "params": ["threadId": "t", "turnId": "u"]])
        _ = router.upstream(["method": "turn/completed", "params": ["threadId": "t", "turn": ["id": "u", "status": "completed"]]])
        XCTAssertThrowsError(try router.agent(["id": 2, "result": [:]], session: "phone"))
        XCTAssertTrue(router.attach("new").isEmpty)
    }

    func testAgentCannotAnswerDesktopToolsOrUnsubscribeDesktop() throws {
        var router = readyRouter()
        _ = router.attach("phone")
        _ = router.upstream(["id": 2, "method": "item/tool/call", "params": [:]])
        XCTAssertThrowsError(try router.agent(["id": 2, "result": [:]], session: "phone"))
        XCTAssertThrowsError(try router.agent(["id": 3, "method": "thread/unsubscribe"], session: "phone"))
    }

    func testReconnectReplaysRunningDesktopTurnBeforePendingApproval() {
        var router = readyRouter()
        let running: JSONValue = ["method": "turn/started", "params": ["threadId": "t", "turn": ["id": "u"]]]
        let approval: JSONValue = ["id": 5, "method": "item/commandExecution/requestApproval",
                                   "params": ["threadId": "t", "turnId": "u"]]
        _ = router.upstream(running)
        _ = router.upstream(approval)
        XCTAssertEqual(router.attach("phone"), [running, approval])
        _ = router.upstream(["method": "turn/completed", "params": ["threadId": "t", "turn": ["id": "u"]]])
        XCTAssertTrue(router.attach("new-phone").isEmpty)
    }

    private func readyRouter() -> CodexBridgeRouter {
        var router = CodexBridgeRouter()
        let request = router.desktop(["id": 0, "method": "initialize"])[0].message
        _ = router.upstream(["id": request["id"]!, "result": [:]])
        return router
    }

    func testDescriptorRequiresPrivateFileAndDirectory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let descriptor = CodexBridgeDescriptor(port: 1234, token: String(repeating: "a", count: 64),
                                               pid: 1, parentPID: 2, instance: "instance")
        let file = directory.appendingPathComponent("connection.json")
        try JSONEncoder().encode(descriptor).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        XCTAssertEqual(CodexBridgeDescriptor.read(directory: directory), descriptor)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertNil(CodexBridgeDescriptor.read(directory: directory))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        XCTAssertNil(CodexBridgeDescriptor.read(directory: directory))
    }
}
