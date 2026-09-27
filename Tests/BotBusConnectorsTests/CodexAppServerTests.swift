import Foundation
import XCTest
@testable import BotBusConnectorKit
@testable import BotBusConnectors
import BotBusProtocol

// MARK: - 假的进程与时钟

/// 内存里的假 `codex app-server`：测试往 stdout 里塞字节（可以是半行），从 stdin 收整行。
/// **不起任何真实进程、不建线程、不发网络请求。**
final class FakeCodexProcess: CodexProcessHandle, @unchecked Sendable {
    /// 写进 stdin 的原始字节，按写入顺序。
    let written = Locked<[Data]>([])
    /// 看到 `initialize` 请求就自动回一条应答（大多数测试不关心握手细节）。
    let autoInitialize = Locked(true)
    let terminated = Locked(false)
    let exit: CodexProcessExit

    private var iterator: AsyncStream<Data>.Iterator
    private let continuation: AsyncStream<Data>.Continuation

    init(exit: CodexProcessExit = CodexProcessExit(status: 0)) {
        self.exit = exit
        var captured: AsyncStream<Data>.Continuation!
        let stream = AsyncStream<Data>(bufferingPolicy: .unbounded) { captured = $0 }
        continuation = captured
        iterator = stream.makeAsyncIterator()
    }

    // MARK: CodexProcessHandle

    func readStdout() async throws -> Data? {
        await iterator.next()
    }

    func writeStdin(_ data: Data) async throws {
        written.withLock { $0.append(data) }
        guard autoInitialize.current else { return }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["method"] as? String == "initialize", let id = object["id"] else { return }
        let reply: [String: Any] = ["id": id, "result": ["userAgent": "fake", "codexHome": "/tmp/fake",
                                                         "platformOs": "macos", "platformFamily": "unix"]]
        deliver(object: reply)
    }

    func terminate() {
        terminated.withLock { $0 = true }
        closeStdout()
    }

    func waitForExit() async -> CodexProcessExit { exit }

    // MARK: 测试控制

    /// 原样投递一段字节。**可以是半行**，分帧是被测代码的事。
    func deliverRaw(_ text: String) { continuation.yield(Data(text.utf8)) }

    /// 投递一个完整的 JSON 对象加换行。
    func deliver(object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        continuation.yield(data + Data("\n".utf8))
    }

    /// 模拟子进程死掉：stdout 关了。
    func closeStdout() { continuation.finish() }

    var objects: [[String: Any]] {
        written.current.compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    func requests(method: String) -> [[String: Any]] {
        objects.filter { $0["method"] as? String == method }
    }
}

/// 每次 `launch()` 造一个新的假进程，全留着给测试查。
final class FakeCodexLauncher: CodexProcessLauncher, @unchecked Sendable {
    private let state = Locked<[FakeCodexProcess]>([])
    private let failures = Locked(0)

    /// 接下来 `n` 次 `launch()` 抛错。
    func failNextLaunches(_ n: Int) { failures.withLock { $0 = n } }

    var processes: [FakeCodexProcess] { state.current }
    var count: Int { state.current.count }
    var latest: FakeCodexProcess? { state.current.last }

    func launch() throws -> any CodexProcessHandle {
        let shouldFail = failures.withLock { pending -> Bool in
            guard pending > 0 else { return false }
            pending -= 1
            return true
        }
        if shouldFail { throw ConnectorError("假的启动失败") }
        let process = FakeCodexProcess()
        state.withLock { $0.append(process) }
        return process
    }
}

/// 假时钟：记下每次被要求睡多久，并挂在那里，直到测试明确 `release(_:)` 放行。
///
/// 两个讲究：
/// - 记账与挂号在**同一把锁里**完成，所以只要 `requested` 里出现了某个时长，对应的等待者
///   就一定已经挂上号了，测试可以安全地 `release` 它，不会有"记了但还没挂上"的空窗。
/// - `release(_:)` 只放行**当前**在等的那些，不会变成"从此不再睡"。
///   否则重启后新进程的 `initialize` 会瞬间超时，被测代码看起来像是在疯狂重启。
/// - 支持取消：请求拿到应答后定时器会被 cancel，不能让它们一直堆着。
final class FakeSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var durations: [TimeInterval] = []
    private var waiters: [(seconds: TimeInterval, box: OneShotContinuation<Void>)] = []

