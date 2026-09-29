#if canImport(CoreServices)
import CoreServices
import Foundation
import BotBusConnectorKit

/// 监视约定目录（spec「发现」）：目录里文件增删、改名、**原地重写**都去抖后回调一次，
/// 调用方据此重新 `AcpDiscovery.discover`。目录不存在时先建出来——它是 BotBus 自己的目录。
///
/// 用 FSEvents 而不是 kqueue 盯目录 fd：kqueue 只在目录本身增删条目（含 rename）时触发，
/// 编辑器保存、安装器 `cp new.json x.json` 这类原地重写已存在文件的写入不会触发；
/// 目录被删了重建（`rm -rf ~/.botbus` 再重装）kqueue 的 fd 挂在已经消失的 vnode 上，此后永远不会再触发。
/// FSEvents 按路径订阅：原地重写能收到（`kFSEventStreamCreateFlagFileEvents` 精确到文件级别），
/// 目录删了重建也能收到（`kFSEventStreamEventFlagRootChanged`），据此重开一条流接住后续事件。
public final class AcpManifestWatcher: @unchecked Sendable {
    private let directory: URL
    private let debounce: TimeInterval
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "io.botbus.agent.acp.manifests")
    /// 认出"当前正跑在这条队列上"：回调本身就在 `queue` 上执行，`onChange` 里如果同步调用
    /// `start()` / `stop()`，不能再 `queue.sync`（自己等自己死锁）。
    private static let queueKey = DispatchSpecificKey<ObjectIdentifier>()
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?

    public init(directory: URL = AcpDiscovery.defaultManifestDirectory, debounce: TimeInterval = 0.5,
                onChange: @escaping @Sendable () -> Void) {
        self.directory = directory
        self.debounce = debounce
        self.onChange = onChange
        queue.setSpecific(key: Self.queueKey, value: ObjectIdentifier(self))
    }

    deinit { stop() }

    public func start() {
        runOnQueue {
            guard self.stream == nil else { return }
            self.startStream()
        }
    }

    public func stop() {
        runOnQueue {
            self.pending?.cancel()
            self.pending = nil
            self.teardownStream()
        }
    }

    private func runOnQueue(_ body: () -> Void) {
        if DispatchQueue.getSpecific(key: Self.queueKey) == ObjectIdentifier(self) {
            body()
        } else {
            queue.sync(execute: body)
        }
    }

    private func startStream() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let pathsToWatch = [directory.path] as CFArray
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, acpManifestWatcherCallback, &context,
                                               pathsToWatch, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                               0.2, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    private func teardownStream() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// FSEvents 回调落在 `queue` 上（`FSEventStreamSetDispatchQueue`），直接跑，不用再切队列。
    fileprivate func handleEvent(rootChanged: Bool) {
        if rootChanged {
            // 目录被删掉又重建：路径没变但 vnode 变了，FSEvents 报 root changed；重开一条流接住后续事件
            // （`startStream()` 顺带把目录建回来，对应"重装时目录还没来得及建"的情形）。
            // 这里立刻把目录建出来是给"目录暂时不存在"兜底，不是鼓励安装器这么干：`rm -rf agents &&
            // mv staged agents` 这种两步操作，第一步的 `rm` 触发 root changed 时我们就把 `agents/`
            // 重建了，第二步 `mv` 落地时会变成 `agents/staged/`（因为目标已经是个目录）。安装器应该
            // 直接把清单文件写进已经存在的目录里，不要先删目录再整个换。
            teardownStream()
            startStream()
        }
        scheduleChange()
    }

    private func scheduleChange() {
        pending?.cancel()
        let item = DispatchWorkItem { [onChange] in onChange() }
        pending = item
        queue.asyncAfter(deadline: .now() + debounce, execute: item)
    }
}

/// C 函数指针不能捕获上下文，自身经 `FSEventStreamContext.info` 传进来。
private func acpManifestWatcherCallback(
    streamRef: ConstFSEventStreamRef,
    clientCallBackInfo: UnsafeMutableRawPointer?,
    numEvents: Int,
    eventPaths: UnsafeMutableRawPointer,
    eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let info = clientCallBackInfo else { return }
    let watcher = Unmanaged<AcpManifestWatcher>.fromOpaque(info).takeUnretainedValue()
    var rootChanged = false
    for index in 0..<numEvents
    where eventFlags[index] & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 {
        rootChanged = true
    }
    watcher.handleEvent(rootChanged: rootChanged)
}

