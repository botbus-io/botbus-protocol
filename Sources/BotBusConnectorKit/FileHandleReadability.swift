import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(WinSDK)
import WinSDK
#endif

extension FileHandle {
    /// 与 `readabilityHandler` 同一个语义：可读（包括读到 EOF）时调 handler，handler 里用 `availableData` 取数据，
    /// 取到空 Data 就是 EOF；设 nil 停止。子进程管道一律用它，别直接用 `readabilityHandler`。
    ///
    /// Apple 平台就是 `readabilityHandler` 本身。Linux 上 swift-corelibs-foundation 的 `readabilityHandler`
    /// 会丢 EOF：最后一段数据和写端关闭一起到达时，回调只来一次（读走数据），之后管道只剩 `EPOLLHUP`，
    /// libdispatch 不再通知——靠 EOF 收尾的读循环（进程输出流、等 EOF 才报退出）就永远等下去。
    /// 所以 Linux 上换成一条自己 `poll` 的线程，`POLLHUP` 照样算可读。
    public var portableReadabilityHandler: (@Sendable (FileHandle) -> Void)? {
        get {
            #if canImport(Darwin)
            readabilityHandler
            #else
            PollingReadability.handler(for: self)
            #endif
        }
        set {
            #if canImport(Darwin)
            readabilityHandler = newValue
            #else
            PollingReadability.set(newValue, for: self)
            #endif
        }
    }

    /// 这根管道不读了：摘掉 `portableReadabilityHandler`，Linux 上另外把 fd 关掉。任意线程都能调（handler 里面也行），重复调无害；
    /// 调过之后别再碰这个 FileHandle。子进程的读端读到 EOF、或不想再等 EOF 时一律用它，而不是只把 handler 设成 nil。
    ///
    /// Linux 上 swift-corelibs-foundation 读到 EOF 不会替你关 fd，`Process` / `Pipe` 又常常活得比这次调用久，
    /// 每起一个子进程就漏一两个描述符；描述符多到上千，Swift 6.4 的 `Process.run()` 读 `/proc/self/fd` 还会越界崩掉。
    /// 读线程还在时由它退出前关（它是唯一在读这个 fd 的线程，关不会撞上一次正在进行的 `availableData`），不在就当场关。
    ///
    /// Apple 平台只摘 handler：别的线程上关 fd 可能撞上正在读的回调（坏 fd 上 `availableData` 直接抛 ObjC 异常），
    /// fd 照旧由 FileHandle 释放时关——Apple 的 Foundation 会释放它，与原来一样。
    public func finishPortableReading() {
        #if canImport(Darwin)
        readabilityHandler = nil
        #else
        PollingReadability.finish(self)
        #endif
    }
}

#if !canImport(Darwin)
/// 一个 fd 一条读线程。线程只在 handler 还在时继续 poll；设成 nil 后最多 `pollInterval` 就退出。
///
/// 线程活着就一直登记在 `active` 里（handler 摘掉了也是），退出前在同一把锁里注销：
/// `set` 挂新 handler、`finish` 要求关 fd 与线程决定退出不会错过彼此。
private final class PollingReadability: @unchecked Sendable {
    private static let lock = NSLock()
    private static var active: [ObjectIdentifier: PollingReadability] = [:]
    /// 没事件时隔这么久看一眼 handler 是不是已经被摘掉了。
    private static let pollInterval: Int32 = 200

    private let handle: FileHandle
    /// 由 `lock` 保护。
    private var handler: (@Sendable (FileHandle) -> Void)?
    /// 由 `lock` 保护：线程退出时顺手关掉 fd（`finishPortableReading()` 要的）。
    private var closeOnExit = false

    private init(handle: FileHandle, handler: @escaping @Sendable (FileHandle) -> Void) {
        self.handle = handle
        self.handler = handler
    }

    static func handler(for handle: FileHandle) -> (@Sendable (FileHandle) -> Void)? {
        lock.withLock { active[ObjectIdentifier(handle)]?.handler }
    }

    static func set(_ handler: (@Sendable (FileHandle) -> Void)?, for handle: FileHandle) {
        let key = ObjectIdentifier(handle)
        let started: PollingReadability? = lock.withLock {
            if let existing = active[key] {
                // 线程还没退出：换掉（或摘掉）它的 handler 就行，它下一轮以现在的为准。
                existing.handler = handler
                return nil
            }
            guard let handler else { return nil }
            let reader = PollingReadability(handle: handle, handler: handler)
            active[key] = reader
            return reader
        }
        guard let started else { return }
        let thread = Thread { started.run() }
        thread.name = "io.botbus.agent.readability"
        thread.start()
    }

    /// close 也在锁里做：读线程退出时关与这里当场关不会同时进行（FileHandle 的 close 不是线程安全的，
    /// 两边都读到同一个 fd 号的话，后关的那一下可能关掉别处刚复用这个号的文件）。
    static func finish(_ handle: FileHandle) {
        lock.withLock {
            if let existing = active[ObjectIdentifier(handle)] {
                existing.handler = nil
                existing.closeOnExit = true
            } else {
                try? handle.close()
            }
        }
    }

    private func currentHandler() -> (@Sendable (FileHandle) -> Void)? {
        Self.lock.withLock { handler }
    }

    /// handler 已经摘掉（或 `force`）就注销、按要求关 fd，返回 true：线程该退出了。
    private func retire(force: Bool = false) -> Bool {
        Self.lock.withLock {
            guard force || handler == nil else { return false }
            handler = nil
            let key = ObjectIdentifier(handle)
            if Self.active[key] === self { Self.active[key] = nil }
            if closeOnExit { try? handle.close() }
            return true
        }
    }

    #if os(Windows)
    /// Windows 没有 `poll`：用 `PeekNamedPipe` 看管道里有没有数据（不取走），有数据或写端已关（`ERROR_BROKEN_PIPE`，
    /// 即 EOF）才调 handler——与 POSIX 那份一样，handler 里的 `availableData` 不会阻塞，摘掉 handler 之后也不会再多调一次。
    /// 不是管道的句柄 Peek 不了：退回直接调 handler，由 `availableData` 自己等。
    private func run() {
        let pipe = handle._handle
        while !retire() {
            var available: DWORD = 0
            if PeekNamedPipe(pipe, nil, 0, nil, &available, nil) {
                guard available > 0 else {
                    Thread.sleep(forTimeInterval: Double(Self.pollInterval) / 4000)
                    continue
                }
            } else if GetLastError() != DWORD(ERROR_BROKEN_PIPE), GetFileType(pipe) == DWORD(FILE_TYPE_PIPE) {
                // 句柄已经坏了（被关掉）：`availableData` 在坏句柄上会直接崩，不再回调，静静退出。
                _ = retire(force: true)
                return
            }
            guard let handler = currentHandler() else { continue }
            handler(handle)
        }
    }
    #else
    private func run() {
        let descriptor = handle.fileDescriptor
        while !retire() {
            var watch = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&watch, 1, Self.pollInterval)
            if ready < 0 {
                if errno == EINTR { continue }
                _ = retire(force: true)
                return
            }
            guard ready > 0 else { continue }
            // fd 已经被关掉（POLLNVAL）：`availableData` 在坏 fd 上会直接崩，不再回调，静静退出。
            if watch.revents & Int16(POLLNVAL) != 0 {
                _ = retire(force: true)
                return
            }
            // poll 期间 handler 可能已经被摘掉或换掉：以现在的为准（摘掉了就回到循环头退出）。
            guard let handler = currentHandler() else { continue }
            handler(handle)
        }
    }
    #endif
}
#endif
