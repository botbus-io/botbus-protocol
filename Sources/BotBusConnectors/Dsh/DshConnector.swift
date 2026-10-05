import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(os)
import os
#endif
import BotBusProtocol
import BotBusConnectorKit

/// DeepSeek Harness（协议 3.1，一档来源 `dsh`）的连接器：BotBus 自己的活走 `dsh --profile acp` 子进程
///（`AcpConnector`，身份 `.builtin(.dsh)`），电脑上的会话经桌面版或 `dsh web` 的内部接口看见、也经它控制；
/// web 不在时扫 `~/.dsh/sessions`（`DshSessionScanner`）。spec「控制」一表：
///
/// | 操作 | 走哪条 |
/// |---|---|
/// | 新建 | 一律 ACP（带 botbus MCP 与审批）；没有可执行文件时报错 |
/// | 续聊 | 会话在我们的 ACP 进程里 → ACP；否则 web 连着 → web `session/prompt`（带任务专用 CLI 管道）；都不是 → ACP `session/resume`，撞锁时 web 连得上就改走 web，否则报错 |
/// | 审批 / 提问 | 我们的 ACP 这一轮挂着的 → ACP；web 的 waterfall 挂着的 → `$events/result`（按最近一条 waterfall 的 eventId） |
/// | 中断 | ACP `session/cancel` 或 web `session/cancel` |
///
/// **所有权**：ACP 的轮次由 `AcpConnector` 自己认领；web 正在跑、挂着 waterfall 的会话由本连接器 `claimLive` 并实时 upsert，
/// 这一轮收尾（follow 流里的 `turn/end`，或 `api-session/status false` 之后的宽限）再交还。其余全部经 `reconcile(source: .dsh)`
/// 全量对账：web 列表或扫盘结果并上 `AcpConnector.staticTasks()`（见 `DshTaskMapping.merged`）。第一次对账要等拿到完整列表之后，
/// 那一次是 store 的静默基线。
///
/// **只 follow web 已经在跑的会话**：`session/follow` 会让 web 载入并一直锁住会话，之后 ACP 的 resume 必撞锁。
/// 只读历史走读盘或 `session/page`（`DshMessageReader`）。
///
/// **只连用我们主目录的服务**（`DshWebLocator` 按 `DSH_HOME` 过滤），别的主目录的实例一概不碰。依赖的是 dsh 0.1.5-rc web / 0.2.0-rc 桌面的内部接口，
/// 升级可能要跟着改：连不上就退回扫盘，不会弄坏 dsh。
public actor DshConnector: TaskConnector {
    public nonisolated var kind: ConnectorKind { .dsh }
    /// 网页端开着时会话跑在 DeepSeek Harness 自己的进程里，BotBus 的文件夹授权说明不了它。
    public nonisolated var runsUnderBotBus: Bool { false }

    /// 运行期健康（web 拒绝登录、ACP 进程起不来之类）：app 转给 `ConnectorRegistry.reportRuntime` 并重发快照。
    public typealias HealthHandler = @Sendable (ConnectorInfo.Status, String?) async -> Void
    public typealias SecretLoader = @Sendable (DshPaths) -> SymmetricKey?
    /// 全部计时器（节拍、等 `ready`、收尾宽限、等续聊开跑）都经它睡：测试注入后按时长放行，不靠墙钟。
    public typealias Sleeper = @Sendable (TimeInterval) async -> Void

    public static var defaultArchiveURL: URL {
        LocalHookServer.defaultSupportDirectory.appendingPathComponent("dsh-sessions.json")
    }

    static let log = PlatformLogger(subsystem: "io.botbus.agent", category: "dsh")

    public struct Timing: Sendable {
        /// 循环的节拍：web 不在时每拍找一次 web 并扫一次盘；连着时看要不要 ping、重新拉列表。
        public var tick: TimeInterval
        /// web 拒绝登录之后隔多久再试。
        public var authRetry: TimeInterval
        public var listRefresh: TimeInterval
        public var ping: TimeInterval
        /// 连上 mux 之后等 `$events` 的 `ready` 多久。
        public var readyTimeout: TimeInterval
        /// `api-session/status false` 比 follow 流里的 `turn/end` 先到：等这么久还没见到收尾就按已结束算。
        public var settleGrace: TimeInterval
        /// 经 web 续聊之后等它开跑多久；过了还没开跑就不再当它在跑。
        public var promptStartTimeout: TimeInterval

        public init(tick: TimeInterval = 5, authRetry: TimeInterval = 30, listRefresh: TimeInterval = 60,
                    ping: TimeInterval = 30, readyTimeout: TimeInterval = 5, settleGrace: TimeInterval = 3,
                    promptStartTimeout: TimeInterval = 20) {
            self.tick = tick
            self.authRetry = authRetry
            self.listRefresh = listRefresh
            self.ping = ping
            self.readyTimeout = readyTimeout
            self.settleGrace = settleGrace
            self.promptStartTimeout = promptStartTimeout
        }
    }

    /// 连着的一个 `dsh web`。
    struct WebLink {
        let generation: Int
        let pid: Int32
        let client: DshWebClient
        let mux: DshWebMux
        let clientId: String
        let isDesktopHost: Bool
    }

    public nonisolated let paths: DshPaths
    /// BotBus 自己的活。测试与读取器要直接问它（`completeTranscript`）。
    let acp: AcpConnector
    private let store: TaskStore
    private let tools: @Sendable () -> AgentToolsConfiguration?
    private let registry: TaskContextRegistry
    private var toolsContexts: [String: DshToolsContext] = [:]
    private var toolsContextGeneration = 0
    private let installation: @Sendable () -> DshInstallation?
    private let http: any DshHTTPTransport
    private let webSocket: any WebSocketTransport
    private let listing: any DshProcessListing
    private let loadSecret: SecretLoader
    private let transcriptRunner: DshTranscriptDecoder.Runner
    private let scanner: DshSessionScanner
    private let now: @Sendable () -> Date
    private let sleep: Sleeper
    private let timing: Timing
    private let onHealth: HealthHandler

    private var loop: Task<Void, Never>?
    private var isShutDown = false

    // web
    private var web: WebLink?
    /// 正在进行的一次找 web + 连接：节拍与续聊撞锁时的"立刻找一次"不能各连各的（会连出两条 mux）。
    private var connecting: Task<Void, Never>?
    private var webGeneration = 0
    private var webSessions: [String: DshWebSessionSummary] = [:]
    private var webRunning: Set<String> = []
    private var lastListRefresh: Date = .distantPast
    private var lastPing: Date = .distantPast
    private var nextConnectAttempt: Date = .distantPast
    /// web 拒绝了登录（或读不到签名密钥）：健康状态里说清楚。
    private var webAuthProblem: String?
    private struct DesktopHandoff {
        let cwd: String
        var nextAttempt = Date.distantPast
    }
    /// 仅本连接器新建的会话，首轮空闲后交给桌面工作区。失败不影响手机任务，延后重试。
    private var desktopHandoffs: [String: DesktopHandoff] = [:]
    private var handingOff: Set<String> = []

    // 扫盘
    private var scanned: [String: DshSessionSummary]?
    private var logFiles: [String: URL] = [:]

    // 实时
    private var live: [String: DshLiveState] = [:]
    private var follows: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    private var pending: [String: DshWaterfall] = [:]
    /// 经 web 续聊、还没见到它开跑的会话 → 发出的时间。
    private var expecting: [String: Date] = [:]
    private var settleTimers: [String: Task<Void, Never>] = [:]
    /// 本连接器 `claimLive` 过、还没交还的任务 id。
    private var claimed: Set<String> = []
    private let liveOwnerToken = UUID()

    // 对账与健康
    private var hasBaseline = false
    private var reconcileGeneration = 0
    private var acpHealth: (status: ConnectorInfo.Status, message: String?)?
    private var lastHealth: (status: ConnectorInfo.Status, message: String?)?

    public init(store: TaskStore,
                paths: DshPaths = DshPaths(),
                installation: @escaping @Sendable () -> DshInstallation?,
                launcher: @escaping AcpLauncherFactory = AcpLaunchRequest.subprocess,
                tools: @escaping @Sendable () -> AgentToolsConfiguration? = { nil },
                registry: TaskContextRegistry = TaskContextRegistry(),
                archive: AcpSessionArchive = AcpSessionArchive(url: nil),
                http: any DshHTTPTransport = URLSessionDshHTTPTransport(),
                webSocket: any WebSocketTransport = OpenClawWebSocketTransport(),
                listing: any DshProcessListing = SystemDshProcessListing(),
                loadSecret: @escaping SecretLoader = { DshWebCredentials.loadBrowserSessionSecret(paths: $0) },
                transcriptRunner: @escaping DshTranscriptDecoder.Runner = DshTranscriptDecoder.runProcess,
                clientVersion: String = AgentIdentity.bundleVersion(),
                now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping Sleeper = { seconds in try? await Task.sleep(for: .seconds(seconds)) },
                timing: Timing = Timing(),
                onHealth: @escaping HealthHandler = { _, _ in }) {
        self.store = store
        self.tools = tools
        self.registry = registry
        self.paths = paths
        self.installation = installation
        self.http = http
        self.webSocket = webSocket
        self.listing = listing
        self.loadSecret = loadSecret
        self.transcriptRunner = transcriptRunner
        self.now = now
        self.sleep = sleep
        self.timing = timing
        self.onHealth = onHealth
        self.scanner = DshSessionScanner(paths: paths, now: now, headers: { files in
            let decoder = DshTranscriptDecoder(node: installation()?.node, runner: transcriptRunner)
            return (try? await decoder.headers(files)) ?? [:]
        })
        // ACP 的回调要回到本连接器，而 init 里还不能捕获 self：经一个弱引用盒子。
        let relay = DshConnectorRef()
        self.acp = AcpConnector(
            spec: Self.acpSpec(installation(), paths: paths), identity: DshTaskMapping.identity, store: store,
            launcher: launcher, tools: tools, registry: registry, archive: archive, clientVersion: clientVersion,
            // 空闲检查仍保护轮次、命令与载入；全部结束后立即释放写锁，供桌面接聊。
            idleTimeout: 0, now: now,
            onHealth: { _, status, message, _ in await relay.connector?.acpHealthChanged(status, message) },
            onTasksChanged: { await relay.connector?.reconcile() })
        relay.connector = self
    }

    static func acpSpec(_ installation: DshInstallation?, paths: DshPaths) -> AcpAgentSpec {
        installation?.acpSpec(paths: paths)
            ?? AcpAgentSpec(id: DshPaths.agentId, name: DshPaths.displayName, executable: nil, arguments: [],
                            environment: paths.environment, origin: .manifest, defaultEnabled: true)
    }

    // MARK: - 生命周期

    /// 开始观察（找 web、扫盘、对账）。幂等。不依赖配对：命令要等 app 把本连接器注册进分发器。
    public func start() {
        guard loop == nil, !isShutDown else { return }
        loop = Task { [weak self] in await self?.runLoop() }
    }

    /// 停用：断开 web、交还认领、关 ACP 子进程。任务交给 store 按开关处理。
    public func stop() async {
        loop?.cancel()
        loop = nil
        await closeToolsContexts()
        desktopHandoffs.removeAll()
        await dropWeb()
        hasBaseline = false
        scanned = nil
        live.removeAll()
        await acp.stop()
    }

    /// 解除配对或被接管：只关 BotBus 拉起的 ACP 子进程，观察照旧。
    public func stopSubprocesses() async {
        await closeToolsContexts()
        await acp.stopSubprocess()
    }

    /// App 退出：不可逆，之后迟到的命令拉不起进程。
    public func shutdown() async {
        isShutDown = true
        desktopHandoffs.removeAll()
        loop?.cancel()
        loop = nil
        await closeToolsContexts()
        await dropWeb()
        await acp.shutdown()
    }

    public var isWebConnected: Bool { web != nil }
    /// 连着的 web 的端口（设置页显示）。
    public var webPort: Int? { web?.client.endpoint.port }

    /// `ConnectorRegistry.refresh()` 会把运行期状态重置回探测结果：再报一次。
    public func reannounceHealth() async {
        guard let lastHealth else { return }
        await onHealth(lastHealth.status, lastHealth.message)
    }

    private func runLoop() async {
        await tick()
        while !Task.isCancelled {
            await sleep(timing.tick)
            guard !Task.isCancelled else { return }
            await tick()
        }
    }

    /// 一拍：web 不在就找 web，还不在就扫盘；连着就按需 ping、重新拉列表。
    func tick() async {
        guard loop != nil, !isShutDown else { return }
        _ = await syncAcpSpec()
        if web == nil, now() >= nextConnectAttempt { await connectWeb() }
        if let link = web {
            if now().timeIntervalSince(lastPing) >= timing.ping {
                lastPing = now()
                do { try await link.mux.ping() } catch { await webLost(generation: link.generation) }
            }
            if web != nil, now().timeIntervalSince(lastListRefresh) >= timing.listRefresh { await refreshWebList() }
        }
        await handOffNewSessionsToDesktop()
        if web == nil {
            await scanDisk()
            await reconcile()
        }
        await updateHealth()
    }

    /// 安装位置变了（用户刚装上、换了版本）就换 ACP 的启动方式。返回有没有可执行文件。
    @discardableResult
    private func syncAcpSpec() async -> Bool {
        let found = installation()
        await acp.update(spec: Self.acpSpec(found, paths: paths))
        return found != nil
    }

    // MARK: - 命令

    public func start(projectPath: String, prompt: String, images: [URL]) async throws -> ConnectorOutcome {
        guard images.isEmpty else { throw ConnectorError("这个 Agent 暂不支持发图") }
        guard await syncAcpSpec() else {
            throw ConnectorError("本机没找到 DeepSeek Harness 的可执行文件（dsh），没法从手机新建任务", diagnosis: .agentNotInstalled)
        }
        // 桌面工作区以 realpath 存目录，adopt 严格比较 session header 的 cwd；两端必须使用同一写法。
        let cwd = TranscriptFileRefs.realPath(projectPath) ?? projectPath
        let outcome = try await acp.start(projectPath: cwd, prompt: prompt, images: [])
        if loop != nil, !isShutDown {
            desktopHandoffs[try Self.sessionId(outcome.taskId)] = DesktopHandoff(cwd: cwd)
        }
        return outcome
    }

    private func handOffNewSessionsToDesktop() async {
        guard let link = web, link.isDesktopHost, loop != nil, !isShutDown else { return }
        for (sessionId, handoff) in desktopHandoffs {
            guard !handingOff.contains(sessionId), now() >= handoff.nextAttempt else { continue }
            let taskId = DshTaskMapping.identity.taskId(sessionId: sessionId)
            guard await acp.isInProcess(taskId: taskId) == false else { continue }
            guard await store.task(id: taskId) != nil else {
                desktopHandoffs.removeValue(forKey: sessionId)
                continue
            }
            guard web?.generation == link.generation, loop != nil, !isShutDown else { return }
            guard handingOff.insert(sessionId).inserted else { continue }
            desktopHandoffs[sessionId]?.nextAttempt = now().addingTimeInterval(timing.authRetry)
            do {
                try await link.client.adoptSession(sessionId: sessionId, cwd: handoff.cwd)
                desktopHandoffs.removeValue(forKey: sessionId)
                if web?.generation == link.generation { await refreshWebList() }
            } catch {
                let category = (error as? DshWebError)?.logCategory ?? "transport"
                Self.log.debug("desktop handoff failed: \(category, privacy: .public)")
            }
            handingOff.remove(sessionId)
        }
    }

    public func followUp(taskId: String, prompt: String, images: [URL]) async throws -> ConnectorOutcome {
        guard images.isEmpty else { throw ConnectorError("这个 Agent 暂不支持发图") }
        let sessionId = try Self.sessionId(taskId)
        // 挂着提问时手机发的一句话就是回答（同 Claude 的 AskUserQuestion）。
        if let waterfall = pending[sessionId], case .questions(let questions) = waterfall.request, let link = web {
            try await answerWaterfall(waterfall, link: link,
                                      answers: DshTaskMapping.answers(for: questions, text: prompt))
            return ConnectorOutcome(taskId: taskId, retainsLiveOwnership: isLive(sessionId))
        }
        if await acp.isInProcess(taskId: taskId) {
            return try await acp.followUp(taskId: taskId, prompt: prompt, images: [])
        }
        if let link = web { return try await followUpOverWeb(sessionId, taskId: taskId, prompt: prompt, link: link) }
        guard await syncAcpSpec() else {
            throw ConnectorError("DeepSeek Harness 网页端没有运行，本机也没找到 dsh 可执行文件，没法续聊")
        }
        do {
            return try await acp.followUp(taskId: taskId, prompt: prompt, images: [])
        } catch let error as AcpConnectorError where error.reason == .sessionBusyElsewhere {
            // 别的 dsh 进程拿着这个会话的锁：多半是刚开的 web，还没被找到。立刻找一次，找到就经它续聊。
            if web == nil { await connectWeb() }
            guard let link = web else { throw error }
            return try await followUpOverWeb(sessionId, taskId: taskId, prompt: prompt, link: link)
        }
    }

    public func approve(taskId: String, requestId: String,
                        decision: Command.Approve.Decision) async throws -> ConnectorOutcome {
        try await approve(taskId: taskId, requestId: requestId, decision: decision, answers: nil)
    }

    /// web 的提问：「允许」带 `answers`（按题目 id，值是选项名或手机上打的字），一个都没答时报错且不动挂起；
    /// 「拒绝」是跳过（每题都不选，dsh 当作用户跳过了，这一轮接着跑）。web 的审批只有允许这一次 / 拒绝。
    public func approve(taskId: String, requestId: String, decision: Command.Approve.Decision,
                        answers: [String: [String]]?) async throws -> ConnectorOutcome {
        let sessionId = try Self.sessionId(taskId)
        if await acp.isRunningTurn(taskId: taskId) {
            return try await acp.approve(taskId: taskId, requestId: requestId, decision: decision, answers: answers)
        }
        guard let waterfall = pending[sessionId], waterfall.eventId == requestId else {
            throw ConnectorError("没有待审批的请求（可能已经处理过了）")
        }
        guard let link = web else {
            throw ConnectorError("和 DeepSeek Harness 网页端的连接断开了，请在电脑上处理这个请求")
        }
        switch waterfall.request {
        case .approval:
            try await answerWaterfall(waterfall, link: link, allow: decision == .allow)
        case .questions(let questions):
            let items: [DshQuestionAnswer]
            if decision == .deny {
                items = DshTaskMapping.skipped(questions)
            } else {
                items = DshTaskMapping.answers(for: questions, from: answers ?? [:])
                guard items.contains(where: { !$0.isEmpty }) else {
                    throw ConnectorError("请先选一个选项或写下回答")
                }
            }
            try await answerWaterfall(waterfall, link: link, answers: items)
        case .other:
            throw ConnectorError("认不出这个请求，请在电脑上处理")
        }
        return ConnectorOutcome(taskId: taskId, retainsLiveOwnership: isLive(sessionId))
    }

    public func interrupt(taskId: String) async throws -> ConnectorOutcome {
        let sessionId = try Self.sessionId(taskId)
        if await acp.isRunningTurn(taskId: taskId) { return try await acp.interrupt(taskId: taskId) }
        guard let link = web, isLive(sessionId) || webSessions[sessionId]?.running == true else {
            throw ConnectorError("这个会话现在没有在运行")
        }
        do {
            try await link.client.cancel(sessionId: sessionId)
        } catch {
            throw Self.webFailure(error)
        }
        // 这一轮由 follow 流里的 `turn/end`（aborted）收尾并交还所有权。
        return ConnectorOutcome(taskId: taskId, retainsLiveOwnership: isLive(sessionId))
    }

    private func followUpOverWeb(_ sessionId: String, taskId: String, prompt: String,
                                 link: WebLink) async throws -> ConnectorOutcome {
        let accepted: Bool
        do {
            let generation = toolsContextGeneration
            let context = try await toolsContext(for: taskId)
            guard generation == toolsContextGeneration, web?.generation == link.generation else {
                throw DshWebError.disconnected
            }
            accepted = try await link.client.prompt(sessionId: sessionId, text: context?.prompt(prompt) ?? prompt,
                requestId: (context == nil ? "botbus-" : DshToolsContext.requestPrefix) + UUID().uuidString)
        } catch {
            throw Self.webFailure(error)
        }
        guard accepted else { throw ConnectorError("DeepSeek Harness 网页端没有接受这条消息") }
        // 发出去之后 web 断了：不再记"在跑"，那份状态没人收尾，会一直盖着扫盘的结果。
        guard web?.generation == link.generation else {
            return ConnectorOutcome(taskId: taskId, retainsLiveOwnership: false)
        }
        // 先当它在跑（同 ACP 的 beginTurn）：`api-session/status true` 一到就开 follow 接着跟。
        if !webRunning.contains(sessionId) {
            expecting[sessionId] = now()
            var state = live[sessionId] ?? DshLiveState()
            state.running = true
            state.turnEnd = nil
            live[sessionId] = state
            scheduleExpectationTimeout(sessionId)
        }
        await publishLive(sessionId)
        return ConnectorOutcome(taskId: taskId, retainsLiveOwnership: isLive(sessionId))
    }

    private func toolsContext(for taskId: String) async throws -> DshToolsContext? {
        #if os(Windows)
        return nil
        #else
        let generation = toolsContextGeneration
        guard let configuration = tools(), configuration.isUsable else { return nil }
        let token = await registry.issue(for: taskId)
        let injection = AgentToolsInjection(configuration: configuration, token: token)
        guard !isShutDown, loop != nil, generation == toolsContextGeneration else { throw DshWebError.disconnected }
        if let existing = toolsContexts[taskId], existing.configuration == injection.configuration,
           existing.token == injection.token { return existing }
        if let existing = toolsContexts.removeValue(forKey: taskId) { await existing.shutdown() }
        guard !isShutDown, loop != nil, generation == toolsContextGeneration else { throw DshWebError.disconnected }
        if toolsContexts.count >= TaskContextRegistry.maxTokens, let oldest = toolsContexts.keys.first,
           let context = toolsContexts.removeValue(forKey: oldest) { await context.shutdown() }
        guard !isShutDown, loop != nil, generation == toolsContextGeneration else { throw DshWebError.disconnected }
        // shutdown 会让出 actor；另一条续聊可能已为同一凭据补建管道。
        if let existing = toolsContexts[taskId], existing.configuration == injection.configuration,
           existing.token == injection.token { return existing }
        let context = try DshToolsContext(injection: injection)
        toolsContexts[taskId] = context
        return context
        #endif
    }

    private func closeToolsContexts() async {
        toolsContextGeneration += 1
        let contexts = toolsContexts.values
        toolsContexts.removeAll()
        for context in contexts { await context.shutdown() }
    }

    private func answerWaterfall(_ waterfall: DshWaterfall, link: WebLink, allow: Bool? = nil,
                                 answers: [DshQuestionAnswer]? = nil) async throws {
        do {
            if let answers {
                try await link.client.answerQuestions(clientId: link.clientId, eventId: waterfall.eventId, answers: answers)
            } else {
                try await link.client.answerApproval(clientId: link.clientId, eventId: waterfall.eventId,
                                                     allow: allow ?? false)
            }
        } catch {
            throw Self.webFailure(error)
        }
        // 先改状态：dsh 随后发的 `approval/decided` / 下一段输出不再需要它。
        if pending[waterfall.sessionId]?.eventId == waterfall.eventId {
            pending.removeValue(forKey: waterfall.sessionId)
            await publishLive(waterfall.sessionId)
        }
    }

    // MARK: - 对话记录

    /// `DshMessageReader` 的实现：ACP 仍拥有且内存里齐全的 → 读盘 → web 的 `session/page`（不激活会话）。
    func transcript(taskId: String, limit: Int) async throws -> (entries: [TranscriptEntry], hasMore: Bool) {
        let sessionId = try Self.sessionId(taskId)
        // 交还写锁后桌面可能已经续聊，内存里的“完整”记录不再代表最新历史。
        if await acp.isInProcess(taskId: taskId),
           let complete = await acp.completeTranscript(taskId: taskId, limit: limit) { return complete }
        var failure: Error?
        if let file = logFile(for: sessionId) {
            do {
                let decoder = DshTranscriptDecoder(node: installation()?.node, runner: transcriptRunner)
                let log = try await decoder.read(file)
                return DshTranscriptParser.window(from: log.events, limit: limit, truncated: log.truncated)
            } catch {
                failure = error
            }
        }
        if let link = web {
            do {
                // dsh 按消息条数取页（用户、Agent、系统消息都算），多要一些才凑得出 `limit` 条对话。
                let page = try await link.client.latestPage(sessionId: sessionId, maxMessages: min(max(limit * 3, 30), 200))
                return DshTranscriptParser.window(from: page.events, limit: limit, truncated: page.hasMore)
            } catch {
                failure = Self.webFailure(error)
            }
        }
        throw failure ?? ConnectorError("没找到这个 DeepSeek Harness 会话的记录")
    }

    /// 会话日志文件：扫盘见过就用它的；否则在 `sessions/<项目>/<会话>/` 里找（目录名是会话 id，特殊字符 `~XXXX` 转义）。
    private func logFile(for sessionId: String) -> URL? {
        if let known = scanned?[sessionId]?.logFile ?? logFiles[sessionId],
           FileManager.default.fileExists(atPath: known.path) {
            return known
        }
        let fileManager = FileManager.default
        let projects = (try? fileManager.contentsOfDirectory(at: paths.sessionsDirectory, includingPropertiesForKeys: nil,
                                                             options: [.skipsHiddenFiles])) ?? []
        for project in projects {
            if let file = DshSessionFiles.logFile(in: project.appendingPathComponent(sessionId, isDirectory: true)) {
                logFiles[sessionId] = file
                return file
            }
        }
        for project in projects {
            let sessions = (try? fileManager.contentsOfDirectory(atPath: project.path)) ?? []
            for name in sessions where name.contains("~") && DshSessionScanner.decodeSegment(name) == sessionId {
                if let file = DshSessionFiles.logFile(in: project.appendingPathComponent(name, isDirectory: true)) {
                    logFiles[sessionId] = file
                    return file
                }
            }
        }
        return nil
    }

    // MARK: - web

    /// 找本机用我们主目录的 `dsh web`，挨个端口试，连上第一个。有一次正在找就先等它；等完还没连上再自己找一次
    ///（续聊撞锁时要的是"现在"的结果，不是节拍早先那次没找到的）。
    private func connectWeb() async {
        while let connecting { await connecting.value }
        guard web == nil, loop != nil, !isShutDown else { return }
        let attempt = Task { await self.attemptWebConnection() }
        connecting = attempt
        await attempt.value
    }

    private func attemptWebConnection() async {
        defer { connecting = nil }
        guard web == nil, loop != nil, !isShutDown else { return }
        let paths = self.paths
        let listing = self.listing
        let instances = await Task.detached(priority: .utility) {
            DshWebLocator.locate(paths: paths, listing: listing)
        }.value
        guard !instances.isEmpty else {
            webAuthProblem = nil
            return
        }
        guard let secret = loadSecret(paths) else {
            webAuthProblem = "读不到 DeepSeek Harness 网页端的登录密钥，连不上网页端"
            nextConnectAttempt = now().addingTimeInterval(timing.authRetry)
            return
        }
        var unauthorized = false
        for instance in instances {
            for endpoint in instance.endpoints {
                switch await attach(endpoint: endpoint, pid: instance.pid, isDesktopHost: instance.isDesktopHost, secret: secret) {
                case .connected:
                    webAuthProblem = nil
                    return
                case .unauthorized: unauthorized = true
                case .failed: continue
                }
                if web != nil { return }
            }
        }
        if unauthorized {
            webAuthProblem = "DeepSeek Harness 网页端拒绝了 BotBus 的登录，只能读电脑上的会话记录"
            nextConnectAttempt = now().addingTimeInterval(timing.authRetry)
        }
    }

    private enum AttachResult { case connected, unauthorized, failed }

    /// 握手、订 `$events`、等 `ready`、拉一次列表。失败就关掉这条 mux。
    private func attach(endpoint: DshWebEndpoint, pid: Int32, isDesktopHost: Bool, secret: SymmetricKey) async -> AttachResult {
        let client = DshWebClient(endpoint: endpoint, secret: secret, http: http, now: now)
        let mux = DshWebMux(client: client, transport: webSocket)
        do {
            try await mux.connect()
        } catch DshWebError.unauthorized {
            return .unauthorized
        } catch {
            return .failed
        }
        let events: DshWebStream
        do {
            events = try await mux.openEvents()
        } catch {
            await mux.close()
            return .failed
        }
        webGeneration += 1
        let generation = webGeneration
        let ready = OneShotContinuation<String>()
        Task { [weak self] in await self?.consumeEvents(events, generation: generation, ready: ready) }
        let timeout = Task { [sleep, delay = timing.readyTimeout] in
            await sleep(delay)
            guard !Task.isCancelled else { return }
            ready.resume(throwing: DshWebError.timeout)
        }
        let clientId = try? await ready.value()
        timeout.cancel()
        guard let clientId, generation == webGeneration, web == nil, loop != nil else {
            await mux.close()
            return .failed
        }
        // 先记下连接再拉列表：期间到的 status / waterfall 照常处理，列表随后按最新的覆盖。
        web = WebLink(generation: generation, pid: pid, client: client, mux: mux, clientId: clientId, isDesktopHost: isDesktopHost)
        await mux.setOnClose { [weak self] in await self?.webLost(generation: generation) }
        let list: [DshWebSessionSummary]
        do {
            list = try await client.listSessions()
        } catch {
            await webLost(generation: generation)
            return (error as? DshWebError) == .unauthorized ? .unauthorized : .failed
        }
        guard web?.generation == generation, loop != nil else { return .failed }
        lastPing = now()
        Self.log.info("connected to dsh web on port \(endpoint.port, privacy: .public)")
        applyList(list)
        hasBaseline = true
        // 连着 web 期间盘上的结果只会越来越旧：断开之后要重新扫过才拿来对账（见 `reconcile`）。
        scanned = nil
        for sessionId in webRunning { startFollow(sessionId) }
        await reconcile()
        await updateHealth()
        return .connected
    }

    /// `$events` 的读循环：第一条 `ready` 交给 `attach`，之后逐条处理。流结束（web 关了、连接断了）就当断开。
    private func consumeEvents(_ stream: DshWebStream, generation: Int, ready: OneShotContinuation<String>) async {
        do {
            for try await item in stream.items {
                let frame = DshEventsFrame(json: item)
                if case .ready(let clientId, _) = frame {
                    ready.resume(returning: clientId)
                    continue
                }
                await handle(frame, generation: generation)
            }
        } catch {}
        ready.resume(throwing: DshWebError.disconnected)
        await webLost(generation: generation)
    }

    private func handle(_ frame: DshEventsFrame, generation: Int) async {
        guard let link = web, link.generation == generation else { return }
        switch frame {
        case .emit(let emit):
            await handle(emit)
        case .waterfall(let waterfall):
            if case .other = waterfall.request { return }
            pending[waterfall.sessionId] = waterfall
            // 挂着请求的会话一定在跑；万一 status 还没到也先跟上。
            startFollow(waterfall.sessionId)
            await publishLive(waterfall.sessionId)
        case .cancel(let eventId):
            guard let sessionId = pending.first(where: { $0.value.eventId == eventId })?.key else { return }
            pending.removeValue(forKey: sessionId)
            await publishLive(sessionId)
            await settleIfIdle(sessionId)
        case .ready, .other:
            return
        }
    }

    private func handle(_ emit: DshSessionEmit) async {
        switch emit {
        case .added(let summary):
            webSessions[summary.sessionId] = summary
            if summary.running {
                webRunning.insert(summary.sessionId)
                startFollow(summary.sessionId)
            }
            await reconcile()
        case .removed(let sessionId):
            webSessions.removeValue(forKey: sessionId)
            webRunning.remove(sessionId)
            // 删掉的会话不会再有 waterfall 收尾、也不会再跑：挂着的实时认领就地交还，否则 store 里一直留着它。
            pending.removeValue(forKey: sessionId)
            expecting.removeValue(forKey: sessionId)
            if claimed.contains(DshTaskMapping.identity.taskId(sessionId: sessionId)) {
                await settleIfIdle(sessionId, force: true)
            } else {
                await reconcile()
            }
        case .status(let sessionId, let running):
            if running {
                webRunning.insert(sessionId)
                expecting.removeValue(forKey: sessionId)
                settleTimers.removeValue(forKey: sessionId)?.cancel()
                markWebRunning(sessionId)
                startFollow(sessionId)
                await publishLive(sessionId)
            } else {
                webRunning.remove(sessionId)
                expecting.removeValue(forKey: sessionId)
                // `turn/end`（乃至 follow 的 snapshot）在另一条流里，常常比这条晚到：这一轮的收尾还不知道就等一会儿，
                // 已经见到收尾（snapshot 里那一轮已经结束、只是 web 还说在跑）就立刻交还。
                if let state = live[sessionId], state.running, state.turnEnd == nil {
                    scheduleSettle(sessionId, after: timing.settleGrace)
                } else {
                    await settleIfIdle(sessionId, force: true)
                }
            }
        case .activity(let sessionId, _):
            // 列表里还没有的会话动了（刚建的、刚被别的进程写过的）：重新拉一次列表收敛。
            if webSessions[sessionId] == nil { await refreshWebList() }
        case .error, .other:
            return
        }
    }

    private func refreshWebList() async {
        guard let link = web else { return }
        lastListRefresh = now()
        do {
            let list = try await link.client.listSessions()
            guard web?.generation == link.generation else { return }
            applyList(list)
            for sessionId in webRunning { startFollow(sessionId) }
            await reconcile()
        } catch DshWebError.unauthorized {
            webAuthProblem = "DeepSeek Harness 网页端拒绝了 BotBus 的登录，只能读电脑上的会话记录"
            await webLost(generation: link.generation)
        } catch {
            Self.log.error("dsh session/list failed: \((error as? DshWebError)?.logCategory ?? "other", privacy: .public)")
        }
    }

    private func applyList(_ list: [DshWebSessionSummary]) {
        lastListRefresh = now()
        webSessions = Dictionary(list.map { ($0.sessionId, $0) }, uniquingKeysWith: { first, _ in first })
        webRunning = Set(list.filter(\.running).map(\.sessionId))
    }

    /// web 断了（关掉了、连接死了）：任务留着，实时认领一律交还，退回扫盘；`controllable` 随对账改。
    private func webLost(generation: Int) async {
        guard let link = web, link.generation == generation else { return }
        web = nil
        let released = detachLive()
        await link.mux.close()
        Self.log.info("dsh web connection closed")
        await release(released)
        guard loop != nil, !isShutDown else { return }
        await scanDisk()
        await reconcile()
        await updateHealth()
    }

    /// 主动断开（停用、退出）。
    private func dropWeb() async {
        webGeneration += 1
        let link = web
        web = nil
        let released = detachLive()
        await link?.mux.close()
        await release(released)
    }

    /// web 没了：实时状态**在第一个 `await` 之前**一次清干净。否则关 mux、交还认领的空当里插进来的对账
    ///（节拍、ACP 的回调）会看到"web 不在、会话却还记着在跑"，把一条运行中、不可控制的记录写进 store。
    /// 返回要交还的任务 id。
    private func detachLive() -> Set<String> {
        for (_, follow) in follows { follow.task.cancel() }
        follows.removeAll()
        for (_, timer) in settleTimers { timer.cancel() }
        settleTimers.removeAll()
        webRunning.removeAll()
        webSessions.removeAll()
        pending.removeAll()
        expecting.removeAll()
        for key in live.keys { live[key]?.running = false }
        let ids = claimed
        claimed.removeAll()
        return ids
    }

    private func release(_ ids: Set<String>) async {
        // 期间又连上了 web、重新认领了的，归新连接管。
        for id in ids where !claimed.contains(id) { await store.releaseLive(id, ownerToken: liveOwnerToken) }
    }

    // MARK: - follow

    /// 只给 web 已经在跑（或挂着请求）的会话开 follow：它本来就载入着，不会因为我们多锁一个会话。
    private func startFollow(_ sessionId: String) {
        guard follows[sessionId] == nil, let link = web else { return }
        // snapshot 与 `$events` 在两条流上各自消费，status false 可能比 snapshot 先到：先按 web 说的记成在跑、
        // 收尾未知，那样 status false 会等 snapshot / `turn/end`（或宽限），而不是当场按"没在跑"收掉。
        if webRunning.contains(sessionId) { markWebRunning(sessionId) }
        let id = UUID()
        let generation = link.generation
        let task = Task { [weak self] in
            do {
                let stream = try await link.mux.follow(sessionId: sessionId, maxMessages: 20)
                for try await item in stream.items {
                    guard let self else { return }
                    await self.handleFollow(sessionId, frame: DshFollowFrame(json: item), generation: generation, follow: id)
                }
            } catch {}
            await self?.followEnded(sessionId, id: id)
        }
        follows[sessionId] = (id, task)
    }

    /// web 说这个会话开跑了：记成在跑、这一轮的收尾未知（上一轮的 `turnEnd` 作废）。
    private func markWebRunning(_ sessionId: String) {
        var state = live[sessionId] ?? DshLiveState()
        state.running = true
        state.turnEnd = nil
        live[sessionId] = state
    }

    private func followEnded(_ sessionId: String, id: UUID) async {
        guard follows[sessionId]?.id == id else { return }
        follows.removeValue(forKey: sessionId)
        // 流自己断了（会话被删、web 出错）：没在跑就收尾。
        if !webRunning.contains(sessionId) { await settleIfIdle(sessionId, force: true) }
    }

    private func handleFollow(_ sessionId: String, frame: DshFollowFrame, generation: Int, follow: UUID) async {
        // 已经收尾（停掉了这条 follow）之后才轮到的帧不算数：迟到的 snapshot 会把收完的会话又认领成在跑，却再没人收尾。
        guard web?.generation == generation, follows[sessionId]?.id == follow else { return }
        var state = live[sessionId] ?? DshLiveState()
        let before = state
        var decided: [String] = []
        switch frame {
        case .snapshot(_, _, let events, _):
            for event in events { if let call = state.apply(event) { decided.append(call) } }
            // snapshot 里最后一轮还开着才算在跑；web 说在跑的以 web 为准。
            state.running = DshTranscriptParser.hasOpenTurn(events) || webRunning.contains(sessionId)
        case .event(let event):
            if let call = state.apply(event) { decided.append(call) }
        case .other:
            return
        }
        live[sessionId] = state
        var changed = state != before
        if let waterfall = pending[sessionId] {
            if case .approval(_, let callId?, _) = waterfall.request, decided.contains(callId) {
                pending.removeValue(forKey: sessionId)
                changed = true
            } else if !state.running, before.running {
                // 这一轮都结束了，挂着的请求不会再有人等。
                pending.removeValue(forKey: sessionId)
                changed = true
            }
        }
        guard changed else { return }
        await publishLive(sessionId)
        if !state.running { await settleIfIdle(sessionId) }
    }

    /// `api-session/status false` 之后等 `turn/end`。等不到就按被打断算：实测 web 上 `session/cancel` 打在
    /// 一轮的两步之间时，web 报了不在跑，却一直不写 `turn/end`（之后别的进程打开这个会话才补一条 interrupted）。
    private func scheduleSettle(_ sessionId: String, after delay: TimeInterval) {
        settleTimers[sessionId]?.cancel()
        settleTimers[sessionId] = Task { [weak self, sleep] in
            await sleep(delay)
            guard !Task.isCancelled else { return }
            await self?.abandonTurn(sessionId)
        }
    }

    private func abandonTurn(_ sessionId: String) async {
        guard !webRunning.contains(sessionId), var state = live[sessionId], state.running else {
            await settleIfIdle(sessionId, force: true)
            return
        }
        state.running = false
        state.turnEnd = .interrupted
        state.updatedAt = now()
        live[sessionId] = state
        await settleIfIdle(sessionId, force: true)
    }

    private func scheduleExpectationTimeout(_ sessionId: String) {
        let sentAt = expecting[sessionId]
        let delay = timing.promptStartTimeout
        Task { [weak self, sleep] in
            await sleep(delay)
            await self?.expectationTimedOut(sessionId, sentAt: sentAt)
        }
    }

    private func expectationTimedOut(_ sessionId: String, sentAt: Date?) async {
        guard let sentAt, expecting[sessionId] == sentAt else { return }
        expecting.removeValue(forKey: sessionId)
        await settleIfIdle(sessionId, force: true)
    }

    /// 这一轮收尾了（或宽限到了）：停 follow、写最终状态、交还所有权。`force` = 不管 follow 还觉得在跑。
    private func settleIfIdle(_ sessionId: String, force: Bool = false) async {
        guard !webRunning.contains(sessionId), pending[sessionId] == nil, expecting[sessionId] == nil else { return }
        if force { live[sessionId]?.running = false }
        guard live[sessionId]?.running != true else { return }
        settleTimers.removeValue(forKey: sessionId)?.cancel()
        follows.removeValue(forKey: sessionId)?.task.cancel()
        let taskId = DshTaskMapping.identity.taskId(sessionId: sessionId)
        guard claimed.contains(taskId) else {
            // 没认领过（列表里一直没有它）：对一次账，列表拉到的就进来了。
            await reconcile()
            return
        }
        await publishLive(sessionId)
        claimed.remove(taskId)
        await store.releaseLive(taskId, ownerToken: liveOwnerToken)
        await reconcile()
    }

    private func isLive(_ sessionId: String) -> Bool {
        webRunning.contains(sessionId) || pending[sessionId] != nil || expecting[sessionId] != nil
            || live[sessionId]?.running == true
    }

    /// 认领并写一条实时记录。列表里还没有这个会话时借 store 里已有的记录补 cwd 与标题，两边都没有就等列表。
    ///
    /// 只在 web 连着时认领：中间几处 `await` 期间 web 可能断掉（`webLost` 已经把认领全交还、退回扫盘），
    /// 这时再认领就会把一条"运行中、可控制"的旧记录钉在 store 里，扫盘的对账再也改不动它。
    private func publishLive(_ sessionId: String) async {
        guard let generation = web?.generation else { return }
        let taskId = DshTaskMapping.identity.taskId(sessionId: sessionId)
        var facts = webSessions[sessionId].flatMap(DshSessionFacts.init(web:))
        if facts == nil, web != nil, webSessions[sessionId]?.blank ?? true {
            // 刚建的会话在列表里还是空白（或还没进列表）：开跑之后重新拉一次就有了。
            await refreshWebList()
            facts = webSessions[sessionId].flatMap(DshSessionFacts.init(web:))
        }
        if facts == nil, let existing = await store.task(id: taskId) {
            facts = DshSessionFacts(sessionId: sessionId, cwd: existing.workingDirectory, title: existing.title,
                                    createdAt: DshTaskMapping.date(existing.startedAt),
                                    updatedAt: DshTaskMapping.date(existing.updatedAt) ?? now())
        }
        guard var facts else { return }
        let acpRecord = await acp.staticTasks().first { $0.id == taskId }
        guard web?.generation == generation else { return }
        if !claimed.contains(taskId) {
            claimed.insert(taskId)
            await store.claimLive(taskId, ownerToken: liveOwnerToken)
        }
        // 记录在最后一个 await 之后才定稿、随即写入：同一个会话可能有几次发布交错（snapshot 的这次还在认领，
        // 收尾那次已经写完交还了），先算好的旧记录晚到就会盖掉最终状态。交还了（收尾、web 断了）就不再写。
        guard web?.generation == generation, claimed.contains(taskId) else { return }
        facts.webRunning = webRunning.contains(sessionId)
        let record = DshTaskMapping.record(facts: facts, live: live[sessionId], pending: pending[sessionId], acp: acpRecord,
                                           controllable: true, now: now())
        await store.upsert(record, notify: hasBaseline)
    }

    // MARK: - 扫盘与对账

    private func scanDisk() async {
        let found = await scanner.scan()
        scanned = Dictionary(found.map { ($0.sessionId, $0) }, uniquingKeysWith: { first, _ in first })
        hasBaseline = true
    }

    /// `.dsh` 的全量对账。拿到完整列表（web 或扫盘）之前不对账：那样第一次对账只有 BotBus 自己的记录，
    /// 之后列表带来的历史会话会被 store 当成新出现的任务推通知。
    func reconcile() async {
        guard hasBaseline, loop != nil, !isShutDown else { return }
        reconcileGeneration += 1
        let generation = reconcileGeneration
        let current = now()
        let base: [DshSessionFacts]
        if web != nil {
            base = webSessions.values.compactMap { summary in
                var facts = DshSessionFacts(web: summary)
                facts?.webRunning = webRunning.contains(summary.sessionId)
                return facts
            }
        } else {
            // web 刚断、还没重新扫盘（`webLost` 马上会扫）：拿空底子对账会把会话都当成消失了。
            guard let scanned else { return }
            base = scanned.values.map { DshSessionFacts(scanned: $0, now: current) }
        }
        let controllable = web != nil || installation() != nil
        var acpTasks = await acp.staticTasks()
        if await forgetDeletedAcpSessions(acpTasks, base: base) { acpTasks = await acp.staticTasks() }
        let records = DshTaskMapping.merged(base: base, acp: acpTasks, live: live, controllable: controllable, now: current)
        let agentId = await store.identity.agentId
        guard generation == reconcileGeneration, hasBaseline, loop != nil else { return }
        await store.reconcile(source: .dsh, tasks: records, projects: SessionFormatting.projects(from: records, agentId: agentId))
    }

    /// 只有 ACP 记着（BotBus 拉起或接上过）、底子里没有的会话：会话目录在磁盘上也没了，就是在电脑上删了，
    /// 让 `AcpConnector` 忘掉（否则它的本机记录会一直把它补回列表，最长 7 天）。web 的列表不收 ACP 新建、
    /// 还没交给桌面的会话，所以不拿底子判断，只认磁盘。返回有没有忘掉什么。
    private func forgetDeletedAcpSessions(_ acpTasks: [TaskRecord], base: [DshSessionFacts]) async -> Bool {
        let inBase = Set(base.map(\.sessionId))
        let candidates = acpTasks.compactMap { record -> String? in
            guard record.source == .dsh, let sessionId = DshTaskMapping.identity.sessionId(taskId: record.id),
                  !inBase.contains(sessionId) else { return nil }
            return sessionId
        }
        guard !candidates.isEmpty else {
            await acp.noteSeen(inBase)
            return false
        }
        let directory = paths.sessionsDirectory
        let started = now()
        let onDisk = await Task.detached(priority: .utility) {
            DshSessionScanner.sessionIdsOnDisk(in: directory)
        }.value
        // 都还在也要报一次：`forgetDeleted` 只忘见过的，这一次就是「见过」。
        guard let onDisk else { return false }
        return await acp.forgetDeleted(notIn: onDisk.union(inBase), updatedAfter: .distantPast, updatedBefore: started)
    }

    // MARK: - 健康

    private func acpHealthChanged(_ status: ConnectorInfo.Status, _ message: String?) async {
        acpHealth = status == .ok ? nil : (status, message)
        await updateHealth()
    }

    private func updateHealth() async {
        let health: (status: ConnectorInfo.Status, message: String?)
        if let webAuthProblem {
            health = (.degraded, webAuthProblem)
        } else if let acpHealth {
            health = acpHealth
        } else if installation() == nil {
            health = (.degraded, web != nil
                ? "没找到 dsh 可执行文件：电脑上的会话能看能续聊，但不能从手机新建任务"
                : "没找到 dsh 可执行文件，只能看电脑上的会话")
        } else {
            health = (.ok, nil)
        }
        if let lastHealth, lastHealth.status == health.status, lastHealth.message == health.message { return }
        lastHealth = health
        await onHealth(health.status, health.message)
    }

    // MARK: - 小工具

    static func sessionId(_ taskId: String) throws -> String {
        guard let sessionId = DshTaskMapping.identity.sessionId(taskId: taskId) else {
            throw ConnectorError("任务 id 不属于 DeepSeek Harness：\(taskId)")
        }
        return sessionId
    }

    /// web 的错误 → 给手机的错误。dsh 回的文本可能带会话内容，只给界面、不进公开日志。
    static func webFailure(_ error: Error) -> Error {
        guard let web = error as? DshWebError else { return error }
        return ConnectorError(web.errorDescription ?? "DeepSeek Harness 网页端出错了", containsPrivateDetail: web.containsPrivateDetail)
    }
}

/// init 里交给 `AcpConnector` 的回调经它回到 `DshConnector`（那时还不能捕获 self）。
final class DshConnectorRef: @unchecked Sendable {
    weak var connector: DshConnector?
}

/// `.dsh` 的对话记录：内存里齐全的（BotBus 本次建的会话）→ 读盘（`DshTranscriptDecoder`）→ web 的 `session/page`。
/// 只读，不认领所有权，不 follow（会锁住会话），也不 resume。
public struct DshMessageReader: MessageReader {
    public var kind: ConnectorKind { .dsh }
    private let connector: DshConnector

    public init(connector: DshConnector) {
        self.connector = connector
    }

    public func entries(taskId: String, limit: Int) async throws -> (entries: [TranscriptEntry], hasMore: Bool) {
        try await connector.transcript(taskId: taskId, limit: limit)
    }
}
