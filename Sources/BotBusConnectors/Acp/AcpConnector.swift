import Foundation
#if canImport(os)
import os
#endif
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif
import BotBusProtocol
import BotBusConnectorKit

/// 起一个 ACP agent 子进程的全部参数。
public struct AcpLaunchRequest: Hashable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: String

    public init(executable: String, arguments: [String], environment: [String: String], workingDirectory: String) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
    }

    /// 生产用：`CodexSubprocessLauncher` 只是"起进程 + 三根管子"，和 Codex 协议无关。
    public static let subprocess: AcpLauncherFactory = { request in
        CodexSubprocessLauncher(executablePath: request.executable, arguments: request.arguments,
                                environment: request.environment,
                                currentDirectory: URL(fileURLWithPath: request.workingDirectory, isDirectory: true))
    }
}

/// 可替换的启动器：测试注入内存里的假 agent。
public typealias AcpLauncherFactory = @Sendable (AcpLaunchRequest) -> any CodexProcessLauncher

/// 一个 ACP agent（spec「第一期」）。按需拉起子进程，把 ACP 会话对应成 BotBus 任务；
/// agent 自己的进程也可以经反向扩展连进来（见 `AcpConnector+Reverse.swift`）。
///
/// 所有权：BotBus 在跑的一轮、反向连接在报的会话归 `.live`；一轮结束或连接断开时交还，
/// 由 `AcpHub` 的全量对账（`staticTasks()`）接住，所以交还后任务不会消失。
///
/// 子进程的代际：每次拉起（以及每次我们主动关掉）都让 `generation` 加一。我们主动关进程时**先**把
/// `running` 清掉再 terminate，所以"进程退出时 `running` 仍是它"就说明是意外退出；握手回来发现代数
/// 已经变了（期间被停用、配置变了）的进程就地关掉，不会复活。
///
/// 反向扩展的文件要读写这里的状态，所以状态是 internal 而不是 private。
public actor AcpConnector {
    public static let idleTimeout: TimeInterval = 600
    /// 内存里最多留这么多会话的完整对话记录（按最近更新，在跑的与反向连接在报的不算）。
    /// 超出的只留任务记录，要看时再 `session/load`。
    static let maxTranscripts = 100
    static let releaseRetryDelay: TimeInterval = 1
    static let log = PlatformLogger(subsystem: "io.botbus.agent", category: "acp")

    /// 健康回报。`handshakeFailed` 只在确定对方不是（能用的）ACP agent 时为 true：进程起不来、握手完成前就退出、
    /// `initialize` 回的不是 ACP、协议版本不对。`initialize` **超时不算**——登录时冷启动的 node agent 可能超过
    /// 10 秒，算进去就会被藏到 app 重启。登录过期（degraded）、握手成功之后的崩溃、被我们作废的那一代
    /// （停用、换配置）也都是 false。hub 据此把没验证过的注册表 agent 藏起来（按文件名认出来的不一定是 ACP agent）。
    public typealias HealthHandler = @Sendable (_ id: String, _ status: ConnectorInfo.Status, _ message: String?,
                                                _ handshakeFailed: Bool) async -> Void

    public nonisolated let id: String
    /// 会话对应成哪种任务（见 `AcpTaskIdentity`）。`AcpHub` 建的都是 `.acp(connectorId: spec.id)`。
    public nonisolated let identity: AcpTaskIdentity
    public private(set) var spec: AcpAgentSpec

    let store: TaskStore
    let tools: @Sendable () -> AgentToolsConfiguration?
    let registry: TaskContextRegistry
    let archive: AcpSessionArchive
    private let openCodeReader: OpenCodeSessionReader?
    /// 自己拉起 agent 之前读一次工作目录（协议 3.7）。
    private let directoryProbe: DirectoryProbe
    private var localTasks: [TaskRecord] = []
    private var localBaselined = false
    let now: @Sendable () -> Date
    /// 健康变化（起不来、登录过期、又好了）。hub 转给 ConnectorRegistry 并重发快照。
    let onHealth: HealthHandler
    /// 静态任务变了（一轮结束、列表刷新、进程退出、反向连接断开）。hub 据此做一次全量对账。
    let onTasksChanged: @Sendable () async -> Void
    private let launcher: AcpLauncherFactory
    private let clientVersion: String
    private let idleTimeout: TimeInterval
    private let initializeTimeout: TimeInterval

    struct Running {
        let handle: any CodexProcessHandle
        let client: AcpClient
        let capabilities: AcpCapabilities
        let generation: Int
    }

    /// 一轮 BotBus 自己发的 `session/prompt`。
    struct Turn {
        /// 收尾只认这一轮自己：`stop()` 已经替它收过尾、同一会话又起了新一轮时，迟到的收尾什么都不做。
        let id: UUID
        let task: Task<Void, Never>
        /// 发这一轮的子进程代数：主动关掉那一代时，它的轮次记成 interrupted 而不是 failed。
        let generation: Int
    }

    /// 载入途中反向连接接管了这个会话：之后一律走反向连接，这次载入作废。
    private struct TakenOverByReverse: Error {}

    private var running: Running?
    private var starting: Task<Running, Error>?
    private var generation = 0
    /// 握手还没回来就已经退出的那一代（最多一条）：握手回来时据此拒绝，不把死进程记成 `running`。
    private var exitedEarly: Set<Int> = []
    /// 最近一次握手得到的能力；进程关掉后仍留着，决定 controllable 与要不要为列表拉起进程。
    private(set) var knownCapabilities: AcpCapabilities?
    /// 最近一次报给 hub 的健康状态。degraded（登录过期）之后再有请求成功就报回 ok。
    private var reportedHealth: ConnectorInfo.Status?
    /// App 正在退出（`shutdown()`）：此后不再拉起任何进程。
    private var isShutDown = false

    var sessions: [String: AcpSessionState] = [:]
    /// 在当前子进程里建过或载入过的会话：只有它们能直接 prompt。
    var loaded: Set<String> = []
    let liveOwnerToken = UUID()
    /// 在跑的一轮：sessionId → 发 prompt 的那个 Task。
    var turns: [String: Turn] = [:]
    /// 被我们主动关掉进程打断的轮次（配置变了、空闲）：收尾时记 interrupted。
    private var cancelledTurns: Set<String> = []
    /// 正在准备续聊（拉起进程、载入会话）的会话：挡住同一会话的并发续聊。
    private var preparing: Set<String> = []
    /// 正在 `session/load` 的会话：续聊与读记录并发时共用同一次载入，不重放两遍。
    private var loads: [String: Task<Void, Error>] = [:]
    /// 正在重放的历史：先放进一份新的状态，载入成功才换上去，失败就留着原来的对话记录。
    private var replays: [String: AcpSessionState] = [:]
    /// 进行中的命令数（新建、续聊、读记录）。不为 0 时不关进程——否则 `session/new` 还没回来，
    /// 进程就可能被当成空闲关掉。
    private var activeCommands = 0
    /// 进行中的列表刷新数。只在刷新期间挡住关进程，**不算**活动：hub 每分钟刷一次列表，
    /// 若算活动，空闲计时就永远到不了期。
    private var activeListRefreshes = 0
    /// 最近一次真正的命令活动（命令开始 / 结束、一轮结束）。空闲从这里起算。
    private var lastCommandActivity: Date = .distantPast
    /// 对话记录份数上限，默认 `maxTranscripts`；测试改小。
    var transcriptLimit = AcpConnector.maxTranscripts
    /// 挂起的审批：sessionId → 等手机回答的那个盒子。
    var waiters: [String: OneShotContinuation<AcpPermissionOutcome>] = [:]
    /// 已在电脑上答掉的审批（反向扩展）：sessionId → toolCallId。
    var resolvedElsewhere: [String: String] = [:]
    /// `session/list` 最近一次的结果。
    private var listed: [String: AcpSessionInfo] = [:]
    /// 这个连接器成功列过一次 `session/list`。见 `isListBaselined`。
    private var listedOnce = false
    private var idleTask: Task<Void, Never>?
    /// 反向连接（见 `AcpConnector+Reverse.swift`）。
    var links: [UUID: ReverseLink] = [:]
    /// 哪个会话由哪条反向连接在报。
    var reverseOwner: [String: UUID] = [:]
    /// 反向连接上 BotBus 自己发的那一轮 `session/prompt`：sessionId → 这一轮的标记。
    /// prompt 的应答只收它自己这一轮，不能把 agent 随后在终端里开的新一轮当成它收尾。
    var reverseTurns: [String: UUID] = [:]

    struct ReverseLink {
        let peer: JSONRPCPeer
        let capabilities: AcpHello.Capabilities
        let close: @Sendable () -> Void
    }

    /// - Parameter identity: nil = 第三方 agent（`.acp(connectorId: spec.id)`）。一档来源传 `.builtin(...)`，
    ///   `spec.id` 仍作健康回报与本机记录的键。
    public init(spec: AcpAgentSpec, identity: AcpTaskIdentity? = nil, store: TaskStore,
                launcher: @escaping AcpLauncherFactory = AcpLaunchRequest.subprocess,
                tools: @escaping @Sendable () -> AgentToolsConfiguration? = { nil },
                registry: TaskContextRegistry = TaskContextRegistry(),
                archive: AcpSessionArchive = AcpSessionArchive(url: nil),
                openCodeReader: OpenCodeSessionReader? = nil,
                directoryProbe: DirectoryProbe = .live(),
                clientVersion: String = AgentIdentity.bundleVersion(),
                idleTimeout: TimeInterval = AcpConnector.idleTimeout,
                initializeTimeout: TimeInterval = AcpClient.initializeTimeout,
                now: @escaping @Sendable () -> Date = { Date() },
                onHealth: @escaping HealthHandler = { _, _, _, _ in },
                onTasksChanged: @escaping @Sendable () async -> Void = {}) {
        self.id = spec.id
        self.identity = identity ?? .acp(connectorId: spec.id)
        self.spec = spec
        self.store = store
        self.launcher = launcher
        self.tools = tools
        self.registry = registry
        self.archive = archive
        self.openCodeReader = openCodeReader
        self.directoryProbe = directoryProbe
        self.clientVersion = clientVersion
        self.idleTimeout = idleTimeout
        self.initializeTimeout = initializeTimeout
        self.now = now
        self.onHealth = onHealth
        self.onTasksChanged = onTasksChanged
    }

    public var isRunning: Bool { running != nil }

    /// `staticTasks()` 里是否已经有这个 agent 在电脑上的全部会话，可以拿来做通知基线。
    ///
    /// 成功列过一次 `session/list`，或者确定根本列不了（没有启动命令、只经反向扩展连进来；握手说不支持列表）。
    /// 在那之前 `staticTasks()` 只有本机记录，第一次列表拉回来的桌面会话会被 `TaskStore` 当成"新出现的已完成任务"，
    /// 所以 hub 只把基线已就绪的 agent 报给 `TaskStore.reconcileAcp`，没就绪的一律静默。
    /// 停用（`stop()`）或换了启动方式之后重新算：回来后要再静默一轮。
    public var isListBaselined: Bool {
        localBaselined || listedOnce || spec.executable == nil || knownCapabilities?.listSessions == false
    }

    /// 发现结果变了。启动方式变了就把正在跑（或正在起）的进程关掉，下一条命令按新配置拉起。
    public func update(spec newSpec: AcpAgentSpec) {
        let relaunch = newSpec.executable != spec.executable || newSpec.arguments != spec.arguments
            || newSpec.environment != spec.environment
        spec = newSpec
        guard relaunch else { return }
        // 换了程序，旧的能力与列表基线都不作数了。
        knownCapabilities = nil
        listedOnce = false
        shutDownProcess()
    }

    /// 停用或退出：关进程、断反向连接、挂起的审批一律当取消。
    ///
    /// 在跑的轮次**在这里就收尾**（记 interrupted、交还所有权），不等进程退出后那条异步的收尾：
    /// hub 停用 agent 后会立刻丢掉这个连接器，等不到的话任务就永远卡在"运行中"且躲开对账。
    /// 反向连接在报的会话同理：agent 从发现结果里消失时 hub 先忘掉它的反向连接，socket 关闭后的
    /// `reverseClosed` 就找不到这个连接器了，所以这里先就地交还，再关连接。
    public func stop() async {
        // 停用期间电脑上的会话照样在变：重新启用后第一次列表要重新静默一轮（见 `isListBaselined`）。
        listedOnce = false
        for box in waiters.values { _ = box.resume(returning: .cancelled) }
        waiters.removeAll()
        await stopSubprocess()
        let reverse = links
        for link in reverse.keys { await releaseReverse(link) }
        for link in reverse.values { link.close() }
    }

    /// 解除配对或被接管：只关我们拉起的子进程，在跑的轮次同 `stop()` 就地记 interrupted、交还所有权；
    /// 反向连接和它在报的会话原样留着（agent 跑在用户自己的终端里，观察不依赖配对）。
    /// 之后的列表刷新（或重新配对后的命令）仍会按需再拉起。
    public func stopSubprocess() async {
        cancelIdle()
        for (sessionId, box) in waiters where reverseOwner[sessionId] == nil {
            _ = box.resume(returning: .cancelled)
            waiters.removeValue(forKey: sessionId)
        }
        shutDownProcess()
        let interrupted = Array(turns.keys)
        for sessionId in interrupted {
            turns.removeValue(forKey: sessionId)
            cancelledTurns.remove(sessionId)
        }
        for sessionId in interrupted { await finalizeInterrupted(sessionId) }
    }

    /// App 退出：先挡住以后的拉起（在途的命令、列表刷新走到 `ensureRunning` 就失败），再同 `stop()` 收尾。不可逆。
    public func shutdown() async {
        isShutDown = true
        await stop()
    }

    // MARK: - 命令

    public func start(projectPath: String, prompt: String, images: [URL]) async throws -> ConnectorOutcome {
        guard Self.isDirectory(projectPath) else { throw ConnectorError.directory(.projectMissing, path: projectPath) }
        // spec「命令对应」：有声明了 `newSession` 的反向连接就走它，没有启动命令时也只能走它。
        if spec.executable == nil || links.values.contains(where: { $0.capabilities.newSession }) {
            return try await startOverReverse(projectPath: projectPath, prompt: prompt, images: images)
        }
        // 已知不收图就别为一条注定失败的命令拉起进程。
        if !images.isEmpty, knownCapabilities?.images == false { throw ConnectorError("这个 Agent 暂不支持发图") }
        // 自己拉起的 agent 沿用 BotBus 的文件夹授权：BotBus 读不了的目录它也读不了，起之前说清楚（协议 3.7）。
        // 反向连接上的 agent 不是 BotBus 起的，上面那条路不看这个。
        if let diagnosis = await directoryProbe.diagnose(projectPath) {
            throw ConnectorError.directory(diagnosis, path: projectPath)
        }
        beginCommand()
        defer { endCommand() }
        let running = try await ensureRunning()
        let acpImages = try Self.encode(images, capabilities: running.capabilities)
        let injection = await AgentToolsInjection.make(tools(), registry: registry)
        let sessionId: String
        do {
            sessionId = try await running.client.newSession(cwd: projectPath,
                                                            mcpServers: injection.map { [.botbus($0)] } ?? [])
        } catch {
            throw await failure(error)
        }
        await markHealthy()
        let timestamp = stamp()
        var state = AcpSessionState(record: AcpSessionState.newRecord(
            identity: identity, sessionId: sessionId, cwd: projectPath, title: nil, origin: .watch,
            controllable: true, at: timestamp))
        // 我们刚建的会话：从第一条起就在内存里。
        state.transcript.isComplete = true
        let taskId = state.record.id
        if let injection { await registry.bind(injection.token, taskId: taskId) }
        if self.running?.generation == running.generation { loaded.insert(sessionId) }
        state.beginTurn(prompt: prompt, images: acpImages, at: timestamp)
        if let outcome = await commitTurn(sessionId, state: state, taskId: taskId, prompt: prompt, images: acpImages,
                                          running: running) {
            return outcome
        }
        return try await followUpOverReverse(sessionId, taskId: taskId, prompt: prompt, images: images)
    }

    public func followUp(taskId: String, prompt: String, images: [URL]) async throws -> ConnectorOutcome {
        let sessionId = try sessionId(taskId)
        if reverseOwner[sessionId] != nil {
            return try await followUpOverReverse(sessionId, taskId: taskId, prompt: prompt, images: images)
        }
        guard turns[sessionId] == nil, !preparing.contains(sessionId) else {
            throw ConnectorError("这个会话正在运行，等它这一轮结束再续聊")
        }
        if let openCodeReader {
            let desktop = try openCodeReader.tasks(now: now()).first { $0.id == taskId }
            if let desktop, [.running, .waitingApproval, .waitingInput].contains(desktop.status) {
                throw ConnectorError("这个会话正在电脑上运行，等它这一轮结束再续聊")
            }
        }
        // 第一个 await 之前就占位：手机和手表同时发的两条续聊不能各起一轮。
        preparing.insert(sessionId)
        defer { preparing.remove(sessionId) }
        if !images.isEmpty, knownCapabilities?.images == false { throw ConnectorError("这个 Agent 暂不支持发图") }
        beginCommand()
        defer { endCommand() }
        let running = try await ensureRunning(missingCommand: "\(spec.name) 没有配置启动命令，只能在电脑上继续这个会话")
        let acpImages = try Self.encode(images, capabilities: running.capabilities)
        do {
            try await loadIfNeeded(sessionId, taskId: taskId, running: running, forReading: false)
        } catch is TakenOverByReverse {
            return try await followUpOverReverse(sessionId, taskId: taskId, prompt: prompt, images: images)
        }
        // 等进程与载入的空当里反向连接可能已经接管了这个会话：之后一律走它，不能再对子进程发 prompt。
        if reverseOwner[sessionId] != nil {
            return try await followUpOverReverse(sessionId, taskId: taskId, prompt: prompt, images: images)
        }
        guard var state = sessions[sessionId] else { throw ConnectorError("本机没有这个任务：\(taskId)") }
        state.beginTurn(prompt: prompt, images: acpImages, at: stamp())
        state.record.controllable = true
        if let outcome = await commitTurn(sessionId, state: state, taskId: taskId, prompt: prompt, images: acpImages,
                                          running: running) {
            return outcome
        }
        return try await followUpOverReverse(sessionId, taskId: taskId, prompt: prompt, images: images)
    }

    public func approve(taskId: String, requestId: String,
                        decision: Command.Approve.Decision) async throws -> ConnectorOutcome {
        try await approve(taskId: taskId, requestId: requestId, decision: decision, answers: nil)
    }

    /// `answers`（协议 2.14）是手机在「允许范围」里选的那个选项名；见 `AcpPermissionRequest.optionId(for:answers:)`。
    public func approve(taskId: String, requestId: String, decision: Command.Approve.Decision,
                        answers: [String: [String]]?) async throws -> ConnectorOutcome {
        let sessionId = try sessionId(taskId)
        guard var state = sessions[sessionId], let pending = state.pending,
              pending.toolCall.toolCallId == requestId, let box = waiters[sessionId] else {
            if resolvedElsewhere[sessionId] == requestId { throw ConnectorError("这个请求已在电脑上处理") }
            throw ConnectorError("没有待审批的请求（可能已经处理过了）")
        }
        guard let optionId = pending.optionId(for: decision, answers: answers) else {
            throw ConnectorError("\(spec.name) 没有提供「\(decision == .allow ? "允许" : "拒绝")」选项")
        }
        touchCommandActivity()
        waiters.removeValue(forKey: sessionId)
        state.clearPending(at: stamp())
        sessions[sessionId] = state
        // 先写"回到运行中"再放行 agent：反过来的话这一轮可能在 upsert 之前就收尾，最终状态被旧的 running 盖掉。
        await store.upsert(state.record)
        _ = box.resume(returning: .selected(optionId: optionId))
        return ConnectorOutcome(taskId: taskId,
                                retainsLiveOwnership: turns[sessionId] != nil || reverseOwner[sessionId] != nil)
    }

    public func interrupt(taskId: String) async throws -> ConnectorOutcome {
        let sessionId = try sessionId(taskId)
        if reverseOwner[sessionId] != nil { return try await interruptOverReverse(sessionId, taskId: taskId) }
        guard turns[sessionId] != nil, let running else {
            throw ConnectorError("这个会话现在没有在 BotBus 里运行，只能在电脑上中断")
        }
        touchCommandActivity()
        // ACP 要求：发 `session/cancel` 时挂着的审批一律回 cancelled。同 `approve`，先写状态再放行。
        if let box = waiters.removeValue(forKey: sessionId) {
            if var state = sessions[sessionId] {
                state.clearPending(at: stamp())
                sessions[sessionId] = state
                await store.upsert(state.record)
            }
            _ = box.resume(returning: .cancelled)
        }
        await running.client.cancel(sessionId)
        // 这一轮由 agent 回的 `cancelled` 收尾（记 interrupted）并交还所有权。
        return ConnectorOutcome(taskId: taskId, retainsLiveOwnership: true)
    }

    /// 对话记录。当前还连着的会话（在跑、反向连接在报、已载入当前进程）直接给内存里的；
    /// 否则 `session/load` 重放一遍拿最新的——电脑上可能已经接着聊过了。载入不了（agent 不支持、
    /// 起不来、要登录）时退回内存里的，内存里也没有才报错。
    ///
    /// **读记录从不 `session/resume`**（它不重放历史，还会拿走会话锁）。agent 不支持 `session/load`、
    /// 内存里又没有时抛 `AcpConnectorError(.transcriptUnavailable)`，由外层用自己的读取器兜底。
    /// 注意 resume 接上的会话算"已载入"，这里给的是接上之后的那几轮；要判断内存里的是否齐全用 `completeTranscript`。
    public func entries(taskId: String, limit: Int) async throws -> (entries: [TranscriptEntry], hasMore: Bool) {
        let sessionId = try sessionId(taskId)
        touchCommandActivity()
        if let openCodeReader, turns[sessionId] == nil, reverseOwner[sessionId] == nil {
            return try await openCodeReader.entries(taskId: taskId, limit: limit)
        }
        if let state = sessions[sessionId] {
            let live = turns[sessionId] != nil || reverseOwner[sessionId] != nil || loaded.contains(sessionId)
            let cannotReload = knownCapabilities?.loadSession != true
            if live || (cannotReload && !state.transcript.isEmpty) {
                return TranscriptWindow.latest(state.transcript.entries, limit: limit)
            }
        }
        beginCommand()
        defer { endCommand() }
        do {
            let running = try await ensureRunning(missingCommand: "\(spec.name) 没有配置启动命令，读不到对话记录")
            try await loadIfNeeded(sessionId, taskId: taskId, running: running, forReading: true)
        } catch is TakenOverByReverse {
            // 反向连接接管了：它报的就是最新的。
        } catch {
            guard let state = sessions[sessionId], !state.transcript.isEmpty else { throw error }
        }
        return TranscriptWindow.latest(sessions[sessionId]?.transcript.entries ?? [], limit: limit)
    }

    /// 内存里**齐全**的对话记录（这个会话是 BotBus 在本次运行里 `session/new` 建的，或 `session/load` 完整重放过），
    /// 不起进程、不载入。没有、不齐（从 store 接过来的、`session/resume` 接上的、被上限淘汰过的）返回 nil——
    /// 一档的 DshConnector 这时改用 web 或读盘。id 不属于这个连接器也返回 nil。
    public func completeTranscript(taskId: String, limit: Int) -> (entries: [TranscriptEntry], hasMore: Bool)? {
        guard let sessionId = identity.sessionId(taskId: taskId), let state = sessions[sessionId],
              state.transcript.isComplete, !state.transcript.isEmpty else { return nil }
        return TranscriptWindow.latest(state.transcript.entries, limit: limit)
    }

    /// 这个会话此刻在我们的子进程里（建过、载入过或接上过，或正跑着一轮）：续聊直接 prompt，不需要 load / resume。
    public func isInProcess(taskId: String) -> Bool {
        guard let sessionId = identity.sessionId(taskId: taskId) else { return false }
        return turns[sessionId] != nil || loaded.contains(sessionId)
    }

    /// BotBus 自己发的一轮正在这个会话上跑（审批也只会在这期间挂起）：中断、审批该回这个连接器。
    public func isRunningTurn(taskId: String) -> Bool {
        guard let sessionId = identity.sessionId(taskId: taskId) else { return false }
        return turns[sessionId] != nil || waiters[sessionId] != nil
    }

    // MARK: - 列表与对账

    /// 给 hub 全量对账：`session/list` 列出的、本机记过的（BotBus 拉起的）、内存里知道状态的，依次覆盖。
    /// 本机记过的会话来源、状态以它为准，列表里更新的标题与时间照收。本机记录和列表一样只要最近窗口
    ///（`SessionFormatting.recentWindow`）里更新过的，以合并列表之后的时间为准。
    public func staticTasks() async -> [TaskRecord] {
        var byId: [String: TaskRecord] = [:]
        let current = now()
        for info in listed.values {
            let record = listedRecord(info)
            byId[record.id] = record
        }
        for record in await archive.records(connectorId: id) {
            var merged = record
            if let info = identity.sessionId(taskId: record.id).flatMap({ listed[$0] }),
               let listedAt = info.updatedAt, listedAt > (Self.date(record.updatedAt) ?? .distantPast) {
                merged.updatedAt = ProtocolJSON.timestamp(listedAt)
                let title = AcpSessionState.singleLine(info.title ?? "")
                if !title.isEmpty { merged.title = SessionFormatting.truncate(title, SessionFormatting.titleLimit) }
            }
            if let updated = Self.date(merged.updatedAt),
               current.timeIntervalSince(updated) > SessionFormatting.recentWindow { continue }
            var aged = Self.aged(merged, now: current)
            if let sessionId = identity.sessionId(taskId: record.id) {
                aged.controllable = controllable(sessionId, otherwise: aged.controllable)
            }
            byId[record.id] = aged
        }
        for (sessionId, state) in sessions {
            var record = state.record
            record.controllable = controllable(sessionId, otherwise: record.controllable)
            byId[record.id] = record
        }
        for var record in localTasks {
            guard let sessionId = identity.sessionId(taskId: record.id),
                  turns[sessionId] == nil, reverseOwner[sessionId] == nil else { continue }
            if let existing = byId[record.id] {
                guard record.updatedAt >= existing.updatedAt else { continue }
                record.origin = existing.origin
            }
            record.controllable = spec.executable != nil
            byId[record.id] = record
        }
        return Array(byId.values)
    }

    /// 内置 OpenCode 的全机发现不依赖 ACP 的项目列表。读失败保留上一次结果。
    public func refreshLocalSessions() async {
        guard let openCodeReader, !isShutDown,
              FileManager.default.fileExists(atPath: openCodeReader.databaseURL.path) else { return }
        do {
            let fresh = try openCodeReader.tasks(now: now())
            let changed = !localBaselined || fresh != localTasks
            localTasks = fresh
            localBaselined = true
            if changed { await onTasksChanged() }
        } catch {
            Self.log.error("opencode local session scan failed")
        }
    }

    /// 刷新 `session/list`。进程没在跑就按需拉起一次；agent 不支持列表就什么都不做。
    /// 刷新不算命令活动：只为列表拉起的进程刷完就会按空闲关掉。
    public func refreshList() async {
        guard spec.executable != nil, knownCapabilities?.listSessions != false else { return }
        activeListRefreshes += 1
        defer {
            activeListRefreshes -= 1
            scheduleIdle()
        }
        do {
            let running = try await ensureRunning()
            guard running.capabilities.listSessions else { return }
            let current = now()
            let fresh = try await running.client.listSessions()
                .filter { ($0.updatedAt.map { current.timeIntervalSince($0) } ?? 0) <= SessionFormatting.recentWindow }
            listed = Dictionary(fresh.map { ($0.sessionId, $0) }, uniquingKeysWith: { first, _ in first })
            listedOnce = true
            await onTasksChanged()
        } catch {
            // 只记错误的类别：进程退出的原因里带 stderr 末尾，agent 回的错误文本也可能有会话内容。
            Self.log.error("acp list failed for \(self.id, privacy: .public): \(Self.logCategory(error), privacy: .public)")
        }
    }

    // MARK: - agent 发来的消息

    /// agent 发来的请求。`link` 为 nil = 来自我们拉起的子进程，否则是那条反向连接。
    func handleAgentRequest(_ method: String, _ params: JSONValue, link: UUID?) async throws -> JSONValue {
        guard method == "session/request_permission" else {
            throw JSONRPCError(code: JSONRPCError.methodNotFound, message: "BotBus 不支持 \(method)")
        }
        guard let request = AcpPermissionRequest(params: params) else {
            throw JSONRPCError(code: JSONRPCError.invalidParams, message: "看不懂的审批请求")
        }
        // 反向连接上"BotBus 没有答案"回错误码而不是 cancelled：agent 同时在终端里问着用户，cancelled 会被当成用户取消。
        guard reverseOwner[request.sessionId] == link else {
            if link != nil { throw AcpPermissionOutcome.noAnswer }
            return AcpPermissionOutcome.cancelled.json
        }
        // 子进程只在 BotBus 发的那一轮里有人等审批；轮次外的请求挂上去就再也没人收尾了。
        if link == nil, turns[request.sessionId] == nil { return AcpPermissionOutcome.cancelled.json }
        let outcome = await askPhone(request)
        if link != nil, outcome == .unanswered { throw AcpPermissionOutcome.noAnswer }
        return outcome.json
    }

    /// agent 发来的通知。由 `JSONRPCPeer` 的读循环串行调用：**不能**在这里对同一个 peer 发请求并等应答。
    func handleAgentNotification(_ method: String, _ params: JSONValue, link: UUID?) async {
        guard method == "session/update" else {
            if let link { await handleReverseNotification(method, params, link: link) }
            return
        }
        guard let sessionId = params["sessionId"]?.stringValue, let update = params["update"] else { return }
        // `session/load` 的历史重放进单独的一份，载入成功才换上去。
        if link == nil, var replay = replays[sessionId] {
            replay.apply(AcpSessionUpdate(json: update), at: stamp())
            replays[sessionId] = replay
            return
        }
        guard reverseOwner[sessionId] == link, var state = sessions[sessionId] else { return }
        let before = state.record
        state.apply(AcpSessionUpdate(json: update), at: stamp())
        sessions[sessionId] = state
        if state.record != before { await store.upsert(state.record) }
    }

    /// 把审批挂到手机上，等手机（或一轮结束、进程退出、电脑上先答掉）给出结果。
    func askPhone(_ request: AcpPermissionRequest) async -> AcpPermissionOutcome {
        guard var state = sessions[request.sessionId] else { return .unanswered }
        // 反向连接上请求与通知走不同的路（请求各起一个 Task，通知串行），电脑上先答掉的
        // `_botbus/permission_resolved` 可能比这条请求先到：那就别再挂到手机上。
        // 终端已经答了：手机这边没有答案（反向模式回 -32001，agent 按终端的答案走）。
        if resolvedElsewhere[request.sessionId] == request.toolCall.toolCallId { return .unanswered }
        // 同一个会话同时只挂一个：新的来了，旧的没有答案了（子进程收到的仍是 ACP 的 cancelled）。
        _ = waiters.removeValue(forKey: request.sessionId)?.resume(returning: .unanswered)
        resolvedElsewhere.removeValue(forKey: request.sessionId)
        state.setPending(request, at: stamp())
        sessions[request.sessionId] = state
        let box = OneShotContinuation<AcpPermissionOutcome>()
        waiters[request.sessionId] = box
        await store.upsert(state.record)
        return (try? await box.value()) ?? .unanswered
    }

    // MARK: - 进程

    func ensureRunning(missingCommand: String? = nil) async throws -> Running {
        guard !isShutDown else { throw ConnectorError("BotBus 正在退出") }
        if let running { return running }
        if let starting { return try await starting.value }
        guard let executable = spec.executable else {
            throw ConnectorError(missingCommand ?? "\(spec.name) 没有配置启动命令，没法从手机新建任务")
        }
        generation += 1
        exitedEarly.removeAll()
        let generation = self.generation
        let request = AcpLaunchRequest(executable: executable, arguments: spec.arguments,
                                       environment: AgentBinary.environment(for: executable, adding: spec.environment),
                                       workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
        // 同时到的几条命令共用这一次拉起；成败的记账都在 `launch` 里，谁等到的都是同一个结果。
        let task = Task { try await self.launch(request, generation: generation) }
        starting = task
        defer { if starting == task { starting = nil } }
        return try await task.value
    }

    /// 起进程、接管道、握手，成功就记成 `running`。失败一律报 `.error` 健康状态（被停用作废的除外）；
    /// 除握手超时之外都标上 `handshakeFailed`。
    private func launch(_ request: AcpLaunchRequest, generation: Int) async throws -> Running {
        let handle: any CodexProcessHandle
        do {
            handle = try launcher(request).launch()
        } catch {
            throw await launchFailed(Self.describe(error), generation: generation)
        }
        // 写 stdin 排成一条队：每行一个 Task 会乱序。
        let (lines, sink) = AsyncStream<String>.makeStream()
        Task { for await line in lines { try? await handle.writeStdin(Data((line + "\n").utf8)) } }
        let peer = JSONRPCPeer(send: { sink.yield($0) })
        await peer.setHandlers(request: { [weak self] method, params in
            guard let self else { throw JSONRPCError(code: JSONRPCError.internalError, message: "BotBus 已停止") }
            return try await self.handleAgentRequest(method, params, link: nil)
        }, notification: { [weak self] method, params in
            await self?.handleAgentNotification(method, params, link: nil)
        })
        // 唯一的读循环（`JSONRPCPeer.receive` 必须串行）。进程退出后先关 peer——在等的请求（包括握手、
        // 在跑的 `session/prompt`）带着退出原因失败——再通知连接器。
        Task { [weak self] in
            while let chunk = try? await handle.readStdout() { await peer.receive(chunk) }
            let exit = await handle.waitForExit()
            sink.finish()
            await peer.close(reason: Self.exitDescription(exit))
            await self?.processExited(generation: generation, exit: exit)
        }
        let client = AcpClient(peer: peer)
        let capabilities: AcpCapabilities
        do {
            capabilities = try await client.initialize(clientVersion: clientVersion, timeout: initializeTimeout)
        } catch {
            handle.terminate()
            // 超时说明不了它不是 ACP agent（可能只是冷启动慢）；进程退了会让请求带着 closed 失败，不会走到超时。
            let timedOut: Bool
            if case JSONRPCPeerError.timeout = error { timedOut = true } else { timedOut = false }
            throw await launchFailed(Self.describe(error), generation: generation, handshakeFailed: !timedOut)
        }
        // 握手期间被停用或换了配置：这一代作废，别让它复活。
        guard generation == self.generation else {
            handle.terminate()
            throw ConnectorError("\(spec.name) 已停止")
        }
        // 握手回来之前进程已经退了（读循环先跑完）：不能把死进程记成 running。
        guard !exitedEarly.contains(generation) else {
            throw await launchFailed("agent 进程启动后立即退出了", generation: generation)
        }
        // 从这里到 return 之间没有 await：之后的退出一定看得到这条 `running`。
        let result = Running(handle: handle, client: client, capabilities: capabilities, generation: generation)
        running = result
        knownCapabilities = capabilities
        scheduleIdle()
        await report(.ok, nil)
        return result
    }

    /// 失败原因可能带 stderr（握手时进程退了），日志里不公开。
    private func launchFailed(_ message: String, generation: Int, handshakeFailed: Bool = true) async -> ConnectorError {
        if generation == self.generation { await report(.error, message, handshakeFailed: handshakeFailed) }
        return ConnectorError(message, containsPrivateDetail: true)
    }

    private func processExited(generation: Int, exit: CodexProcessExit) async {
        guard let current = running, current.generation == generation else {
            // 不是当前进程：要么是我们主动关掉的（`running` 早已清掉），要么还在握手。后者记一笔。
            if generation == self.generation { exitedEarly.insert(generation) }
            return
        }
        running = nil
        forgetProcessSessions()
        // 在跑的一轮由它自己的 prompt 失败收尾（peer 已关，请求会抛 closed）。
        let reason = exit.reason.map { "：\($0)" } ?? ""
        Self.log.error("acp agent \(self.id, privacy: .public) exited unexpectedly, status \(exit.status, privacy: .public)")
        await report(.error, "agent 进程意外退出（退出码 \(exit.status)）\(reason)")
        // 没有进程了，不支持 `session/load` 的 agent 上的会话不能再续聊：对账把 controllable 改掉。
        await onTasksChanged()
    }

    /// 我们自己关掉当前进程（空闲、停用、配置变了）。先清状态再 terminate：它随后的退出就不算故障；
    /// 这一代发起、还没结束的轮次记成 interrupted。正在握手的那一代因为代数变了会自己关掉。
    ///
    /// `CodexProcessHandle` 只有 `terminate()`（SIGTERM），拿不到 pid，也就没有"等一会儿再 SIGKILL"：
    /// 不理 SIGTERM 的 agent 进程会一直留着，直到它自己退出。BotBus 这边的状态不受影响。
    private func shutDownProcess() {
        generation += 1
        starting = nil
        guard let current = running else { return }
        running = nil
        for (sessionId, turn) in turns where turn.generation == current.generation {
            cancelledTurns.insert(sessionId)
        }
        forgetProcessSessions()
        current.handle.terminate()
    }

    /// 进程没了：载入过的会话作废，子进程里挂着的审批当取消（反向连接的不动）。
    private func forgetProcessSessions() {
        loaded.removeAll()
        for (sessionId, box) in waiters where reverseOwner[sessionId] == nil {
            _ = box.resume(returning: .cancelled)
            waiters.removeValue(forKey: sessionId)
        }
    }

    // MARK: - 轮次

    /// 发 prompt 前的最后一段。`state` 是已经 `beginTurn` 过的这一轮，只在本地攒着：
    ///
    /// 1. 先认领、把"运行中"写进 store，再发 prompt——反过来的话，一轮若很快结束，收尾写的最终状态会被这里的 running 盖掉。
    ///    认领排在最前：之后这几次 await 期间的对账不会拿本机记录（`aged` 成 interrupted）去写这个任务。
    /// 2. 这几次 await 期间反向连接可能接管了这个会话（`_botbus/session` 只拦已经在跑的轮次）。所以复查接管、换上内存状态、
    ///    `runTurn` 放在**同一段不 await 的代码里**：被接管就不对子进程发 prompt（不能两个进程写同一个会话），
    ///    内存里留着的是没开这一轮的原状态（接管方拿去当底子的就是它），store 写回接管后的记录，返回 nil 由调用方改走反向连接。
    /// 3. 期间进程若被停掉或换了一代，这一轮就不发了，直接记成被中断。
    private func commitTurn(_ sessionId: String, state: AcpSessionState, taskId: String, prompt: String,
                            images: [AcpImage], running: Running) async -> ConnectorOutcome? {
        await store.claimLive(taskId, ownerToken: liveOwnerToken)
        await store.upsert(state.record)
        await archive.remember(connectorId: id, record: state.record)
        guard reverseOwner[sessionId] == nil else {
            if let current = sessions[sessionId]?.record {
                await store.upsert(current)
                await archive.remember(connectorId: id, record: current)
            }
            return nil
        }
        sessions[sessionId] = state
        trimTranscripts(keeping: sessionId)
        guard self.running?.generation == running.generation else {
            await finalizeInterrupted(sessionId)
            return ConnectorOutcome(taskId: taskId, retainsLiveOwnership: false)
        }
        runTurn(sessionId, prompt: prompt, images: images, running: running)
        return ConnectorOutcome(taskId: taskId, retainsLiveOwnership: true)
    }

    private func runTurn(_ sessionId: String, prompt: String, images: [AcpImage], running: Running) {
        let client = running.client
        let turnId = UUID()
        // 强引用 self：连接器被丢掉（停用）时这一轮也要能收尾；peer 一关 prompt 就会结束，不会久留。
        let task = Task {
            do {
                let stop = try await client.prompt(sessionId, text: prompt, images: images)
                await self.finishTurn(sessionId, turnId: turnId, stop: stop, error: nil)
            } catch {
                await self.finishTurn(sessionId, turnId: turnId, stop: nil, error: AcpConnector.describe(error))
            }
        }
        turns[sessionId] = Turn(id: turnId, task: task, generation: running.generation)
    }

    private func finishTurn(_ sessionId: String, turnId: UUID, stop: AcpStopReason?, error: String?) async {
        // `stop()` 已经收过尾，或者早已换成了新的一轮：不动。
        guard turns[sessionId]?.id == turnId else { return }
        turns.removeValue(forKey: sessionId)
        let cancelledByUs = cancelledTurns.remove(sessionId) != nil
        _ = waiters.removeValue(forKey: sessionId)?.resume(returning: .unanswered)
        lastCommandActivity = now()
        if error == nil { await markHealthy() }
        guard var state = sessions[sessionId] else { return }
        if cancelledByUs {
            state.endTurn(.cancelled, error: nil, at: stamp())
        } else {
            state.endTurn(stop, error: error, at: stamp())
        }
        sessions[sessionId] = state
        trimTranscripts(keeping: sessionId)
        await archive.remember(connectorId: id, record: state.record)
        await store.upsert(sessions[sessionId]?.record ?? state.record)
        await release(state.record.id, sessionId: sessionId)
        await onTasksChanged()
        scheduleIdle()
    }

    /// 没跑完、也不会再由 prompt 收尾的一轮：就地记成 interrupted 并交还所有权（同样带延迟补放——
    /// `start` 刚回执、分发器还没 claim 时 agent 就被停用的话，分发器那一手 claim 会晚于这里的 release）。
    private func finalizeInterrupted(_ sessionId: String) async {
        guard var state = sessions[sessionId] else { return }
        state.endTurn(.cancelled, error: nil, at: stamp())
        sessions[sessionId] = state
        await archive.remember(connectorId: id, record: state.record)
        await store.upsert(sessions[sessionId]?.record ?? state.record)
        await release(state.record.id, sessionId: sessionId)
    }

    func release(_ taskId: String, sessionId: String) async {
        guard turns[sessionId] == nil, reverseOwner[sessionId] == nil else { return }
        await store.releaseLive(taskId, ownerToken: liveOwnerToken)
        // 兜底：分发器在 start / interrupt 返回之后才处理所有权（同 `PiConnector.complete`）。
        // 这一轮若恰好在"回执已返回、分发器还没 claim"的空当里结束，上面那次 release 会先于 claim。
        // 直接拿着 store：`stop()` 之后 hub 会丢掉这个连接器，补放仍要执行。连接器还在时先问它
        // 期间有没有新一轮（新一轮自己拿着所有权，不能替它放）。
        let store = self.store
        Task { [weak self, liveOwnerToken] in
            try? await Task.sleep(for: .seconds(AcpConnector.releaseRetryDelay))
            if let self {
                await self.releaseIfIdle(taskId, sessionId: sessionId)
            } else {
                await store.releaseLive(taskId, ownerToken: liveOwnerToken)
            }
        }
    }

    private func releaseIfIdle(_ taskId: String, sessionId: String) async {
        guard turns[sessionId] == nil, reverseOwner[sessionId] == nil,
              !preparing.contains(sessionId), loads[sessionId] == nil else { return }
        await store.releaseLive(taskId, ownerToken: liveOwnerToken)
    }

    /// 会话不在当前进程里时载入它。同一会话并发的载入（续聊 + 读记录）共用一次。
    ///
    /// 没有 `loadSession`、但有 `resumeSession` 时，续聊（`forReading == false`）改用 `session/resume` 接上；
    /// 读记录不 resume，抛 `AcpConnectorError(.transcriptUnavailable)`。
    private func loadIfNeeded(_ sessionId: String, taskId: String, running: Running, forReading: Bool) async throws {
        guard !loaded.contains(sessionId) else { return }
        let resuming = !running.capabilities.loadSession && running.capabilities.resumeSession
        if forReading && !running.capabilities.loadSession {
            throw AcpConnectorError(.transcriptUnavailable, message: "\(spec.name) 不支持读取之前的会话")
        }
        if let inFlight = loads[sessionId] { return try await inFlight.value }
        guard running.capabilities.loadSession || resuming else {
            throw ConnectorError("\(spec.name) 不支持续聊或读取之前的会话")
        }
        let task = Task {
            if resuming {
                try await self.resume(sessionId, taskId: taskId, running: running)
            } else {
                try await self.load(sessionId, taskId: taskId, running: running)
            }
        }
        loads[sessionId] = task
        defer { if loads[sessionId] == task { loads[sessionId] = nil } }
        try await task.value
    }

    /// 历史经 `session/update` 重放进一份新的状态（`replays`），载入成功才替换内存里的——
    /// 失败（要登录、进程崩了）时原来的对话记录原样留着。发 `session/load` 前后各查一次反向连接：
    /// 期间被它接管就作废，不能让两个进程同写一个会话，也不能把反向连接报的记录清掉。
    private func load(_ sessionId: String, taskId: String, running: Running) async throws {
        var replay = try await knownState(sessionId, taskId: taskId)
        replay.transcript.reset()
        let injection = await AgentToolsInjection.make(tools(), registry: registry, reusing: taskId)
        guard reverseOwner[sessionId] == nil else { throw TakenOverByReverse() }
        replays[sessionId] = replay
        defer { replays.removeValue(forKey: sessionId) }
        do {
            try await running.client.loadSession(sessionId, cwd: replay.record.workingDirectory,
                                                 mcpServers: injection.map { [.botbus($0)] } ?? [])
        } catch {
            throw await failure(error)
        }
        guard reverseOwner[sessionId] == nil else { throw TakenOverByReverse() }
        // 载入期间进程换了代：这次载入落在旧进程上，不算数。
        guard self.running?.generation == running.generation else {
            throw ConnectorError("agent 进程已重启，请重试")
        }
        await markHealthy()
        if let injection { await registry.bind(injection.token, taskId: taskId) }
        // 上面的 await 期间同样可能被接管。
        guard reverseOwner[sessionId] == nil, var finished = replays[sessionId] else { throw TakenOverByReverse() }
        finished.transcript.isComplete = true
        let before = sessions[sessionId]?.record
        sessions[sessionId] = finished
        loaded.insert(sessionId)
        trimTranscripts(keeping: sessionId)
        if let before, before != finished.record { await store.upsert(finished.record) }
    }

    /// `session/resume`：接上会话继续聊。不重放历史，内存里原有的对话记录原样留着（没有就是空的、不齐的）；
    /// botbus MCP 与新会话一样注入（复用这个任务已有的 token）。`cwd` 取记录里的真实工作目录。
    /// 撞上会话锁时 `failure` 把错误换成 `AcpConnectorError(.sessionBusyElsewhere)`。反向连接的复查同 `load`。
    private func resume(_ sessionId: String, taskId: String, running: Running) async throws {
        let state = try await knownState(sessionId, taskId: taskId)
        let injection = await AgentToolsInjection.make(tools(), registry: registry, reusing: taskId)
        guard reverseOwner[sessionId] == nil else { throw TakenOverByReverse() }
        do {
            try await running.client.resumeSession(sessionId, cwd: state.record.workingDirectory,
                                                   mcpServers: injection.map { [.botbus($0)] } ?? [])
        } catch {
            throw await failure(error)
        }
        guard reverseOwner[sessionId] == nil else { throw TakenOverByReverse() }
        guard self.running?.generation == running.generation else {
            throw ConnectorError("agent 进程已重启，请重试")
        }
        await markHealthy()
        if let injection { await registry.bind(injection.token, taskId: taskId) }
        guard reverseOwner[sessionId] == nil else { throw TakenOverByReverse() }
        if sessions[sessionId] == nil { sessions[sessionId] = state }
        // resume 不重放交还期间由桌面写入的记录，原先完整的缓存也已过期。
        sessions[sessionId]?.transcript.isComplete = false
        loaded.insert(sessionId)
    }

    func knownState(_ sessionId: String, taskId: String) async throws -> AcpSessionState {
        if let state = sessions[sessionId] { return state }
        guard var record = await store.task(id: taskId) else { throw ConnectorError("本机没有这个任务：\(taskId)") }
        record.artifacts = nil
        record.systemPermission = nil
        return AcpSessionState(record: record)
    }

    /// 对话记录最多留 `transcriptLimit` 份：超出时丢掉最久没更新的（在跑、挂着审批、正在载入 / 准备续聊的不丢）。
    /// 反向连接在报、但此刻没在跑的会话也会被丢：它们没法 `session/load` 找回，但一条连接能报几十个会话，不能无限攒。
    /// agent 支持 `session/load` 时丢掉的会话也从 `loaded` 里拿掉，下次要看或续聊时重新载入；不支持的只丢记录、
    /// 仍留在 `loaded` 里——否则它在当前进程里就再也续聊不了（读记录会是空的，续聊照常）。`keeping` 是刚写进来的那个会话，
    /// 时间戳只精确到秒，同一秒里的几份按时间排不出先后，不能把它自己挤掉。
    func trimTranscripts(keeping current: String) {
        let kept = sessions.filter { !$0.value.transcript.isEmpty }
        guard kept.count > transcriptLimit else { return }
        let evictable = kept
            .filter { $0.key != current && turns[$0.key] == nil && loads[$0.key] == nil && !preparing.contains($0.key)
                && !(reverseOwner[$0.key] != nil && ($0.value.running || $0.value.pending != nil)) }
            .sorted { $0.value.record.updatedAt < $1.value.record.updatedAt }
        let canReload = knownCapabilities?.loadSession == true
        for (sessionId, _) in evictable.prefix(kept.count - transcriptLimit) {
            sessions[sessionId]?.transcript.reset()
            if canReload { loaded.remove(sessionId) }
        }
    }

    // MARK: - 空闲

    private func beginCommand() {
        activeCommands += 1
        lastCommandActivity = now()
    }

    private func endCommand() {
        activeCommands -= 1
        lastCommandActivity = now()
        scheduleIdle()
    }

    private func touchCommandActivity() {
        lastCommandActivity = now()
    }

    /// 按"最近一次命令活动 + idleTimeout"排空闲检查。重排不会推迟这个期限——列表刷新结束时也调它。
    func scheduleIdle() {
        idleTask?.cancel()
        idleTask = nil
        guard running != nil else { return }
        let delay = max(0, lastCommandActivity.addingTimeInterval(idleTimeout).timeIntervalSince(now()))
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.stopIfIdle()
        }
    }

    private func cancelIdle() {
        idleTask?.cancel()
        idleTask = nil
    }

    /// 忙着（在跑的一轮、命令、列表刷新、载入）就先不关：它们结束时会重新排检查。
    private func stopIfIdle() async {
        guard running != nil, turns.isEmpty, preparing.isEmpty, loads.isEmpty,
              activeCommands == 0, activeListRefreshes == 0 else { return }
        guard now().timeIntervalSince(lastCommandActivity) >= idleTimeout else {
            scheduleIdle()
            return
        }
        shutDownProcess()
        // 不支持 `session/load` 的 agent：进程一关，会话就不能再续聊了。
        await onTasksChanged()
    }

    // MARK: - 小工具

    func stamp() -> String { ProtocolJSON.timestamp(now()) }

    /// 会话此刻能不能从手机续聊：在跑或已载入当前进程的能；反向连接在报的按它握手时声明的（`otherwise`）；
    /// 其余看 agent 支不支持 `session/load` 或 `session/resume`（还没握过手就沿用记录里的值）。
    func controllable(_ sessionId: String, otherwise fallback: Bool) -> Bool {
        if reverseOwner[sessionId] != nil { return fallback }
        if turns[sessionId] != nil || loaded.contains(sessionId) { return true }
        return knownCapabilities?.canContinueSessions ?? fallback
    }

    private func report(_ status: ConnectorInfo.Status, _ message: String?, handshakeFailed: Bool = false) async {
        reportedHealth = status
        await onHealth(id, status, message, handshakeFailed)
    }

    /// 一次请求（建会话、载入、一轮）成功了：之前报过 degraded / error 的话报回 ok。
    private func markHealthy() async {
        guard let reportedHealth, reportedHealth != .ok else { return }
        await report(.ok, nil)
    }

    /// JSON-RPC 错误里认出 `auth_required`：说成"请在电脑上登录"，并把健康状态报成 degraded。
    /// 会话锁错误（dsh）换成 `AcpConnectorError(.sessionBusyElsewhere)`，不影响健康状态。
    func failure(_ error: Error) async -> Error {
        if let rpc = error as? JSONRPCError, rpc.code == AcpProtocol.authRequiredCode {
            let message = "请在电脑上登录 \(spec.name)"
            await report(.degraded, message)
            return ConnectorError(message, diagnosis: .notSignedIn)
        }
        if let rpc = error as? JSONRPCError, AcpConnectorError.isSessionLockError(rpc) {
            return AcpConnectorError(.sessionBusyElsewhere, message: "这个会话正开在电脑上的 \(spec.name) 里")
        }
        if identity.source == .dsh, let rpc = error as? JSONRPCError,
           let details = rpc.data?["details"]?.stringValue,
           details.contains("uses log format"), details.contains("this harness reads only") {
            return ConnectorError("这个会话由更新的 DeepSeek Harness 写入，请升级本机 dsh，或启动 DeepSeek Harness 桌面版后重试")
        }
        // 可能是进程退出（带 stderr）或 agent 自己的错误文本：照样给手机看，日志里不公开。
        return ConnectorError(Self.describe(error), containsPrivateDetail: true)
    }

    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    /// 能公开进日志的错误类别：不带任何消息正文（stderr、agent 回的文本、路径）。
    static func logCategory(_ error: Error) -> String {
        switch error {
        case JSONRPCPeerError.closed: return "closed"
        case JSONRPCPeerError.timeout(let method): return "timeout \(method)"
        case JSONRPCPeerError.unencodable(let method): return "unencodable \(method)"
        case let rpc as JSONRPCError: return "rpc error \(rpc.code)"
        default: return String(describing: type(of: error))
        }
    }

    /// peer 关闭的原因：在等的请求（握手、在跑的一轮）带着它失败，手机上看得到。
    /// `reason` 是 stderr 末尾一小段，只给界面看，不进日志。
    static func exitDescription(_ exit: CodexProcessExit) -> String {
        "agent 进程退出了（退出码 \(exit.status)）" + (exit.reason.map { "：\($0)" } ?? "")
    }

    func sessionId(_ taskId: String) throws -> String {
        guard let sessionId = identity.sessionId(taskId: taskId) else {
            throw ConnectorError("任务 id 不属于这个 agent：\(taskId)")
        }
        return sessionId
    }

    static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return !path.isEmpty && FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    static func encode(_ images: [URL], capabilities: AcpCapabilities?) throws -> [AcpImage] {
        guard !images.isEmpty else { return [] }
        guard capabilities?.images == true else { throw ConnectorError("这个 Agent 暂不支持发图") }
        return try images.map { url in
            let mime: String
            #if canImport(UniformTypeIdentifiers)
            mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "image/jpeg"
            #else
            mime = Self.mimeType(for: url.pathExtension)
            #endif
            return AcpImage(base64: try Data(contentsOf: url).base64EncodedString(), mimeType: mime)
        }
    }

    #if !canImport(UniformTypeIdentifiers)
    private static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "heic", "heif": return "image/heic"
        default: return "image/jpeg"
        }
    }
    #endif

    static func date(_ timestamp: String) -> Date? { ISO8601DateFormatter().date(from: timestamp) }

    /// 本机记过的旧记录：还挂着"运行中 / 待审批"的说明 app 在那一轮中途退出过，一律当被中断；太久没动的算 idle。
    static func aged(_ record: TaskRecord, now: Date) -> TaskRecord {
        var copy = record
        if [.running, .waitingApproval, .waitingInput].contains(copy.status) {
            copy.status = .interrupted
            copy.pendingRequest = nil
        }
        if let updated = date(copy.updatedAt), now.timeIntervalSince(updated) > SessionFormatting.idleAfter {
            copy.status = .idle
        }
        return copy
    }

    private func listedRecord(_ info: AcpSessionInfo) -> TaskRecord {
        let current = now()
        var record = AcpSessionState.newRecord(identity: identity, sessionId: info.sessionId, cwd: info.cwd,
                                               title: info.title, origin: .desktop,
                                               controllable: controllable(info.sessionId, otherwise: false),
                                               at: ProtocolJSON.timestamp(info.updatedAt ?? current))
        let stale = info.updatedAt.map { current.timeIntervalSince($0) > SessionFormatting.idleAfter } ?? true
        record.status = stale ? .idle : .completed
        return record
    }
}
