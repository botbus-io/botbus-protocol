import Foundation
import XCTest
@testable import BotBusConnectorParsers

final class ConnectorParserTests: XCTestCase {
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

    func testClaudeStreamKeepsSessionAndFinalTextWhileIgnoringUnknownLines() throws {
        let pipe = Pipe()
        let finished = expectation(description: "stream finished")
        let session = expectation(description: "session discovered")
        let result = LockedResult()
        let reader = StreamJSONReader(handle: pipe.fileHandleForReading)
        reader.onSessionID = { id in
            result.sessionID = id
            session.fulfill()
        }
        reader.onFinished = { value in
            result.value = value
            finished.fulfill()
        }
        reader.start()
        let lines = [
            #"{"type":"system","subtype":"init","session_id":"session-42"}"#,
            #"{"type":"unknown","future":true}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"draft"}]}}"#,
            #"{"type":"result","subtype":"success","result":"final answer"}"#,
        ]
        try pipe.fileHandleForWriting.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
        try pipe.fileHandleForWriting.close()
        wait(for: [session, finished], timeout: 2)
        XCTAssertEqual(result.sessionID, "session-42")
        XCTAssertEqual(result.value?.sessionID, "session-42")
        XCTAssertEqual(result.value?.lastText, "final answer")
        XCTAssertEqual(result.value?.failed, false)
    }
}

private final class LockedResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storedSessionID: String?
    private var storedValue: StreamJSONReader.Result?

    var sessionID: String? {
        get { lock.withLock { storedSessionID } }
        set { lock.withLock { storedSessionID = newValue } }
    }

    var value: StreamJSONReader.Result? {
        get { lock.withLock { storedValue } }
        set { lock.withLock { storedValue = newValue } }
    }
}
