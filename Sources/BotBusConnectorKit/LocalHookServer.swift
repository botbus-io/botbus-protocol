import Foundation
import Network
import os

/// Claude Code 的 hook 脚本 POST 进来的地方：`NWListener` 绑 `127.0.0.1` 的随机高位端口，
/// 自带一个够用的 HTTP/1.1 解析（只认 POST + Content-Length），端口写进 `agent.json`。不引第三方依赖。
///
/// 本机工具服务器（`LocalToolAPI`，给 `botbus` CLI / MCP 用）是同一个实现的另一个实例：
/// 不写端口文件（地址经环境变量交给 agent），解析层的错误也回 JSON。两个实例互不相干。
///
/// **为什么要能"挂着不回"**：`PermissionRequest` 这条 hook 会一直阻塞在 HTTP 响应上，
/// 等手机上点允许或拒绝。所以 handler 除了"立刻回"，还能返回一个 `Hold`，把响应留在半空中，
/// 等 `approve` 命令来 `answer(_:)`。
///
/// **这正是本项目崩过一次的形状**：挂起的响应有三条路径抢同一个出口——被回答、超时、连接断开。
/// `CheckedContinuation` 第二次 resume 是无条件的运行时检查，Release 构建照样 SIGTRAP 把菜单栏进程打死。
/// 所以出口一律走 `OneShotContinuation`；超时也不用 TaskGroup 的"先到者胜"——那种写法输的那条分支
/// 会一直挂着，而这里超时必须是真的硬上限，由同一个盒子兜住。
public actor LocalHookServer {
    /// 挂起响应的默认硬上限。对齐 spec 6.3：hook 脚本那边 `curl --max-time 120`，
    /// Agent 不能比它晚放手，否则脚本先超时、我们的响应就没人收了。
    public static let defaultHoldTimeout: TimeInterval = 120
    /// hooks 实例的端口文件名（hook 脚本写死了读它）。
    public static let portFileName = "agent.json"
    public static let defaultMaxBodyBytes = 1 << 20
    /// 请求头的上限：hook 负载都在 body 里，头再长也属于不该收的东西。
    private static let maxHeadBytes = 16 * 1024
    private static let headSeparator = Data("\r\n\r\n".utf8)
    private static let log = Logger(subsystem: "io.botbus.agent", category: "hookserver")

    public typealias Handler = @Sendable (Request) async -> Reply
    /// 解析层（请求行、头、Content-Length、方法）出错时回什么。默认纯文本，工具服务器换成 JSON。
    public typealias ErrorResponder = @Sendable (_ status: Int, _ message: String) -> Response

    /// 解析出来的请求。只保留 hook 用得上的部分。
    public struct Request: Sendable {
        public var method: String
        /// 原始请求目标，含 query。
        public var target: String
        /// 去掉 query 的路径，路由用它。
        public var path: String
        /// 键一律小写，取值请用 `header(_:)`。
        public var headers: [String: String]
        public var body: Data

        public var bodyText: String { String(decoding: body, as: UTF8.self) }

        public func header(_ name: String) -> String? { headers[name.lowercased()] }
    }

    public struct Response: Sendable {
        public var status: Int
        public var contentType: String?
        public var body: Data

        public init(status: Int, contentType: String? = nil, body: Data = Data()) {
            self.status = status
            self.contentType = contentType
            self.body = body
        }

        public static func json(_ body: Data) -> Response {
            Response(status: 200, contentType: "application/json", body: body)
        }

        public static func json(_ text: String) -> Response { json(Data(text.utf8)) }

        public static func text(status: Int, _ message: String) -> Response {
            Response(status: status, contentType: "text/plain; charset=utf-8", body: Data(message.utf8))
        }

        /// 空响应。hook 脚本把 body 原样吐到 stdout，空 body 就等于"没有输出"，
        /// Claude Code 会回落到自己的权限弹窗——正是超时时想要的行为。
        public static let noContent = Response(status: 204)

        /// 连接已经没了才会用到：写不出去，只是给 `Hold` 一个明确的出口。
        static let abandoned = Response(status: 503)
    }

    /// 一个被挂起的响应。谁先到谁生效：`answer(_:)`、超时、连接断开抢的是同一个出口，
    /// 后到的一律静默丢弃（`OneShotContinuation` 保证不会二次 resume）。
    ///
    /// handler 自己造它、自己留一份（例如按 requestId 存进连接器），命令到了再 `answer(_:)`。
    public final class Hold: Sendable {
        /// 硬上限；到点了就用 `onTimeout` 的结果回。
        public let timeout: TimeInterval
        private let box = OneShotContinuation<Response>()
        private let fallback: @Sendable () -> Response

        public init(timeout: TimeInterval = LocalHookServer.defaultHoldTimeout,
                    onTimeout: @escaping @Sendable () -> Response = { .noContent }) {
            self.timeout = timeout
            self.fallback = onTimeout
        }

        /// 回答这个挂起的请求。第一个调用者生效返回 true；已经超时或断线过就返回 false。
        @discardableResult
        public func answer(_ response: Response) -> Bool { box.resume(returning: response) }

        @discardableResult
        func timedOut() -> Bool { box.resume(returning: fallback()) }

        @discardableResult
        func abandon() -> Bool { box.resume(returning: .abandoned) }

        func value() async -> Response {
            let settled = try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Response, Error>) in
                box.install(continuation)
            }
            // 本类型只走 resume(returning:)，nil 不会发生；真发生了也当成被放弃。
            return settled ?? .abandoned
        }
    }

    public enum Reply: Sendable {
        /// 立刻回。
        case now(Response)
        /// 挂起，等 `Hold.answer(_:)` 或超时。
        case hold(Hold)
    }

    public enum Failure: Error, Sendable, Equatable {
        case alreadyRunning
        case listenerFailed(String)
        case noPortAssigned
    }

    /// `~/Library/Application Support/BotBus`。测试一律注入临时目录，不碰这里。
    public static var defaultSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("BotBus", isDirectory: true)
    }

    private let handler: Handler
    private let supportDirectory: URL
    private let portFileName: String?
    private let requestedPort: UInt16?
    private let maxBodyBytes: Int
    private let errorResponder: ErrorResponder
    private let queue = DispatchQueue(label: "io.botbus.agent.hookserver")
    private let live = LiveConnections()

    private var listener: NWListener?
    /// 实际监听的端口，`start()` 之后有值。
    public private(set) var port: UInt16?

    /// - Parameter portFileName: 端口文件名，写在 `supportDirectory` 下；nil = 不写端口文件。
    public init(supportDirectory: URL = LocalHookServer.defaultSupportDirectory,
                portFileName: String? = LocalHookServer.portFileName,
                maxBodyBytes: Int = LocalHookServer.defaultMaxBodyBytes,
                requestedPort: UInt16? = nil,
                errorResponder: @escaping ErrorResponder = { Response.text(status: $0, $1) },
                handler: @escaping Handler) {
        self.supportDirectory = supportDirectory
        self.portFileName = portFileName
        self.maxBodyBytes = maxBodyBytes
        self.requestedPort = requestedPort
        self.errorResponder = errorResponder
        self.handler = handler
    }

    /// 端口文件的位置。hook 脚本从这里读端口。不写端口文件的实例是 nil。
    public nonisolated var portFileURL: URL? {
        portFileName.map { supportDirectory.appendingPathComponent($0) }
    }

    // MARK: - 生命周期

    /// 起监听并返回系统分配的端口。端口随后写进端口文件（配置了的话）。
    @discardableResult
    public func start() async throws -> UInt16 {
        guard listener == nil else { throw Failure.alreadyRunning }

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
        writePortFile(assigned)
        return assigned
    }

    /// 幂等：停监听、掐掉在跑的连接（挂着的响应会因此被放掉）、删端口文件。
    public func stop() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        port = nil
        live.cancelAll()
        if let portFileURL { try? FileManager.default.removeItem(at: portFileURL) }
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

    private nonisolated func serve(_ connection: NWConnection, inFlight: HoldBox) async {
        let request: Request
        do {
            request = try await readRequest(from: connection)
        } catch let bad as BadRequest {
            // 畸形请求一律好好回个错误码，绝不 crash。
            await write(errorResponder(bad.status, bad.message), to: connection)
            return
        } catch {
            // 连接层面的错误：对端已经不在了，回什么都没人收。
            return
        }

        let response: Response
        switch await handler(request) {
        case .now(let immediate):
            response = immediate
        case .hold(let hold):
            inFlight.set(hold)
            watchForDisconnect(connection, hold: hold)
            response = await settle(hold)
            inFlight.clear()
        }
        await write(response, to: connection)
    }

    /// 等一个挂起的响应。超时由同一个 `OneShotContinuation` 兜住——定时器直接往盒子里塞结果，
    /// 不是 TaskGroup 的"先到者胜"（那种写法输的那条分支会一直挂着）。
    private nonisolated func settle(_ hold: Hold) async -> Response {
        let timer = Task {
            do { try await Task.sleep(for: .seconds(hold.timeout)) } catch { return }
            hold.timedOut()
        }
        defer { timer.cancel() }
        return await hold.value()
    }

    /// 挂起期间对端可能直接走人。`stateUpdateHandler` 只在连接被 reset 时才动，
    /// 普通的 FIN 要再挂一个 receive 才看得见。
    private nonisolated func watchForDisconnect(_ connection: NWConnection, hold: Hold) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, isComplete, error in
            if isComplete || error != nil { hold.abandon() }
        }
    }

    // MARK: - 最小 HTTP/1.1

    private struct BadRequest: Error {
        let status: Int
        let message: String
    }

    private nonisolated func readRequest(from connection: NWConnection) async throws -> Request {
        var buffer = Data()
        var reachedEOF = false
        var separator = buffer.range(of: Self.headSeparator)
        while separator == nil {
            guard buffer.count <= Self.maxHeadBytes else {
                throw BadRequest(status: 431, message: "请求头过长")
            }
            guard !reachedEOF else { throw BadRequest(status: 400, message: "请求头不完整") }
            guard let chunk = try await receive(on: connection) else {
                throw BadRequest(status: 400, message: "请求头不完整")
            }
            buffer.append(chunk.data)
            reachedEOF = chunk.isComplete
            separator = buffer.range(of: Self.headSeparator)
        }
        guard let separator else { throw BadRequest(status: 400, message: "请求头不完整") }

        let head = String(decoding: buffer[..<separator.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let fields = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: false)
        guard fields.count == 3, fields[2].hasPrefix("HTTP/"), !fields[0].isEmpty, !fields[1].isEmpty else {
            throw BadRequest(status: 400, message: "请求行无法解析")
        }
        let method = fields[0].uppercased()
        let target = String(fields[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else {
                throw BadRequest(status: 400, message: "请求头无法解析")
            }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard !name.isEmpty else { throw BadRequest(status: 400, message: "请求头无法解析") }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        // hook 与工具调用都只 POST；别的方法明确回 405，省得将来有人以为这是个通用服务器。
        guard method == "POST" else {
            throw BadRequest(status: 405, message: "只支持 POST")
        }
        guard let text = headers["content-length"], let length = Int(text), length >= 0 else {
            throw BadRequest(status: 400, message: "缺少或非法的 Content-Length")
        }
        guard length <= maxBodyBytes else {
            throw BadRequest(status: 413, message: "请求体过大")
        }

        var body = Data(buffer[separator.upperBound...])
        while body.count < length {
            guard !reachedEOF else { throw BadRequest(status: 400, message: "请求体不完整") }
            guard let chunk = try await receive(on: connection) else {
                throw BadRequest(status: 400, message: "请求体不完整")
            }
            body.append(chunk.data)
            reachedEOF = chunk.isComplete
        }
        // 一条连接只服务一个请求，多出来的字节直接丢。
        if body.count > length { body = Data(body.prefix(length)) }

        let path = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? target
        return Request(method: method, target: target, path: path, headers: headers, body: body)
    }

    private struct ReceivedChunk {
        let data: Data
        let isComplete: Bool
    }

    /// 读一段。`nil` = 对端把写端关了。数据与 FIN 可以在同一次回调中到达，必须一起带回解析器。
    private nonisolated func receive(on connection: NWConnection) async throws -> ReceivedChunk? {
        let box = OneShotContinuation<ReceivedChunk?>()
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            if let data, !data.isEmpty {
                box.resume(returning: ReceivedChunk(data: data, isComplete: isComplete))
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

    private nonisolated func write(_ response: Response, to connection: NWConnection) async {
        var head = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
        if let contentType = response.contentType, response.status != 204 {
            head += "Content-Type: \(contentType)\r\n"
        }
        // 204 按规范不带 body，也不带 Content-Length。
        if response.status != 204 { head += "Content-Length: \(response.body.count)\r\n" }
        // 一条连接一个请求：不做 keep-alive，hook 脚本每次都是新起一条 curl。
        head += "Connection: close\r\n\r\n"

        var data = Data(head.utf8)
        if response.status != 204 { data.append(response.body) }

        let box = OneShotContinuation<Void>()
        // HTTP/1.1 一次请求一条连接。先用 FIN 完成写端，再由调用方 cancel；
        // 对端已半关闭写端时，直接 cancel 可能在较慢的系统上丢掉这个错误响应。
        connection.send(content: data, isComplete: true, completion: .contentProcessed { error in
            if let error { box.resume(throwing: error) } else { box.resume(returning: ()) }
        })
        // 写失败只意味着对端不在了，没有补救动作。
        _ = try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            box.install(continuation)
        }
    }

    private nonisolated static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 204: "No Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 408: "Request Timeout"
        case 413: "Payload Too Large"
        case 431: "Request Header Fields Too Large"
        case 500: "Internal Server Error"
        case 502: "Bad Gateway"
        case 503: "Service Unavailable"
        case 504: "Gateway Timeout"
        default: status < 400 ? "OK" : "Error"
        }
    }

    // MARK: - 端口文件

    private struct PortFile: Codable { var port: Int }

    private func writePortFile(_ port: UInt16) {
        guard let portFileURL else { return }
        do {
            try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            try JSONEncoder().encode(PortFile(port: Int(port))).write(to: portFileURL, options: .atomic)
        } catch {
            // 写不了只是 hook 脚本找不到端口，服务本身照跑——不能因此让 Agent 起不来。
            Self.log.error("写端口文件失败：\(String(describing: error))")
        }
    }
}

/// 一条连接当前挂着的响应。连接断开与正常回答会同时来碰它，所以加锁。
private final class HoldBox: @unchecked Sendable {
    private let lock = NSLock()
    private var hold: LocalHookServer.Hold?

    func set(_ hold: LocalHookServer.Hold) { lock.lock(); self.hold = hold; lock.unlock() }
    func clear() { lock.lock(); hold = nil; lock.unlock() }
    func take() -> LocalHookServer.Hold? {
        lock.lock(); defer { lock.unlock() }
        let taken = hold
        hold = nil
        return taken
    }
}

/// 在跑的连接。`stop()` 要把它们一次性掐掉，挂着的响应才会被放掉、serve 的任务才会退出。
private final class LiveConnections: @unchecked Sendable {
    private let lock = NSLock()
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var closed = false

    /// 已经在 stop 了就返回 false，调用方直接把连接关掉。
    func add(_ connection: NWConnection) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return false }
        connections[ObjectIdentifier(connection)] = connection
        return true
    }

    func remove(_ connection: NWConnection) {
        lock.lock()
        connections.removeValue(forKey: ObjectIdentifier(connection))
        lock.unlock()
    }

    func reopen() { lock.lock(); closed = false; lock.unlock() }

    func cancelAll() {
        lock.lock()
        closed = true
        let taken = Array(connections.values)
        connections = [:]
        lock.unlock()
        for connection in taken { connection.cancel() }
    }
}
