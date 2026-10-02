import Foundation
#if canImport(Network)
import Network
#endif
#if canImport(os)
import os
#endif

/// Claude Code 的 hook 脚本 POST 进来的地方：监听绑 `127.0.0.1` 的随机高位端口，
/// 自带一个够用的 HTTP/1.1 解析（只认 POST + Content-Length），端口写进 `agent.json`。不引第三方依赖。
///
/// 监听与收发按平台分两份，其余（请求解析、挂起、回写的报文、端口文件）只有这一份：
/// 有 Network.framework 的平台用 `NWListener`（`LocalHookServer+Network.swift`），
/// 其余（Linux）用 POSIX socket（`LocalHookServer+POSIX.swift`，系统调用集中在 `LoopbackSocket.swift`）。
///
/// 本机工具服务器（`LocalToolAPI`，给 `botbus` CLI / MCP 用）是同一个实现的另一个实例：
/// 不写端口文件（地址经环境变量交给 agent），解析层的错误也回 JSON。两个实例互不相干。
///
/// **鉴权**：回环挡不住同机的别的用户（Linux 多用户服务器）。Claude hook 实例开 `sharedSecret`：
/// 每次 `start()` 换一个随机密钥写进 0600 的文件，请求头不对就 403，见 `LocalHookServer+Secret.swift`。
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
    /// 挂起响应的默认硬上限。对齐 hook 脚本那边的 `curl --max-time`，
    /// Agent 不能比它晚放手，否则脚本先超时、我们的响应就没人收了。
    /// 30 分钟：手机用户不一定立刻能回应，给够时间。
    public static let defaultHoldTimeout: TimeInterval = 1800
    /// hooks 实例的端口文件名（hook 脚本写死了读它）。
    public static let portFileName = "agent.json"
    public static let defaultMaxBodyBytes = 1 << 20
    /// 请求头的上限：hook 负载都在 body 里，头再长也属于不该收的东西。
    static let maxHeadBytes = 16 * 1024
    static let headSeparator = Data("\r\n\r\n".utf8)
    static let log = PlatformLogger(subsystem: "io.botbus.agent", category: "hookserver")

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

    /// Apple: `~/Library/Application Support/BotBus`。
    /// Linux: `$XDG_DATA_HOME/botbus` or `~/.local/share/botbus`。
    /// 测试一律注入临时目录，不碰这里。
    public static var defaultSupportDirectory: URL {
        #if os(Linux)
        let base: URL
        if let xdg = ProcessInfo.processInfo.environment["XDG_DATA_HOME"], !xdg.isEmpty {
            base = URL(fileURLWithPath: xdg, isDirectory: true)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/share", isDirectory: true)
        }
        return base.appendingPathComponent("botbus", isDirectory: true)
        #elseif os(Windows)
        // `%LOCALAPPDATA%\BotBus`：不放 Roaming，漫游配置文件不该把一台电脑的配对与存档带到另一台上。
        let local = ProcessInfo.processInfo.environment["LOCALAPPDATA"].flatMap { $0.isEmpty ? nil : $0 }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("AppData\\Local", isDirectory: true)
        return local.appendingPathComponent("BotBus", isDirectory: true)
        #else
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("BotBus", isDirectory: true)
        #endif
    }

    let handler: Handler
    let supportDirectory: URL
    let portFileName: String?
    let requestedPort: UInt16?
    let maxBodyBytes: Int
    let errorResponder: ErrorResponder
    let sharedSecret: SharedSecret?
    /// 当前这一轮 `start()` 的密钥。只在内存与 0600 的密钥文件里，不进日志。
    var activeSecret: String?

    let queue = DispatchQueue(label: "io.botbus.agent.hookserver")
#if canImport(Network)
    let live = LiveConnections<NWConnection>()
    var listener: NWListener?
#else
    let live = LiveConnections<SocketConnection>()
    var listener: SocketListener?
