import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
@testable import BotBusConnectorKit

final class PlatformProcessTests: XCTestCase {
    #if !os(Windows)
    /// 发起线程屏蔽了 SIGINT / SIGTERM（Linux 上 GCD 工作线程就是这样）时，子进程不能跟着屏蔽，
    /// 否则 `interrupt` 打不动，取消登录后假 claude 一直卡在 `read`（#28）。
    func testChildDoesNotInheritBlockedSignals() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "read line"]
        let input = Pipe()
        process.standardInput = input
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        let launched = DispatchSemaphore(value: 0)
        let failure = LockedBox<Error?>(nil)
        let thread = Thread {
            var blocked = sigset_t()
            sigemptyset(&blocked)
            sigaddset(&blocked, SIGINT)
            sigaddset(&blocked, SIGTERM)
            pthread_sigmask(SIG_BLOCK, &blocked, nil)
            do { try PlatformProcess.run(process) } catch { failure.value = error }
            launched.signal()
        }
        thread.start()
        launched.wait()
        if let error = failure.value { throw error }
        defer { try? input.fileHandleForWriting.close() }

        Thread.sleep(forTimeInterval: 0.2)
        PlatformProcess.interrupt(process.processIdentifier)
        XCTAssertEqual(exited.wait(timeout: .now() + 5), .success, "SIGINT 应该结束 sh")
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
    }
    #endif
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
