import Darwin
import Foundation
import os

/// 本机 Unix socket 监听（反向扩展用，spec「反向扩展 → 连接」）。目录 0700、socket 0600，另外按
/// `getpeereid` 只收同一用户的进程：权限位之外再挡一道。
///
/// 路径受 `sockaddr_un.sun_path` 限制（104 字节，含结尾的 0），太长直接报 `ENAMETOOLONG`。
public final class UnixSocketServer: @unchecked Sendable {
    /// fd 用完（EMFILE / ENFILE）时暂停接受这么久：读事件源是电平触发的，不停下来就是空转。
    public static let acceptBackoff: TimeInterval = 1
    private static let log = Logger(subsystem: "io.botbus.agent", category: "acp")

    private let path: String
    private let onConnection: @Sendable (UnixSocketConnection) -> Void
    private let queue = DispatchQueue(label: "io.botbus.agent.acp.socket")
    private let lock = NSLock()
    private var source: DispatchSourceRead?

    public init(path: String, onConnection: @escaping @Sendable (UnixSocketConnection) -> Void) {
        self.path = path
        self.onConnection = onConnection
    }

    deinit { stop() }

    /// 开始监听。已经在监听时什么都不做。
    ///
    /// 路径上已有的东西：没人在听的旧 socket（上次没清掉）替换掉；有人在听的报 `EADDRINUSE`，不抢；
    /// 不是 socket（普通文件、软链接）报 `EEXIST`，不删。所在目录必须是当前用户自己的真目录（不是软链接），否则报错。
    public func start() throws {
        try lock.withLock {
            guard source == nil else { return }
            try Self.prepareDirectory((path as NSString).deletingLastPathComponent)
            try Self.removeStaleSocket(path)
            let descriptor = try Self.makeSocket()
            do {
                var address = try Self.address(path)
                let bound = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
                guard bound == 0 else { throw Self.posixError() }
                guard chmod(path, 0o600) == 0, listen(descriptor, 16) == 0 else {
                    let error = Self.posixError()
                    unlink(path)
                    throw error
                }
                // 只有监听端非阻塞：一次事件里 accept 到 EAGAIN 为止。
                _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
            } catch {
                Darwin.close(descriptor)
                throw error
            }
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            let onConnection = self.onConnection
            let queue = self.queue
            let throttle = AcceptThrottle()
            // 事件源在自己的处理器里引用自己：取消后 dispatch 放掉处理器，环就断了。
            source.setEventHandler {
                Self.acceptPending(descriptor, source: source, queue: queue, throttle: throttle, onConnection: onConnection)
            }
            source.setCancelHandler { Darwin.close(descriptor) }
            self.source = source
            source.resume()
        }
    }

    /// 停止监听并删掉 socket 文件。已接受的连接不归这里管（见 `AcpReverseServer.stop()`）。幂等。
    public func stop() {
        let source: DispatchSourceRead? = lock.withLock {
            defer { self.source = nil }
            return self.source
        }
        guard let source else { return }
        source.cancel()
        unlink(path)
    }

    /// 只在 `queue` 上用。
    private final class AcceptThrottle: @unchecked Sendable {
        var logged = false
    }

    private static func acceptPending(_ listener: Int32, source: DispatchSourceRead, queue: DispatchQueue,
                                      throttle: AcceptThrottle, onConnection: @Sendable (UnixSocketConnection) -> Void) {
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else {
                let code = errno
                switch code {
                case EINTR, ECONNABORTED:
                    continue
                case EAGAIN:
                    return
                default:
                    // EMFILE / ENFILE 之类：连接还在监听队列里，事件会一直触发。停一会儿再接（暂停中被取消也没关系，
                    // 恢复后取消处理器照常执行；恢复前 asyncAfter 的闭包拿着事件源，不会在暂停状态下被释放）。
                    if !throttle.logged {
                        throttle.logged = true
                        log.error("acp socket accept failed (errno \(code, privacy: .public)); pausing")
                    }
                    source.suspend()
                    queue.asyncAfter(deadline: .now() + acceptBackoff) { source.resume() }
                    return
                }
            }
            throttle.logged = false
            // macOS 上 accept 出来的 socket 继承监听端的 O_NONBLOCK：写要阻塞到写完，读由 DispatchSource 触发。
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            configure(client)
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == geteuid() else {
                Darwin.close(client)
                continue
            }
            onConnection(UnixSocketConnection(descriptor: client))
        }
    }

    // MARK: - 小工具

    public static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty, bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return address
    }

    public static func makeSocket() throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw posixError() }
        configure(descriptor)
        return descriptor
    }

    /// 不让 agent 子进程继承这些 fd；对端关了再写返回 EPIPE 而不是给整个进程发 SIGPIPE。
    public static func configure(_ descriptor: Int32) {
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    public static func posixError(_ code: Int32 = errno) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    /// 目录不在就建成 0700；在的话必须是当前用户自己的真目录（软链接、别人的目录如 `/tmp` 一律报错），并收紧到 0700。
    private static func prepareDirectory(_ directory: String) throws {
        var info = stat()
        if lstat(directory, &info) != 0 {
            guard errno == ENOENT else { throw posixError() }
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            guard lstat(directory, &info) == 0 else { throw posixError() }
        }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw POSIXError(.ENOTDIR) }
        guard info.st_uid == geteuid() else { throw POSIXError(.EACCES) }
        if info.st_mode & 0o777 != 0o700 {
            guard chmod(directory, 0o700) == 0 else { throw posixError() }
        }
    }

    private static func removeStaleSocket(_ path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else { return }
        guard info.st_mode & S_IFMT == S_IFSOCK else { throw POSIXError(.EEXIST) }
        // 有人在听（另一个 BotBus、别的程序）就不抢；连不上才是上次没清掉的旧文件。
        if isListening(path) { throw POSIXError(.EADDRINUSE) }
        guard unlink(path) == 0 else { throw posixError() }
    }

    private static func isListening(_ path: String) -> Bool {
        guard let descriptor = try? makeSocket() else { return false }
        defer { Darwin.close(descriptor) }
        guard var address = try? address(path) else { return false }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return connected == 0
    }
}

