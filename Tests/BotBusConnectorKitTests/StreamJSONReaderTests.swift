import Foundation
import XCTest
@testable import BotBusConnectorKit

final class StreamJSONReaderTests: XCTestCase {
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

    /// `claude -p --resume` 配了 SessionStart hook 时，hook 行排在 `init` 前面，带的是临时 id。
    func testSessionIDComesFromInitNotFromEarlierHookLines() throws {
        let pipe = Pipe()
        let finished = expectation(description: "stream finished")
        let result = LockedResult()
        let reader = StreamJSONReader(handle: pipe.fileHandleForReading)
        reader.onSessionID = { id in result.sessionID = id }
        reader.onFinished = { value in
            result.value = value
            finished.fulfill()
        }
        reader.start()
        let lines = [
            #"{"type":"system","subtype":"hook_started","session_id":"temporary-hook-id"}"#,
            #"{"type":"system","subtype":"hook_response","session_id":"temporary-hook-id"}"#,
            #"{"type":"system","subtype":"init","session_id":"resumed-session"}"#,
            #"{"type":"result","subtype":"success","result":"ok"}"#,
        ]
        try pipe.fileHandleForWriting.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
        try pipe.fileHandleForWriting.close()
        wait(for: [finished], timeout: 2)
        XCTAssertEqual(result.sessionID, "resumed-session")
        XCTAssertEqual(result.value?.sessionID, "resumed-session")
    }

    /// `--permission-prompt-tool stdio`：审批请求整行交出并带上会话 id，`result` 行另报一声（调用方据此关 stdin）。
    func testControlRequestsAreHandedOverWithTheSessionAndResultIsSignalled() throws {
        let pipe = Pipe()
        let finished = expectation(description: "stream finished")
        let resulted = expectation(description: "result seen")
        let controls = LockedControls()
        let reader = StreamJSONReader(handle: pipe.fileHandleForReading)
        reader.onControl = { line, sessionID in controls.append(line, sessionID) }
        reader.onResult = { resulted.fulfill() }
        reader.onFinished = { _ in finished.fulfill() }
        reader.start()
        let lines = [
            #"{"type":"control_request","request_id":"early","request":{"subtype":"can_use_tool"}}"#,
            #"{"type":"system","subtype":"init","session_id":"s-1"}"#,
            #"{"type":"control_request","request_id":"r-1","request":{"subtype":"can_use_tool","tool_name":"Bash"}}"#,
            #"{"type":"control_cancel_request","request_id":"r-1"}"#,
            #"{"type":"result","subtype":"success","result":"ok"}"#,
        ]
        try pipe.fileHandleForWriting.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
        try pipe.fileHandleForWriting.close()
        wait(for: [resulted, finished], timeout: 2)
        XCTAssertEqual(controls.sessionIDs, [nil, "s-1", "s-1"])
        let second = try XCTUnwrap(try JSONSerialization.jsonObject(with: controls.lines[1]) as? [String: Any])
        XCTAssertEqual(second["request_id"] as? String, "r-1")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: controls.lines[2]) as? [String: String],
                       ["type": "control_cancel_request", "request_id": "r-1"])
    }
}

private final class LockedControls: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [(line: Data, sessionID: String?)] = []

    func append(_ line: Data, _ sessionID: String?) { lock.withLock { stored.append((line, sessionID)) } }
    var lines: [Data] { lock.withLock { stored.map(\.line) } }
    var sessionIDs: [String?] { lock.withLock { stored.map(\.sessionID) } }
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
