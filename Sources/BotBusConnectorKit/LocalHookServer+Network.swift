#if canImport(Network)
import Foundation
import Network

/// Apple 平台：`NWListener` / `NWConnection`。解析与回写的报文在 `LocalHookServer.swift`。
extension LocalHookServer {
    // MARK: - 生命周期

    /// 起监听并返回系统分配的端口。端口随后写进端口文件（配置了的话），开了密钥的先写密钥文件。
    @discardableResult
    public func start() async throws -> UInt16 {
        guard listener == nil else { throw Failure.alreadyRunning }
        // 先换密钥再监听：第一条连接进来时就必须认得出来。
        rotateSecret()

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = false
        // 绑死 127.0.0.1（端口 .any = 让系统挑）：外面根本连不进来，
        // 下面 accept 里的 isLoopback 只是万一参数被改坏时的第二道闸。
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: requestedPort.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any)

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw Failure.listenerFailed(String(describing: error))
        }

        // ready / failed / cancelled 三条路径抢同一个出口，照例过盒子。
        let ready = OneShotContinuation<UInt16>()
        listener.stateUpdateHandler = { [weak listener] state in
            switch state {
            case .ready:
                guard let value = listener?.port?.rawValue, value != 0 else {
                    ready.resume(throwing: Failure.noPortAssigned)
                    return
                }
                ready.resume(returning: value)
            case .failed(let error):
                ready.resume(throwing: Failure.listenerFailed(String(describing: error)))
            case .cancelled:
                ready.resume(throwing: Failure.listenerFailed("listener cancelled"))
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.accept(connection)
        }
        live.reopen()
        listener.start(queue: queue)

        let assigned: UInt16
        do {
            assigned = try await withCheckedThrowingContinuation { ready.install($0) }
        } catch {
            listener.stateUpdateHandler = nil
            listener.newConnectionHandler = nil
            listener.cancel()
            throw error
        }

        self.listener = listener
        self.port = assigned
        publish(port: assigned)
        return assigned
    }

    /// 幂等：停监听、掐掉在跑的连接（挂着的响应会因此被放掉）、删端口文件与密钥文件。
    public func stop() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        port = nil
        live.cancelAll()
        if let portFileURL { try? FileManager.default.removeItem(at: portFileURL) }
        retractSecret()
    }

    // MARK: - 来源校验

    /// 第二道闸：监听本来就绑在 127.0.0.1 上，这里再挡一次非回环来源。
    public nonisolated static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address): return isLoopback(address)
        case .ipv6(let address): return address.isLoopback || (address.asIPv4.map(isLoopback) ?? false)
        case .name(let name, _): return isLoopbackAddress(name)
        @unknown default: return false
        }
    }

    /// 文本形式的地址是不是回环。IPv6 的 zone（`%en0`）先去掉，再认 IPv4-mapped（`::ffff:127.0.0.1`）。
    public nonisolated static func isLoopbackAddress(_ text: String) -> Bool {
        let bare = String(text.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        if let v4 = IPv4Address(bare) { return isLoopback(v4) }
        if let v6 = IPv6Address(bare) { return v6.isLoopback || (v6.asIPv4.map(isLoopback) ?? false) }
        return bare.caseInsensitiveCompare("localhost") == .orderedSame
    }

    /// 整个 `127.0.0.0/8` 都是回环。`IPv4Address.isLoopback` 只认 127.0.0.1 一个地址，
    /// 而 macOS 的 lo0 收下的是整段，别把 127.0.0.53 这种判成外来的。
    private nonisolated static func isLoopback(_ address: IPv4Address) -> Bool {
        address.rawValue.first == 127
    }

    // MARK: - 每条连接

    private nonisolated func accept(_ connection: NWConnection) {
        guard Self.isLoopback(connection.endpoint) else {
            Self.log.warning("拒绝非回环来源：\(String(describing: connection.endpoint), privacy: .public)")
            connection.cancel()
            return
        }
        guard live.add(connection) else { connection.cancel(); return }

        let inFlight = HoldBox()
        connection.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled:
                // 第三条路径：对端走了（或 stop() 掐了连接），把挂着的响应放掉，别让 serve 干等。
                inFlight.take()?.abandon()
            default:
                break
            }
        }
        connection.start(queue: queue)
        Task { [self] in
            await serve(connection, inFlight: inFlight)
            connection.cancel()
            live.remove(connection)
        }
    }
}

extension NWConnection: HookTransport {
    /// 读一段。`nil` = 对端把写端关了。数据与 FIN 可以在同一次回调中到达，必须一起带回解析器。
    func receiveChunk() async throws -> LocalHookServer.ReceivedChunk? {
        let box = OneShotContinuation<LocalHookServer.ReceivedChunk?>()
        receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            if let data, !data.isEmpty {
                box.resume(returning: LocalHookServer.ReceivedChunk(data: data, isComplete: isComplete))
            } else if isComplete {
                // 某些 macOS 版本在对端半关闭时同时给出 EOF 和错误；EOF 仍是可回复的坏请求。
                box.resume(returning: nil)
            } else if let error {
                box.resume(throwing: error)
            } else {
                // minimumIncompleteLength 是 1，走到这里只可能是对端关了（isComplete）。
                box.resume(returning: nil)
            }
        }
        return try await withCheckedThrowingContinuation { box.install($0) }
    }

    func sendFinal(_ data: Data) async {
        let box = OneShotContinuation<Void>()
        // HTTP/1.1 一次请求一条连接。先用 FIN 完成写端，再由调用方 cancel；
        // 对端已半关闭写端时，直接 cancel 可能在较慢的系统上丢掉这个错误响应。
        send(content: data, isComplete: true, completion: .contentProcessed { error in
            if let error { box.resume(throwing: error) } else { box.resume(returning: ()) }
        })
        // 写失败只意味着对端不在了，没有补救动作。
        _ = try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            box.install(continuation)
        }
    }

    /// 挂起期间对端可能直接走人。`stateUpdateHandler` 只在连接被 reset 时才动，
    /// 普通的 FIN 要再挂一个 receive 才看得见。
    func watchForDisconnect(_ hold: LocalHookServer.Hold) {
        receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, isComplete, error in
            if isComplete || error != nil { hold.abandon() }
        }
    }
}
#endif // canImport(Network)
