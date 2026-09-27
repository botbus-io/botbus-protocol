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