#endif

    /// 实际监听的端口，`start()` 之后有值。
    public internal(set) var port: UInt16?

    /// - Parameters:
    ///   - portFileName: 端口文件名，写在 `supportDirectory` 下；nil = 不写端口文件。
    ///   - sharedSecret: nil = 不鉴权（调用方自己有鉴权，或不对外）。开了就把密钥文件写在端口文件旁边。
    public init(supportDirectory: URL = LocalHookServer.defaultSupportDirectory,
                portFileName: String? = LocalHookServer.portFileName,
                maxBodyBytes: Int = LocalHookServer.defaultMaxBodyBytes,
                requestedPort: UInt16? = nil,
                sharedSecret: SharedSecret? = nil,
                errorResponder: @escaping ErrorResponder = { Response.text(status: $0, $1) },
                handler: @escaping Handler) {
        self.supportDirectory = supportDirectory
        self.sharedSecret = sharedSecret
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

    // 生命周期（`start()` / `stop()`）、来源校验（`isLoopbackAddress(_:)`）与每条连接的收发按平台实现，
    // 见 `LocalHookServer+Network.swift` / `LocalHookServer+POSIX.swift`。

    // MARK: - 每条连接（两个平台共用）

    nonisolated func serve(_ connection: some HookTransport, inFlight: HoldBox) async {
        let request: Request
        do {
            request = try await readRequest(from: connection)
        } catch let bad as BadRequest {
            // 畸形请求一律好好回个错误码，绝不 crash。
            await connection.sendFinal(Self.encode(errorResponder(bad.status, bad.message)))
            return
        } catch {
            // 连接层面的错误：对端已经不在了，回什么都没人收。
            return
        }
        if let rejected = await rejection(for: request) {
            await connection.sendFinal(Self.encode(rejected))
            return
        }

        let response: Response
        switch await handler(request) {
        case .now(let immediate):
            response = immediate
        case .hold(let hold):
            inFlight.set(hold)
            connection.watchForDisconnect(hold)
            response = await settle(hold)
            inFlight.clear()
        }
        await connection.sendFinal(Self.encode(response))
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

    // MARK: - 最小 HTTP/1.1

    struct BadRequest: Error {
        let status: Int
        let message: String
    }

    struct ReceivedChunk: Sendable {
        let data: Data
        let isComplete: Bool
    }

    private nonisolated func readRequest(from connection: some HookTransport) async throws -> Request {
        var buffer = Data()
        var reachedEOF = false
        var separator = buffer.range(of: Self.headSeparator)
        while separator == nil {
            guard buffer.count <= Self.maxHeadBytes else {
                throw BadRequest(status: 431, message: "请求头过长")
            }
            guard !reachedEOF else { throw BadRequest(status: 400, message: "请求头不完整") }
            guard let chunk = try await connection.receiveChunk() else {
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
            guard let chunk = try await connection.receiveChunk() else {
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

    /// 整个响应报文。一条连接一个请求：不做 keep-alive，hook 脚本每次都是新起一条 curl。
    nonisolated static func encode(_ response: Response) -> Data {
        var head = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
        if let contentType = response.contentType, response.status != 204 {
            head += "Content-Type: \(contentType)\r\n"
        }
        // 204 按规范不带 body，也不带 Content-Length。
        if response.status != 204 { head += "Content-Length: \(response.body.count)\r\n" }
        head += "Connection: close\r\n\r\n"

        var data = Data(head.utf8)
        if response.status != 204 { data.append(response.body) }
        return data
    }

    // MARK: - 状态码

    nonisolated static func reason(_ status: Int) -> String {
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

    func writePortFile(_ port: UInt16) {
        guard let portFileURL else { return }
        do {
            try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            try JSONEncoder().encode(PortFile(port: Int(port))).write(to: portFileURL, options: .atomic)
        } catch {
            // 写不了只是 hook 脚本找不到端口，服务本身照跑——不能因此让 Agent 起不来。
            Self.log.error("写端口文件失败：\(String(describing: error), privacy: .public)")
        }
    }
}

/// 解析层眼里的一条连接：Network.framework 的 `NWConnection` 与 POSIX socket 各实现一份，
/// 请求解析、挂起与回写只写一遍（`LocalHookServer.serve`）。
protocol HookTransport: AnyObject, Sendable {
    /// 读一段。`nil` = 对端把写端关了。数据与 FIN 可以在同一次读中到达（`isComplete`），必须一起带回解析器。
    func receiveChunk() async throws -> LocalHookServer.ReceivedChunk?
    /// 写出整个响应并关掉写端（FIN），之后由调用方 `cancel()`。写失败只意味着对端不在了，没有补救动作。
    func sendFinal(_ data: Data) async
    /// 挂起期间对端可能直接走人：看到 FIN 或出错就 `abandon()` 这个 hold。
    func watchForDisconnect(_ hold: LocalHookServer.Hold)
    /// 关掉连接。挂着的响应要因此被放掉（每个平台在自己的关闭回调里 `abandon()`）。
    func cancel()
}

/// 一条连接当前挂着的响应。连接断开与正常回答会同时来碰它，所以加锁。
final class HoldBox: @unchecked Sendable {
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
final class LiveConnections<Connection: HookTransport>: @unchecked Sendable {
    private let lock = NSLock()
    private var connections: [ObjectIdentifier: Connection] = [:]
    private var closed = false

    /// 已经在 stop 了就返回 false，调用方直接把连接关掉。
    func add(_ connection: Connection) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return false }
        connections[ObjectIdentifier(connection)] = connection
        return true
    }

    func remove(_ connection: Connection) {
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
