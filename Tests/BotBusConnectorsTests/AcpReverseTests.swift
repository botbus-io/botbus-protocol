#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import XCTest
import BotBusProtocol
@testable import BotBusConnectorKit
@testable import BotBusConnectors

final class AcpReverseTests: XCTestCase {
    private var directory: String!
    private var socketPath: String!
    private var server: AcpReverseServer!
    private var store: TaskStore!
    private var hub: AcpHub!
    private var subprocesses: FakeAgentQueue!

    override func setUp() async throws {
        // sockaddr_un 的路径上限约 104 字节：临时目录用短名。socket 所在目录必须是自己的真目录（`/tmp` 是软链接、属于 root）。
        #if os(Windows)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("bb-\(UUID().uuidString.prefix(8))").path
        #else
        directory = "/tmp/bb-\(UUID().uuidString.prefix(8))"
        #endif
        socketPath = directory + "/a.sock"
        store = makeAcpStore([])
        subprocesses = FakeAgentQueue([])
        let queue = subprocesses!
        let store = self.store!
        hub = AcpHub(store: store) { spec, onHealth, onChanged in
            AcpConnector(spec: spec, store: store, launcher: queue.factory, clientVersion: "1.0",
                         onHealth: onHealth, onTasksChanged: onChanged)
        }
        await hub.sync([AcpAgentSpec(id: "my-agent", name: "My Agent", executable: nil, arguments: [],
                                     environment: [:], origin: .manifest, defaultEnabled: true)])
        server = AcpReverseServer(path: socketPath, hub: hub)
        try server.start()
    }