    /// 被要求睡过的时长，按顺序。
    var requested: [TimeInterval] { lock.withLock { durations } }

    var sleep: CodexSleeper { { [weak self] seconds in await self?.wait(seconds) } }

    /// 放行当前在等的：`seconds` 为 nil 时全放，否则只放这个时长的。
    func release(_ seconds: TimeInterval? = nil) {
        let taken: [OneShotContinuation<Void>] = lock.withLock {
            var kept: [(seconds: TimeInterval, box: OneShotContinuation<Void>)] = []
            var released: [OneShotContinuation<Void>] = []
            for waiter in waiters {
                if seconds == nil || waiter.seconds == seconds {
                    released.append(waiter.box)
                } else {
                    kept.append(waiter)
                }
            }
            waiters = kept
            return released
        }
        for box in taken { box.resume(returning: ()) }
    }

    private func wait(_ seconds: TimeInterval) async {
        let box = OneShotContinuation<Void>()
        lock.withLock {
            durations.append(seconds)
            waiters.append((seconds, box))
        }
        await withTaskCancellationHandler {
            _ = try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                box.install(continuation)
            }
        } onCancel: {
            box.resume(returning: ())
        }
    }
}

// MARK: - 测试

final class CodexAppServerTests: XCTestCase {
    private func makeServer(launcher: FakeCodexLauncher,
                            sleeper: FakeSleeper) -> CodexAppServer {
        CodexAppServer(launcher: launcher,
                       configuration: CodexAppServer.Configuration(clientName: "BotBusTest",
                                                                   clientVersion: "0.0.0"),
                       sleeper: sleeper.sleep)
    }

    /// 起来之后等握手跑完（第一条写出去的是 initialize，紧跟一条 initialized 通知）。
    private func startAndWaitForHandshake(_ server: CodexAppServer,
                                          _ launcher: FakeCodexLauncher) async -> FakeCodexProcess {
        await server.start()
        var process: FakeCodexProcess?
        await assertEventually {
            guard let latest = launcher.latest else { return false }
            process = latest
            return latest.requests(method: "initialized").count == 1
        }
        return process ?? FakeCodexProcess()
    }

    // MARK: 握手与分帧

    func testInitializeHandshakeIsSentFirst() async {
        let launcher = FakeCodexLauncher()
        let sleeper = FakeSleeper()
        let server = makeServer(launcher: launcher, sleeper: sleeper)
        await server.start()

        // 紧跟着就发一条业务请求：它必须排在 initialize 后面。
        let follower = Task { try await server.request("thread/start", params: ["cwd": "/tmp/project"]) }
        await assertEventually {
            guard let process = launcher.latest else { return false }
            return process.requests(method: "thread/start").count == 1
        }
        let process = try! XCTUnwrap(launcher.latest)
        let methods = process.objects.compactMap { $0["method"] as? String }
        XCTAssertEqual(methods.first, "initialize", "第一行必须是 initialize")
        XCTAssertEqual(methods, ["initialize", "initialized", "thread/start"])

        // initialize 的参数里带 clientInfo。
        let initialize = try! XCTUnwrap(process.requests(method: "initialize").first)
        let clientInfo = (initialize["params"] as? [String: Any])?["clientInfo"] as? [String: Any]
        XCTAssertEqual(clientInfo?["name"] as? String, "BotBusTest")

        follower.cancel()
        await server.stop()
    }

