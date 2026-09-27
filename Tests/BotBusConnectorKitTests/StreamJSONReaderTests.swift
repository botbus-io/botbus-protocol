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
