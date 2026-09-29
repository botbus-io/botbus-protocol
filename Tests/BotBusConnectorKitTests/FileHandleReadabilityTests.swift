import Foundation
import XCTest
@testable import BotBusConnectorKit

final class FileHandleReadabilityTests: XCTestCase {
    /// 最后一段数据和写端关闭一起到：Linux 上的 `readabilityHandler` 在这种情况下收不到 EOF。
    func testDeliversDataThenEOFWhenWriterClosesRightAfterWriting() throws {
        let pipe = Pipe()
        let received = Locked(Data())
        let eof = expectation(description: "eof")
        pipe.fileHandleForReading.portableReadabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.portableReadabilityHandler = nil
                eof.fulfill()
            } else {
                received.withLock { $0.append(chunk) }
            }
        }
        try pipe.fileHandleForWriting.write(contentsOf: Data("last line\n".utf8))
        try pipe.fileHandleForWriting.close()
        wait(for: [eof], timeout: 2)
        XCTAssertEqual(String(decoding: received.current, as: UTF8.self), "last line\n")
    }

    func testClearingTheHandlerStopsCallbacks() throws {
        let pipe = Pipe()
        let calls = Locked(0)
        let first = expectation(description: "first chunk")
        pipe.fileHandleForReading.portableReadabilityHandler = { handle in
            _ = handle.availableData
            calls.withLock { $0 += 1 }
            handle.portableReadabilityHandler = nil
            first.fulfill()
        }
        try pipe.fileHandleForWriting.write(contentsOf: Data("one\n".utf8))
        wait(for: [first], timeout: 2)
        XCTAssertNil(pipe.fileHandleForReading.portableReadabilityHandler)

        try pipe.fileHandleForWriting.write(contentsOf: Data("two\n".utf8))
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertEqual(calls.current, 1, "摘掉之后不该再回调")
        try pipe.fileHandleForWriting.close()
    }

    /// `finishPortableReading()` 在别的线程上调：之后不再回调（Linux 上读线程退出时把 fd 关掉）。
    func testFinishingFromAnotherThreadStopsCallbacks() throws {
        let pipe = Pipe()
        let calls = Locked(0)
        let first = expectation(description: "first chunk")
        pipe.fileHandleForReading.portableReadabilityHandler = { handle in
            _ = handle.availableData
            if calls.withLock({ $0 += 1; return $0 }) == 1 { first.fulfill() }
        }
        try pipe.fileHandleForWriting.write(contentsOf: Data("one\n".utf8))
        wait(for: [first], timeout: 2)
        pipe.fileHandleForReading.finishPortableReading()
        XCTAssertNil(pipe.fileHandleForReading.portableReadabilityHandler)
        try pipe.fileHandleForWriting.write(contentsOf: Data("two\n".utf8))
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertEqual(calls.current, 1, "收掉之后不该再回调")
        try pipe.fileHandleForWriting.close()
    }

    #if os(Linux)
    private func openDescriptors() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd").count) ?? -1
    }

    /// Linux 的 Foundation 读到 EOF 不关 fd：连接器靠 `finishPortableReading()` 收掉读端，
    /// 不然每起一个子进程漏一个描述符，多到上千 Swift 6.4 的 `Process.run()` 会崩。
    func testFinishClosesTheDescriptorAtEOFAndWhenGivingUp() throws {
        let before = openDescriptors()
        var pipes: [Pipe] = []
        for index in 0..<200 {
            let pipe = Pipe()
            pipes.append(pipe)
            let eof = expectation(description: "eof \(index)")
            pipe.fileHandleForReading.portableReadabilityHandler = { handle in
                if handle.availableData.isEmpty {
                    handle.finishPortableReading()
                    eof.fulfill()
                }
            }
            if index.isMultiple(of: 2) {
                // 读到 EOF 时在 handler 里收。
                try pipe.fileHandleForWriting.write(contentsOf: Data("x".utf8))
                try pipe.fileHandleForWriting.close()
                wait(for: [eof], timeout: 2)
            } else {
                // EOF 不来（孙进程攥着写端）：别的线程上放弃。
                pipe.fileHandleForReading.finishPortableReading()
                try pipe.fileHandleForWriting.close()
                eof.isInverted = true
                wait(for: [eof], timeout: 0.01)
            }
        }
        // 读线程最多一个 poll 间隔后退出并关 fd；Pipe 都还活着，关掉的只能是我们。
        Thread.sleep(forTimeInterval: 0.5)
        let after = openDescriptors()
        // 泄漏时每次 1 个（+200）；整套测试一起跑时别的用例的后台任务还在开关描述符，留 40 的余量。
        XCTAssertLessThan(after - before, 40, "200 根管道之后多出了 \(after - before) 个描述符")
        XCTAssertEqual(pipes.count, 200)
    }
    #endif
}
