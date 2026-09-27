import Foundation
import XCTest
@testable import BotBusConnectorKit
@testable import BotBusConnectors

final class CodexJSONTests: XCTestCase {
    func testCodexRequestKeepsStringIdAndDoesNotLogParams() throws {
        let line = Data(#"{"id":"5","method":"item/commandExecution/requestApproval","params":{"command":"private command"}}"#.utf8)
        guard case .request(let id, let method, let params)? = CodexIncomingMessage(line: line) else {
            return XCTFail("expected an app-server request")
        }
        XCTAssertEqual(id, .text("5"))
        XCTAssertEqual(method, "item/commandExecution/requestApproval")
        XCTAssertEqual(params["command"]?.stringValue, "private command")
        XCTAssertFalse(CodexIncomingMessage(line: line)!.logDescription.contains("private command"))

        let reply = try CodexOutgoingMessage.response(id: id, result: .null).encoded()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: reply) as? [String: Any])
        XCTAssertEqual(object["id"] as? String, "5")
        XCTAssertNil(object["jsonrpc"])
    }

    func testCodexUnknownNotificationAndNumericResponse() throws {
        let unknown = Data(#"{"method":"new/upstream/event","params":{"newField":42}}"#.utf8)
        guard case .notification(let method, let params)? = CodexIncomingMessage(line: unknown) else {
            return XCTFail("unknown method should remain a notification")
        }
        XCTAssertEqual(method, "new/upstream/event")
        XCTAssertEqual(params["newField"]?.intValue, 42)

        let response = Data(#"{"id":5,"result":{"ok":true}}"#.utf8)
        guard case .response(let id, let result)? = CodexIncomingMessage(line: response) else {
            return XCTFail("expected response")
        }
        XCTAssertEqual(id, .number(5))
        XCTAssertEqual(result["ok"]?.boolValue, true)
    }
}
