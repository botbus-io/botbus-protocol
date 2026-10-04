import Foundation
import XCTest
@testable import BotBusConnectorKit

final class UnixSocketTests: XCTestCase {
    private var directory: String!

    override func setUp() {
        super.setUp()
        // sockaddr_un 的路径上限约 104 字节：用 /tmp 下的短名（所在目录必须是自己的真目录）。
        #if os(Windows)
        // Windows 的 AF_UNIX 路径上限 108 字节：用户临时目录下的短名。
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("bb-\(UUID().uuidString.prefix(8))").path
        #else
        directory = "/tmp/bb-\(UUID().uuidString.prefix(8))"
        #endif
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: directory)
        super.tearDown()
    }

    /// 对端写完最后一行紧接着整个关掉：数据和关闭一起到，这边既要收到数据，也要收尾（`onClose`）。
    /// Linux 的 libdispatch 在这种情况下只通知一次，不在同一轮里读出 EOF 连接就永远不收尾。
    func testServerSeesDataAndCloseWhenClientClosesRightAfterWriting() async throws {
        let received = Locked<[Int: String]>([:])
        let closed = Locked(Set<Int>())
        let counter = Locked(0)
        let server = UnixSocketServer(path: directory + "/s.sock") { connection in
            let index = counter.withLock { value -> Int in
                defer { value += 1 }
                return value
            }
            connection.start(onData: { data in
                received.withLock { $0[index, default: ""] += String(decoding: data, as: UTF8.self) }
            }, onClose: {
                _ = closed.withLock { $0.insert(index) }
            })
        }
        try server.start()
        defer { server.stop() }

        for accepted in 1...20 {
            let client = try UnixSocketConnection.connect(path: directory + "/s.sock")
            client.write("hello")
            client.closeAfterPendingWrites()
            // 等服务端接走这个连接再连下一个：监听队列只有 16（macOS 上排满了 `connect` 直接 ECONNREFUSED），
            // 机器一忙 accept 跟不上，一口气连 20 个就会被拒。
            await assertEventually(timeout: 5) { counter.current == accepted }
        }
        await assertEventually(timeout: 5) { closed.current.count == 20 }
        XCTAssertEqual(Set(received.current.values), ["hello\n"])
    }

    func testClientSeesDataAndCloseWhenServerClosesRightAfterWriting() async throws {
        let server = UnixSocketServer(path: directory + "/s.sock") { connection in
            connection.start(onData: { _ in }, onClose: {})
            connection.write("bye")
            connection.closeAfterPendingWrites()
        }
        try server.start()
        defer { server.stop() }

        for _ in 0..<20 {
            let text = Locked("")
            let client = try UnixSocketConnection.connect(path: directory + "/s.sock")
            client.start(onData: { data in text.withLock { $0 += String(decoding: data, as: UTF8.self) } }, onClose: {})
            await assertEventually(timeout: 5) { client.isClosed }
            XCTAssertEqual(text.current, "bye\n")
        }
    }
}
