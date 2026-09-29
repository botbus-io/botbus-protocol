#if !canImport(Network)
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// 没有 Network.framework 的平台（Linux）：非阻塞 POSIX socket + `DispatchSource`。
/// 对外的 API 与语义和 Apple 平台那份完全一样；解析与回写的报文在 `LocalHookServer.swift`，
/// 系统调用在 `LoopbackSocket.swift`。
extension LocalHookServer {
    /// 监听队列的长度。hook 都是一次一条 curl，够用。
    static let listenBacklog: Int32 = 64

    // MARK: - 生命周期

    /// 起监听并返回系统分配的端口。端口随后写进端口文件（配置了的话），开了密钥的先写密钥文件。
    @discardableResult
    public func start() async throws -> UInt16 {
        guard listener == nil else { throw Failure.alreadyRunning }
        // 先换密钥再监听：第一条连接进来时就必须认得出来。
        rotateSecret()

        // 绑死 127.0.0.1（端口 0 = 让系统挑）：外面根本连不进来，
        // 下面 accept 里的 isLoopbackAddress 只是万一绑定被改坏时的第二道闸。
        let listener: SocketListener
        do {
            listener = try SocketListener(port: requestedPort ?? 0, backlog: Self.listenBacklog, queue: queue) {
                [weak self] descriptor, peer in
                guard let self else { LoopbackSocket.closeSocket(descriptor); return }
                self.accept(descriptor, peer: peer)
            }
        } catch {
            throw Failure.listenerFailed(String(describing: error))
        }
        guard listener.port != 0 else {
            listener.cancel()
            throw Failure.noPortAssigned
        }
        live.reopen()
        listener.start()

        self.listener = listener
        self.port = listener.port
        publish(port: listener.port)
        return listener.port
    }

    /// 幂等：停监听、掐掉在跑的连接（挂着的响应会因此被放掉）、删端口文件与密钥文件。
    ///
    /// 监听 fd 在这里同步关掉（`SocketListener.cancel()` 等关闭回调跑完）：
    /// 紧接着用同一个 `requestedPort` 再起一个实例时端口必须已经空出来。
    public func stop() {
        listener?.cancel()
        listener = nil
        port = nil
        live.cancelAll()
        if let portFileURL { try? FileManager.default.removeItem(at: portFileURL) }
        retractSecret()
    }

    // MARK: - 来源校验

    /// 文本形式的地址是不是回环。IPv6 的 zone（`%eth0`）先去掉，再认 IPv4-mapped（`::ffff:127.0.0.1`）。
    /// 整个 `127.0.0.0/8` 都算回环，别把 127.0.0.53 这种判成外来的。
    public nonisolated static func isLoopbackAddress(_ text: String) -> Bool {
        let bare = String(text.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        if let v4 = LoopbackSocket.ipv4Bytes(bare) { return v4.first == 127 }
        if let v6 = LoopbackSocket.ipv6Bytes(bare) {
            if v6 == [UInt8](repeating: 0, count: 15) + [1] { return true }
            let mapped = [UInt8](repeating: 0, count: 10) + [0xFF, 0xFF]
            return Array(v6.prefix(12)) == mapped && v6[12] == 127
        }
        return bare.caseInsensitiveCompare("localhost") == .orderedSame
    }

    // MARK: - 每条连接

    private nonisolated func accept(_ descriptor: Int32, peer: String) {
        guard Self.isLoopbackAddress(peer) else {
            Self.log.warning("拒绝非回环来源：\(peer, privacy: .public)")
            LoopbackSocket.closeSocket(descriptor)
            return
        }
        let inFlight = HoldBox()
        // 第三条路径：对端走了（或 stop() 掐了连接），把挂着的响应放掉，别让 serve 干等。
        let connection = SocketConnection(descriptor: descriptor, onCancel: { inFlight.take()?.abandon() })
        guard live.add(connection) else { connection.cancel(); return }

        Task { [self] in
            await serve(connection, inFlight: inFlight)
            connection.cancel()
            live.remove(connection)
        }
    }
}

/// 监听 socket。可读事件来了就 accept 到队列空为止，每条新连接交给 `onAccept`（fd 归对方）。
final class SocketListener: @unchecked Sendable {
    /// fd 用完（EMFILE / ENFILE）时暂停接受这么久：读事件源是电平触发的，不停下来就是空转。
    static let acceptBackoff: TimeInterval = 1
    private static let log = PlatformLogger(subsystem: "io.botbus.agent", category: "hookserver")

    let port: UInt16
    private let descriptor: Int32
    private let queue: DispatchQueue
    private let source: DispatchSourceRead
    private let closed = DispatchSemaphore(value: 0)
    // 以下只在 `queue` 上碰。
    private var suspended = true
    private var cancelled = false
    private var loggedFailure = false

