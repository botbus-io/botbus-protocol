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

    /// `--permission-prompt-tool stdio`：审批请求整行交出并带上会话 id。不报状态的旧版本读到 `result` 就报空闲（调用方据此关 stdin）。
    func testControlRequestsAreHandedOverWithTheSessionAndResultIsSignalled() throws {
        let pipe = Pipe()
        let finished = expectation(description: "stream finished")
        let resulted = expectation(description: "result seen")
        let controls = LockedControls()
        let reader = StreamJSONReader(handle: pipe.fileHandleForReading)
        reader.onControl = { line, sessionID in controls.append(line, sessionID) }
        reader.onIdle = { resulted.fulfill() }
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

    // MARK: - 什么时候关 stdin

    /// 后台子代理：`result` 先出来，claude 的 idle 要等子代理跑完才来。中间子代理要审批，stdin 得还开着。
    func testBackgroundAgentKeepsStdinOpenUntilClaudeReportsIdle() throws {
        let stream = try IdleStream()
        stream.write([
            #"{"type":"system","subtype":"session_state_changed","state":"running"}"#,
            #"{"type":"system","subtype":"init","session_id":"s-1"}"#,
            #"{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"a1","task_type":"local_agent","description":"x"}]}"#,
            #"{"type":"result","subtype":"success","result":"started"}"#,
        ])
        stream.expectNoIdle(for: 0.3)
        stream.write([
            #"{"type":"control_request","request_id":"r-1","request":{"subtype":"can_use_tool","tool_name":"Bash"}}"#,
            #"{"type":"system","subtype":"background_tasks_changed","tasks":[]}"#,
        ])
        stream.expectNoIdle(for: 0.3)
        stream.write([
            #"{"type":"result","subtype":"success","result":"done"}"#,
            #"{"type":"system","subtype":"session_state_changed","state":"idle"}"#,
        ])
        stream.expectIdle()
    }

    /// 后台命令（`local_bash`）不拦 idle：idle 时还有后台任务就不报；命令跑完 claude 紧接着起一轮，
    /// 那一轮的审批也得送得到，它的 `result` + idle 之后才报。
    func testBackgroundCommandWaitsForTheFollowUpTurn() throws {
        let stream = try IdleStream(grace: 0.2)
        stream.write([
            #"{"type":"system","subtype":"session_state_changed","state":"running"}"#,
            #"{"type":"system","subtype":"init","session_id":"s-1"}"#,
            #"{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"b1","task_type":"local_bash","description":"sleep"}]}"#,
            #"{"type":"result","subtype":"success","result":"started"}"#,
            #"{"type":"system","subtype":"session_state_changed","state":"idle"}"#,
        ])
        stream.expectNoIdle(for: 0.4)
        // 命令跑完：后台清空，claude 马上为完成通知起新的一轮（同一块里，或宽限期内的下一块）。
        stream.write([
            #"{"type":"system","subtype":"task_notification","task_id":"b1","status":"completed"}"#,
            #"{"type":"system","subtype":"background_tasks_changed","tasks":[]}"#,
        ])
        stream.write([
            #"{"type":"system","subtype":"session_state_changed","state":"running"}"#,
            #"{"type":"system","subtype":"init","session_id":"s-1"}"#,
        ])
        stream.expectNoIdle(for: 0.5)
        stream.write([
            #"{"type":"control_request","request_id":"r-2","request":{"subtype":"can_use_tool","tool_name":"Bash"}}"#,
            #"{"type":"result","subtype":"success","result":"done"}"#,
            #"{"type":"system","subtype":"session_state_changed","state":"idle"}"#,
        ])
        stream.expectIdle()
        XCTAssertEqual(stream.sessionID, "s-1", "后面那一轮的 init 不改会话 id")
    }

    /// 空闲时后台清空、之后什么也没来（比如任务被结束、不起新的一轮）：宽限期过了照样报，进程不会一直挂着。
    func testBackgroundClearedWhileIdleSignalsAfterTheGrace() throws {
        let stream = try IdleStream(grace: 0.2)
        stream.write([
            #"{"type":"system","subtype":"session_state_changed","state":"running"}"#,
            #"{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"b1","task_type":"local_bash","description":"x"}]}"#,
            #"{"type":"result","subtype":"success","result":"started"}"#,
            #"{"type":"system","subtype":"session_state_changed","state":"idle"}"#,
        ])
        stream.expectNoIdle(for: 0.4)
        stream.write([#"{"type":"system","subtype":"background_tasks_changed","tasks":[]}"#])
        stream.expectIdle()
    }

    /// `ambient` 的后台任务（监视器之类）不算活动，不拦着关 stdin。
    func testAmbientBackgroundTasksDoNotHoldStdinOpen() throws {
        let stream = try IdleStream()
        stream.write([
            #"{"type":"system","subtype":"session_state_changed","state":"running"}"#,
            #"{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"m1","task_type":"monitor","description":"x","ambient":true}]}"#,
            #"{"type":"result","subtype":"success","result":"ok"}"#,
            #"{"type":"system","subtype":"session_state_changed","state":"idle"}"#,
        ])
        stream.expectIdle()
    }

    /// 报状态的版本只认 idle：`result` 后还没 idle（留着的结果、后台子代理）不报；一行 `result` 都没有的 idle 也不报
    /// （刚起来还没读 stdin 时的状态，这时关 stdin 会把这一轮的审批全掐掉）。
    func testIdleCountsOnlyAfterAResult() throws {
        let stream = try IdleStream()
        stream.write([
            #"{"type":"system","subtype":"session_state_changed","state":"idle"}"#,
            #"{"type":"system","subtype":"session_state_changed","state":"running"}"#,
            #"{"type":"system","subtype":"init","session_id":"s-1"}"#,
            #"{"type":"result","subtype":"success","result":"ok"}"#,
        ])
        stream.expectNoIdle(for: 0.3)
        stream.write([#"{"type":"system","subtype":"session_state_changed","state":"idle"}"#])
        stream.expectIdle()
    }
}

/// 一根开着的管道喂给 reader，按块写、看 `onIdle` 报没报。
private final class IdleStream: @unchecked Sendable {
    private let pipe = Pipe()
    private let reader: StreamJSONReader
    private let lock = NSLock()
    private var idleCount = 0
    private var storedSessionID: String?

    init(grace: TimeInterval = 0.2) throws {
        reader = StreamJSONReader(handle: pipe.fileHandleForReading, idleGrace: grace)
        reader.onIdle = { [weak self] in self?.lock.withLock { self?.idleCount += 1 } }
        reader.onSessionID = { [weak self] id in self?.lock.withLock { self?.storedSessionID = id } }
        reader.start()
    }

    deinit {
        try? pipe.fileHandleForWriting.close()
        reader.finish()
    }

    var sessionID: String? { lock.withLock { storedSessionID } }
    private var count: Int { lock.withLock { idleCount } }

    func write(_ lines: [String]) {
        try? pipe.fileHandleForWriting.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
        // 一次 write 一块：等 reader 读完这块再写下一块，免得两块并成一块。
        Thread.sleep(forTimeInterval: 0.05)
    }

    func expectNoIdle(for seconds: TimeInterval, file: StaticString = #filePath, line: UInt = #line) {
        Thread.sleep(forTimeInterval: seconds)
        XCTAssertEqual(count, 0, "不该这么早关 stdin", file: file, line: line)
    }

    func expectIdle(file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(2)
        while count == 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertEqual(count, 1, "应当报一次空闲", file: file, line: line)
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
