import Foundation
import BotBusConnectorKit
import BotBusProtocol
#if canImport(os)
import os
#endif

/// 一个已经在跑的 `codex app-server` 子进程。**这就是测试用的注入缝**：
/// 生产实现是 `CodexSubprocess`（`Foundation.Process` + 三根管子），测试实现是内存里的假管子，
/// 全套测试不起任何真实进程、不建线程、不发一次网络请求。
///
/// 约定：
/// - `readStdout()` 只允许被单个读循环**串行**调用（`CodexAppServer` 自己保证）。
///   返回的 `Data` 是**任意切分**的字节：可能是半行，也可能一口气好几行，分帧是调用方的事。
///   返回 `nil` = stdout 关了，进程正在或已经结束。
/// - `writeStdin(_:)` 必须把整个 buffer **原子地**写出去，否则两条并发的请求会交错成半行。
/// - `terminate()` 幂等。
public protocol CodexProcessHandle: Sendable {
    func readStdout() async throws -> Data?
    func writeStdin(_ data: Data) async throws
    func terminate()
    /// 等进程真的退出。只用于拿退出码与 stderr 末尾。
    func waitForExit() async -> CodexProcessExit
}

/// 怎么起一个 `codex app-server`。抛错表示这次没起成（`CodexAppServer` 会按重启节奏再试）。
public protocol CodexProcessLauncher: Sendable {
    func launch() throws -> any CodexProcessHandle
}

/// 时间的注入缝：重启延迟与请求硬超时都走它，测试里换成"记一笔然后等闸门"，不真的睡。
public typealias CodexSleeper = @Sendable (TimeInterval) async -> Void

