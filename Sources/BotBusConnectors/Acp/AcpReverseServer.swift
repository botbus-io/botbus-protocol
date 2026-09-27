import Foundation
import BotBusConnectorKit
import os

/// 反向扩展的监听端（spec「反向扩展」）：agent 自己的进程连 `~/.botbus/run/acp.sock`，
/// 先发 `_botbus/hello`，通过后这条连接上的 ACP 消息全交给对应的 `AcpConnector`（经 `AcpHub`）。
/// 角色不变：agent 进程仍是 ACP 的 agent，BotBus 仍是 client。
///
/// 每条连接一个 `JSONRPCPeer`、一个读循环（`receive` 必须串行）。连接结束时先关 peer（在等的请求——
/// 比如经这条连接发的 `session/prompt`——带着 closed 失败），再告诉 hub（`reverseClosed` → 连接器 `detach`）。
///
/// 握手：`helloTimeout` 内没握上手的连接直接断开；hello 被拒（没发现这个 agent、已停用、版本不对、参数不对）的，
/// 应答发出去之后断开。握手通过之前到的通知（agent 没等应答就开始报）先攒着（最多 `maxPendingNotifications` 条），
/// 通过后按原顺序交给 hub，被拒就丢掉——这只是尽力而为，agent 应当等到 `accepted: true` 再报。
public final class AcpReverseServer: @unchecked Sendable {
    /// 反向扩展自己的版本号（`_botbus/hello.version`），和 Relay 协议版本无关。
    public static let extensionVersion: Int64 = 1
    public static let helloTimeout: TimeInterval = 10
    static let maxPendingNotifications = 100
    public static var defaultSocketPath: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".botbus/run/acp.sock").path
    }
    private static let log = Logger(subsystem: "io.botbus.agent", category: "acp")

    private let server: UnixSocketServer
    private let connections: ConnectionSet

    public init(path: String = AcpReverseServer.defaultSocketPath, hub: AcpHub,
                helloTimeout: TimeInterval = AcpReverseServer.helloTimeout) {
        let connections = ConnectionSet()
        self.connections = connections
        server = UnixSocketServer(path: path) { connection in
            AcpReverseServer.serve(connection, hub: hub, connections: connections, helloTimeout: helloTimeout)
        }
    }

    public func start() throws {
        connections.reopen()
        try server.start()
    }

    /// 停止监听、删掉 socket 文件，并断开所有连接（握过手的由 hub 收尾，没握手的也不留着）。
    public func stop() {
        server.stop()
        for connection in connections.closeAll() { connection.close() }
    }

    private static func serve(_ connection: UnixSocketConnection, hub: AcpHub, connections: ConnectionSet,
                              helloTimeout: TimeInterval) {
        guard connections.insert(connection) else {
            connection.close()
            return
        }
        let link = connection.id
        let peer = JSONRPCPeer(send: { connection.write($0) })
        let gate = HelloGate { method, params in await hub.reverseNotification(link, method, params) }
        let closeAfterReply = Flag()
        let (chunks, sink) = AsyncStream<Data>.makeStream()
        Task {
            // 处理器里对 peer 用弱引用：peer 持有处理器，强引用就是一个环。
            await peer.setHandlers(request: { [weak peer] method, params in
                guard method == "_botbus/hello" else { return try await hub.reverseRequest(link, method, params) }
                guard let peer else { throw JSONRPCError(code: JSONRPCError.internalError, message: "连接已断开") }
                let reply: JSONValue
                do {
                    reply = try await hub.acceptReverse(link, hello: params, peer: peer, close: { connection.close() })
                } catch {
                    if await gate.reject() { closeAfterReply.set() }
                    throw error
                }
                if reply["accepted"] == true {
                    // 攒着的通知在应答之前交给 hub：agent 看到 accepted 之后再发的，一定排在它们后面。
                    await gate.accept()
                } else if await gate.reject() {
                    // 已经握过手的连接再发一次 hello 只回拒绝，不断开（`reject()` 为 false）。
                    closeAfterReply.set()
                }
                return reply
            }, notification: { method, params in
                await gate.deliver(method, params)
            })
            // 拒绝的应答交给 `send` 之后才排"写完就关"，保证 agent 先收到拒绝理由。
            await peer.setResponseObserver { method, _ in
                if method == "_botbus/hello", closeAfterReply.take() { connection.closeAfterPendingWrites() }
            }
            let timeout = Task {
                try? await Task.sleep(for: .seconds(helloTimeout))
                guard !Task.isCancelled, await !gate.isAccepted else { return }
                log.notice("acp reverse connection did not complete _botbus/hello in time; closing")
                connection.close()
            }
            connection.start(onData: { sink.yield($0) }, onClose: { sink.finish() })
            for await chunk in chunks { await peer.receive(chunk) }
            timeout.cancel()
            await peer.close(reason: "反向连接已断开")
            await peer.setHandlers(request: nil, notification: nil)
            await peer.setResponseObserver(nil)
            connections.remove(link)
            await hub.reverseClosed(link)
        }
    }

    /// 一条连接的握手状态。握手通过前到的通知先攒着，通过后按顺序交出去；被拒就丢掉。
    ///
    /// actor 重入：`accept()` 逐条交出去的 await 期间 `deliver` 仍可能进来，那时还是 `pending`，接着排到队尾，
    /// 由 `accept()` 的循环一并交出——队列清空之前不切到 `accepted`，所以直接交出的永远排在攒着的后面。
    private actor HelloGate {
        private enum State { case pending, accepted, rejected }

        private let forward: @Sendable (String, JSONValue) async -> Void
        private var state = State.pending
        private var buffered: [(method: String, params: JSONValue)] = []
        private var overflowLogged = false

        init(forward: @escaping @Sendable (String, JSONValue) async -> Void) {
            self.forward = forward
        }

        var isAccepted: Bool { state == .accepted }

        func deliver(_ method: String, _ params: JSONValue) async {
            switch state {
            case .accepted:
                await forward(method, params)
            case .pending:
                guard buffered.count < AcpReverseServer.maxPendingNotifications else {
                    if !overflowLogged {
                        overflowLogged = true
                        AcpReverseServer.log.notice("acp reverse connection sent too many notifications before hello; dropping")
                    }
                    return
                }
                buffered.append((method, params))
            case .rejected:
                return
            }
        }

        func accept() async {
            while state == .pending, !buffered.isEmpty {
                let next = buffered.removeFirst()
                await forward(next.method, next.params)
            }
            if state == .pending { state = .accepted }
        }

        /// 还没握上手就切到被拒并丢掉攒着的，返回 true；已经握上手（或已被拒）返回 false。
        func reject() -> Bool {
            guard state == .pending else { return false }
            state = .rejected
            buffered.removeAll()
            return true
        }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func set() { lock.withLock { value = true } }

        func take() -> Bool {
            lock.withLock {
                defer { value = false }
                return value
            }
        }
    }

    /// 还开着的连接。停止之后才接受到的连接（最后一次 accept 与 `stop()` 撞上）直接关掉。
    private final class ConnectionSet: @unchecked Sendable {
        private let lock = NSLock()
        private var open: [UUID: UnixSocketConnection] = [:]
        private var stopped = false

        func reopen() { lock.withLock { stopped = false } }

        func insert(_ connection: UnixSocketConnection) -> Bool {
            lock.withLock {
                guard !stopped else { return false }
                open[connection.id] = connection
                return true
            }
        }

        func remove(_ id: UUID) { _ = lock.withLock { open.removeValue(forKey: id) } }

        func closeAll() -> [UnixSocketConnection] {
            lock.withLock {
                stopped = true
                defer { open.removeAll() }
                return Array(open.values)
            }
        }
    }
}
