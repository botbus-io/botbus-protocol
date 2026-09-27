import Darwin
import Foundation
import Network
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
    private func startServer(supportDirectory: URL? = nil,
                             handler: @escaping LocalHookServer.Handler) async throws
        -> (server: LocalHookServer, port: UInt16) {
        let server = LocalHookServer(supportDirectory: supportDirectory ?? makeSupportDirectory(), handler: handler)
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
        try await Task.detached(priority: .userInitiated) {
            try RawSocket.roundTrip(text, host: host, port: port, halfClose: halfClose,
                                    readTimeout: readTimeout, connectTimeout: connectTimeout)
        }.value
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
        XCTAssertTrue(LocalHookServer.isLoopback(.hostPort(host: .ipv4(.loopback), port: 9)))
        XCTAssertTrue(LocalHookServer.isLoopback(.hostPort(host: .ipv6(.loopback), port: 9)))
        let lan = try XCTUnwrap(IPv4Address("192.168.1.10"))
        XCTAssertFalse(LocalHookServer.isLoopback(.hostPort(host: .ipv4(lan), port: 9)))
        XCTAssertFalse(LocalHookServer.isLoopback(.unix(path: "/tmp/x.sock")))

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
}

/// 极简 HTTP 客户端。用裸 socket 而不是 URLSession：这些用例里有一半发的就是畸形请求，
/// URLSession 会替我们"纠正"掉，测不到解析器。
private enum RawSocket {
    struct Failure: Error, Sendable { let message: String }

    static func roundTrip(_ request: String, host: String, port: UInt16, halfClose: Bool,
                          readTimeout: TimeInterval, connectTimeout: TimeInterval) throws -> String {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure(message: "socket() 失败") }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr(host)

        // 非阻塞 connect + poll：没人在听的地址不会回 RST 而是石沉大海，
        // 阻塞版要等系统默认的 75 秒才罢休，用例不能这么耗着。
        let flags = fcntl(descriptor, F_GETFL, 0)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        let started = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if started != 0 {
            guard errno == EINPROGRESS else { throw Failure(message: "connect(\(host):\(port)) 失败 errno=\(errno)") }
            var watch = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            guard poll(&watch, 1, Int32(connectTimeout * 1000)) > 0 else {
                throw Failure(message: "connect(\(host):\(port)) 超时")
            }
            var failure: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &failure, &size)
            guard failure == 0 else { throw Failure(message: "connect(\(host):\(port)) 被拒 errno=\(failure)") }
        }
        _ = fcntl(descriptor, F_SETFL, flags)

        var timeout = timeval(tv_sec: Int(readTimeout), tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let bytes = Array(request.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBufferPointer { buffer in
                write(descriptor, buffer.baseAddress! + offset, bytes.count - offset)
            }
            guard written > 0 else { throw Failure(message: "write() 失败 errno=\(errno)") }
            offset += written
        }
        // 只关写端：服务端读到 EOF，我们这边还能把响应读回来。
        if halfClose { shutdown(descriptor, SHUT_WR) }

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