    init(port requested: UInt16, backlog: Int32, queue: DispatchQueue,
         onAccept: @escaping @Sendable (Int32, String) -> Void) throws {
        let (descriptor, port) = try LoopbackSocket.makeListener(port: requested, backlog: backlog)
        self.descriptor = descriptor
        self.port = port
        self.queue = queue
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        // 事件源在自己的处理器里引用 self：取消后 dispatch 放掉处理器，环就断了。
        source.setEventHandler { self.acceptPending(onAccept) }
        let closed = self.closed
        source.setCancelHandler {
            LoopbackSocket.closeSocket(descriptor)
            closed.signal()
        }
    }

    func start() {
        queue.async {
            guard !self.cancelled, self.suspended else { return }
            self.suspended = false
            self.source.resume()
        }
    }

    /// 幂等。返回时监听 fd 已经关掉，端口已经空出来。不能在 `queue` 上调用。
    func cancel() {
        let first: Bool = queue.sync {
            guard !cancelled else { return false }
            cancelled = true
            // 暂停中的事件源取消后，关闭回调要等它恢复才跑。
            if suspended {
                suspended = false
                source.resume()
            }
            source.cancel()
            return true
        }
        guard first else { return }
        // 关闭回调排在 `queue` 上，马上就跑；等不到只可能是队列被别的活卡住，别把 stop() 一起卡死。
        _ = closed.wait(timeout: .now() + 2)
    }

    private func acceptPending(_ onAccept: @Sendable (Int32, String) -> Void) {
        while !cancelled {
            switch LoopbackSocket.acceptConnection(descriptor) {
            case .connection(let client, let peer):
                loggedFailure = false
                onAccept(client, peer)
            case .retry:
                continue
            case .wouldBlock:
                return
            case .failed(let code):
                // EMFILE / ENFILE 之类：连接还在监听队列里，事件会一直触发。停一会儿再接。
                if !loggedFailure {
                    loggedFailure = true
                    Self.log.error("hook server accept failed (errno \(code, privacy: .public)); pausing")
                }
                suspended = true
                source.suspend()
                queue.asyncAfter(deadline: .now() + Self.acceptBackoff) {
                    guard !self.cancelled, self.suspended else { return }
                    self.suspended = false
                    self.source.resume()
                }
                return
            }
        }
    }
}

/// 一条 TCP 连接（非阻塞 fd）。读由 `DispatchSource` 触发：有人在等（`receiveChunk` / 断线监视 / 收尾时的排空）
/// 才恢复读事件源，没人等就暂停——电平触发的事件源不暂停会空转。所有状态只在自己的串行队列上碰。
///
/// 每次可读都读到 EAGAIN 或 EOF 为止：Linux 的 libdispatch 对带 `EPOLLHUP` 的事件只通知一次，
/// 数据和对端关闭一起到的时候，不在同一轮里读出 EOF 就再也看不见它。读出的 EOF 记下来（`peerClosed`），
/// 之后再等读直接给 EOF——和 Network.framework 一样，数据与 FIN 可以在同一段里带回（`isComplete`）。
///
/// 关闭分两种：还没回过响应（`stop()` 掐掉挂起的请求、读出错）就直接关；已经回完响应、写端已关，
/// 先把对端还在路上的字节读掉、等它的 FIN（最多 `lingerTimeout`）再关——Linux 上 close 一个接收缓冲里
/// 还有数据的 socket 会回 RST，对端（比如被 413 挡回去、body 还没发完的 curl）可能连响应都没读到就被 reset。
final class SocketConnection: HookTransport, @unchecked Sendable {
    static let readChunk = 64 * 1024
    static let lingerTimeout: TimeInterval = 1
    /// 写一次最多等对端腾出缓冲这么久；一直不读的对端不值得一直等。
    static let writeTimeout: TimeInterval = 30

    private enum Outcome {
        /// `endOfStream`：这段数据后面紧跟着对端的 FIN。
        case data(Data, endOfStream: Bool)
        case endOfStream
        case failed(Int32)
    }

    private enum State {
        case open
        /// 已回完响应，正在排空对端的剩余字节。
        case lingering
        case closed
    }

    private let descriptor: Int32
    private let queue = DispatchQueue(label: "io.botbus.agent.hookserver.connection")
    private let source: DispatchSourceRead
    // 以下只在 `queue` 上碰。
    private var state = State.open
    private var armed = false
    private var reader: ((Outcome) -> Void)?
    private var writeShut = false
    /// 已经读到过对端的 FIN。
    private var peerClosed = false
    private var onCancel: (@Sendable () -> Void)?