    func testFramesAreNewlineDelimitedWithoutContentLength() async {
        let launcher = FakeCodexLauncher()
        let sleeper = FakeSleeper()
        let server = makeServer(launcher: launcher, sleeper: sleeper)
        let process = await startAndWaitForHandshake(server, launcher)

        for data in process.written.current {
            let text = String(decoding: data, as: UTF8.self)
            XCTAssertTrue(text.hasSuffix("\n"), "每一帧都以换行符结尾")
            XCTAssertEqual(text.filter { $0 == "\n" }.count, 1, "一帧就是一行，中间不能有换行符")
            XCTAssertFalse(text.lowercased().contains("content-length"), "不能有 Content-Length 头")
        }
        for object in process.objects {
            XCTAssertNil(object["jsonrpc"], "app-server 的帧不带 jsonrpc 字段")
        }
        await server.stop()
    }

    func testPartialLineIsBufferedUntilNewline() async {
        let launcher = FakeCodexLauncher()
        let sleeper = FakeSleeper()
        let server = makeServer(launcher: launcher, sleeper: sleeper)
        let process = await startAndWaitForHandshake(server, launcher)
        let events = await server.events()
        let seen = Locked<[String]>([])
        let collector = Task {
            for await event in events {
                if case .notification(let notification) = event {
                    seen.withLock { $0.append(notification.method) }
                }
            }
        }

        // 一条通知被切成三段，中间那段还卡在 JSON 字符串里。
        process.deliverRaw("{\"method\":\"turn/start")
        process.deliverRaw("ed\",\"params\":{\"threadId\":\"t1\",\"turn\":{\"id\":\"r1\"}")
        // 收尾的同时再塞两条完整的行：一次 read 给回好几行也要全部处理。
        process.deliverRaw("}}\n{\"method\":\"thread/started\",\"params\":{\"thread\":{\"id\":\"t1\"}}}\n{\"method\":\"item/agentMessage/delta\",\"params\":{\"threadId\":\"t1\",\"itemId\":\"i1\",\"delta\":\"hi\"}}\n")

        await assertEventually { seen.current.count == 3 }
        XCTAssertEqual(seen.current, ["turn/started", "thread/started", "item/agentMessage/delta"])
        collector.cancel()
        await server.stop()
    }

    // MARK: 请求应答对号

    func testRequestIdMatchingResolvesTheRightCaller() async {
        let launcher = FakeCodexLauncher()
        let sleeper = FakeSleeper()
        let server = makeServer(launcher: launcher, sleeper: sleeper)
        let process = await startAndWaitForHandshake(server, launcher)

        let first = Task { try await server.request("thread/list") }
        let second = Task { try await server.request("model/list") }
        await assertEventually {
            process.requests(method: "thread/list").count == 1 && process.requests(method: "model/list").count == 1
        }
        let firstId = try! XCTUnwrap(process.requests(method: "thread/list").first?["id"])
        let secondId = try! XCTUnwrap(process.requests(method: "model/list").first?["id"])
        XCTAssertNotEqual("\(firstId)", "\(secondId)")

        // 故意反序应答：谁的 id 就是谁的结果。
        process.deliver(object: ["id": secondId, "result": ["who": "model"]])
        process.deliver(object: ["id": firstId, "result": ["who": "thread"]])

        let firstResult = try! await first.value
        let secondResult = try! await second.value
        XCTAssertEqual(firstResult["who"]?.stringValue, "thread")
        XCTAssertEqual(secondResult["who"]?.stringValue, "model")
        await server.stop()
    }