#else
import Foundation
import BotBusConnectorKit
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// 监视约定目录（spec「发现」）：目录里文件增删、改名、**原地重写**都去抖后回调一次，
/// 调用方据此重新 `AcpDiscovery.discover`。目录不存在时先建出来——它是 BotBus 自己的目录。
///
/// 没有 FSEvents 的平台：Linux 用 inotify 盯目录（`IN_CLOSE_WRITE` / `IN_MODIFY` 收得到原地重写）；
/// 目录被删了重建（`IN_DELETE_SELF` / `IN_MOVE_SELF`）就把目录建回来、按路径重新挂 watch，接住后续事件。
/// inotify 用不了（watch 数到了 `max_user_watches` 上限、文件系统不支持、不是 Linux）就退回每 `pollInterval`
/// 比一次目录清单与各文件的 mtime / 大小 / inode。
public final class AcpManifestWatcher: @unchecked Sendable {
    /// 退回轮询时的间隔。
    public static let pollInterval: TimeInterval = 2
    private static let log = PlatformLogger(subsystem: "io.botbus.agent", category: "acp")

    private let directory: URL
    private let debounce: TimeInterval
    private let pollInterval: TimeInterval
    private let forcePolling: Bool
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "io.botbus.agent.acp.manifests")
    /// 认出"当前正跑在这条队列上"：回调本身就在 `queue` 上执行，`onChange` 里如果同步调用
    /// `start()` / `stop()`，不能再 `queue.sync`（自己等自己死锁）。
    private static let queueKey = DispatchSpecificKey<ObjectIdentifier>()
    // 以下只在 `queue` 上碰。
    private var running = false
    private var pending: DispatchWorkItem?
    #if os(Linux)
    private var notifier: DispatchSourceRead?
    private var notifyDescriptor: Int32 = -1
    private var watchDescriptor: Int32 = -1
    #endif
    private var timer: DispatchSourceTimer?
    private var snapshot: [String: FileStamp] = [:]

    public convenience init(directory: URL = AcpDiscovery.defaultManifestDirectory, debounce: TimeInterval = 0.5,
                            onChange: @escaping @Sendable () -> Void) {
        self.init(directory: directory, debounce: debounce, pollInterval: Self.pollInterval, forcePolling: false,
                  onChange: onChange)
    }

    /// 测试用：`forcePolling` 跳过 inotify，直接走轮询。
    init(directory: URL, debounce: TimeInterval, pollInterval: TimeInterval, forcePolling: Bool,
         onChange: @escaping @Sendable () -> Void) {
        self.directory = directory
        self.debounce = debounce
        self.pollInterval = pollInterval
        self.forcePolling = forcePolling
        self.onChange = onChange
        queue.setSpecific(key: Self.queueKey, value: ObjectIdentifier(self))
    }

    deinit { stop() }

    public func start() {
        runOnQueue {
            guard !self.running else { return }
            self.running = true
            self.ensureDirectory()
            #if os(Linux)
            if !self.forcePolling, self.startNotifier() { return }
            #endif
            self.startPolling()
        }
    }

    public func stop() {
        runOnQueue {
            self.running = false
            self.pending?.cancel()
            self.pending = nil
            #if os(Linux)
            self.stopNotifier()
            #endif
            self.timer?.cancel()
            self.timer = nil
            self.snapshot = [:]
        }
    }

    private func runOnQueue(_ body: () -> Void) {
        if DispatchQueue.getSpecific(key: Self.queueKey) == ObjectIdentifier(self) {
            body()
        } else {
            queue.sync(execute: body)
        }
    }

    private func ensureDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func scheduleChange() {
        guard running else { return }
        pending?.cancel()
        let item = DispatchWorkItem { [onChange] in onChange() }
        pending = item
        queue.asyncAfter(deadline: .now() + debounce, execute: item)
    }

    // MARK: - inotify

    #if os(Linux)
    /// 起 inotify 并挂上目录。失败返回 false（调用方退回轮询）。
    private func startNotifier() -> Bool {
        let descriptor = inotify_init1(Int32(IN_NONBLOCK | IN_CLOEXEC))
        guard descriptor >= 0 else {
            Self.log.notice("inotify_init1 failed (errno \(errno, privacy: .public)); polling manifests")
            return false
        }
        notifyDescriptor = descriptor
        guard addWatch() else {
            close(descriptor)
            notifyDescriptor = -1
            return false
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.readNotifications() }
        source.setCancelHandler { close(descriptor) }
        notifier = source
        source.resume()
        return true
    }

    private func stopNotifier() {
        notifier?.cancel()
        notifier = nil
        notifyDescriptor = -1
        watchDescriptor = -1
    }

    private func addWatch() -> Bool {
        let mask = UInt32(IN_CREATE | IN_DELETE | IN_MODIFY | IN_CLOSE_WRITE | IN_MOVED_FROM | IN_MOVED_TO | IN_ATTRIB
            | IN_DELETE_SELF | IN_MOVE_SELF)
        let watch = inotify_add_watch(notifyDescriptor, directory.path, mask)
        guard watch >= 0 else {
            Self.log.notice("inotify_add_watch failed (errno \(errno, privacy: .public)); polling manifests")
            return false
        }
        watchDescriptor = watch
        return true
    }

    private func readNotifications() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var changed = false
        var rootChanged = false
        while true {
            let count = buffer.withUnsafeMutableBytes { read(notifyDescriptor, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            changed = true
            // struct inotify_event { int wd; uint32_t mask; uint32_t cookie; uint32_t len; char name[len]; }
            var offset = 0
            while offset + 16 <= count {
                let (wd, mask, length) = buffer.withUnsafeBytes { raw in
                    (raw.loadUnaligned(fromByteOffset: offset, as: Int32.self),
                     raw.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self),
                     raw.loadUnaligned(fromByteOffset: offset + 12, as: UInt32.self))
                }
                offset += 16 + Int(length)
                // 旧 watch 的收尾事件（`IN_IGNORED`）在重挂之后才到，不再算一次"目录没了"。
                guard wd == watchDescriptor else { continue }
                if mask & UInt32(IN_DELETE_SELF | IN_MOVE_SELF | IN_IGNORED) != 0 { rootChanged = true }
            }
        }
        guard changed else { return }
        if rootChanged { rewatch() }
        scheduleChange()
    }

    /// 目录被删掉（或挪走）又重建：路径没变但 inode 变了，旧 watch 已经作废；把目录建回来、按路径重挂。
    /// 这里立刻把目录建出来是给"目录暂时不存在"兜底，不是鼓励安装器这么干：`rm -rf agents &&
    /// mv staged agents` 这种两步操作，第一步的 `rm` 触发时我们就把 `agents/` 重建了，第二步 `mv`
    /// 落地时会变成 `agents/staged/`。安装器应该直接把清单文件写进已经存在的目录里。
    private func rewatch() {
        if watchDescriptor >= 0 { _ = inotify_rm_watch(notifyDescriptor, watchDescriptor) }
        watchDescriptor = -1
        ensureDirectory()
        guard addWatch() else {
            stopNotifier()
            startPolling()
            return
        }
    }
    #endif

    // MARK: - 轮询

    fileprivate struct FileStamp: Equatable {
        var modified: Date?
        var size: Int?
        var inode: Int?
    }

    private func startPolling() {
        guard timer == nil else { return }
        snapshot = takeSnapshot()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        timer.setEventHandler { [weak self] in self?.poll() }
        self.timer = timer
        timer.resume()
    }

    private func poll() {
        let current = takeSnapshot()
        guard current != snapshot else { return }
        snapshot = current
        scheduleChange()
    }

    /// 目录里每个条目的 mtime / 大小 / inode。目录没了就先建回来（与 inotify 那条路一致），当成空目录。
    private func takeSnapshot() -> [String: FileStamp] {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else {
            ensureDirectory()
            return [:]
        }
        var result: [String: FileStamp] = [:]
        for name in names {
            let attributes = try? manager.attributesOfItem(atPath: directory.appendingPathComponent(name).path)
            result[name] = FileStamp(modified: attributes?[.modificationDate] as? Date,
                                     size: (attributes?[.size] as? NSNumber)?.intValue,
                                     inode: (attributes?[.systemFileNumber] as? NSNumber)?.intValue)
        }
        return result
    }
}
#endif
