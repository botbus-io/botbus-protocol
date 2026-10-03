import Foundation
import XCTest
@testable import BotBusConnectorKit

final class StreamJSONReaderTests: XCTestCase {
    #if os(Linux)
    /// 每一轮 `claude -p` 一个 reader：读完（或进程先退出）都得把读端关掉，Linux 的 Foundation 不会替你关。
    func testFinishedReadersCloseTheirDescriptor() throws {
        let count = { (try? FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd").count) ?? -1 }
        let before = count()
        var pipes: [Pipe] = []
        for index in 0..<200 {
            let pipe = Pipe()
            pipes.append(pipe)
            let finished = expectation(description: "finished \(index)")
            let reader = StreamJSONReader(handle: pipe.fileHandleForReading)
            reader.onFinished = { _ in finished.fulfill() }
            reader.start()
            if index.isMultiple(of: 2) {
                try pipe.fileHandleForWriting.write(contentsOf: Data(#"{"type":"result","subtype":"success"}"#.utf8 + [0x0A]))
                try pipe.fileHandleForWriting.close()
            } else {
                // 进程退出先到（`terminationHandler` 调 `finish()`）。
                reader.finish()
                try pipe.fileHandleForWriting.close()
            }
            wait(for: [finished], timeout: 2)
        }
        Thread.sleep(forTimeInterval: 0.5)
        let after = count()
        // 泄漏时每次 1 个（+200）；整套测试一起跑时别的用例的后台任务还在开关描述符，留 40 的余量。
        XCTAssertLessThan(after - before, 40, "200 个 reader 之后多出了 \(after - before) 个描述符")
        XCTAssertEqual(pipes.count, 200)
    }
    #endif

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

    /// 失败诊断（协议 3.7）只看报错的 `result` 行的原文：成功的 result 与 agent 的最后一段话都不算错误原文。
    func testErrorTextComesOnlyFromAnErrorResultLine() throws {
        func read(_ lines: [String]) throws -> StreamJSONReader.Result? {
            let pipe = Pipe()
            let finished = expectation(description: "stream finished")
            let result = LockedResult()
            let reader = StreamJSONReader(handle: pipe.fileHandleForReading)
            reader.onFinished = { value in
                result.value = value
                finished.fulfill()
            }
            reader.start()
            try pipe.fileHandleForWriting.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
            try pipe.fileHandleForWriting.close()
            wait(for: [finished], timeout: 2)
            return result.value
        }
        let init_ = #"{"type":"system","subtype":"init","session_id":"s"}"#
        let failed = try read([init_, #"{"type":"result","subtype":"success","is_error":true,"result":"Not logged in · Please run /login"}"#])
        XCTAssertEqual(failed?.failed, true)
        XCTAssertEqual(failed?.errorText, "Not logged in · Please run /login")
        XCTAssertEqual(failed?.lastText, "Not logged in · Please run /login")

        let succeeded = try read([init_, #"{"type":"result","subtype":"success","result":"You've hit your limit"}"#])
        XCTAssertEqual(succeeded?.failed, false)
        XCTAssertNil(succeeded?.errorText)

        // 没等到 result 行：照样算失败，但最后一段话是 agent 说的，不是错误原文。
        let cutOff = try read([init_, #"{"type":"assistant","message":{"content":[{"type":"text","text":"usage limit reached"}]}}"#])
        XCTAssertEqual(cutOff?.failed, true)
        XCTAssertEqual(cutOff?.lastText, "usage limit reached")
        XCTAssertNil(cutOff?.errorText)
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