    func testServerRequestIdCanBeStringOrInteger() async {
        let launcher = FakeCodexLauncher()
        let sleeper = FakeSleeper()
        let server = makeServer(launcher: launcher, sleeper: sleeper)
        let process = await startAndWaitForHandshake(server, launcher)

        process.deliver(object: ["id": "req-abc", "method": "item/permissions/requestApproval",
                                 "params": ["threadId": "t1", "turnId": "r1", "itemId": "i1",
                                            "cwd": "/tmp", "permissions": []]])
        process.deliver(object: ["id": 77, "method": "item/tool/requestUserInput",
                                 "params": ["threadId": "t1", "turnId": "r1", "itemId": "i2",
                                            "isBlocking": true, "questions": []]])
        await assertEventually { await server.pendingServerRequests().count == 2 }

        let pending = await server.pendingServerRequests()
        XCTAssertEqual(pending.map(\.key), ["$req-abc", "#77"])
        XCTAssertEqual(pending.map(\.kind), [.permissions, .userInput])

        let before = process.written.current.count
        try! await server.respond(to: "$req-abc", result: ["permissions": []])
        try! await server.respond(to: "#77", result: ["answers": [:]])
        let replies = Array(process.objects.dropFirst(before))
        XCTAssertEqual(replies.count, 2)
        // id 必须原样回去：字符串还是字符串，整数还是整数。
        XCTAssertEqual(replies[0]["id"] as? String, "req-abc")
        XCTAssertEqual(replies[1]["id"] as? Int, 77)
        let empty = await server.pendingServerRequests()
        XCTAssertTrue(empty.isEmpty)
        await server.stop()
    }

