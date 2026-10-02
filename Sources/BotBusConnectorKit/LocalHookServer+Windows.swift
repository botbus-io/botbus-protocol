#if os(Windows)
import Foundation
import WinSDK

// Windows 的监听与连接：阻塞的 Winsock socket，监听一个线程、每条连接一个读队列。
// `LocalHookServer+POSIX.swift` 里的生命周期（start / stop / 来源校验 / accept 分派）两个平台共用，
// 只认这里的 `SocketListener` 与 `SocketConnection`。不用 `DispatchSource`：libdispatch 在 Windows 上对
// SOCKET 的可读事件不可靠，hook 的量又很小（一次一条 curl），线程足够。

/// 监听 socket。`start()` 起一个 accept 线程，每条新连接交给 `onAccept`（socket 归对方）。
final class SocketListener: @unchecked Sendable {
    /// accept 出错（句柄用完之类）时停一会儿再接，免得空转。
    static let acceptBackoff: TimeInterval = 1
    private static let log = PlatformLogger(subsystem: "io.botbus.agent", category: "hookserver")

    let port: UInt16
    private let descriptor: LoopbackSocket.Descriptor
    private let onAccept: @Sendable (LoopbackSocket.Descriptor, String) -> Void
    private let lock = NSLock()
    private var cancelled = false
    private var started = false
    private let exited = DispatchSemaphore(value: 0)

    init(port requested: UInt16, backlog: Int32, queue: DispatchQueue,
         onAccept: @escaping @Sendable (LoopbackSocket.Descriptor, String) -> Void) throws {
        let (descriptor, port) = try LoopbackSocket.makeListener(port: requested, backlog: backlog)
        self.descriptor = descriptor
        self.port = port
        self.onAccept = onAccept
    }

    func start() {
        lock.lock()
        guard !cancelled, !started else { lock.unlock(); return }
        started = true
        lock.unlock()
        let thread = Thread { [self] in acceptLoop() }
        thread.name = "botbus-hookserver-accept"
        thread.start()
    }

    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    private func acceptLoop() {
        defer { exited.signal() }
        var loggedFailure = false
        while !isCancelled {
            switch LoopbackSocket.acceptConnection(descriptor) {
            case .connection(let client, let peer):
                loggedFailure = false
                guard !isCancelled else { LoopbackSocket.closeSocket(client); return }
                onAccept(client, peer)
            case .retry:
                continue
            case .failed(let code):
                guard !isCancelled else { return }
                if !loggedFailure {
                    loggedFailure = true
                    Self.log.error("hook server accept failed (WSA \(code, privacy: .public)); pausing")
                }
                Thread.sleep(forTimeInterval: Self.acceptBackoff)
            }
        }
    }

    /// 幂等。返回时监听 socket 已经关掉、端口已经空出来。
    func cancel() {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        cancelled = true
        let wasStarted = started
        lock.unlock()
        // 关掉监听 socket：阻塞在 accept 里的线程随即返回错误，看到 cancelled 就退出。
        LoopbackSocket.closeSocket(descriptor)
        if wasStarted { _ = exited.wait(timeout: .now() + 2) }
    }
}

/// 一条 TCP 连接（阻塞 socket）。读都在自己的串行队列上做（一次一个），写在另一个队列上，
/// 这样挂起期间盯着断线的那个阻塞读不会挡住回写。
///
/// 关闭分两种，与 Linux 那份一样：还没回过响应就两头 shutdown 再关；已经回完、写端已关，就先把对端还在路上的字节
/// 读掉、等它的 FIN（最多 `lingerTimeout`）再关——接收缓冲里还有数据时 closesocket 会回 RST，对端可能连响应都没读到。
final class SocketConnection: HookTransport, @unchecked Sendable {
    static let readChunk = 64 * 1024
    static let lingerTimeout: TimeInterval = 1
    static let writeTimeout: TimeInterval = 30

    private let descriptor: LoopbackSocket.Descriptor
    private let readQueue = DispatchQueue(label: "io.botbus.agent.hookserver.read")
    private let writeQueue = DispatchQueue(label: "io.botbus.agent.hookserver.write")
    private let lock = NSLock()
    // 以下由 `lock` 保护。
    private var open = true
    private var writeShut = false
    private var peerClosed = false
    private var handleClosed = false
    private var onCancel: (@Sendable () -> Void)?