/// 一条 socket 连接：读到的字节按顺序交给 `onData`，连接结束（对端关了、读写出错、`close()`）时调一次 `onClose`；
/// 写排在一条串行队列上，整行写完再写下一行。
///
/// fd 的生命周期：`close()` 先 `shutdown`（卡在写上的那次立刻返回，对端读到 EOF），再取消读事件源；
/// 真正的 `close(fd)` 排在写队列末尾——已经在写的那一行写完（或失败）之前 fd 号不会被系统复用给别的文件。
public final class UnixSocketConnection: @unchecked Sendable {
    public static let readChunk = 64 * 1024

    public let id = UUID()
    private let descriptor: Int32
    private let readQueue = DispatchQueue(label: "io.botbus.agent.acp.read")
    private let writeQueue = DispatchQueue(label: "io.botbus.agent.acp.write")
    private let lock = NSLock()
    private var started = false
    private var closed = false
    private var source: DispatchSourceRead?
    private var onClose: (@Sendable () -> Void)?
    /// 只在 `readQueue` 上用。
    private var readBuffer = [UInt8](repeating: 0, count: UnixSocketConnection.readChunk)

    public init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        // 从没 start 过、也没 close 过（start 之后读事件源一直持有 self，走不到这里）。
        if !closed { Darwin.close(descriptor) }
    }

    /// 以客户端身份连一个 socket（测试与 `botbus agent` 自检用）。
    public static func connect(path: String) throws -> UnixSocketConnection {
        let descriptor = try UnixSocketServer.makeSocket()
        do {
            var address = try UnixSocketServer.address(path)
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard connected == 0 else { throw UnixSocketServer.posixError() }
        } catch {
            Darwin.close(descriptor)
            throw error
        }
        return UnixSocketConnection(descriptor: descriptor)
    }

    public var isClosed: Bool { lock.withLock { closed } }

    /// 开始读。只认第一次调用；连接已经关了的话立刻调 `onClose`（之前没人等它）。
    public func start(onData: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable () -> Void) {
        let closedAlready: Bool = lock.withLock {
            guard !started else { return false }
            started = true
            guard !closed else { return true }
            self.onClose = onClose
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: readQueue)
            // 强引用 self：连接活到被关掉为止；取消后 dispatch 放掉这个闭包，环就断了。
            source.setEventHandler { self.readAvailable(onData) }
            let descriptor = self.descriptor
            let writeQueue = self.writeQueue
            source.setCancelHandler { writeQueue.async { Darwin.close(descriptor) } }
            self.source = source
            source.resume()
            return false
        }
        if closedAlready { onClose() }
    }

    /// 发一行（不带换行，这里补）。连接关了就丢掉。写失败（对端关了）等同于关连接。
    ///
    /// 写是阻塞的：对端一直不读，写队列就卡在这一行，后面的行在队列里越攒越多（无上限）。本机同一用户的 agent
    /// 才连得上，这里不设上限也不设写超时；`close()` 会用 `shutdown` 把卡住的写唤醒。
    public func write(_ line: String) {
        var data = Data(line.utf8)
        data.append(UInt8(ascii: "\n"))
        writeQueue.async {
            guard !self.isClosed else { return }
            let complete = data.withUnsafeBytes { raw -> Bool in
                guard let base = raw.baseAddress else { return true }
                var offset = 0
                while offset < raw.count {
                    let written = Darwin.write(self.descriptor, base + offset, raw.count - offset)
                    if written > 0 {
                        offset += written
                    } else if written < 0, errno == EINTR {
                        continue
                    } else {
                        return false
                    }
                }
                return true
            }
            if !complete { self.close() }
        }
    }

    /// 已经交给 `write` 的行都写完（或失败）之后再关。
    public func closeAfterPendingWrites() {
        writeQueue.async { self.close() }
    }

    /// 幂等。对端先关也走这里，`onClose` 只调一次。
    public func close() {
        let taken: (source: DispatchSourceRead?, onClose: (@Sendable () -> Void)?)? = lock.withLock {
            guard !closed else { return nil }
            closed = true
            defer {
                source = nil
                onClose = nil
            }
            return (source, onClose)
        }
        guard let taken else { return }
        // 到这里 fd 一定还开着：只有把 `closed` 置真的这一次调用会走到这里，fd 要等下面的取消之后才关。
        shutdown(descriptor, SHUT_RDWR)
        if let source = taken.source {
            source.cancel()
        } else {
            let descriptor = self.descriptor
            writeQueue.async { Darwin.close(descriptor) }
        }
        taken.onClose?()
    }

    private func readAvailable(_ onData: @Sendable (Data) -> Void) {
        let count = readBuffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
        if count > 0 {
            onData(Data(readBuffer[0..<count]))
        } else if count == 0 {
            close()
        } else if errno != EINTR, errno != EAGAIN {
            close()
        }
    }
}