    override func tearDown() async throws {
        server.stop()
        await hub.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath), "停止后要删掉 socket 文件")
        try? FileManager.default.removeItem(atPath: directory)
    }

    /// 以 agent 的身份连上 socket，返回说 JSON-RPC 的一端。
    private func connectAgent(handler: JSONRPCPeer.RequestHandler? = nil) async throws -> (JSONRPCPeer, UnixSocketConnection) {
        let connection = try UnixSocketConnection.connect(path: socketPath)
        let peer = JSONRPCPeer(send: { connection.write($0) })
        await peer.setHandlers(request: handler, notification: nil)
        let (chunks, sink) = AsyncStream<Data>.makeStream()
        connection.start(onData: { sink.yield($0) }, onClose: { sink.finish() })
        Task { for await chunk in chunks { await peer.receive(chunk) } }
        return (peer, connection)
    }

    private func hello(_ peer: JSONRPCPeer, id: String = "my-agent", prompt: Bool = true,
                       cancel: Bool = true, newSession: Bool = false) async throws -> JSONValue {
        try await peer.request("_botbus/hello", params: [
            "id": .string(id), "version": 1, "pid": 1,
            "capabilities": ["prompt": .bool(prompt), "cancel": .bool(cancel), "newSession": .bool(newSession)],
        ], timeout: 2)
    }

    private let taskId = "acp:my-agent:desk-1"

    private func announce(_ peer: JSONRPCPeer) async {
        await peer.notify("_botbus/session", params: ["sessionId": "desk-1", "cwd": "/Users/me/app", "title": "电脑上的会话"])
    }

    // 下面四条查的是 POSIX 的权限位、软链接与 errno；Windows 版的同一套检查（DACL、重解析点、用户 SID）在
    // `UnixSocket+Windows.swift`，Windows 上只跑经 socket 说 JSON-RPC 的那些用例。
    #if !os(Windows)
    private func expectPOSIX(_ code: POSIXErrorCode, file: StaticString = #filePath, line: UInt = #line,
                             _ body: () throws -> Void) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual((error as? POSIXError)?.code, code, "\(error)", file: file, line: line)
        }
    }

    func testSocketIsPrivate() throws {
        var info = stat()
        XCTAssertEqual(lstat(socketPath, &info), 0)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFSOCK)
        XCTAssertEqual(info.st_mode & 0o777, 0o600, "只有本用户连得上")
        XCTAssertEqual(lstat(directory, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o700)
    }

    func testRegularFileAndSymlinkAtSocketPathAreNotReplaced() throws {
        let file = directory + "/file"
        FileManager.default.createFile(atPath: file, contents: Data("x".utf8))
        expectPOSIX(.EEXIST) { try UnixSocketServer(path: file, onConnection: { _ in }).start() }
        XCTAssertEqual(try String(contentsOfFile: file, encoding: .utf8), "x")
        let link = directory + "/link"
        XCTAssertEqual(symlink(file, link), 0)
        expectPOSIX(.EEXIST) { try UnixSocketServer(path: link, onConnection: { _ in }).start() }
        var info = stat()
        XCTAssertEqual(lstat(link, &info), 0)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFLNK)
    }

    /// 有人在听的 socket 不抢（另一个实例、别的程序）；没人听的旧文件照常替换。
    func testLiveSocketIsNotStolenButStaleOneIsReplaced() throws {
        expectPOSIX(.EADDRINUSE) { try UnixSocketServer(path: socketPath, onConnection: { _ in }).start() }
        XCTAssertNoThrow(try UnixSocketConnection.connect(path: socketPath).close(), "原来的监听还在")

        let stale = directory + "/stale.sock"
        let descriptor = try UnixSocketServer.makeSocket()
        var address = try UnixSocketServer.address(stale)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { systemBind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(bound, 0)
        close(descriptor) // 留下一个没人听的 socket 文件
        let replacement = UnixSocketServer(path: stale, onConnection: { _ in })
        XCTAssertNoThrow(try replacement.start())
        replacement.stop()
    }

    /// socket 所在目录必须是自己的真目录：软链接、别人的目录（macOS 的 `/tmp` 两样都占）都不行。
    func testSymlinkedOrForeignDirectoryIsRefused() throws {
        #if os(macOS)
        expectPOSIX(.ENOTDIR) { try UnixSocketServer(path: "/tmp/bb-\(UUID().uuidString.prefix(8)).sock", onConnection: { _ in }).start() }
        expectPOSIX(.EACCES) { try UnixSocketServer(path: "/private/tmp/bb-\(UUID().uuidString.prefix(8)).sock", onConnection: { _ in }).start() }
        #else
        // Linux 的 `/tmp` 是 root 的真目录：不是 root 跑的话就是"别人的目录"。root 跑（容器里）什么目录都是自己的，测不了这一条。
        if geteuid() != 0 {
            expectPOSIX(.EACCES) { try UnixSocketServer(path: "/tmp/bb-\(UUID().uuidString.prefix(8)).sock", onConnection: { _ in }).start() }
        }
        #endif
        let real = directory + "/real"
        try FileManager.default.createDirectory(atPath: real, withIntermediateDirectories: false)
        XCTAssertEqual(symlink(real, directory + "/ln"), 0)
        expectPOSIX(.ENOTDIR) { try UnixSocketServer(path: directory + "/ln/a.sock", onConnection: { _ in }).start() }
    }
    #endif

    func testUnknownAgentIsRejectedAndDisconnected() async throws {
        let (peer, connection) = try await connectAgent()
        let result = try await hello(peer, id: "stranger")
        XCTAssertEqual(result["accepted"], false)
        XCTAssertNotNil(result["reason"]?.stringValue, "先收到拒绝理由，再断开")
        await assertEventually { connection.isClosed }
    }

    func testSecondHelloOnSameLinkIsRejectedButKeepsTheLink() async throws {
        let (peer, connection) = try await connectAgent()
        let first = try await hello(peer)["accepted"]
        XCTAssertEqual(first, true)
        let second = try await hello(peer, id: "my-agent")["accepted"]
        XCTAssertEqual(second, false)
        await announce(peer)
        await assertEventually { await self.store.task(id: self.taskId) != nil }
        XCTAssertFalse(connection.isClosed)
    }

    func testConnectionWithoutHelloTimesOut() async throws {
        let path = directory + "/t.sock"
        let quick = AcpReverseServer(path: path, hub: hub, helloTimeout: 0.2)
        try quick.start()
        defer { quick.stop() }
        let connection = try UnixSocketConnection.connect(path: path)
        connection.start(onData: { _ in }, onClose: {})
        await assertEventually { connection.isClosed }
    }

    /// agent 没等 hello 的应答就开始报：握手通过前的通知先攒着，通过后按顺序交出去。
    func testNotificationsSentBeforeHelloReplyAreReplayed() async throws {
        let (peer, _) = try await connectAgent()
        let reply = Task { try await self.hello(peer) }
        await announce(peer)
        await peer.notify("_botbus/turn", params: ["sessionId": "desk-1", "state": "started"])
        let accepted = try await reply.value["accepted"]
        XCTAssertEqual(accepted, true)
        await assertEventually { await self.store.task(id: self.taskId)?.status == .running }
    }

    /// 超过 16 MiB 的一行被丢掉之后，后面的消息照常处理。
    func testOversizedLineIsDroppedAndLinkRecovers() async throws {
        let (peer, connection) = try await connectAgent()
        _ = try await hello(peer)
        connection.write(String(repeating: "a", count: JSONRPCPeer.maxLineBytes + 1024 * 1024))
        await announce(peer)
        await assertEventually(timeout: 10) { await self.store.task(id: self.taskId) != nil }
    }

    func testRequestsBeforeHelloAreRefused() async throws {
        let (peer, _) = try await connectAgent()
        do {
            _ = try await peer.request("session/request_permission", params: [:], timeout: 2)
            XCTFail("应当拒绝")
        } catch let error as JSONRPCError {
            XCTAssertTrue(error.message.contains("hello"))
        }
    }

    func testReportedSessionBecomesLiveTask() async throws {
        let (peer, _) = try await connectAgent()
        let accepted = try await hello(peer)["accepted"]
        XCTAssertEqual(accepted, true)
        await announce(peer)
        await assertEventually { await self.store.task(id: self.taskId)?.origin == .desktop }
        let record = await store.task(id: taskId)
        XCTAssertEqual(record?.title, "电脑上的会话")
        XCTAssertEqual(record?.controllable, true, "声明了 prompt 就能从手机续聊")
        let owner = await store.owner(of: taskId)
        XCTAssertEqual(owner, .live)
        XCTAssertEqual(store.connectors.connectors().first { $0.connectorId == "my-agent" }?.canStartTask, false)
    }

    func testTurnLifecycle() async throws {
        let (peer, _) = try await connectAgent()
        _ = try await hello(peer)
        await announce(peer)
        await peer.notify("_botbus/turn", params: ["sessionId": "desk-1", "state": "started"])
        await assertEventually { await self.store.task(id: self.taskId)?.status == .running }
        await peer.notify("session/update", params: ["sessionId": "desk-1",
            "update": ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "搞定"]]])
        await peer.notify("_botbus/turn", params: ["sessionId": "desk-1", "state": "ended", "stopReason": "end_turn"])
        await assertEventually { await self.store.task(id: self.taskId)?.status == .completed }
        let last = await store.task(id: taskId)?.lastMessage
        XCTAssertEqual(last, "搞定")
    }

    /// 终端里敲的 prompt 可以转成 `user_message_chunk` 报过来；BotBus 自己发的那句被回显时要丢掉。
    func testTerminalPromptIsRecordedButEchoIsDropped() async throws {
        // agent 在回 `session/prompt` 之前把收到的 prompt 原样回显（线上顺序：回显先到，应答后到）。
        let agent = Locked<JSONRPCPeer?>(nil)
        let (peer, _) = try await connectAgent(handler: { method, params in
            guard method == "session/prompt" else { return .null }
            let text = params["prompt"]?[0]?["text"] ?? ""
            await agent.current?.notify("session/update", params: ["sessionId": "desk-1",
                "update": ["sessionUpdate": "user_message_chunk", "content": ["type": "text", "text": text]]])
            return ["stopReason": "end_turn"]
        })
        agent.withLock { $0 = peer }
        _ = try await hello(peer)
        await announce(peer)
        await peer.notify("_botbus/turn", params: ["sessionId": "desk-1", "state": "started"])
        await peer.notify("session/update", params: ["sessionId": "desk-1",
            "update": ["sessionUpdate": "user_message_chunk", "content": ["type": "text", "text": "终端里敲的"]]])
        await peer.notify("_botbus/turn", params: ["sessionId": "desk-1", "state": "ended"])
        await assertEventually { await self.store.task(id: self.taskId)?.status == .completed }
        _ = try await hub.followUp(taskId: taskId, prompt: "手机上说的", images: [])
        await assertEventually { await self.store.task(id: self.taskId)?.status == .completed }
        let (entries, _) = try await hub.entries(taskId: taskId, limit: 40)
        XCTAssertEqual(entries.map(\.message.text), ["终端里敲的", "手机上说的"])
    }

    func testPhoneAnswersPermission() async throws {
        let (peer, _) = try await connectAgent()
        _ = try await hello(peer)
        await announce(peer)
        await peer.notify("_botbus/turn", params: ["sessionId": "desk-1", "state": "started"])
        let answer = Task {
            try await peer.request("session/request_permission", params: [
                "sessionId": "desk-1", "toolCall": ["toolCallId": "call-1", "title": "rm build", "kind": "execute"],
                "options": [["optionId": "once", "name": "允许", "kind": "allow_once"]],
            ])
        }
        await assertEventually { await self.store.task(id: self.taskId)?.status == .waitingApproval }
        _ = try await hub.approve(taskId: taskId, requestId: "call-1", decision: .allow)
        let result = try await answer.value
        XCTAssertEqual(result, ["outcome": ["outcome": "selected", "optionId": "once"]])
    }

    private func permissionRequest(_ peer: JSONRPCPeer, session: String = "desk-1",
                                   toolCallId: String = "call-1") async throws -> JSONValue {
        try await peer.request("session/request_permission", params: [
            "sessionId": .string(session), "toolCall": ["toolCallId": .string(toolCallId)],
            "options": [["optionId": "once", "name": "允许", "kind": "allow_once"]],
        ], timeout: 2)
    }

    private func expectNoAnswer(file: StaticString = #filePath, line: UInt = #line,
                                _ body: () async throws -> JSONValue) async {
        do {
            let result = try await body()
            XCTFail("应当回 -32001，实际回了 \(result)", file: file, line: line)
        } catch let error as JSONRPCError {
            XCTAssertEqual(error.code, AcpProtocol.noAnswerCode, file: file, line: line)
            XCTAssertEqual(error.message, "BotBus 没有答案", file: file, line: line)
        } catch {
            XCTFail("\(error)", file: file, line: line)
        }
    }

    /// 另一条还活着的连接在报这个会话：新连接的宣告、轮次、审批都不算数，审批回"没有答案"让它继续等终端。
    func testAnotherLiveLinkCannotClaimAnOwnedSession() async throws {
        let (first, _) = try await connectAgent()
        _ = try await hello(first)
        await announce(first)
        await assertEventually { await self.store.task(id: self.taskId) != nil }
        let (second, _) = try await connectAgent()
        _ = try await hello(second)
        await second.notify("_botbus/session", params: ["sessionId": "desk-1", "cwd": "/a", "title": "冒领"])
        await second.notify("_botbus/turn", params: ["sessionId": "desk-1", "state": "started"])
        await expectNoAnswer { try await self.permissionRequest(second) }
        let record = await store.task(id: taskId)
        XCTAssertEqual(record?.title, "电脑上的会话")
        XCTAssertNotEqual(record?.status, .running)
    }

    func testPermissionForUnannouncedSessionHasNoAnswer() async throws {
        let (peer, _) = try await connectAgent()
        _ = try await hello(peer)
        await expectNoAnswer { try await self.permissionRequest(peer, session: "never-announced") }
    }

    /// 同一会话来了新的审批，旧的那条 BotBus 就没有答案了；新的照常由手机回答。
    func testSupersededPermissionHasNoAnswer() async throws {
        let (peer, _) = try await connectAgent()
        _ = try await hello(peer)
        await announce(peer)
        await peer.notify("_botbus/turn", params: ["sessionId": "desk-1", "state": "started"])
        await assertEventually { await self.store.task(id: self.taskId)?.status == .running }
        let old = Task { try await self.permissionRequest(peer, toolCallId: "call-1") }
        await assertEventually { await self.store.task(id: self.taskId)?.pendingRequest?.id == "call-1" }
        let new = Task { try await self.permissionRequest(peer, toolCallId: "call-2") }
        await expectNoAnswer { try await old.value }
        await assertEventually { await self.store.task(id: self.taskId)?.pendingRequest?.id == "call-2" }
        _ = try await hub.approve(taskId: taskId, requestId: "call-2", decision: .allow)
        let answer = try await new.value
        XCTAssertEqual(answer, ["outcome": ["outcome": "selected", "optionId": "once"]])
    }

    func testTurnEndWithPendingPermissionHasNoAnswer() async throws {
        let (peer, _) = try await connectAgent()
        _ = try await hello(peer)
        await announce(peer)
        await peer.notify("_botbus/turn", params: ["sessionId": "desk-1", "state": "started"])
        let pending = Task { try await self.permissionRequest(peer) }
        await assertEventually { await self.store.task(id: self.taskId)?.status == .waitingApproval }
        await peer.notify("_botbus/turn", params: ["sessionId": "desk-1", "state": "ended"])
        await expectNoAnswer { try await pending.value }
        await assertEventually { await self.store.task(id: self.taskId)?.status == .completed }
    }

    /// 手机点中断是真的取消：挂着的审批回 cancelled。
    func testInterruptCancelsPendingPermission() async throws {
        let (peer, _) = try await connectAgent()
        _ = try await hello(peer)
        await announce(peer)
        await peer.notify("_botbus/turn", params: ["sessionId": "desk-1", "state": "started"])
        let pending = Task { try await self.permissionRequest(peer) }
        await assertEventually { await self.store.task(id: self.taskId)?.status == .waitingApproval }
        _ = try await hub.interrupt(taskId: taskId)
        let answer = try await pending.value
        XCTAssertEqual(answer, ["outcome": ["outcome": "cancelled"]])
    }

    /// 终端先答掉的通知比审批请求先到（请求与通知不走同一条串行路径）：别再挂到手机上。
    func testPermissionResolvedBeforeTheRequestArrives() async throws {
        let (peer, _) = try await connectAgent()
        _ = try await hello(peer)
        await announce(peer)
        await peer.notify("_botbus/turn", params: ["sessionId": "desk-1", "state": "started"])
        await assertEventually { await self.store.task(id: self.taskId)?.status == .running }
        await peer.notify("_botbus/permission_resolved", params: ["sessionId": "desk-1", "toolCallId": "call-1"])
        await expectNoAnswer { try await self.permissionRequest(peer) }
        let status = await store.task(id: taskId)?.status
        XCTAssertEqual(status, .running)
    }

    /// agent 断线立刻重连、重报同一个会话：旧连接的 detach 还没轮到也不能把新连接当冒领，所有权一直在实时这边。
    func testImmediateReconnectKeepsLiveOwnership() async throws {
        let (first, firstConnection) = try await connectAgent()
        _ = try await hello(first)
        await announce(first)
        await first.notify("_botbus/turn", params: ["sessionId": "desk-1", "state": "started"])
        await assertEventually { await self.store.task(id: self.taskId)?.status == .running }
        firstConnection.close()
        let (second, _) = try await connectAgent()
        _ = try await hello(second)
        await announce(second)
        await second.notify("_botbus/turn", params: ["sessionId": "desk-1", "state": "started"])
        await assertEventually { await self.store.task(id: self.taskId)?.status == .running }
        // 越过交还的延迟补放（`releaseRetryDelay`）。
        try await Task.sleep(for: .seconds(AcpConnector.releaseRetryDelay + 0.5))
        let owner = await store.owner(of: taskId)
        XCTAssertEqual(owner, .live)
        let status = await store.task(id: taskId)?.status
        XCTAssertEqual(status, .running)
    }

    func testSessionsPerLinkAreCapped() async throws {
        let (peer, _) = try await connectAgent()
        _ = try await hello(peer)
        let limit = AcpConnector.maxSessionsPerLink
        for index in 0...limit {
            await peer.notify("_botbus/session", params: ["sessionId": .string("s\(index)"), "cwd": "/Users/me/app"])
        }
        // 通知串行处理：这一条落地时，上面的都处理过了。
        await peer.notify("_botbus/turn", params: ["sessionId": "s0", "state": "started"])
        await assertEventually { await self.store.task(id: "acp:my-agent:s0")?.status == .running }
        let last = await store.task(id: "acp:my-agent:s\(limit - 1)")
        XCTAssertNotNil(last)
        let over = await store.task(id: "acp:my-agent:s\(limit)")
        XCTAssertNil(over, "超出上限的会话不接")
    }

    func testPermissionResolvedOnDesktop() async throws {
        let (peer, _) = try await connectAgent()
        _ = try await hello(peer)
        await announce(peer)
        await peer.notify("_botbus/turn", params: ["sessionId": "desk-1", "state": "started"])
        let answer = Task {
            try await peer.request("session/request_permission", params: [
                "sessionId": "desk-1", "toolCall": ["toolCallId": "call-1"],
                "options": [["optionId": "once", "name": "允许", "kind": "allow_once"]],
            ])
        }
        await assertEventually { await self.store.task(id: self.taskId)?.status == .waitingApproval }
        await peer.notify("_botbus/permission_resolved", params: ["sessionId": "desk-1", "toolCallId": "call-1"])
        await expectNoAnswer { try await answer.value }
        await assertEventually { await self.store.task(id: self.taskId)?.status == .running }
        do {
            _ = try await hub.approve(taskId: taskId, requestId: "call-1", decision: .allow)
            XCTFail("应当失败")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("已在电脑上处理"))
        }
    }

    func testFollowUpGoesOverTheLinkAndNeverSpawns() async throws {
        let prompts = Locked<[String]>([])
        let (peer, _) = try await connectAgent(handler: { method, params in
            if method == "session/prompt" {
                prompts.withLock { $0.append(params["prompt"]?[0]?["text"]?.stringValue ?? "") }
                return ["stopReason": "end_turn"]
            }
            return .null
        })
        _ = try await hello(peer)
        await announce(peer)
        await assertEventually { await self.store.task(id: self.taskId) != nil }
        _ = try await hub.followUp(taskId: taskId, prompt: "手机上说的", images: [])
        await assertEventually { prompts.withLock { $0 } == ["手机上说的"] }
        XCTAssertEqual(subprocesses.requests.withLock { $0.count }, 0, "反向连接在报的会话绝不再拉子进程")
    }

    func testFollowUpWithoutPromptCapability() async throws {
        let (peer, _) = try await connectAgent()
        _ = try await hello(peer, prompt: false)
        await announce(peer)
        await assertEventually { await self.store.task(id: self.taskId) != nil }
        do {
            _ = try await hub.followUp(taskId: taskId, prompt: "x", images: [])
            XCTFail("应当拒绝")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("请在电脑上继续"))
        }
    }

    func testInterruptSendsCancelOverTheLink() async throws {
        let cancelled = Locked<[String]>([])
        let (peer, _) = try await connectAgent()
        await peer.setHandlers(request: nil, notification: { method, params in
            if method == "session/cancel" { cancelled.withLock { $0.append(params["sessionId"]?.stringValue ?? "") } }
        })
        _ = try await hello(peer)
        await announce(peer)
        await peer.notify("_botbus/turn", params: ["sessionId": "desk-1", "state": "started"])
        await assertEventually { await self.store.task(id: self.taskId)?.status == .running }
        _ = try await hub.interrupt(taskId: taskId)
        await assertEventually { cancelled.withLock { $0 } == ["desk-1"] }
    }

    func testDisconnectReleasesAndInterruptsRunningTurn() async throws {
        let (peer, connection) = try await connectAgent()
        _ = try await hello(peer)
        await announce(peer)
        await peer.notify("_botbus/turn", params: ["sessionId": "desk-1", "state": "started"])
        await assertEventually { await self.store.task(id: self.taskId)?.status == .running }
        connection.close()
        await assertEventually { await self.store.task(id: self.taskId)?.status == .interrupted }
        await assertEventually { await self.store.owner(of: self.taskId) == .observer }
        let controllable = await store.task(id: taskId)?.controllable
        XCTAssertEqual(controllable, false, "没有启动命令的 agent，连接断了就不能再续聊")
    }

    /// agent 从发现结果里消失时 hub 先忘掉它的反向连接、再停连接器：socket 的关闭回调找不到它了，
    /// 反向连接在报的会话要由连接器的 `stop()` 就地收尾，不能永远卡在"运行中"的实时所有权里。
    func testRemovingAgentFinalisesReverseSessions() async throws {
        let (peer, connection) = try await connectAgent()
        _ = try await hello(peer)
        await announce(peer)
        await peer.notify("_botbus/turn", params: ["sessionId": "desk-1", "state": "started"])
        await assertEventually { await self.store.task(id: self.taskId)?.status == .running }
        await hub.sync([])
        await assertEventually { await self.store.owner(of: self.taskId) == .observer }
        await assertEventually { connection.isClosed }
    }

    func testNewSessionOverLink() async throws {
        let (peer, _) = try await connectAgent(handler: { method, _ in
            switch method {
            case "session/new": return ["sessionId": "from-phone"]
            case "session/prompt": return ["stopReason": "end_turn"]
            default: return .null
            }
        })
        _ = try await hello(peer, newSession: true)
        await assertEventually { self.store.connectors.connectors().first { $0.connectorId == "my-agent" }?.canStartTask == nil }
        let outcome = try await hub.start(connectorId: "my-agent", projectPath: FileManager.default.temporaryDirectory.path,
                                          prompt: "从手机新建", images: [])
        XCTAssertEqual(outcome.taskId, "acp:my-agent:from-phone")
        await assertEventually { await self.store.task(id: outcome.taskId)?.status == .completed }
        let origin = await store.task(id: outcome.taskId)?.origin
        XCTAssertEqual(origin, .watch)
    }

    func testConnectionCloseIsIdempotentAndReportsOnce() async throws {
        let closes = Locked(0)
        let connection = try UnixSocketConnection.connect(path: socketPath)
        connection.start(onData: { _ in }, onClose: { closes.withLock { $0 += 1 } })
        connection.close()
        connection.close()
        XCTAssertTrue(connection.isClosed)
        XCTAssertEqual(closes.withLock { $0 }, 1)
    }

    func testServerClosesUnhelloedConnectionsOnStop() async throws {
        let (_, connection) = try await connectAgent()
        server.stop()
        await assertEventually { connection.isClosed }
    }

    // MARK: - 连接器层面

    /// followUp 载入完、还没对子进程发 prompt 的空当（写 store 的几次 await）里反向连接接管了会话：
    /// 不能再对子进程发 prompt（两个进程写同一个会话），改走反向连接。
    ///
    /// 宣告等到 followUp 认领所有权之后才发（`commitTurn` 的第一步，一定在载入之后），落点只剩"空当里"或"已经发出"两种；
    /// 跑几轮，要求每轮都守住不变量，并且至少有一轮真的落进了空当（改走了反向连接）。
    func testReverseTakeoverAfterLoadReroutesFollowUp() async throws {
        let taskId = "acp:my-agent:s1"
        var rerouted = 0
        for _ in 0..<20 {
            let behavior = FakeAcpBehavior()
            behavior.capabilities = ["loadSession": true, "promptCapabilities": ["image": false]]
            behavior.onPrompt = { _, _ in
                try await Task.sleep(for: .seconds(5))
                return "end_turn"
            }
            let h = await AcpHarness.make(behavior: behavior)
            let reversePrompts = Locked(0)
            let (client, agent) = connectedPeers()
            await agent.setHandlers(request: { method, _ in
                if method == "session/prompt" { reversePrompts.withLock { $0 += 1 } }
                return ["stopReason": "end_turn"]
            }, notification: nil)
            let link = UUID()
            await h.connector.attach(link, capabilities: .init(prompt: true, cancel: true), peer: client, close: {})
            await h.store.upsert(acpRecord("my-agent", "s1"))
            let claimer = Task {
                let deadline = Date().addingTimeInterval(2)
                while await h.store.owner(of: taskId) != .live, Date() < deadline { await Task.yield() }
                await h.connector.handleAgentNotification("_botbus/session", ["sessionId": "s1", "cwd": "/Users/me/app"],
                                                          link: link)
            }
            _ = try? await h.connector.followUp(taskId: taskId, prompt: "hi", images: [])
            await claimer.value
            XCTAssertTrue(behavior.methods().contains("session/load"))
            let owned = await h.connector.reverseOwner["s1"] == link
            let subprocessTurn = await h.connector.turns["s1"] != nil
            XCTAssertNotEqual(owned, subprocessTurn, "要么被接管、要么子进程在跑这一轮，不能两个都是")
            if owned {
                await assertEventually { reversePrompts.withLock { $0 } == 1 }
                XCTAssertFalse(behavior.methods().contains("session/prompt"), "被接管的会话不能再对子进程发 prompt")
                rerouted += 1
            }
            await h.connector.stop()
        }
        XCTAssertGreaterThan(rerouted, 0, "至少有一轮宣告落在载入与发 prompt 之间")
    }

    /// 反向连接在报的会话也受对话记录份数上限约束：没在跑的可以丢，在跑的留着。
    func testIdleReverseTranscriptsAreTrimmedButRunningOnesKept() async throws {
        let spec = AcpAgentSpec(id: "my-agent", name: "My Agent", executable: nil, arguments: [], environment: [:],
                                origin: .manifest, defaultEnabled: true)
        let connector = AcpConnector(spec: spec, store: makeAcpStore(), clientVersion: "1.0")
        await connector.setTranscriptLimitForTesting(1)
        let link = UUID()
        await connector.attach(link, capabilities: .init(prompt: true), peer: JSONRPCPeer(send: { _ in }), close: {})
        func announce(_ session: String) async {
            await connector.handleAgentNotification("_botbus/session", ["sessionId": .string(session), "cwd": "/Users/me/app"],
                                                    link: link)
        }
        func say(_ session: String, _ text: String) async {
            await connector.handleAgentNotification("session/update", ["sessionId": .string(session),
                "update": ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": .string(text)]]],
                link: link)
        }
        await announce("a")
        await connector.handleAgentNotification("_botbus/turn", ["sessionId": "a", "state": "started"], link: link)
        await say("a", "在跑")
        await announce("b")
        await say("b", "闲着")
        await announce("c")
        let running = try await connector.entries(taskId: "acp:my-agent:a", limit: 40).entries.map(\.message.text)
        XCTAssertEqual(running, ["在跑"])
        let idle = try await connector.entries(taskId: "acp:my-agent:b", limit: 40).entries
        XCTAssertTrue(idle.isEmpty)
    }

    // MARK: - 解除配对：只关子进程

    /// 子进程的一轮就地记 interrupted、交还所有权；反向连接和它报的会话原样留着。
    func testStopSubprocessKeepsReverseSessionsAndLinks() async throws {
        let gate = Gate()
        addTeardownBlock { gate.open() }
        let behavior = FakeAcpBehavior()
        behavior.onPrompt = { _, _ in await gate.wait(); return "end_turn" }
        let h = await AcpHarness.make(behavior: behavior)
        let (client, _) = connectedPeers()
        let closed = Locked(false)
        let link = UUID()
        await h.connector.attach(link, capabilities: .init(prompt: true, cancel: true), peer: client,
                                 close: { closed.withLock { $0 = true } })
        await h.connector.handleAgentNotification("_botbus/session", ["sessionId": "desk-1", "cwd": "/Users/me/app"],
                                                  link: link)
        await assertEventually { await h.store.owner(of: self.taskId) == .live }
        let outcome = try await h.connector.start(projectPath: FileManager.default.temporaryDirectory.path,
                                                  prompt: "x", images: [])
        await assertEventually { await h.task(outcome.taskId)?.status == .running }

        await h.connector.stopSubprocess()

        let subprocessStatus = await h.task(outcome.taskId)?.status
        let subprocessOwner = await h.store.owner(of: outcome.taskId)
        XCTAssertEqual(subprocessStatus, .interrupted)
        XCTAssertEqual(subprocessOwner, .observer)
        let running = await h.connector.isRunning
        XCTAssertFalse(running)
        XCTAssertTrue(h.agent.terminated.current)
        let reverseOwner = await h.store.owner(of: taskId)
        XCTAssertEqual(reverseOwner, .live, "反向连接报的会话仍归它")
        let stillLinked = await h.connector.reverseOwner["desk-1"] == link
        XCTAssertTrue(stillLinked)
        XCTAssertFalse(closed.current, "反向连接不能被断开")
        await h.connector.stop()
        XCTAssertTrue(closed.current)
    }

    /// hub 一级：解除配对后经 socket 连着的 agent 不断开，它报的会话照旧在。
    func testHubStopSubprocessesKeepsSocketLinks() async throws {
        let (peer, connection) = try await connectAgent()
        _ = try await hello(peer)
        await announce(peer)
        await assertEventually { await self.store.owner(of: self.taskId) == .live }
        await hub.stopSubprocesses()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(connection.isClosed)
        let owner = await store.owner(of: taskId)
        XCTAssertEqual(owner, .live)
    }

    /// 退出之后的反向握手一律拒绝。
    func testHelloAfterShutdownIsRejected() async throws {
        await hub.shutdown()
        let (peer, _) = try await connectAgent()
        let reply = try await hello(peer)
        XCTAssertEqual(reply["accepted"], false)
    }
}

#if !os(Windows)
/// XCTestCase（NSObject）自己有个 `bind(_:to:withKeyPath:options:)`，裸写 `bind` 会解析到它身上。
private func systemBind(_ descriptor: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
    #if canImport(Darwin)
    Darwin.bind(descriptor, address, length)
    #else
    Glibc.bind(descriptor, address, length)
    #endif
}
#endif
