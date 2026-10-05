import XCTest
import BotBusProtocol
@testable import BotBusConnectorKit

final class DirectoryProbeTests: XCTestCase {
    private func probe(_ access: DirectoryProbe.Access?, timeout: TimeInterval = 1,
                       delay: TimeInterval = 0) -> DirectoryProbe {
        DirectoryProbe(timeout: timeout, access: { _ in
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            return access
        }, folder: { _ in .documents })
    }

    func testMissingAndDeniedBecomeDiagnoses() async {
        let missing = await probe(.missing).diagnose("/x")
        XCTAssertEqual(missing, .projectMissing)
        let denied = await probe(.denied).diagnose("/x")
        XCTAssertEqual(denied, .folderAccessDenied(.documents))
        // 普通文件权限（EACCES）不是系统隐私授权：只说没权限，不带受保护位置，手机不指向「文件与文件夹」。
        let unreadable = await probe(.unreadable).diagnose("/x")
        XCTAssertEqual(unreadable, FailureDiagnosis(kind: .folderAccessDenied))
        XCTAssertNil(unreadable?.folder)
        let readable = await probe(.readable).diagnose("/x")
        XCTAssertNil(readable)
        let unknown = await probe(nil).diagnose("/x")
        XCTAssertNil(unknown)
        let empty = await probe(.missing).diagnose("")
        XCTAssertNil(empty)
    }

    /// 授权弹窗开着时读目录会一直卡住：超时不下结论；同一个目录还卡着时不再起第二个。
    func testBlockedReadTimesOutAndIsNotStackedPerPath() async {
        let calls = LockedCounter()
        let blocked = DirectoryProbe(timeout: 0.05, access: { _ in
            calls.increment()
            Thread.sleep(forTimeInterval: 0.5)
            return .denied
        }, folder: { _ in .documents })
        let first = await blocked.diagnose("/slow")
        XCTAssertNil(first)
        let second = await blocked.diagnose("/slow")
        XCTAssertNil(second)
        await assertFirstReadStarted(calls)
        XCTAssertEqual(calls.value, 1)
    }

    /// 进程里各处的 `DirectoryProbe`（Claude、Hermes、分发器、TaskStore）共用一份「还卡着的目录」：
    /// 一个实例卡在授权弹窗上时，别的实例读同一个目录也不再起线程。
    func testInFlightPathsAreSharedAcrossInstances() async {
        let calls = LockedCounter()
        func blocked() -> DirectoryProbe {
            DirectoryProbe(timeout: 0.05, access: { _ in
                calls.increment()
                Thread.sleep(forTimeInterval: 0.5)
                return .denied
            }, folder: { _ in .documents })
        }
        let path = "/shared-slow-\(UUID().uuidString)"
        let first = await blocked().diagnose(path)
        XCTAssertNil(first)
        let second = await blocked().diagnose(path)
        XCTAssertNil(second)
        await assertFirstReadStarted(calls)
        XCTAssertEqual(calls.value, 1)
    }

    /// 第一次读在后台队列上跑，超时只是不再等它：线程被饿着的机器上（Windows 的托管 runner）两次 `diagnose` 都回来了，
    /// 它可能还没开始。先等它真的跑起来，再数一共起了几次（第二次在 `diagnose` 里同步地被挡掉，不会后补）。
    private func assertFirstReadStarted(_ calls: LockedCounter, file: StaticString = #filePath, line: UInt = #line) async {
        let started = await eventually(timeout: 5) { calls.value >= 1 }
        XCTAssertTrue(started, "第一次读一直没开始", file: file, line: line)
    }

    /// 等结果的任务被取消（任务重新跑起来、被删掉）：立刻回 nil，不等读完或超时。
    func testCancelledWaitReturnsAtOnce() async {
        let probe = DirectoryProbe(timeout: 5, access: { _ in
            Thread.sleep(forTimeInterval: 1)
            return .denied
        }, folder: { _ in .documents })
        let path = "/cancelled-\(UUID().uuidString)"
        let started = Date()
        let task = Task { await probe.diagnose(path) }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.8)
    }

    func testErrorsMapToAccess() {
        let eperm = NSError(domain: NSCocoaErrorDomain, code: CocoaError.Code.fileReadNoPermission.rawValue,
                            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.EPERM.rawValue))])
        XCTAssertEqual(DirectoryProbe.access(from: eperm), .denied)
        XCTAssertEqual(DirectoryProbe.access(from: NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.EPERM.rawValue))), .denied)
        XCTAssertEqual(DirectoryProbe.access(from: NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.EACCES.rawValue))), .unreadable)
        let eacces = NSError(domain: NSCocoaErrorDomain, code: CocoaError.Code.fileReadNoPermission.rawValue,
                             userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.EACCES.rawValue))])
        XCTAssertEqual(DirectoryProbe.access(from: eacces), .unreadable)
        XCTAssertEqual(DirectoryProbe.access(from: NSError(domain: NSCocoaErrorDomain, code: CocoaError.Code.fileReadNoPermission.rawValue)), .denied)
        XCTAssertEqual(DirectoryProbe.access(from: NSError(domain: NSCocoaErrorDomain, code: CocoaError.Code.fileReadNoSuchFile.rawValue)), .missing)
        XCTAssertEqual(DirectoryProbe.access(from: NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.ENOTDIR.rawValue))), .missing)
        XCTAssertNil(DirectoryProbe.access(from: NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.EIO.rawValue))))
    }

    func testFolderClassification() {
        let home = "/Users/me"
        func folder(_ path: String, network: Bool = false) -> FailureDiagnosis.Folder {
            DirectoryProbe.folder(for: path, home: home, isNetworkVolume: { _ in network })
        }
        XCTAssertEqual(folder("/Users/me/Desktop/app"), .desktop)
        XCTAssertEqual(folder("/Users/me/Documents"), .documents)
        XCTAssertEqual(folder("/Users/me/Downloads/x/y"), .downloads)
        XCTAssertEqual(folder("/Users/me/Library/Mobile Documents/com~apple~CloudDocs/p"), .iCloudDrive)
        XCTAssertEqual(folder("/Volumes/USB/p"), .removableVolume)
        XCTAssertEqual(folder("/Volumes/Share/p", network: true), .networkVolume)
        XCTAssertEqual(folder("/Users/me/DocumentsOld/p"), .other)
        XCTAssertEqual(folder("/Users/me/Projects/p"), .other)
    }

    /// 真实文件系统：临时目录读得了，不存在的目录给 projectMissing。
    func testLiveProbeOnRealDirectories() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let live = DirectoryProbe.live()
        let readable = await live.diagnose(dir.path)
        XCTAssertNil(readable)
        let missing = await live.diagnose(dir.appendingPathComponent("gone").path)
        XCTAssertEqual(missing, .projectMissing)
    }

    func testConnectorErrorCarriesDiagnosis() {
        let error: Error = ConnectorError("本机没找到 claude 可执行文件", diagnosis: .agentNotInstalled)
        XCTAssertEqual((error as? any FailureDiagnosing)?.diagnosis, .agentNotInstalled)
        XCTAssertNil((ConnectorError("x") as any FailureDiagnosing).diagnosis)
        XCTAssertEqual(ConnectorError.directory(.projectMissing, path: "/p").message, "项目目录不存在：/p")
        XCTAssertEqual(ConnectorError.directory(.folderAccessDenied(.documents), path: "/p").diagnosis,
                       .folderAccessDenied(.documents))
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