    func testRequestTimesOutWithAHardBound() async {
        let launcher = FakeCodexLauncher()
        let sleeper = FakeSleeper()
        let server = makeServer(launcher: launcher, sleeper: sleeper)
        let process = await startAndWaitForHandshake(server, launcher)

        let pending = Task { try await server.request("thread/list", timeout: 9) }
        await assertEventually { sleeper.requested.contains(9) }
        sleeper.release(9) // 时间到：超时把自己塞进同一个 OneShotContinuation。

        do {
            _ = try await pending.value
            XCTFail("应该超时")
        } catch let error as CodexAppServerError {
            XCTAssertEqual(error.reason, .timedOut)
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
        // 迟到的应答撞上一个已经关了的盒子：不许崩，也不许有人收到第二份结果。
        if let id = process.requests(method: "thread/list").first?["id"] {
            process.deliver(object: ["id": id, "result": [:]])
        }
        try? await Task.sleep(for: .milliseconds(30))
        await server.stop()
    }

    // MARK: 服务端请求不自动回

    func testServerRequestBecomesPendingNotAutoReply() async {
        let launcher = FakeCodexLauncher()
        let sleeper = FakeSleeper()
        let server = makeServer(launcher: launcher, sleeper: sleeper)
        let process = await startAndWaitForHandshake(server, launcher)
        let events = await server.events()
        let surfaced = Locked<[CodexServerRequest]>([])
        let collector = Task {
            for await event in events {
                if case .serverRequest(let request) = event { surfaced.withLock { $0.append(request) } }
            }
        }
        let before = process.written.current.count

        process.deliver(object: ["id": 5, "method": "item/commandExecution/requestApproval",
                                 "params": ["threadId": "t1", "turnId": "r1", "itemId": "i1",
                                            "command": "rm -rf /", "cwd": "/tmp", "startedAtMs": 1]])

        await assertEventually { surfaced.current.count == 1 }
        XCTAssertEqual(surfaced.current.first?.kind, .commandExecution)
        XCTAssertEqual(surfaced.current.first?.threadId, "t1")
        XCTAssertEqual(surfaced.current.first?.params["command"]?.stringValue, "rm -rf /")
        XCTAssertEqual(surfaced.current.first?.kind.pendingRequestKind, .command)

        let pending = await server.pendingServerRequests()
        XCTAssertEqual(pending.map(\.key), ["#5"])
        // 关键：一个字节都没往回写。
        XCTAssertEqual(process.written.current.count, before, "审批请求绝不能被自动回复")

        // 只有上层主动回，才写回去。
        try! await server.respond(to: "#5", result: ["decision": "accept"])
        XCTAssertEqual(process.written.current.count, before + 1)
        let reply = try! XCTUnwrap(process.objects.last)
        XCTAssertEqual(reply["id"] as? Int, 5)
        XCTAssertNil(reply["method"], "应答里不该有 method")
        XCTAssertNil(reply["jsonrpc"])
        collector.cancel()
        await server.stop()
    }

    func testFileChangeApprovalCarriesDiffCachedFromItemStarted() async {
        let launcher = FakeCodexLauncher()
        let sleeper = FakeSleeper()
        let server = makeServer(launcher: launcher, sleeper: sleeper)
        let process = await startAndWaitForHandshake(server, launcher)

        // diff 只在 item/started 里出现过一次。
        process.deliver(object: ["method": "item/started",
                                 "params": ["threadId": "t1", "turnId": "r1",
                                            "item": ["id": "i9", "type": "fileChange", "status": "inProgress",
                                                     "changes": [["path": "/tmp/a.swift", "kind": "update",
                                                                  "diff": "@@ -1 +1 @@\n-a\n+b\n"]]]]])
        // 审批请求本身不带 diff。
        process.deliver(object: ["id": 11, "method": "item/fileChange/requestApproval",
                                 "params": ["threadId": "t1", "turnId": "r1", "itemId": "i9", "startedAtMs": 2]])

        await assertEventually { await server.pendingServerRequest(key: "#11") != nil }
        let found = await server.pendingServerRequest(key: "#11")
        let request = try! XCTUnwrap(found)
        XCTAssertNil(request.params["changes"], "审批请求本身确实不带 diff")
        XCTAssertEqual(request.fileChanges.count, 1)
        XCTAssertEqual(request.fileChanges.first?.path, "/tmp/a.swift")
        XCTAssertEqual(request.fileChanges.first?.diff, "@@ -1 +1 @@\n-a\n+b\n")
        await server.stop()
    }

    func testPendingServerRequestsAreDroppedWhenTheTurnEnds() async {
        let launcher = FakeCodexLauncher()
        let sleeper = FakeSleeper()
        let server = makeServer(launcher: launcher, sleeper: sleeper)
        let process = await startAndWaitForHandshake(server, launcher)

        process.deliver(object: ["id": 3, "method": "item/commandExecution/requestApproval",
                                 "params": ["threadId": "t1", "turnId": "r1", "itemId": "i1", "startedAtMs": 1]])
        await assertEventually { await server.pendingServerRequests().count == 1 }

        process.deliver(object: ["method": "turn/completed",
                                 "params": ["threadId": "t1",
                                            "turn": ["id": "r1", "status": "interrupted"]]])
        await assertEventually { await server.pendingServerRequests().isEmpty }
        // 丢掉不等于回复：还是一个字节都没写回去。
        XCTAssertTrue(process.objects.allSatisfy { $0["id"] as? Int != 3 })
        await server.stop()
    }

    // MARK: 通知映射

    func testNotificationsMapToStatusTransitions() async {
        let launcher = FakeCodexLauncher()
        let sleeper = FakeSleeper()
        let server = makeServer(launcher: launcher, sleeper: sleeper)
        let process = await startAndWaitForHandshake(server, launcher)
        let events = await server.events()
        let seen = Locked<[CodexNotification]>([])
        let collector = Task {
            for await event in events {
                if case .notification(let notification) = event { seen.withLock { $0.append(notification) } }
            }
        }

        process.deliver(object: ["method": "turn/started",
                                 "params": ["threadId": "t1", "turn": ["id": "r1"]]])
        process.deliver(object: ["method": "turn/completed",
                                 "params": ["threadId": "t1", "turn": ["id": "r1", "status": "failed",
                                                                       "error": ["message": "boom"]]]])
        process.deliver(object: ["method": "thread/status/changed",
                                 "params": ["threadId": "t1", "status": ["type": "idle"]]])
        process.deliver(object: ["method": "item/agentMessage/delta",
                                 "params": ["threadId": "t1", "itemId": "i1", "delta": "部分"]])
        process.deliver(object: ["method": "thread/tokenUsage/updated", "params": ["threadId": "t1"]])

        await assertEventually { seen.current.count == 5 }
        let notifications = seen.current
        XCTAssertEqual(notifications[0], .turnStarted(threadId: "t1", turnId: "r1"))
        XCTAssertEqual(notifications[0].statusTransition, .running)
        XCTAssertEqual(notifications[1].statusTransition, .failed)
        if case .turnCompleted(_, _, _, let error) = notifications[1] {
            XCTAssertEqual(error, "boom")
        } else {
            XCTFail("第二条应该是 turn/completed")
        }
        XCTAssertEqual(notifications[2].statusTransition, .idle)
        XCTAssertNil(notifications[3].statusTransition)
        XCTAssertEqual(notifications[3], .agentMessageDelta(threadId: "t1", itemId: "i1", delta: "部分"))
        XCTAssertEqual(notifications[4].method, "thread/tokenUsage/updated")
        XCTAssertNil(notifications[4].statusTransition, "认不得的通知不产生状态跃迁，也不是错误")

        // completed / interrupted 的另外两条映射。
        XCTAssertEqual(CodexNotification(method: "turn/completed",
                                         params: ["threadId": "t1", "turn": ["id": "r1", "status": "completed"]])
            .statusTransition, .completed)
        XCTAssertEqual(CodexNotification(method: "turn/completed",
                                         params: ["threadId": "t1", "turn": ["id": "r1", "status": "interrupted"]])
            .statusTransition, .interrupted)
        XCTAssertEqual(CodexNotification(method: "thread/status/changed",
                                         params: ["threadId": "t1", "status": ["type": "active"]])
            .statusTransition, .running)
        collector.cancel()
        await server.stop()
    }

    // MARK: 退出、重启与 resume

    func testSubprocessExitSchedulesRestartAfterThreeSeconds() async {
        let launcher = FakeCodexLauncher()
        let sleeper = FakeSleeper()
        let server = makeServer(launcher: launcher, sleeper: sleeper)
        let process = await startAndWaitForHandshake(server, launcher)
        let events = await server.events()
        let restartDelays = Locked<[TimeInterval?]>([])
        let collector = Task {
            for await event in events {
                if case .exited(_, let restartingIn) = event { restartDelays.withLock { $0.append(restartingIn) } }
            }
        }

        process.closeStdout() // 子进程死了

        await assertEventually { restartDelays.current == [3] }
        // 还没到点：不许偷跑。
        XCTAssertEqual(launcher.count, 1)
        await assertEventually { sleeper.requested.contains(CodexAppServer.restartDelay) }
        XCTAssertEqual(launcher.count, 1, "3 秒没过就不能重启")

        sleeper.release(CodexAppServer.restartDelay)
        await assertEventually { launcher.count == 2 }
        await assertEventually { await server.processGeneration == 2 }
        collector.cancel()
        await server.stop()
    }

    func testRestartResumesPreviouslyControlledRunningThreads() async {
        let launcher = FakeCodexLauncher()
        let sleeper = FakeSleeper()
        let server = makeServer(launcher: launcher, sleeper: sleeper)
        let first = await startAndWaitForHandshake(server, launcher)

        // t1：本机发过 turn/start（= 本机在驱动），而且还在跑 → 重启后要 resume。
        let started = Task { try await server.request("turn/start", params: ["threadId": "t1", "input": []]) }
        await assertEventually { first.requests(method: "turn/start").count == 1 }
        if let id = first.requests(method: "turn/start").first?["id"] {
            first.deliver(object: ["id": id, "result": ["turn": ["id": "r1", "status": "inProgress"]]])
        }
        _ = try? await started.value
        first.deliver(object: ["method": "turn/started", "params": ["threadId": "t1", "turn": ["id": "r1"]]])

        // t2：在跑，但本机没驱动过（桌面上自己跑的）→ 不该被 resume。
        first.deliver(object: ["method": "turn/started", "params": ["threadId": "t2", "turn": ["id": "r2"]]])
        // t3：本机驱动过，但已经跑完了 → 也不该被 resume。
        let interrupted = Task { try await server.request("turn/interrupt", params: ["threadId": "t3", "turnId": "r3"]) }
        await assertEventually { first.requests(method: "turn/interrupt").count == 1 }
        if let id = first.requests(method: "turn/interrupt").first?["id"] {
            first.deliver(object: ["id": id, "result": [:]])
        }
        _ = try? await interrupted.value
        first.deliver(object: ["method": "turn/completed",
                               "params": ["threadId": "t3", "turn": ["id": "r3", "status": "completed"]]])

        await assertEventually { await server.runningControlledThreads() == ["t1"] }

        first.closeStdout()
        await assertEventually { sleeper.requested.contains(CodexAppServer.restartDelay) }
        sleeper.release(CodexAppServer.restartDelay)
        await assertEventually { launcher.count == 2 }

        let second = try! XCTUnwrap(launcher.latest)
        await assertEventually { second.requests(method: "thread/resume").count == 1 }
        let resumes = second.requests(method: "thread/resume").compactMap {
            ($0["params"] as? [String: Any])?["threadId"] as? String
        }
        XCTAssertEqual(resumes, ["t1"], "只 resume 之前由本机控制且还在跑的线程")
        // resume 必须排在握手之后。
        let methods = second.objects.compactMap { $0["method"] as? String }
        XCTAssertEqual(Array(methods.prefix(2)), ["initialize", "initialized"])
        await server.stop()
    }

    func testStopDoesNotRestartAndFailsInFlightRequests() async {
        let launcher = FakeCodexLauncher()
        let sleeper = FakeSleeper()
        let server = makeServer(launcher: launcher, sleeper: sleeper)
        let process = await startAndWaitForHandshake(server, launcher)

        let pending = Task { try await server.request("thread/list") }
        await assertEventually { process.requests(method: "thread/list").count == 1 }
        await server.stop()

        do {
            _ = try await pending.value
            XCTFail("stop() 之后在途请求必须失败")
        } catch let error as CodexAppServerError {
            XCTAssertEqual(error.reason, .notRunning)
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
        XCTAssertTrue(process.terminated.current)

        sleeper.release()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(launcher.count, 1, "stop() 之后不许重启")
        let alive = await server.isProcessAlive
        XCTAssertFalse(alive)
    }

    func testLaunchFailureRetriesOnTheSameSchedule() async {
        let launcher = FakeCodexLauncher()
        let sleeper = FakeSleeper()
        launcher.failNextLaunches(1)
        let server = makeServer(launcher: launcher, sleeper: sleeper)
        await server.start()

        await assertEventually { sleeper.requested.contains(CodexAppServer.restartDelay) }
        XCTAssertEqual(launcher.count, 0)
        sleeper.release(CodexAppServer.restartDelay)
        await assertEventually { launcher.count == 1 }
        await server.stop()
    }

    // MARK: 请求 id 的编解码

    func testRequestIdKeyRoundTrips() {
        XCTAssertEqual(CodexRequestID.number(12).key, "#12")
        XCTAssertEqual(CodexRequestID.text("abc").key, "$abc")
        XCTAssertEqual(CodexRequestID(key: "#12"), .number(12))
        XCTAssertEqual(CodexRequestID(key: "$abc"), .text("abc"))
        // 整数 5 与字符串 "5" 不能撞车。
        XCTAssertNotEqual(CodexRequestID.number(5).key, CodexRequestID.text("5").key)
        XCTAssertNil(CodexRequestID(key: "5"))
    }
}