/// 常驻的 `codex app-server` 子进程与它的协议层：分帧、请求应答对号、通知分发、挂起服务端请求、
/// 进程死了自动重启并把之前控制的线程 resume 回来。
///
/// **不做**命令语义——`startTask` / `followUp` / `approve` / `interrupt` 怎么映射是 Task 7 的
/// `CodexConnector` 的事。这里只提供 `request(_:params:)` / `notify(_:params:)` /
/// `respond(to:result:)` 三把工具和一条事件流。
///
/// 几条不显然的约定：
///
/// - **分帧是按行的**：一行一个 JSON 对象，没有 `Content-Length` 头，也没有 `jsonrpc` 字段。
///   一次 read 给回来的字节可能是半行，也可能是好几行，所以要一直攒到换行符为止。
/// - **请求 id 可能是字符串也可能是整数**。我们自己发的一律用整数，但服务端发来的审批请求
///   见过字符串 id，回复时必须原样回去，所以对号表的键是 `CodexRequestID` 而不是 `Int`。
/// - **服务端请求绝不自动回**。`item/commandExecution/requestApproval`、
///   `item/fileChange/requestApproval`、`item/permissions/requestApproval`、
///   `item/tool/requestUserInput` 到达时只挂起来并推一条事件，谁来回是上层的决定。
/// - **超时是同一个 `OneShotContinuation` 里的硬上限**，不是 TaskGroup 的"先到者胜"
///   （输的那条分支会一直挂着）。应答、超时、进程退出三条路径抢同一个盒子，第二个静默丢弃。
///   这个项目被二次 resume 的 `CheckedContinuation` 打死过一次，不再来第二回。
/// - **日志只记种类、方法名、id 与字节数**，绝不记 params / result 本体——那里面是用户的会话内容。
public actor CodexAppServer {
    /// 子进程退出后隔多久重启（spec 6.1）。
    public static let restartDelay: TimeInterval = 3
    /// 单条请求的硬超时。
    public static let defaultRequestTimeout: TimeInterval = 60
    /// 单行上限。正常的一行可以很大（整个补丁），但不能无上限地攒下去。
    public static let maxLineBytes = 16 * 1024 * 1024
    /// `item/started` 补丁缓存的条数上限。
    public static let maxCachedFileChangeItems = 128
    /// 同时挂起的服务端请求上限。超了从最旧的丢，免得对端发疯把内存吃光。
    public static let maxPendingServerRequests = 64
    /// 记住多少个线程的控制/运行状态。
    public static let maxTrackedThreads = 256
    public static let eventBufferLimit = 512

    private static let log = PlatformLogger(subsystem: "io.botbus.agent", category: "codexappserver")

    /// 会把某个线程变成"由本机驱动"的方法：发过这些，重启后就该把它 resume 回来。
    private static let threadControllingMethods: Set<String> = [
        "thread/resume", "turn/start", "turn/steer", "turn/interrupt",
    ]

    public struct Configuration: Sendable {
        /// `initialize` 里报给 app-server 的客户端名。
        public var clientName: String
        public var clientVersion: String
        public var requestTimeout: TimeInterval
        public var restartDelay: TimeInterval
        public var maxLineBytes: Int

        public init(clientName: String = "BotBus",
                    clientVersion: String = AgentIdentity.bundleVersion(),
                    requestTimeout: TimeInterval = CodexAppServer.defaultRequestTimeout,
                    restartDelay: TimeInterval = CodexAppServer.restartDelay,
                    maxLineBytes: Int = CodexAppServer.maxLineBytes) {
            self.clientName = clientName
            self.clientVersion = clientVersion
            self.requestTimeout = requestTimeout
            self.restartDelay = restartDelay
            self.maxLineBytes = maxLineBytes
        }
    }

    /// 一个线程在本机眼里的样子。`controlled` = 本机发过命令；`running` = 最后一条通知说它在跑。
    private struct ThreadState {
        var controlled = false
        var running = false
    }

    /// 一条在途请求。应答、超时、进程退出抢同一个盒子。
    private struct PendingRequest {
        let method: String
        let box: OneShotContinuation<JSONValue>
        let timer: Task<Void, Never>
    }

    /// 一代子进程。换一代就换一个实例，迟到的读循环靠 `generation` 认出自己已经过期。
    private final class Live: @unchecked Sendable {
        let generation: Int
        let handle: any CodexProcessHandle
        var readLoop: Task<Void, Never>?
        var handshake: Task<Void, Error>?
        var resume: Task<Void, Never>?

        init(generation: Int, handle: any CodexProcessHandle) {
            self.generation = generation
            self.handle = handle
        }
    }

    private let launcher: any CodexProcessLauncher
    private let configuration: Configuration
    private nonisolated let sleeper: CodexSleeper

    /// `start()` 过且没 `stop()` 过。决定进程死了要不要重启。
    private var active = false
    private var generation = 0
    private var live: Live?
    private var restartTask: Task<Void, Never>?
    /// 协议 3.7：最近一次起子进程失败时错误带的原因（找不到 codex → `agentNotInstalled`），起成功就清掉。
    /// 起不来时 `launchProcess` 只排重启，请求要到 `notRunning` 才失败，原因得挂在那上面才到得了手机。
    private var launchFailureDiagnosis: FailureDiagnosis?

    private var nextRequestNumber: Int64 = 1
    private var inFlight: [CodexRequestID: PendingRequest] = [:]

    private var serverRequests: [String: CodexServerRequest] = [:]
    private var serverRequestOrder: [String] = []

    /// itemId → 那个 `fileChange` 条目的补丁。审批请求不带 diff，只能从这里配对。
    private var fileChangeCache: [String: [CodexFileChange]] = [:]
    private var fileChangeOrder: [String] = []

    private var threads: [String: ThreadState] = [:]
    private var threadOrder: [String] = []
    /// 进程死的那一刻，"由本机控制且还在跑"的线程。下一代握手完就逐个 `thread/resume`。
    private var pendingResumes: [String] = []

    private var eventContinuation: AsyncStream<CodexAppServerEvent>.Continuation?
    private var eventSubscription = 0

    public init(launcher: any CodexProcessLauncher,
                configuration: Configuration = Configuration(),
                sleeper: @escaping CodexSleeper = { seconds in
                    try? await Task.sleep(for: .seconds(seconds))
                }) {
        self.launcher = launcher
        self.configuration = configuration
        self.sleeper = sleeper
    }

    // MARK: - 事件流

    /// 事件出口。**只允许一个订阅者**（`CodexConnector`）：再调一次会终止上一条流并接管。
    /// 没有订阅者时事件直接丢弃，不攒历史。
    public func events() -> AsyncStream<CodexAppServerEvent> {
        eventSubscription += 1
        let generation = eventSubscription
        eventContinuation?.finish()
        var captured: AsyncStream<CodexAppServerEvent>.Continuation!
        let stream = AsyncStream<CodexAppServerEvent>(bufferingPolicy: .bufferingNewest(Self.eventBufferLimit)) {
            captured = $0
        }
        captured.onTermination = { [weak self] _ in
            Task { await self?.forgetSubscription(generation) }
        }
        eventContinuation = captured
        return stream
    }

    private func forgetSubscription(_ generation: Int) {
        guard eventSubscription == generation else { return }
        eventContinuation = nil
    }

    private func publish(_ event: CodexAppServerEvent) {
        eventContinuation?.yield(event)
    }

    // MARK: - 生命周期

    /// 起子进程并开始握手。幂等：已经在跑就什么都不做。
    /// 不等握手完成就返回——握手由第一条 `request(_:)` 自动等。
    public func start() {
        guard !active else { return }
        active = true
        launchProcess()
    }

    /// 停掉：不再重启、掐掉读循环、终止子进程、把所有在途请求与挂起的服务端请求放掉。幂等。
    public func stop() {
        active = false
        restartTask?.cancel()
        restartTask = nil
        if let live {
            live.readLoop?.cancel()
            live.handshake?.cancel()
            live.resume?.cancel()
            live.handle.terminate()
            self.live = nil
        }
        failAllInFlight(CodexAppServerError(.notRunning, "Codex app-server 已停止"))
        serverRequests.removeAll()
        serverRequestOrder.removeAll()
        fileChangeCache.removeAll()
        fileChangeOrder.removeAll()
        pendingResumes.removeAll()
    }

    /// 当前是不是有一个活着的子进程（不代表握手已完成）。
    public var isProcessAlive: Bool { live != nil }
    /// 已经起过几代子进程。第一代是 1，每重启一次加一。
    public var processGeneration: Int { generation }

    private func launchProcess() {
        guard active, live == nil else { return }
        generation += 1
        let mine = generation
        let handle: any CodexProcessHandle
        do {
            handle = try launcher.launch()
            launchFailureDiagnosis = nil
        } catch {
            launchFailureDiagnosis = (error as? any FailureDiagnosing)?.diagnosis
            Self.log.error("起 codex app-server 失败（第 \(mine, privacy: .public) 代）：\(String(describing: error), privacy: .public)")
            publish(.exited(CodexProcessExit(status: -1, reason: "无法启动 codex app-server"),
                            restartingIn: configuration.restartDelay))
            scheduleRestart(after: mine)
            return
        }
        let live = Live(generation: mine, handle: handle)
        self.live = live
        Self.log.info("codex app-server 起来了（第 \(mine, privacy: .public) 代）")
        publish(.started(generation: mine))
        live.readLoop = Task { [weak self] in await self?.runReadLoop(live) }
        live.handshake = Task { [weak self] in
            guard let self else { throw CodexAppServerError.notRunning() }
            do {
                try await self.performHandshake(live)
            } catch {
                await self.handshakeFailed(live, error: error)
                throw error
            }
        }
    }

    /// 握手没成：进程可能还活着但已经没用了。掐掉它，让读循环收尾走正常的重启流程。
    private func handshakeFailed(_ broken: Live, error: Error) {
        guard live === broken else { return }
        Self.log.error("Codex 握手失败：\(Self.describe(error), privacy: .public)")
        broken.handle.terminate()
    }

    private func scheduleRestart(after generation: Int) {
        guard active else { return }
        restartTask?.cancel()
        let delay = configuration.restartDelay
        let sleeper = self.sleeper
        restartTask = Task { [weak self] in
            await sleeper(delay)
            if Task.isCancelled { return }
            await self?.relaunch(after: generation)
        }
    }

    private func relaunch(after generation: Int) {
        guard active, live == nil, self.generation == generation else { return }
        restartTask = nil
        launchProcess()
    }

    // MARK: - 握手

    private func performHandshake(_ live: Live) async throws {
        let params: JSONValue = [
            "clientInfo": [
                "name": .string(configuration.clientName),
                "version": .string(configuration.clientVersion),
            ],
        ]
        // 这一条必须是写出去的第一行，所以它不走 `request(_:)`（那会先等握手，自己等自己）。
        _ = try await perform(method: "initialize", params: params,
                              timeout: configuration.requestTimeout, live: live)
        try await send(.notification(method: "initialized", params: nil), live: live)
        publish(.ready(generation: live.generation))
        // resume 放到握手之后的独立任务里：真实 resume 可能要几秒，不该把后面的命令全堵住。
        live.resume = Task { [weak self] in await self?.resumeControlledThreads(live) }
    }

    /// 重启后把之前由本机控制、当时还在跑的线程逐个 `thread/resume`（spec 6.1）。
    private func resumeControlledThreads(_ live: Live) async {
        let ids = pendingResumes
        pendingResumes = []
        guard !ids.isEmpty else { return }
        Self.log.info("重启后 resume \(ids.count, privacy: .public) 个线程")
        publish(.resumingAfterRestart(threadIds: ids))
        for threadId in ids {
            guard self.live === live else { return }
            markControlled(threadId: threadId)
            do {
                _ = try await perform(method: "thread/resume", params: ["threadId": .string(threadId)],
                                      timeout: configuration.requestTimeout, live: live)
            } catch {
                // resume 失败不致命：那条线程回落成只读观察即可，别把重启流程一起拖垮。
                Self.log.error("thread/resume 失败：\(Self.describe(error), privacy: .public)")
            }
        }
    }

    // MARK: - 对外的三把工具

    /// 发一条请求并等应答。会先等握手完成（`initialize` 永远是第一行）。
    ///
    /// `timeout` 是**硬上限**，由同一个 `OneShotContinuation` 兜住：到点就抛 `.timedOut`，
    /// 迟到的应答只会撞上一个已经关了的盒子，不会二次 resume。
    @discardableResult
    public func request(_ method: String, params: JSONValue? = nil,
                        timeout: TimeInterval? = nil) async throws -> JSONValue {
        try await waitForHandshake()
        guard let live else { throw notRunning() }
        // 发过这条就等于本机在驱动这个线程：重启后要把它 resume 回来。
        if Self.threadControllingMethods.contains(method), let id = params?["threadId"]?.stringValue {
            markControlled(threadId: id)
        }
        let result = try await perform(method: method, params: params,
                                       timeout: timeout ?? configuration.requestTimeout, live: live)
        // `thread/start` 的 id 只能从应答里拿。
        if method == "thread/start", let id = result.path("thread", "id")?.stringValue {
            markControlled(threadId: id)
        }
        return result
    }

    /// 发一条不需要应答的通知。
    public func notify(_ method: String, params: JSONValue? = nil) async throws {
        try await waitForHandshake()
        guard let live else { throw notRunning() }
        try await send(.notification(method: method, params: params), live: live)
    }

    /// 回复一条挂起的服务端请求。**只有上层调它**——`CodexAppServer` 自己永远不回审批。
    /// `key` 是 `CodexServerRequest.key`。不在挂起表里就抛 `.unknownRequest`。
    public func respond(to key: String, result: JSONValue) async throws {
        try await respond(to: key, message: { .response(id: $0, result: result) })
    }

    /// 用 JSON-RPC 错误回复一条挂起的服务端请求（例如不支持的 `item/tool/call`）。
    public func respond(to key: String, errorCode: Int, message text: String) async throws {
        try await respond(to: key, message: { .failure(id: $0, code: errorCode, message: text) })
    }

    private func respond(to key: String, message: (CodexRequestID) -> CodexOutgoingMessage) async throws {
        guard let request = serverRequests[key] else {
            throw CodexAppServerError(.unknownRequest, "没有挂起的 Codex 请求 \(key)")
        }
        guard let live else { throw notRunning() }
        try await send(message(request.id), live: live)
        // 写成功才从表里摘：写失败时请求还挂着，上层可以重试。
        dropServerRequest(key)
    }

    // MARK: - 挂起的服务端请求

    /// 当前挂着、等人回答的服务端请求。按到达顺序。
    public func pendingServerRequests() -> [CodexServerRequest] {
        serverRequestOrder.compactMap { serverRequests[$0] }
    }

    public func pendingServerRequest(key: String) -> CodexServerRequest? { serverRequests[key] }

    /// 丢掉某个线程（可选再限定某一轮）所有还挂着的请求，不回复。
    /// 轮次被中断时用：那些请求已经没人收了。返回被丢掉的那些。
    @discardableResult
    public func discardServerRequests(threadId: String, turnId: String? = nil) -> [CodexServerRequest] {
        let doomed = serverRequestOrder.compactMap { serverRequests[$0] }.filter {
            $0.threadId == threadId && (turnId == nil || $0.turnId == turnId)
        }
        for request in doomed { dropServerRequest(request.key) }
        return doomed
    }

    private func dropServerRequest(_ key: String) {
        guard serverRequests.removeValue(forKey: key) != nil else { return }
        serverRequestOrder.removeAll { $0 == key }
    }

    // MARK: - 线程控制记账

    /// 标记某个线程由本机驱动。`request(_:)` 对 `thread/start` / `thread/resume` / `turn/*`
    /// 会自动标，上层一般不必手动调；从只读观察接管一个桌面线程时可以先手动标上。
    public func markControlled(threadId: String) {
        touchThread(threadId) { $0.controlled = true }
    }

    /// 交还控制权（任务结束、连接器不再驱动它）。重启后不会再 resume 它。
    public func releaseControl(threadId: String) {
        guard threads[threadId] != nil else { return }
        threads[threadId]?.controlled = false
        pendingResumes.removeAll { $0 == threadId }
    }

    public func controlledThreads() -> [String] {
        threadOrder.filter { threads[$0]?.controlled == true }
    }

    /// 由本机控制、且最后一条通知说还在跑的线程。重启时要 resume 的就是这批。
    public func runningControlledThreads() -> [String] {
        threadOrder.filter { threads[$0]?.controlled == true && threads[$0]?.running == true }
    }

    private func touchThread(_ id: String, _ mutate: (inout ThreadState) -> Void) {
        var state = threads[id] ?? ThreadState()
        if threads[id] == nil { threadOrder.append(id) }
        mutate(&state)
        threads[id] = state
        // 上限只淘汰"已经不由本机控制"的，别把还要 resume 的线程挤掉。
        while threadOrder.count > Self.maxTrackedThreads,
              let victim = threadOrder.first(where: { $0 != id && threads[$0]?.controlled != true }) {
            threads.removeValue(forKey: victim)
            threadOrder.removeAll { $0 == victim }
        }
    }

    // MARK: - 请求对号

    /// 没有活着的子进程：「还没就绪」，带上最近一次起不来的原因。
    private func notRunning() -> CodexAppServerError {
        var error = CodexAppServerError.notRunning()
        error.diagnosis = launchFailureDiagnosis
        return error
    }

    private func waitForHandshake() async throws {
        guard let handshake = live?.handshake else { throw notRunning() }
        do {
            try await handshake.value
        } catch {
            throw error as? CodexAppServerError ?? CodexAppServerError(.notRunning, Self.describe(error))
        }
    }

    private func perform(method: String, params: JSONValue?, timeout: TimeInterval,
                         live: Live) async throws -> JSONValue {
        let id = CodexRequestID.number(nextRequestNumber)
        nextRequestNumber += 1
        let box = OneShotContinuation<JSONValue>()
        // 超时是同一个盒子里的硬上限：定时器直接往盒子里塞错误，不是 TaskGroup 的"先到者胜"。
        let sleeper = self.sleeper
        let timer = Task { [weak self] in
            await sleeper(timeout)
            guard !Task.isCancelled else { return }
            guard box.resume(throwing: CodexAppServerError.timedOut(method: method, seconds: timeout)) else { return }
            Self.log.error("Codex \(method, privacy: .public) \(id.key, privacy: .public) 超时")
            await self?.forgetInFlight(id)
        }
        inFlight[id] = PendingRequest(method: method, box: box, timer: timer)
        do {
            try await send(.request(id: id, method: method, params: params), live: live)
        } catch {
            inFlight.removeValue(forKey: id)
            timer.cancel()
            throw error
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { box.install($0) }
    }

    private func forgetInFlight(_ id: CodexRequestID) {
        inFlight.removeValue(forKey: id)
    }

    private func resolve(_ id: CodexRequestID, with result: Result<JSONValue, Error>) {
        guard let pending = inFlight.removeValue(forKey: id) else {
            // 超时之后迟到的应答会走到这里。不是错误，记一笔就好。
            Self.log.debug("无人认领的应答 \(id.key, privacy: .public)")
            return
        }
        pending.timer.cancel()
        switch result {
        case .success(let value): pending.box.resume(returning: value)
        case .failure(let error): pending.box.resume(throwing: error)
        }
    }

    private func failAllInFlight(_ error: CodexAppServerError) {
        let taken = inFlight
        inFlight.removeAll()
        for (_, pending) in taken {
            pending.timer.cancel()
            pending.box.resume(throwing: error)
        }
    }

    // MARK: - 写

    private func send(_ message: CodexOutgoingMessage, live: Live) async throws {
        let encoded: Data
        do {
            encoded = try message.encoded()
        } catch {
            throw CodexAppServerError(.transport, "无法编码 Codex \(message.logDescription)")
        }
        var line = encoded
        line.append(0x0A) // 分帧就是这一个换行符：没有 Content-Length 头。
        do {
            try await live.handle.writeStdin(line)
        } catch {
            throw CodexAppServerError(.transport, "写 Codex stdin 失败：\(Self.describe(error))")
        }
        // 只记方法名、id 与字节数；载荷里是用户的会话内容，一个字都不进日志。
        Self.log.debug("→ \(message.logDescription, privacy: .public) \(line.count, privacy: .public)B")
    }

    // MARK: - 读与分帧

    private func runReadLoop(_ live: Live) async {
        var buffer = Data()
        /// 攒过头（对端一直不给换行符）就整段丢掉，不能无限长。
        var overflowed = false
        while !Task.isCancelled {
            let chunk: Data?
            do {
                chunk = try await live.handle.readStdout()
            } catch {
                Self.log.error("读 Codex stdout 失败：\(Self.describe(error), privacy: .public)")
                break
            }
            guard let chunk else { break }
            if chunk.isEmpty { continue }
            buffer.append(chunk)
            // 一次 read 可能给回半行，也可能给回好几行：只处理到最后一个换行符为止，剩下的攒着。
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer = buffer[buffer.index(after: newline)...]
                if overflowed {
                    // 丢掉的那一行的尾巴，跳过。
                    overflowed = false
                    continue
                }
                ingest(Data(line))
            }
            buffer = Data(buffer)
            if buffer.count > configuration.maxLineBytes {
                Self.log.error("Codex 单行超过 \(self.configuration.maxLineBytes, privacy: .public) 字节，丢弃")
                buffer.removeAll(keepingCapacity: false)
                overflowed = true
            }
        }
        await handleExit(live)
    }

    private func ingest(_ line: Data) {
        // 容忍 CRLF 与空行。
        var trimmed = line
        if trimmed.last == 0x0D { trimmed = trimmed.dropLast() }
        guard !trimmed.isEmpty else { return }
        guard let message = CodexIncomingMessage(line: Data(trimmed)) else {
            Self.log.warning("无法解析的 Codex 行，\(trimmed.count, privacy: .public)B")
            return
        }
        Self.log.debug("← \(message.logDescription, privacy: .public) \(trimmed.count, privacy: .public)B")
        switch message {
        case .response(let id, let result):
            resolve(id, with: .success(result))
        case .failure(let id, let code, let text):
            resolve(id, with: .failure(CodexAppServerError(.server(code: code), "Codex 返回错误 \(code)：\(text)")))
        case .request(let id, let method, let params):
            surface(id: id, method: method, params: params)
        case .notification(let method, let params):
            dispatch(method: method, params: params)
        }
    }

    // MARK: - 服务端请求：只挂起，绝不自动回

    private func surface(id: CodexRequestID, method: String, params: JSONValue) {
        // `item/fileChange/requestApproval` 不带 diff，从同 itemId 的 `item/started` 缓存里补。
        let cached = params["itemId"]?.stringValue.flatMap { fileChangeCache[$0] } ?? []
        let request = CodexServerRequest(id: id, method: method, params: params, fileChanges: cached)
        if serverRequests.updateValue(request, forKey: request.key) == nil {
            serverRequestOrder.append(request.key)
        }
        while serverRequestOrder.count > Self.maxPendingServerRequests, let oldest = serverRequestOrder.first {
            Self.log.error("挂起的 Codex 请求过多，丢掉最旧的 \(oldest, privacy: .public)")
            dropServerRequest(oldest)
        }
        Self.log.info("挂起 Codex 服务端请求 \(method, privacy: .public) \(request.key, privacy: .public)")
        publish(.serverRequest(request))
    }

    // MARK: - 通知分发

    private func dispatch(method: String, params: JSONValue) {
        if method == "serverRequest/resolved", let rawID = params["requestId"] {
            if let number = rawID.intValue { dropServerRequest(CodexRequestID.number(number).key) }
            else if let text = rawID.stringValue { dropServerRequest(CodexRequestID.text(text).key) }
        }
        let notification = CodexNotification(method: method, params: params)
        switch notification {
        case .turnStarted(let threadId, _):
            touchThread(threadId) { $0.running = true }
        case .turnCompleted(let threadId, let turnId, _, _, _):
            touchThread(threadId) { $0.running = false }
            // 轮次结束了，这一轮里还挂着的审批已经没人收，静默丢掉。
            discardServerRequests(threadId: threadId, turnId: turnId.isEmpty ? nil : turnId)
        case .threadStatusChanged(let threadId, let status):
            switch status {
            case .active: touchThread(threadId) { $0.running = true }
            case .idle, .systemError, .notLoaded: touchThread(threadId) { $0.running = false }
            case .unknown: break
            }
        case .itemStarted(_, _, let item), .itemCompleted(_, _, let item):
            cacheFileChanges(item)
        case .threadStarted, .agentMessageDelta, .serverError, .other:
            break
        }
        publish(.notification(notification))
    }

    private func cacheFileChanges(_ item: CodexItem) {
        guard !item.changes.isEmpty else { return }
        if fileChangeCache.updateValue(item.changes, forKey: item.id) == nil {
            fileChangeOrder.append(item.id)
        }
        while fileChangeOrder.count > Self.maxCachedFileChangeItems, let oldest = fileChangeOrder.first {
            fileChangeCache.removeValue(forKey: oldest)
            fileChangeOrder.removeFirst()
        }
    }

    // MARK: - 进程退出

    private func handleExit(_ dead: Live) async {
        // 已经换代了（或者被 stop() 了）：这个读循环是上一代的尾巴，什么都不做。
        guard live === dead else { return }
        live = nil
        dead.handshake?.cancel()
        dead.resume?.cancel()
        let exit = await dead.handle.waitForExit()
        // 再确认一次：等退出码的这段时间里可能已经 stop() 又 start() 过了。
        guard generation == dead.generation else { return }

        // 进程死的那一刻还在跑、且由本机控制的线程，重启后要 resume 回来。
        pendingResumes = runningControlledThreads()
        for id in pendingResumes { threads[id]?.running = false }

        failAllInFlight(CodexAppServerError.processExited(method: "在途请求"))
        serverRequests.removeAll()
        serverRequestOrder.removeAll()
        fileChangeCache.removeAll()
        fileChangeOrder.removeAll()

        Self.log.error("codex app-server 退出（第 \(dead.generation, privacy: .public) 代，status=\(exit.status, privacy: .public)），\(self.active ? "准备重启" : "不重启", privacy: .public)")
        publish(.exited(exit, restartingIn: active ? configuration.restartDelay : nil))
        guard active else {
            pendingResumes.removeAll()
            return
        }
        scheduleRestart(after: dead.generation)
    }

    private static func describe(_ error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty { return localized }
        return String(describing: error)
    }
}
