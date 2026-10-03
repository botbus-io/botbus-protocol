#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(WinSDK)
import WinSDK
#endif
import Foundation
#if canImport(Network)
import Network
#endif
import XCTest
import BotBusConnectorKit
@testable import BotBusConnectorKit

final class LocalHookServerTests: XCTestCase {
    private let temporaryDirectories = Locked<[URL]>([])

    override func tearDown() {
        for url in temporaryDirectories.current { try? FileManager.default.removeItem(at: url) }
        temporaryDirectories.withLock { $0 = [] }
        super.tearDown()
    }

    /// 端口文件只许落在临时目录里：绝不碰用户真实的 ~/Library/Application Support/BotBus。
    private func makeSupportDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("botbus-hookserver-\(UUID().uuidString)", isDirectory: true)
        temporaryDirectories.withLock { $0.append(url) }
        return url
    }

    /// 端口一律由系统分配（不写死，免得撞车），并且一定在 teardown 里停掉，不把监听漏给下一个用例。
    private func startServer(supportDirectory: URL? = nil, portFileName: String? = LocalHookServer.portFileName,
                             maxBodyBytes: Int = LocalHookServer.defaultMaxBodyBytes,
                             handler: @escaping LocalHookServer.Handler) async throws
        -> (server: LocalHookServer, port: UInt16) {
        let server = LocalHookServer(supportDirectory: supportDirectory ?? makeSupportDirectory(),
                                     portFileName: portFileName, maxBodyBytes: maxBodyBytes, handler: handler)
        addTeardownBlock { await server.stop() }
        let port = try await server.start()
        return (server, port)
    }

    private func post(path: String, body: String, contentLength: Int? = nil) -> String {
        let length = contentLength ?? body.utf8.count
        return "POST \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\n"
            + "Content-Length: \(length)\r\n\r\n\(body)"
    }

    private func rawRequest(_ text: String, host: String = "127.0.0.1", port: UInt16,
                            halfClose: Bool = false, readTimeout: TimeInterval = 5,
                            connectTimeout: TimeInterval = 2) async throws -> String {
        try await rawRequest([text], host: host, port: port, halfClose: halfClose,
                             readTimeout: readTimeout, connectTimeout: connectTimeout)
    }

    /// 分几次写出去（中间停一会儿），测解析器跨多次读拼请求。
    private func rawRequest(_ pieces: [String], host: String = "127.0.0.1", port: UInt16,
                            halfClose: Bool = false, readTimeout: TimeInterval = 5,
                            connectTimeout: TimeInterval = 2) async throws -> String {
        // 阻塞的 socket 调用放到 GCD 线程上，别占协作线程池：并发用例一多，服务端自己的 Task 会被饿住。
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    try RawSocket.roundTrip(pieces, host: host, port: port, halfClose: halfClose,
                                            readTimeout: readTimeout, connectTimeout: connectTimeout)
                })
            }
        }
    }

    // MARK: -

    func testRequestedPortBindsExclusively() async throws {
        let reservation = try await startServer { _ in .now(.json("{}")) }
        let selected = reservation.port
        await reservation.server.stop()
        let first = LocalHookServer(supportDirectory: makeSupportDirectory(), requestedPort: selected) { _ in .now(.json("{}")) }
        addTeardownBlock { await first.stop() }
        let assigned = try await first.start()
        XCTAssertEqual(assigned, selected)
        let second = LocalHookServer(supportDirectory: makeSupportDirectory(), requestedPort: selected) { _ in .now(.json("{}")) }
        addTeardownBlock { await second.stop() }
        do { _ = try await second.start(); XCTFail("A second listener must not share the control port") } catch {}
        let result = try await rawRequest(post(path: "/v1/control", body: "{}"), port: selected)
        XCTAssertTrue(result.hasPrefix("HTTP/1.1 200 "))
    }

    func testBindsToLoopbackOnlyAndReportsPort() async throws {
        let started = try await startServer { _ in .now(.json(#"{"ok":true}"#)) }
        XCTAssertGreaterThan(started.port, 1024, "让系统挑一个高位端口")
        let reported = await started.server.port
        XCTAssertEqual(reported, started.port)

        let response = try await rawRequest(post(path: "/hooks/claude", body: "{}"), port: started.port)
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 200 "), response)
    }

    func testParsesPostWithContentLengthAndReturnsJSON() async throws {
        let seen = Locked<LocalHookServer.Request?>(nil)
        let started = try await startServer { request in
            seen.withLock { $0 = request }
            return .now(.json(#"{"decision":"allow"}"#))
        }

        let body = #"{"hook_event_name":"PermissionRequest","tool_name":"Bash"}"#
        let response = try await rawRequest(post(path: "/hooks/claude?v=1", body: body), port: started.port)

        let request = try XCTUnwrap(seen.current)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.target, "/hooks/claude?v=1")
        XCTAssertEqual(request.path, "/hooks/claude", "路由只看 path，query 另算")
        XCTAssertEqual(request.bodyText, body)
        XCTAssertEqual(request.header("content-length"), "\(body.utf8.count)")
        XCTAssertEqual(request.header("Content-Type"), "application/json", "头名大小写不敏感")

        XCTAssertTrue(response.hasPrefix("HTTP/1.1 200 OK\r\n"), response)
        XCTAssertTrue(response.contains("Content-Type: application/json"), response)
        XCTAssertTrue(response.contains("Content-Length: \(#"{"decision":"allow"}"#.utf8.count)"), response)
        XCTAssertTrue(response.hasSuffix(#"{"decision":"allow"}"#), response)
    }

    func testRejectsNonLoopbackOrigin() async throws {
        for address in ["127.0.0.1", "127.0.0.53", "::1", "::ffff:127.0.0.1", "localhost"] {
            XCTAssertTrue(LocalHookServer.isLoopbackAddress(address), address)
        }
        for address in ["0.0.0.0", "10.0.0.7", "192.168.1.10", "fe80::1%en0", "::", "example.com", ""] {
            XCTAssertFalse(LocalHookServer.isLoopbackAddress(address), address)
        }
        #if canImport(Network)
        XCTAssertTrue(LocalHookServer.isLoopback(.hostPort(host: .ipv4(.loopback), port: 9)))
        XCTAssertTrue(LocalHookServer.isLoopback(.hostPort(host: .ipv6(.loopback), port: 9)))
        let lan = try XCTUnwrap(IPv4Address("192.168.1.10"))
        XCTAssertFalse(LocalHookServer.isLoopback(.hostPort(host: .ipv4(lan), port: 9)))
        XCTAssertFalse(LocalHookServer.isLoopback(.unix(path: "/tmp/x.sock")))
        #endif

        // 监听绑死在 127.0.0.1 上：同属回环网段的 127.0.0.2 都连不上。
        // 要是退化成绑 0.0.0.0，这一发会立刻连通——这就是这条断言在守的东西。
        let started = try await startServer { _ in .now(.json("{}")) }
        do {
            let text = try await rawRequest(post(path: "/hooks/claude", body: "{}"), host: "127.0.0.2",
                                            port: started.port, readTimeout: 1, connectTimeout: 1)
            XCTFail("绑在 127.0.0.1 的监听不该接受 127.0.0.2 的连接，却回了：\(text)")
        } catch {
            // 预期：连不上。
        }
    }

    func testMalformedRequestGetsBadRequestNotCrash() async throws {
        let calls = Locked(0)
        let started = try await startServer { _ in
            calls.withLock { $0 += 1 }
            return .now(.json("{}"))
        }

        let garbage = try await rawRequest("GARBAGE\r\n\r\n", port: started.port)
        XCTAssertTrue(garbage.hasPrefix("HTTP/1.1 400 "), garbage)

        let noLength = try await rawRequest("POST /hooks/claude HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n", port: started.port)
        XCTAssertTrue(noLength.hasPrefix("HTTP/1.1 400 "), noLength)

        let badLength = try await rawRequest(post(path: "/hooks/claude", body: "{}", contentLength: -3), port: started.port)
        XCTAssertTrue(badLength.hasPrefix("HTTP/1.1 400 "), badLength)

        let badHeader = try await rawRequest("POST /h HTTP/1.1\r\nnot-a-header-line\r\n\r\n", port: started.port)
        XCTAssertTrue(badHeader.hasPrefix("HTTP/1.1 400 "), badHeader)

        let notPost = try await rawRequest("GET /hooks/claude HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n", port: started.port)
        XCTAssertTrue(notPost.hasPrefix("HTTP/1.1 405 "), notPost)

        // 声明了 99 字节却只发 2 个就关掉写端：读到 EOF 也只能是 400，不能挂死也不能崩。
        let truncated = try await rawRequest("POST /h HTTP/1.1\r\nContent-Length: 99\r\n\r\n{}",
                                             port: started.port, halfClose: true)
        XCTAssertTrue(truncated.hasPrefix("HTTP/1.1 400 "), truncated)

        XCTAssertEqual(calls.current, 0, "畸形请求不该进到 handler")

        let good = try await rawRequest(post(path: "/hooks/claude", body: "{}"), port: started.port)
        XCTAssertTrue(good.hasPrefix("HTTP/1.1 200 "), good)
        XCTAssertEqual(calls.current, 1, "被畸形请求折腾过之后服务还活着")
    }

    func testHandlerCanHoldResponseForApproval() async throws {
        let held = Locked<LocalHookServer.Hold?>(nil)
        let answered = Locked<String?>(nil)
        let started = try await startServer { _ in
            let hold = LocalHookServer.Hold(timeout: 30, onTimeout: { .noContent })
            held.withLock { $0 = hold }
            return .hold(hold)
        }

        let pending = Task { [self] in
            let text = try await rawRequest(post(path: "/hooks/claude", body: "{}"), port: started.port, readTimeout: 10)
            answered.withLock { $0 = text }
        }
        await assertEventually { held.current != nil }
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(answered.current, "还没人批准，HTTP 响应必须一直挂着")

        let hold = try XCTUnwrap(held.current)
        XCTAssertTrue(hold.answer(.json(#"{"decision":"allow"}"#)))
        await assertEventually { answered.current != nil }
        let response = try XCTUnwrap(answered.current)
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 200 "), response)
        XCTAssertTrue(response.hasSuffix(#"{"decision":"allow"}"#), response)

        XCTAssertFalse(hold.answer(.noContent), "回答、超时、断线抢的是同一个出口，第二个必须静默丢弃")
        _ = await pending.result
    }

    /// 超时是硬上限，而且和"被回答"共用同一个出口：晚到的回答只能被丢掉，不能二次 resume。
    func testHeldResponseTimesOutWithFallback() async throws {
        let held = Locked<LocalHookServer.Hold?>(nil)
        let started = try await startServer { _ in
            let hold = LocalHookServer.Hold(timeout: 0.2, onTimeout: { .json(#"{"decision":"ask"}"#) })
            held.withLock { $0 = hold }
            return .hold(hold)
        }

        let begin = Date()
        let response = try await rawRequest(post(path: "/hooks/claude", body: "{}"), port: started.port)
        XCTAssertLessThan(Date().timeIntervalSince(begin), 3, "超时必须真的把响应放出来")
        XCTAssertTrue(response.hasSuffix(#"{"decision":"ask"}"#), response)

        let hold = try XCTUnwrap(held.current)
        XCTAssertFalse(hold.answer(.noContent), "超时之后来的批准已经晚了")
    }

    func testWritesPortFileAndRemovesItOnStop() async throws {
        let directory = makeSupportDirectory()
        let started = try await startServer(supportDirectory: directory) { _ in .now(.json("{}")) }
        let portFile = directory.appendingPathComponent("agent.json")
        XCTAssertEqual(started.server.portFileURL, portFile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: portFile.path))

        let payload = try JSONSerialization.jsonObject(with: Data(contentsOf: portFile)) as? [String: Any]
        XCTAssertEqual(payload?["port"] as? Int, Int(started.port))

        await started.server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: portFile.path))
        let port = await started.server.port
        XCTAssertNil(port)
        // teardown 还会再 stop 一次：必须幂等。
    }

    // MARK: - 并发、上限与断线（两个平台的监听实现都要过）

    func testServesConcurrentRequests() async throws {
        let started = try await startServer { request in
            try? await Task.sleep(for: .milliseconds(50))
            return .now(.json(request.body))
        }
        let responses = try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for index in 0..<24 {
                group.addTask { [self] in
                    let body = #"{"n":\#(index)}"#
                    return (index, try await rawRequest(post(path: "/hooks/claude", body: body), port: started.port))
                }
            }
            var collected: [Int: String] = [:]
            for try await (index, text) in group { collected[index] = text }
            return collected
        }
        XCTAssertEqual(responses.count, 24)
        for (index, text) in responses {
            XCTAssertTrue(text.hasPrefix("HTTP/1.1 200 "), text)
            XCTAssertTrue(text.hasSuffix(#"{"n":\#(index)}"#), "每条连接拿回自己的响应：\(text)")
        }
    }

    func testHeldRequestDoesNotBlockOtherRequests() async throws {
        let held = Locked<LocalHookServer.Hold?>(nil)
        let started = try await startServer { request in
            guard request.path == "/hold" else { return .now(.json(#"{"quick":true}"#)) }
            let hold = LocalHookServer.Hold(timeout: 30)
            held.withLock { $0 = hold }
            return .hold(hold)
        }
        let pending = Task { [self] in
            try await rawRequest(post(path: "/hold", body: "{}"), port: started.port, readTimeout: 10)
        }
        await assertEventually { held.current != nil }

        let quick = try await rawRequest(post(path: "/quick", body: "{}"), port: started.port)
        XCTAssertTrue(quick.hasSuffix(#"{"quick":true}"#), "挂着的请求不能卡住别的连接：\(quick)")

        XCTAssertTrue(try XCTUnwrap(held.current).answer(.json(#"{"late":true}"#)))
        let late = try await pending.value
        XCTAssertTrue(late.hasSuffix(#"{"late":true}"#), late)
    }

    func testRequestSplitAcrossReadsIsReassembled() async throws {
        let seen = Locked<String?>(nil)
        let started = try await startServer { request in
            seen.withLock { $0 = request.bodyText }
            return .now(.json("{}"))
        }
        let body = #"{"hook_event_name":"Stop"}"#
        let head = "POST /hooks/claude HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: \(body.utf8.count)\r\n"
        let response = try await rawRequest([head, "\r\n" + body.prefix(5), String(body.dropFirst(5))],
                                            port: started.port)
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 200 "), response)
        XCTAssertEqual(seen.current, body)
    }

    func testRejectsOversizedBody() async throws {
        let calls = Locked(0)
        let started = try await startServer(maxBodyBytes: 64) { _ in
            calls.withLock { $0 += 1 }
            return .now(.json("{}"))
        }
        // 声明超限就回 413，不等 body 发完；多发的那点 body 也不能让对端被 reset 掉、读不到响应。
        let oversized = try await rawRequest(post(path: "/hooks/claude", body: String(repeating: "x", count: 65)),
                                             port: started.port)
        XCTAssertTrue(oversized.hasPrefix("HTTP/1.1 413 "), oversized)
        let declaredOnly = try await rawRequest("POST /h HTTP/1.1\r\nContent-Length: 999999999\r\n\r\n", port: started.port)
        XCTAssertTrue(declaredOnly.hasPrefix("HTTP/1.1 413 "), declaredOnly)

        let atLimit = try await rawRequest(post(path: "/hooks/claude", body: String(repeating: "x", count: 64)),
                                           port: started.port)
        XCTAssertTrue(atLimit.hasPrefix("HTTP/1.1 200 "), atLimit)
        XCTAssertEqual(calls.current, 1)
    }

    func testOversizedHeadIsRejected() async throws {
        let started = try await startServer { _ in .now(.json("{}")) }
        // 头超过 16 KiB 还没见到空行就回 431，不再往下读。
        let filler = String(repeating: "a", count: 20 * 1024)
        let response = try await rawRequest("POST /h HTTP/1.1\r\nX-Filler: \(filler)", port: started.port)
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 431 "), String(response.prefix(80)))
    }

    /// 挂起期间 hook 脚本被杀（连接整个关掉）：挂着的响应要被放掉，后到的批准只能落空。
    func testClientDisconnectAbandonsHold() async throws {
        let held = Locked<LocalHookServer.Hold?>(nil)
        let started = try await startServer { _ in
            let hold = LocalHookServer.Hold(timeout: 30)
            held.withLock { $0 = hold }
            return .hold(hold)
        }
        try await Task.detached { try RawSocket.sendAndClose(self.post(path: "/hooks/claude", body: "{}"), port: started.port) }.value
        await assertEventually { held.current != nil }
        let hold = try XCTUnwrap(held.current)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(hold.answer(.json("{}")), "对端已经走了，挂着的响应应该已经被放掉")
    }

    /// `stop()` 把挂着的连接一起掐掉：对端立刻读到 EOF，而不是等满 hold 的超时。
    func testStopReleasesHeldConnections() async throws {
        let held = Locked<LocalHookServer.Hold?>(nil)
        let started = try await startServer { _ in
            let hold = LocalHookServer.Hold(timeout: 30)
            held.withLock { $0 = hold }
            return .hold(hold)
        }
        let pending = Task { [self] in
            try await rawRequest(post(path: "/hooks/claude", body: "{}"), port: started.port, readTimeout: 10)
        }
        await assertEventually { held.current != nil }
        let begin = Date()
        await started.server.stop()
        let text = try await pending.value
        XCTAssertLessThan(Date().timeIntervalSince(begin), 3)
        XCTAssertFalse(text.hasPrefix("HTTP/1.1 200 "), text)
        XCTAssertFalse(try XCTUnwrap(held.current).answer(.json("{}")))
    }

    func testStartTwiceThrowsAndRestartWorks() async throws {
        let started = try await startServer { _ in .now(.json("{}")) }
        do {
            _ = try await started.server.start()
            XCTFail("已经在监听，第二次 start 必须报错")
        } catch let failure as LocalHookServer.Failure {
            XCTAssertEqual(failure, .alreadyRunning)
        }
        await started.server.stop()
        let again = try await started.server.start()
        let response = try await rawRequest(post(path: "/h", body: "{}"), port: again)
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 200 "), response)
    }

    /// 服务过请求之后（连接由我们先关，TIME_WAIT 留在监听端口上）用同一个端口重开：
    /// 工具服务器重启时会带上一轮的 `requestedPort`，不能因为 TIME_WAIT 绑不上。
    func testRequestedPortCanBeReboundAfterServing() async throws {
        let first = try await startServer { _ in .now(.json("{}")) }
        for _ in 0..<3 {
            let response = try await rawRequest(post(path: "/h", body: "{}"), port: first.port)
            XCTAssertTrue(response.hasPrefix("HTTP/1.1 200 "), response)
        }
        await first.server.stop()
        let second = LocalHookServer(supportDirectory: makeSupportDirectory(), requestedPort: first.port) { _ in .now(.json("{}")) }
        addTeardownBlock { await second.stop() }
        let assigned = try await second.start()
        XCTAssertEqual(assigned, first.port)
        let response = try await rawRequest(post(path: "/h", body: "{}"), port: assigned)
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 200 "), response)
    }

    func testNoPortFileWhenNameIsNil() async throws {
        let directory = makeSupportDirectory()
        let started = try await startServer(supportDirectory: directory, portFileName: nil) { _ in .now(.json("{}")) }
        XCTAssertNil(started.server.portFileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("agent.json").path))
    }

    func testNoContentResponseHasNoBodyOrLength() async throws {
        let started = try await startServer { _ in .now(.noContent) }
        let response = try await rawRequest(post(path: "/h", body: "{}"), port: started.port)
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 204 No Content\r\n"), response)
        XCTAssertFalse(response.contains("Content-Length"), response)
        XCTAssertTrue(response.hasSuffix("Connection: close\r\n\r\n"), response)
    }
}

/// 极简 HTTP 客户端。用裸 socket 而不是 URLSession：这些用例里有一半发的就是畸形请求，
/// URLSession 会替我们"纠正"掉，测不到解析器。
#if !os(Windows)
private enum RawSocket {
    struct Failure: Error, Sendable { let message: String }

    static func roundTrip(_ pieces: [String], host: String, port: UInt16, halfClose: Bool,
                          readTimeout: TimeInterval, connectTimeout: TimeInterval) throws -> String {
        let descriptor = try connect(host: host, port: port, readTimeout: readTimeout, connectTimeout: connectTimeout)
        defer { close(descriptor) }

        for (index, piece) in pieces.enumerated() {
            if index > 0 { usleep(100_000) }
            try send(piece, on: descriptor)
        }
        // 只关写端：服务端读到 EOF，我们这边还能把响应读回来。
        if halfClose { shutdown(descriptor, Int32(SHUT_WR)) }
        return readAll(descriptor)
    }

    /// 发完请求就整个关掉，不等响应：模拟挂起期间 hook 脚本被杀掉。
    static func sendAndClose(_ request: String, port: UInt16) throws {
        let descriptor = try connect(host: "127.0.0.1", port: port, readTimeout: 5, connectTimeout: 2)
        defer { close(descriptor) }
        try send(request, on: descriptor)
    }

    private static func connect(host: String, port: UInt16, readTimeout: TimeInterval,
                                connectTimeout: TimeInterval) throws -> Int32 {
        #if canImport(Darwin)
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let descriptor = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard descriptor >= 0 else { throw Failure(message: "socket() 失败") }
        #if canImport(Darwin)
        // 服务端先关了我们还在写，别让 SIGPIPE 把测试进程打死（Linux 上写用 MSG_NOSIGNAL）。
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif

        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr(host)

        // 非阻塞 connect + poll：没人在听的地址不会回 RST 而是石沉大海，
        // 阻塞版要等系统默认的 75 秒才罢休，用例不能这么耗着。
        let flags = fcntl(descriptor, F_GETFL, 0)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        let started = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Self.systemConnect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if started != 0 {
            guard errno == EINPROGRESS else {
                close(descriptor)
                throw Failure(message: "connect(\(host):\(port)) 失败 errno=\(errno)")
            }
            var watch = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            guard poll(&watch, 1, Int32(connectTimeout * 1000)) > 0 else {
                close(descriptor)
                throw Failure(message: "connect(\(host):\(port)) 超时")
            }
            var failure: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &failure, &size)
            guard failure == 0 else {
                close(descriptor)
                throw Failure(message: "connect(\(host):\(port)) 被拒 errno=\(failure)")
            }
        }
        _ = fcntl(descriptor, F_SETFL, flags)

        var timeout = timeval(tv_sec: Int(readTimeout), tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return descriptor
    }

    private static func systemConnect(_ descriptor: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
        #if canImport(Darwin)
        Darwin.connect(descriptor, address, length)
        #else
        Glibc.connect(descriptor, address, length)
        #endif
    }

    private static func systemSend(_ descriptor: Int32, _ bytes: UnsafeRawPointer, _ count: Int, _ flags: Int32) -> Int {
        #if canImport(Darwin)
        Darwin.send(descriptor, bytes, count, flags)
        #else
        Glibc.send(descriptor, bytes, count, flags)
        #endif
    }

    private static func send(_ text: String, on descriptor: Int32) throws {
        let bytes = Array(text.utf8)
        #if canImport(Darwin)
        let flags: Int32 = 0
        #else
        let flags = Int32(MSG_NOSIGNAL)
        #endif
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBufferPointer { buffer in
                systemSend(descriptor, buffer.baseAddress! + offset, bytes.count - offset, flags)
            }
            guard written > 0 else { throw Failure(message: "send() 失败 errno=\(errno)") }
            offset += written
        }
    }

    private static func readAll(_ descriptor: Int32) -> String {
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count <= 0 { break }
            response.append(contentsOf: buffer[0..<count])
        }
        return String(decoding: response, as: UTF8.self)
    }
}
#endif

#if os(Windows)
/// Windows 版的极简 HTTP 客户端（Winsock）。语义同上：发什么就是什么，不替调用方"纠正"请求。
private enum RawSocket {
    struct Failure: Error, Sendable { let message: String }

    static let invalid = ~SOCKET(0)

    static func roundTrip(_ pieces: [String], host: String, port: UInt16, halfClose: Bool,
                          readTimeout: TimeInterval, connectTimeout: TimeInterval) throws -> String {
        let descriptor = try connect(host: host, port: port, readTimeout: readTimeout, connectTimeout: connectTimeout)
        defer { closesocket(descriptor) }
        for (index, piece) in pieces.enumerated() {
            if index > 0 { Thread.sleep(forTimeInterval: 0.1) }
            try send(piece, on: descriptor)
        }
        if halfClose { shutdown(descriptor, SD_SEND) }
        return readAll(descriptor)
    }

    static func sendAndClose(_ request: String, port: UInt16) throws {
        let descriptor = try connect(host: "127.0.0.1", port: port, readTimeout: 5, connectTimeout: 2)
        defer { closesocket(descriptor) }
        try send(request, on: descriptor)
    }

    private static func connect(host: String, port: UInt16, readTimeout: TimeInterval,
                                connectTimeout: TimeInterval) throws -> SOCKET {
        var data = WSADATA()
        _ = WSAStartup(0x0202, &data)
        let descriptor = socket(AF_INET, SOCK_STREAM, Int32(IPPROTO_TCP.rawValue))
        guard descriptor != invalid else { throw Failure(message: "socket() 失败") }
        var address = sockaddr_in()
        address.sin_family = ADDRESS_FAMILY(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
            closesocket(descriptor)
            throw Failure(message: "认不出地址 \(host)")
        }
        // 非阻塞 connect + select：连一个没人在听、也不回 RST 的地址时不用干等。
        var nonBlocking: u_long = 1
        ioctlsocket(descriptor, FIONBIO_, &nonBlocking)
        let started = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                WinSDK.connect(descriptor, $0, Int32(MemoryLayout<sockaddr_in>.size))
            }
        }
        if started != 0 {
            guard WSAGetLastError() == WSAEWOULDBLOCK else {
                closesocket(descriptor)
                throw Failure(message: "connect(\(host):\(port)) 失败 WSA \(WSAGetLastError())")
            }
            var watch = WSAPOLLFD(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            let ready = WSAPoll(&watch, 1, Int32(connectTimeout * 1000))
            guard ready > 0, watch.revents & Int16(POLLOUT) != 0 else {
                closesocket(descriptor)
                throw Failure(message: "connect(\(host):\(port)) 超时或被拒")
            }
        }
        nonBlocking = 0
        ioctlsocket(descriptor, FIONBIO_, &nonBlocking)
        var milliseconds = DWORD(readTimeout * 1000)
        _ = withUnsafePointer(to: &milliseconds) {
            $0.withMemoryRebound(to: CChar.self, capacity: 4) {
                setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, $0, Int32(MemoryLayout<DWORD>.size))
            }
        }
        return descriptor
    }

    /// `FIONBIO` 是个带类型转换的宏，没导进来：`_IOW('f', 126, u_long)`。
    private static let FIONBIO_ = Int32(bitPattern: 0x8004_667E)

    private static func send(_ text: String, on descriptor: SOCKET) throws {
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBufferPointer { buffer in
                buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: bytes.count) {
                    WinSDK.send(descriptor, $0 + offset, Int32(bytes.count - offset), 0)
                }
            }
            guard written > 0 else { throw Failure(message: "send() 失败 WSA \(WSAGetLastError())") }
            offset += Int(written)
        }
    }

    private static func readAll(_ descriptor: SOCKET) -> String {
        var response = Data()
        var buffer = [CChar](repeating: 0, count: 4096)
        while true {
            let count = recv(descriptor, &buffer, Int32(buffer.count), 0)
            if count <= 0 { break }
            response.append(contentsOf: buffer[0..<Int(count)].map { UInt8(bitPattern: $0) })
        }
        return String(decoding: response, as: UTF8.self)
    }
}
#endif
