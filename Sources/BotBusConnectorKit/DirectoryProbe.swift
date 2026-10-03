import Foundation
import BotBusProtocol

/// 读一次项目目录，认出「不在了」与「没权限」（协议 3.7 的 `projectMissing` / `folderAccessDenied`）。
///
/// agent 由 BotBus 启动、沿用 BotBus 的权限（macOS 的「文件与文件夹」授权跟着起进程的 app 走），所以 BotBus 自己读不了
/// 的目录，它起的 agent 也读不了。macOS 上授权还没决定时，读目录会弹出系统授权框并一直卡到有人点：在后台线程上读、
/// 最多等 `timeout`，等不到（或等的任务被取消）就不下结论（交给已有的系统弹窗检测）；同一个目录还卡着时不再起第二个读取，
/// 免得线程越堆越多——这份登记是整个进程共用的，Claude、Hermes、分发器、TaskStore 各自的实例都算。
public struct DirectoryProbe: Sendable {
    public enum Access: Sendable, Equatable {
        case readable
        /// 不在了，或不是目录。
        case missing
        /// 被系统的隐私授权挡住（macOS「文件与文件夹」，`EPERM`）：诊断带上目录算哪一类受保护位置。
        case denied
        /// 普通的文件权限读不了（`EACCES`）：只说没权限，不带受保护位置——系统设置里的开关帮不上忙。
        case unreadable
    }

    public static let defaultTimeout: TimeInterval = 2

    /// 还卡在读取里的目录，整个进程一份。
    private static let inFlight = InFlightPaths()

    private let timeout: TimeInterval
    private let access: @Sendable (String) -> Access?
    private let folder: @Sendable (String) -> FailureDiagnosis.Folder

    /// - Parameters:
    ///   - access: 同步读一次目录；nil = 判断不了。可能阻塞，只在后台线程上调用。
    ///   - folder: 被拒时这个目录算哪一类受保护位置。
    public init(timeout: TimeInterval = DirectoryProbe.defaultTimeout,
                access: @escaping @Sendable (String) -> Access?,
                folder: @escaping @Sendable (String) -> FailureDiagnosis.Folder) {
        self.timeout = timeout
        self.access = access
        self.folder = folder
    }

    /// 真实文件系统。
    public static func live(home: String = NSHomeDirectory(), timeout: TimeInterval = defaultTimeout) -> DirectoryProbe {
        DirectoryProbe(timeout: timeout, access: { path in
            do {
                _ = try FileManager.default.contentsOfDirectory(atPath: path)
                return .readable
            } catch {
                return Self.access(from: error)
            }
        }, folder: { path in
            Self.folder(for: path, home: home, isNetworkVolume: { volume in
                let values = try? URL(fileURLWithPath: volume).resourceValues(forKeys: [.volumeIsLocalKey])
                return values?.volumeIsLocal == false
            })
        })
    }

    /// 读不了就给诊断：不存在（或不是目录）→ `projectMissing`，被系统授权挡住 → 带受保护位置的 `folderAccessDenied`，
    /// 普通权限读不了 → 不带位置的 `folderAccessDenied`；读得了、判断不了、超时或被取消 → nil。
    public func diagnose(_ path: String) async -> FailureDiagnosis? {
        guard !path.isEmpty, !Task.isCancelled, Self.inFlight.begin(path) else { return nil }
        let box = OneShotContinuation<Access?>()
        let access = self.access
        DispatchQueue.global(qos: .utility).async {
            let result = access(path)
            Self.inFlight.end(path)
            box.resume(returning: result)
        }
        let timeout = self.timeout
        let timer = Task {
            try? await Task.sleep(for: .seconds(timeout))
            box.resume(returning: nil)
        }
        let result = await withTaskCancellationHandler {
            defer { timer.cancel() }
            return (try? await box.value()) ?? nil
        } onCancel: {
            timer.cancel()
            box.resume(returning: nil)
        }
        switch result {
        case .missing: return .projectMissing
        case .denied: return .folderAccessDenied(folder(path))
        case .unreadable: return FailureDiagnosis(kind: .folderAccessDenied)
        case .readable, nil: return nil
        }
    }

    /// `FileManager` 的错误 → 读目录的结论。Cocoa 错误码与底层 POSIX 码都认。
    /// `EPERM` 是 macOS 隐私授权挡住的样子，`EACCES` 是普通的文件权限；Cocoa 只说「没权限」、底下没有 `EACCES` 时按前者算。
    static func access(from error: Error) -> Access? {
        let error = error as NSError
        var posix: [Int] = []
        if error.domain == NSPOSIXErrorDomain { posix.append(error.code) }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            posix.append(underlying.code)
        }
        let cocoa = error.domain == NSCocoaErrorDomain ? error.code : nil
        let missing = [POSIXErrorCode.ENOENT, .ENOTDIR].map { Int($0.rawValue) }
        if posix.contains(Int(POSIXErrorCode.EPERM.rawValue)) { return .denied }
        if posix.contains(Int(POSIXErrorCode.EACCES.rawValue)) { return .unreadable }
        if cocoa == CocoaError.Code.fileReadNoPermission.rawValue { return .denied }
        if posix.contains(where: missing.contains) || cocoa == CocoaError.Code.fileReadNoSuchFile.rawValue
            || cocoa == CocoaError.Code.fileNoSuchFile.rawValue { return .missing }
        return nil
    }

    /// 目录落在哪类受保护位置（macOS「文件与文件夹」里的开关名对应的那几类）。
    public static func folder(for path: String, home: String,
                              isNetworkVolume: (String) -> Bool) -> FailureDiagnosis.Folder {
        let path = (path as NSString).standardizingPath
        let home = (home as NSString).standardizingPath
        func under(_ base: String) -> Bool { path == base || path.hasPrefix(base + "/") }
        if under(home + "/Desktop") { return .desktop }
        if under(home + "/Documents") { return .documents }
        if under(home + "/Downloads") { return .downloads }
        if under(home + "/Library/Mobile Documents") { return .iCloudDrive }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        if parts.count >= 2, parts[0] == "Volumes" {
            return isNetworkVolume("/Volumes/\(parts[1])") ? .networkVolume : .removableVolume
        }
        return .other
    }
}

/// 还卡在读取里的目录。
private final class InFlightPaths: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: Set<String> = []

    func begin(_ path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return paths.insert(path).inserted
    }

    func end(_ path: String) {
        lock.lock()
        paths.remove(path)
        lock.unlock()
    }
}