    init(descriptor: LoopbackSocket.Descriptor, onCancel: @escaping @Sendable () -> Void) {
        self.descriptor = descriptor
        self.onCancel = onCancel
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: HookTransport

    func receiveChunk() async throws -> LocalHookServer.ReceivedChunk? {
        let box = OneShotContinuation<LocalHookServer.ReceivedChunk?>()
        readQueue.async { [self] in
            let (isOpen, closedByPeer) = withLock { (open, peerClosed) }
            guard isOpen else {
                box.resume(throwing: LoopbackSocket.Failure(call: "recv", code: WSAECONNABORTED))
                return
            }
            guard !closedByPeer else {
                box.resume(returning: nil)
                return
            }
            switch LoopbackSocket.receive(descriptor, maximum: Self.readChunk) {
            case .data(let data):
                box.resume(returning: LocalHookServer.ReceivedChunk(data: data, isComplete: false))
            case .endOfStream:
                withLock { peerClosed = true }
                box.resume(returning: nil)
            case .failed(let code):
                box.resume(throwing: LoopbackSocket.Failure(call: "recv", code: code))
            }
        }
        return try await withCheckedThrowingContinuation { box.install($0) }
    }

    func sendFinal(_ data: Data) async {
        let box = OneShotContinuation<Void>()
        writeQueue.async { [self] in
            if withLock({ open }) {
                _ = LoopbackSocket.writeAll(descriptor, data, timeout: Self.writeTimeout)
                LoopbackSocket.shutdownWrite(descriptor)
                withLock { writeShut = true }
            }
            box.resume(returning: ())
        }
        _ = try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            box.install(continuation)
        }
    }

    /// 只认 FIN 与出错；挂起期间对端多发的字节不算断线，也不再接着盯（与另外两份实现一致）。
    func watchForDisconnect(_ hold: LocalHookServer.Hold) {
        readQueue.async { [self] in
            guard withLock({ open && !peerClosed }) else {
                hold.abandon()
                return
            }
            switch LoopbackSocket.receive(descriptor, maximum: Self.readChunk) {
            case .data:
                return
            case .endOfStream:
                withLock { peerClosed = true }
                hold.abandon()
            case .failed:
                hold.abandon()
            }
        }
    }

    /// 幂等。挂着的响应在这里被放掉（`onCancel`）。
    func cancel() {
        let (first, notify, lingering) = withLock { () -> (Bool, (@Sendable () -> Void)?, Bool) in
            guard open else { return (false, nil, false) }
            open = false
            let notify = onCancel
            onCancel = nil
            return (true, notify, writeShut && !peerClosed)
        }
        guard first else { return }
        notify?()
        if lingering {
            // 排空对端剩下的字节、等它的 FIN；读有超时，另外到点了两头 shutdown，保证挂着的读一定会返回。
            LoopbackSocket.setReceiveTimeout(descriptor, seconds: Self.lingerTimeout)
            // 句柄已经关了就什么都不做：Windows 会把同一个 SOCKET 值马上发给下一条新连接，关错了就是别人的请求被掐断。
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.lingerTimeout + 1) { [self] in
                withLock { if !handleClosed { LoopbackSocket.shutdownBoth(descriptor) } }
            }
            readQueue.async { [self] in
                let deadline = Date().addingTimeInterval(Self.lingerTimeout)
                while Date() < deadline, case .data = LoopbackSocket.receive(descriptor, maximum: Self.readChunk) {}
                close()
            }
        } else {
            LoopbackSocket.shutdownBoth(descriptor)
            readQueue.async { [self] in close() }
        }
    }

    /// 只在读队列上调用：之前排着的读都已经返回。等写队列也空了再关句柄。
    private func close() {
        writeQueue.sync {}
        // 先在锁里记下「已关」，之后迟到的 shutdown 看到它就不会碰这个（可能已被复用的）句柄值。
        withLock { handleClosed = true }
        LoopbackSocket.closeSocket(descriptor)
    }
}
#endif