    init(descriptor: Int32, onCancel: @escaping @Sendable () -> Void) {
        self.descriptor = descriptor
        self.onCancel = onCancel
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        // 强引用 self：连接活到被关掉为止；取消后 dispatch 放掉这个闭包，环就断了。
        source.setEventHandler { self.readable() }
        source.setCancelHandler { LoopbackSocket.closeSocket(descriptor) }
    }

    // MARK: HookTransport

    func receiveChunk() async throws -> LocalHookServer.ReceivedChunk? {
        let box = OneShotContinuation<LocalHookServer.ReceivedChunk?>()
        queue.async {
            self.arm { outcome in
                switch outcome {
                case .data(let data, let endOfStream):
                    box.resume(returning: LocalHookServer.ReceivedChunk(data: data, isComplete: endOfStream))
                case .endOfStream: box.resume(returning: nil)
                case .failed(let code): box.resume(throwing: LoopbackSocket.Failure(call: "recv", code: code))
                }
            }
        }
        return try await withCheckedThrowingContinuation { box.install($0) }
    }

    func sendFinal(_ data: Data) async {
        let box = OneShotContinuation<Void>()
        queue.async {
            // 挂起期间的断线监视到这里就用不着了。
            self.reader = nil
            self.disarm()
            if self.state == .open {
                // 写失败只意味着对端不在了，没有补救动作。
                _ = LoopbackSocket.writeAll(self.descriptor, data, timeout: Self.writeTimeout)
                LoopbackSocket.shutdownWrite(self.descriptor)
                self.writeShut = true
            }
            box.resume(returning: ())
        }
        _ = try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            box.install(continuation)
        }
    }

    /// 和 Apple 那份一样：只认 FIN 与出错；挂起期间对端多发的字节不算断线，也不再接着盯。
    func watchForDisconnect(_ hold: LocalHookServer.Hold) {
        queue.async {
            self.arm { outcome in
                if case .data(_, endOfStream: false) = outcome { return }
                hold.abandon()
            }
        }
    }

    /// 幂等。挂着的响应在这里被放掉（`onCancel`）。
    func cancel() {
        queue.async {
            guard self.state == .open else { return }
            let notify = self.onCancel
            self.onCancel = nil
            notify?()
            if self.writeShut {
                self.linger()
            } else {
                self.close()
            }
        }
    }

    // MARK: 读

    /// 只在 `queue` 上调用。连接已经关了就立刻报错，不让等的一方挂死。
    private func arm(_ reader: @escaping (Outcome) -> Void) {
        guard state != .closed else {
            reader(.failed(ECANCELED))
            return
        }
        // FIN 已经读出来过：不会再有可读事件了，直接给 EOF。
        guard !peerClosed else {
            reader(.endOfStream)
            return
        }
        self.reader = reader
        if !armed {
            armed = true
            source.resume()
        }
    }

    private func disarm() {
        guard armed, state != .closed else { return }
        armed = false
        source.suspend()
    }

    private func readable() {
        guard let current = reader else {
            disarm()
            return
        }
        guard let outcome = readUntilDrained() else { return }
        reader = nil
        current(outcome)
        // 回调里可能又挂了一个读（排空）；没挂就暂停事件源。
        if reader == nil { disarm() }
    }

    /// 读到 EAGAIN、EOF 或攒满一段为止。nil = 其实没东西可读（接着等下一次事件）。
    private func readUntilDrained() -> Outcome? {
        var collected = Data()
        while collected.count < Self.readChunk {
            switch LoopbackSocket.receive(descriptor, maximum: Self.readChunk - collected.count) {
            case .data(let data):
                collected.append(data)
            case .wouldBlock:
                return collected.isEmpty ? nil : .data(collected, endOfStream: false)
            case .endOfStream:
                peerClosed = true
                return collected.isEmpty ? .endOfStream : .data(collected, endOfStream: true)
            case .failed(let code):
                // 已经读到的先交出去；错误（多半是 reset）下一次读还会再报。
                return collected.isEmpty ? .failed(code) : .data(collected, endOfStream: false)
            }
        }
        return .data(collected, endOfStream: false)
    }

    // MARK: 关

    private func linger() {
        state = .lingering
        queue.asyncAfter(deadline: .now() + Self.lingerTimeout) { self.close() }
        drain()
    }

    private func drain() {
        arm { outcome in
            if case .data(_, endOfStream: false) = outcome {
                self.drain()
            } else {
                self.close()
            }
        }
    }

    private func close() {
        guard state != .closed else { return }
        state = .closed
        reader = nil
        // 暂停中的事件源取消后，关闭回调（close fd）要等它恢复才跑。
        if !armed {
            armed = true
            source.resume()
        }
        source.cancel()
    }
}
#endif // !canImport(Network)
