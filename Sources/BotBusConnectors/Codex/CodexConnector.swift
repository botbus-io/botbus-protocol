import Foundation
#if canImport(os)
import os
#endif
import BotBusProtocol
import BotBusConnectorKit

/// Codex app-server 的审批决策。四个值就是协议里 `CommandExecutionApprovalDecision` /
/// `FileChangeApprovalDecision` 的全集（另外几个带载荷的变体是 execpolicy / 网络策略修正，本版本不产生）。
///
/// 协议层的 `Command.Approve.Decision` 只有 `allow` / `deny` 两档——手机上就两个按钮——
/// 所以映射是收敛的：`allow → accept`、`deny → decline`。
/// `acceptForSession` 与 `cancel` 留给将来 UI 长出"本次会话都允许"与"撤销整轮"时使用，
/// 它们的编码与作用域在这里已经定义好，接上去只要多两个按钮。
public enum CodexApprovalDecision: String, Hashable, Sendable, CaseIterable {
    case accept
    case acceptForSession
    case decline
    case cancel

    public init(_ decision: Command.Approve.Decision) {
        switch decision {
        case .allow: self = .accept
        case .deny: self = .decline
        }
    }

    /// 是不是"同意"。`item/permissions/requestApproval` 的响应里没有 decision 字段，
    /// 拒绝只能表达成"一项权限都不授"，所以那条路径要靠这个判断。
    public var grantsPermission: Bool {
        switch self {
        case .accept, .acceptForSession: return true
        case .decline, .cancel: return false
        }
    }

    /// 权限授予的作用域（`PermissionGrantScope`）。只有 `acceptForSession` 覆盖整个会话。
    public var permissionScope: String { self == .acceptForSession ? "session" : "turn" }
}

/// Codex 的命令语义与审批生命周期：坐在 `CodexAppServer`（协议层）、`CommandDispatcher`（路由）
/// 与 `TaskStore`（状态与通知）中间。
///
/// 几条不显然的约定：
///
/// - **命令返回 ≠ 轮次结束**。四条命令一律返回 `retainsLiveOwnership: true`：`turn/start` 发出去之后
///   模型才刚开始干活，`approve` 之后轮次接着跑，`turn/interrupt` 也要等 `turn/completed` 才算落地。
///   所有权在 `turn/completed`（或子进程退出）时由本连接器自己交还，分发器不掺和。
/// - **服务端请求一条都不能不回**。四类审批转成 `PendingRequest` 挂到任务上等人回答；
///   其余的（`item/tool/call`、`mcpServer/elicitation/request`、`account/chatgptAuthTokens/refresh`、
///   `attestation/generate`，以及将来冒出来的任何新方法）**立刻**回掉，见 `autoAnswer(_:)`。
///   漏一条，codex 就在那条请求上一直等，整个线程挂死。
/// - **审批请求本身不带 diff**：`item/fileChange/requestApproval` 的补丁由 `CodexAppServer`
///   从同 itemId 的 `item/started` 缓存里配好放进 `CodexServerRequest.fileChanges`，这里直接用。
/// - **状态不自己推导**：一律取 `CodexNotification.statusTransition`（spec 6.1 的映射表只此一份）。
/// - **日志只记方法名、id、种类与条数**，审批摘要、补丁、消息正文一个字都不进日志——那是用户的会话内容。
/// - **手机任务带上 agent 工具**（spec 3.2）：app 给了可用的 `AgentToolsConfiguration` 时，`thread/start` 与
///   `thread/resume` 多带 `developerInstructions` 与点路径到叶子的 `config`（MCP server + shell 环境变量），
///   拿到线程 id 后把 token 绑到任务上。已在本代子进程加载的线程续聊只发 `turn/start`，不重复注入。
///   `CodexAppServer` 重启后自动 resume 的线程不带注入——那一轮本来就随旧进程没了，下一次续聊会重新 resume 并注入。
public actor CodexConnector: TaskConnector {
    /// 标题上限，与只读观察保持一致（`CodexThreadReader.titleLimit`）。
    public static let titleLimit = 80
    /// 只发图、不写字新建任务时的标题。本连接器之后不再改标题；交还只读观察后，Codex 线程自己的标题会盖掉它。
    static let imageOnlyTitle = "图片"
    public static let messageLimit = 500
    /// 流式 agent 消息最多隔多久改一次 `lastMessage`。每个 delta 都改的话，每个 token 都是一条 `taskUpdated`：
    /// Relay 每条都要落一次存储、叫醒所有手机各拉一遍快照。
    public static let defaultStreamInterval: TimeInterval = 1
    /// `PendingRequest.summary` 的上限：手表上就一行。
    public static let summaryLimit = 200
    /// `PendingRequest.detail` 的上限。整个补丁可能上兆，不能原样塞进 WebSocket 帧。
    public static let detailLimit = 4000
    /// 最多记住多少个线程的实时状态。
    public static let maxTrackedThreads = 256
    /// 回给"本 Agent 不实现这个请求"的 JSON-RPC 错误码（method not found）。
    public static let unsupportedRequestCode = -32601

    private static let log = PlatformLogger(subsystem: "io.botbus.agent", category: "codexconnector")

    public let kind: ConnectorKind = .codex

    /// 一个由本连接器实时驱动的线程。字段分两类：进 `TaskRecord` 的，和纯控制用的。
    private struct LiveThread {
        let threadId: String
        var projectPath: String
        var projectName: String
        var title: String
        var status: TaskStatus
        var lastMessage: String?
        var pendingRequest: PendingRequest?
        var origin: TaskOrigin
        var startedAt: Date
        var updatedAt: Date

        /// 挂在这个任务上的服务端请求 key（`CodexServerRequest.key`），与 `pendingRequest?.id` 同值。
        var pendingKey: String?
        /// 最近一次 `turn/started` 的轮次 id。`turn/interrupt` 必须带它。
        var currentTurnId: String?
        /// 线程在哪一代子进程里被 `thread/start` / `thread/resume` 过。与当前代不同就得重新 resume。
        var loadedGeneration: Int?
        /// 本连接器是否已向 `TaskStore` 认领这个 id。
        var owned: Bool
        /// 本轮是否已经收到过 `phase == final_answer` 的 agent 消息；收到之后就不再被 commentary 覆盖。
        var hasFinalAnswer: Bool
        /// 协议 3.7：最近一次失败的 turn 带回的错误码换成的诊断。
        var diagnosis: FailureDiagnosis? = nil
        /// 协议 3.2：线程下一轮的模型与思考强度（`thread/start` / `thread/resume` 的应答，或手机刚换过的）。
        var model: String? = nil
        var effort: String? = nil
        /// 协议 3.3：共用桌面时，当前这一轮是不是手机起的（本连接器发了 `turn/start` / `turn/steer`，
        /// 到 `turn/completed` 为止）。只有这样的轮次里的审批才按项目的自动批准放行；不进 `TaskRecord`。
        var phoneTurn = false
    }

    /// 子进程现在什么情况。菜单栏要能看出 `codex app-server` 是活着、正在起、还是死了等着重启——
    /// 这是一个跑在用户自己机器上的常驻进程，它的生死不该是悄无声息的。
    public struct Status: Hashable, Sendable {
        public enum Phase: Hashable, Sendable {
            /// 没 `start()` 过，或者已经 `stop()` 了。此时机器上没有我们起的 codex 进程。
            case stopped
            /// 子进程起来了，`initialize` 握手还没跑完。
            case starting
            /// 握手完成，命令可以下发了。
            case ready
            /// 子进程没了，`after` 秒后自动重启（`CodexAppServer.restartDelay`）。
            case restarting(after: TimeInterval)
        }

        /// 退出原因（stderr 末尾）在菜单里最多显示这么长。
        public static let detailLimit = 120

        public var phase: Phase
        /// 第几代子进程。每重启一次加一；没起过是 0。
        public var generation: Int
        /// 当前由本连接器实时驱动的线程数。
        public var liveTaskCount: Int
        /// 退出原因的一小段，只给界面看。**不进日志**。
        public var detail: String?

        public init(phase: Phase = .stopped, generation: Int = 0, liveTaskCount: Int = 0, detail: String? = nil) {
            self.phase = phase
            self.generation = generation
            self.liveTaskCount = liveTaskCount
            self.detail = detail
        }

        /// 菜单栏里那一行。
        public var text: String {
            switch phase {
            case .stopped:
                return "app-server：未运行"
            case .starting:
                return "app-server：正在启动…"
            case .ready:
                return liveTaskCount > 0
                    ? "app-server：运行中 · 正在驱动 \(liveTaskCount) 个任务"
                    : "app-server：运行中"
            case .restarting(let after):
                let seconds = after < 1 ? "\(after)" : "\(Int(after.rounded()))"
                let head = "app-server：已退出，\(seconds) 秒后重启"
                guard let detail, !detail.isEmpty else { return head }
                return "\(head)（\(detail)）"
            }
        }

        /// 要不要让用户注意到。死了等重启算要，其余不算——正常运行不该抢眼。
        public var needsAttention: Bool {
            if case .restarting = phase { return true }
            return false
        }
    }

    private let server: CodexAppServer
    private let store: TaskStore
    private let now: @Sendable () -> Date
    private let statusObserver: @Sendable (Status) -> Void
    private let tools: @Sendable () -> AgentToolsConfiguration?
    private let registry: TaskContextRegistry
    /// The desktop owns this app-server connection; unknown tool calls belong to the desktop.
    private let sharedDesktop: Bool

    private var threads: [String: LiveThread] = [:]
    /// 插入顺序，淘汰时从队首找。
    private var order: [String] = []
    /// 桌面上游也会广播内部子代理；记住最近的过滤结果，避免每条流式事件都去读一次元数据。
    private var ignoredDesktopThreads: [String] = []
    /// itemId → 正在流式拼接的 agent 消息。不进 `LiveThread`：它不影响 `TaskRecord`，
    /// 塞进去会让每个 delta 都变成一次"记录变了"。
    private var messageBuffers: [String: [String: String]] = [:]
    /// 流式节流（见 `defaultStreamInterval`）：上次因 delta 改 `lastMessage` 的时间、间隔内攒下还没写进记录的
    /// 最新文本，和到点补写它的定时任务。都按线程记。
    private let streamInterval: TimeInterval
    private var streamWrittenAt: [String: Date] = [:]
    private var pendingStreamText: [String: String] = [:]
    private var streamFlushes: [String: Task<Void, Never>] = [:]
    private var eventLoop: Task<Void, Never>?
    private var activeCommands = 0
    private var handoffRequested = false

    /// Stop accepting new commands once all in-flight commands have completed.
    public func prepareForDesktopHandoff() -> Bool {
        guard activeCommands == 0, status.liveTaskCount == 0 else { return false }
        handoffRequested = true
        return true
    }

    public func cancelDesktopHandoff() { handoffRequested = false }

    private func enterCommand() throws {
        guard !handoffRequested else { throw ConnectorError("Codex 桌面正在连接，请稍后重试") }
        activeCommands += 1
    }

    /// 子进程状态。只在真的变了的时候才通知观察者。
    public private(set) var status = Status()

    /// - Parameters:
    ///   - tools: 每次 `thread/start` / `thread/resume` 前现取；nil 或不可用 = 不注入 agent 工具。
    ///   - registry: 签发与绑定 task token；app 里与本机工具服务器共用同一个实例。
    public init(server: CodexAppServer, store: TaskStore,
                now: @escaping @Sendable () -> Date = { Date() },
                statusObserver: @escaping @Sendable (Status) -> Void = { _ in },
                tools: @escaping @Sendable () -> AgentToolsConfiguration? = { nil },
                registry: TaskContextRegistry = TaskContextRegistry(),
                sharedDesktop: Bool = false,
                streamInterval: TimeInterval = CodexConnector.defaultStreamInterval) {
        self.server = server
        self.store = store
        self.now = now
        self.statusObserver = statusObserver
        self.tools = tools
        self.registry = registry
        self.sharedDesktop = sharedDesktop
        self.streamInterval = streamInterval
    }

    // MARK: - 生命周期

    /// 订阅事件流、起 app-server。幂等。
    ///
    /// 订阅必须排在 `CodexAppServer.start()` 前面：`events()` 没有历史缓冲，晚一步就会漏掉
    /// `.started` / `.ready`。
    public func start() async {
        guard eventLoop == nil else { return }
        let stream = await server.events()
        eventLoop = Task { [weak self] in
            for await event in stream {
                await self?.handle(event)
            }
        }
        // 先报"正在启动"再真的起：`.started` 是异步送达的，不然菜单栏会有一小段写着"未运行"。
        updateStatus { $0.phase = .starting }
        await server.start()
    }

    /// 停掉事件循环与 app-server，并把所有实时任务交还给只读观察。幂等。
    public func stop() async {
        eventLoop?.cancel()
        eventLoop = nil
        await server.stop()
        for threadId in order {
            // 不动 markControlled：那是"重启后要不要 resume"的账，跟停机无关。
            await release(threadId, relinquishControl: false)
        }
        threads.removeAll()
        order.removeAll()
        ignoredDesktopThreads.removeAll()
        messageBuffers.removeAll()
        dropAllStreams()
        // `CodexAppServer.stop()` 不发 `.exited`（那条只给"自己死掉"的路径），状态得自己收。
        // liveTaskCount 由 updateStatus 自己按账本重算，上面刚清空，这里必然是 0。
        updateStatus {
            $0.phase = .stopped
            $0.detail = nil
        }
    }

    /// 当前由本连接器实时驱动的线程 id（按首次出现顺序）。菜单栏与测试用。
    public func liveThreadIds() -> [String] { order }

    /// 线程上最近一次 `turn/started` 的轮次 id。`interrupt` 要它，没有就不能中断。
    public func currentTurnId(threadId: String) -> String? { threads[threadId]?.currentTurnId }

    /// 线程是否已在**当前这一代**子进程里加载过（`thread/start` / `thread/resume` 成功）。
    ///
    /// 代数每次都现问 `CodexAppServer`，不缓存 `.started` 事件里的那个数：事件是异步送达的，
    /// 缓存会开出一个"进程已经换代、我们还以为线程加载着"的窗口，那会让下一条命令撞上
    /// `-32600 thread not found`。
    public func isLoaded(threadId: String) async -> Bool {
        guard let loaded = threads[threadId]?.loadedGeneration else { return false }
        return loaded == (await server.processGeneration)
    }

    // MARK: - TaskConnector：四条命令（spec 6.1）

    /// `thread/start {cwd}` → `turn/start {threadId, input:[text, localImage…]}`。
    public func start(projectPath: String, prompt: String, images: [URL]) async throws -> ConnectorOutcome {
        try await start(projectPath: projectPath, prompt: prompt, images: images, selection: ModelSelection())
    }

    /// 协议 3.2：`selection` 随第一轮 `turn/start` 发出去，app-server 记在线程上，之后的续聊沿用。
    public func start(projectPath: String, prompt: String, images: [URL],
                      selection: ModelSelection) async throws -> ConnectorOutcome {
        try enterCommand()
        defer { activeCommands -= 1 }
        let path = projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { throw ConnectorError("startTask 没有给项目目录") }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        // 只发图不写字也是一条完整的消息。
        guard !text.isEmpty || !images.isEmpty else { throw ConnectorError("startTask 的 prompt 是空的") }
        // 在 `thread/start` 之前就查：选错了不该先建出一条空线程。
        try validate(selection, threadId: nil)

        let injection = await AgentToolsInjection.make(tools(), registry: registry)
        let response = try await server.request("thread/start",
                                                params: Self.threadStartParams(cwd: path, injection: injection))
        guard let threadId = response.path("thread", "id")?.stringValue, !threadId.isEmpty else {
            throw ConnectorError("Codex 没有返回线程 id")
        }
        if let injection { await registry.bind(injection.token, taskId: Self.protocolId(threadId)) }
        // 应答里的 cwd 是 app-server 规范化过的绝对路径，比客户端传来的更可信。
        let cwd = response["cwd"]?.stringValue ?? path
        // 手机端没有空标题兜底：只发图时总得给列表里的这一行起个名字。
        let title = text.isEmpty
            ? Self.imageOnlyTitle
            : CodexThreadReader.truncate(CodexThreadReader.singleLine(text), limit: Self.titleLimit)
        register(threadId: threadId, projectPath: cwd, title: title, origin: .watch)
        applyModel(from: response, to: threadId)
        let generation = await server.processGeneration
        mutate(threadId) {
            $0.loadedGeneration = generation
            $0.status = .running
        }
        await claim(threadId)
        await publish(threadId)

        // 先记下再发：这一轮的第一条审批可能比 `turn/start` 的应答先到。
        mutate(threadId) { $0.phoneTurn = true }
        do {
            _ = try await server.request("turn/start",
                                         params: Self.turnStartParams(threadId: threadId, text: text, images: images,
                                                                      selection: selection))
            mutate(threadId) {
                if let model = selection.model { $0.model = model }
                if let effort = selection.effort { $0.effort = effort }
            }
        } catch {
            mutate(threadId) { $0.phoneTurn = false }
            // 轮次没起来就别霸着所有权，让只读观察接手这条线程。
            await release(threadId)
            throw error
        }
        await publish(threadId)
        return ConnectorOutcome(taskId: Self.protocolId(threadId), retainsLiveOwnership: true)
    }

    /// 线程不在本进程里就先 `thread/resume`，再 `turn/start`。
    ///
    /// 有一个例外：这个线程正挂着一条 `item/tool/requestUserInput` 时，续聊**就是**那条回答
    /// （spec 6.1：收到 approve 或 followUp 后按响应结构回复），不另起一轮。
    public func followUp(taskId: String, prompt: String, images: [URL]) async throws -> ConnectorOutcome {
        try await followUp(taskId: taskId, prompt: prompt, images: images, selection: ModelSelection())
    }

    /// 协议 3.2：`selection` 随 `turn/start` 一起发（app-server 记在线程上）。回答挂着的提问、
    /// 或共用桌面时插进正在跑的那一轮（`turn/steer` 不收模型）时不换，手机上的选择会跟着快照退回去。
    public func followUp(taskId: String, prompt: String, images: [URL],
                         selection: ModelSelection) async throws -> ConnectorOutcome {
        try enterCommand()
        defer { activeCommands -= 1 }
        let threadId = try Self.nativeId(taskId)
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !images.isEmpty else { throw ConnectorError("followUp 的 prompt 是空的") }
        try validate(selection, threadId: threadId)

        if let question = await pendingUserInput(threadId: threadId) {
            // `requestUserInput` 的回答只收文字：带图的续聊若当成回答，图会被悄悄丢掉；
            // 另起一轮又会让挂着的提问没人回。两头都不对，让用户先回答。
            guard images.isEmpty else { throw ConnectorError("Agent 正在等你回答问题，先回答再发图") }
            if try await answerUserInput(question, text: text) {
                mutate(threadId) {
                    $0.pendingKey = nil
                    $0.pendingRequest = nil
                    if $0.status == .waitingInput { $0.status = .running }
                }
                await publish(threadId)
                return ConnectorOutcome(taskId: Self.protocolId(threadId), retainsLiveOwnership: true)
            }
        }

        if sharedDesktop, await !isLoaded(threadId: threadId) {
            // A desktop thread can already be loaded in the same upstream even if this Agent
            // has never seen it. Resuming that thread would unnecessarily alter its settings.
            let loaded = try await server.request("thread/loaded/list", params: [:])
            if (loaded["data"]?.arrayValue ?? []).contains(.string(threadId)) {
                await adopt(threadId: threadId, resumeResponse: nil)
                let generation = await server.processGeneration
                mutate(threadId) { $0.loadedGeneration = generation }
            }
        }

        if await !isLoaded(threadId: threadId) {
            // 只有要重新加载线程时才注入：已加载的线程上次 start / resume 时已经带过了。
            let injection = await AgentToolsInjection.make(tools(), registry: registry,
                                                           reusing: Self.protocolId(threadId))
            let response = try await server.request("thread/resume",
                                                    params: Self.threadResumeParams(threadId: threadId, injection: injection))
            if let injection { await registry.bind(injection.token, taskId: Self.protocolId(threadId)) }
            await adopt(threadId: threadId, resumeResponse: response)
            let generation = await server.processGeneration
            mutate(threadId) { $0.loadedGeneration = generation }
        }
        await claim(threadId)
        // 图与字一起进 `input`（localImage）：`turn/steer` 与 `turn/start` 收同一种 UserInput，
        // 所以共用桌面端时插进正在跑的那一轮也带得上图。
        let params = Self.turnStartParams(threadId: threadId, text: text, images: images, selection: selection)
        // 协议 3.3：从这里到 `turn/completed` 都算手机的轮次（插进桌面那一轮时，剩下的部分也算）。先记下再发，
        // 这一轮的第一条审批可能比应答先到；没发出去就撤回。
        let wasPhoneTurn = threads[threadId]?.phoneTurn ?? false
        mutate(threadId) { $0.phoneTurn = true }
        do {
            if sharedDesktop, let activeTurn = threads[threadId]?.currentTurnId {
                let input = params["input"] ?? .array([])
                _ = try await server.request("turn/steer", params: [
                    "threadId": .string(threadId), "expectedTurnId": .string(activeTurn), "input": input,
                ])
            } else {
                _ = try await server.request("turn/start", params: params)
                mutate(threadId) {
                    if let model = selection.model { $0.model = model }
                    if let effort = selection.effort { $0.effort = effort }
                }
            }
        } catch {
            mutate(threadId) { $0.phoneTurn = wasPhoneTurn }
            throw error
        }
        mutate(threadId) { $0.status = .running }
        await publish(threadId)
        return ConnectorOutcome(taskId: Self.protocolId(threadId), retainsLiveOwnership: true)
    }

    /// 回答一条挂起的服务端请求。
    ///
    /// 请求可能**已经不在了**：`turn/completed`（任何状态）会让 `CodexAppServer` 静默丢弃该轮所有挂起的
    /// 服务端请求——是丢弃不是回答。手机端在那之后点批准，只能拿到 `ok:false` 加一句说明。
    public func approve(taskId: String, requestId: String,
                        decision: Command.Approve.Decision) async throws -> ConnectorOutcome {
        try await approve(taskId: taskId, requestId: requestId, decision: decision, answers: nil)
    }

    /// `answers`（协议 2.14）只对 `requestUserInput` 有意义：手机在选项里点好的答案，按问题 id 原样回过去。
    public func approve(taskId: String, requestId: String, decision: Command.Approve.Decision,
                        answers: [String: [String]]?) async throws -> ConnectorOutcome {
        try enterCommand()
        defer { activeCommands -= 1 }
        let threadId = try Self.nativeId(taskId)
        guard let request = await server.pendingServerRequest(key: requestId) else {
            // 顺手把任务上那条已经没有对端的待审批摘掉，免得手机上一直挂着一颗按不动的按钮。
            await forgetPendingRequest(threadId: threadId, key: requestId)
            throw ConnectorError("审批请求 \(requestId) 已失效：所属轮次已经结束，或者它已经被回答过了")
        }
        if let owner = request.threadId, owner != threadId {
            throw ConnectorError("审批请求 \(requestId) 属于另一个 Codex 线程，不是 \(taskId)")
        }
        let mapped = CodexApprovalDecision(decision)
        let payload: JSONValue
        if request.kind == .userInput, decision == .allow, let answered = Self.userInputAnswers(answers ?? [:], for: request) {
            payload = answered
        } else if let result = Self.approvalResult(for: request, decision: mapped) {
            payload = result
        } else {
            throw ConnectorError("不认识的审批请求 \(request.method)")
        }

        await claim(threadId)
        try await server.respond(to: requestId, result: payload)
        Self.log.info("回答审批 \(request.method, privacy: .public) \(requestId, privacy: .public) → \(mapped.rawValue, privacy: .public)")
        mutate(threadId) {
            if $0.pendingKey == requestId {
                $0.pendingKey = nil
                $0.pendingRequest = nil
            }
            if $0.status == .waitingApproval || $0.status == .waitingInput { $0.status = .running }
        }
        await publish(threadId)
        return ConnectorOutcome(taskId: Self.protocolId(threadId), retainsLiveOwnership: true)
    }

    /// `turn/interrupt {threadId, turnId}`。轮次 id 来自最近一条 `turn/started`——
    /// 协议要求必填，不知道就明确失败，而不是发一条注定被 app-server 拒掉的请求。
    public func interrupt(taskId: String) async throws -> ConnectorOutcome {
        try enterCommand()
        defer { activeCommands -= 1 }
        let threadId = try Self.nativeId(taskId)
        guard let turnId = threads[threadId]?.currentTurnId, !turnId.isEmpty else {
            throw ConnectorError("Codex 线程 \(threadId) 上没有本机在驱动的轮次，无法中断")
        }
        await claim(threadId)
        _ = try await server.request("turn/interrupt",
                                     params: ["threadId": .string(threadId), "turnId": .string(turnId)])
        // 中断只是发出去了：状态要等 turn/completed(interrupted) 才落地，所有权也留到那时再还。
        return ConnectorOutcome(taskId: Self.protocolId(threadId), retainsLiveOwnership: true)
    }

    public func deleteTask(taskId: String) async throws {
        let threadId = try Self.nativeId(taskId)
        try enterCommand()
        defer { activeCommands -= 1 }
        if let thread = threads[threadId], thread.currentTurnId != nil {
            throw ConnectorError("会话还在进行中，等它停下来再删除")
        }
        // 使用上游的删除事务，绝不写 Codex 数据库。老版本不支持时原样回失败。
        _ = try await server.request("thread/delete", params: ["threadId": .string(threadId)])
        threads.removeValue(forKey: threadId)
        order.removeAll { $0 == threadId }
    }

    /// 协议 3.4：合并并结束后把线程归档（`thread/archive {threadId}`），Codex 自己的列表里也不再显示。
    /// 尽力而为：桌面正在接管、app-server 不认这个方法都只记日志，会话早已由 `TaskStore.hide` 藏起来。
    public func discard(taskId: String) async {
        guard let threadId = try? Self.nativeId(taskId) else { return }
        do {
            try enterCommand()
        } catch {
            Self.log.info("桌面正在接管，跳过 thread/archive")
            return
        }
        defer { activeCommands -= 1 }
        do {
            _ = try await server.request("thread/archive", params: ["threadId": .string(threadId)])
        } catch {
            Self.log.error("thread/archive 失败：\(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - 事件

    private func handle(_ event: CodexAppServerEvent) async {
        switch event {
        case .started(let generation):
            // 新一代子进程里什么线程都没加载；下一条命令会自己发现代数变了并重新 resume。
            Self.log.info("app-server 第 \(generation, privacy: .public) 代起来了")
            updateStatus {
                $0.phase = .starting
                $0.generation = generation
                $0.detail = nil
            }
        case .ready(let generation):
            updateStatus {
                $0.phase = .ready
                $0.generation = generation
                $0.detail = nil
            }
            // 不在事件循环里等应答：`model/list` 慢一点不该挡住后面的通知。
            Task { [weak self] in await self?.refreshModels() }
        case .notification(let notification):
            await apply(notification)
        case .serverRequest(let request):
            await apply(request)
        case .exited(let exit, let restartingIn):
            await handleProcessExit()
            updateStatus {
                // `restartingIn == nil` 只会出现在"已经 stop() 了"的路径上，那边自己会收尾。
                $0.phase = restartingIn.map { Status.Phase.restarting(after: $0) } ?? .stopped
                $0.detail = Self.exitDetail(exit)
            }
        case .resumingAfterRestart(let threadIds):
            Self.log.info("app-server 重启后正在 resume \(threadIds.count, privacy: .public) 个线程")
        }
    }

    /// 只在值真的变了时才通知观察者：菜单栏没必要为每一条通知重画一次。
    private func updateStatus(_ body: (inout Status) -> Void) {
        var next = status
        body(&next)
        next.liveTaskCount = order.reduce(into: 0) { $0 += (threads[$1]?.owned == true ? 1 : 0) }
        guard next != status else { return }
        status = next
        statusObserver(next)
    }

    /// 退出原因给界面用的一小段。**不进日志**：stderr 末尾可能带用户的内容。
    private static func exitDetail(_ exit: CodexProcessExit) -> String? {
        guard let reason = nonEmpty(exit.reason) else {
            return exit.status == 0 ? nil : "退出码 \(exit.status)"
        }
        return clampLine(reason, limit: Status.detailLimit)
    }

    private func apply(_ notification: CodexNotification) async {
        if case .other(let method, let params) = notification, method == "thread/deleted",
           let id = params["threadId"]?.stringValue {
            threads.removeValue(forKey: id)
            order.removeAll { $0 == id }
            dropStream(id)
            await store.hide(id: Self.protocolId(id))
            return
        }
        guard let threadId = notification.threadId else { return }
        guard !ignoredDesktopThreads.contains(threadId) else { return }
        if threads[threadId] == nil, sharedDesktop {
            // Desktop turns on the shared upstream are also actionable on the phone.
            let seed: JSONValue?
            if case .threadStarted(_, let thread) = notification {
                seed = ["thread": thread, "cwd": thread["cwd"] ?? .string("")]
            } else {
                // A phone can attach halfway through a desktop turn. In that case the
                // thread/started event predates this Agent, so read its metadata once.
                seed = nil
            }
            guard await adoptDesktop(threadId: threadId, seed: seed) else { return }
        }
        guard threads[threadId] != nil else { return }
        // 节流攒下的文本先写进去，再处理别的通知：顺序不乱，后面的 item/completed 照样能盖掉它。
        if case .agentMessageDelta = notification {} else { settleStream(threadId) }

        switch notification {
        case .turnStarted(_, let turnId):
            if sharedDesktop, threads[threadId]?.origin == .desktop,
               let response = try? await server.request("thread/read", params: [
                   "threadId": .string(threadId), "includeTurns": .bool(false),
               ]) {
                // 桌面端可以在同一线程的两轮之间换模型；实时所有权期间观察者不能覆盖任务。
                applyModel(from: response, to: threadId)
            }
            mutate(threadId) {
                $0.currentTurnId = turnId.isEmpty ? nil : turnId
                $0.hasFinalAnswer = false
                // 上一轮的失败原因不带进这一轮：这一轮若因 systemError 失败，不能还说额度用完。
                $0.diagnosis = nil
            }
            await claim(threadId)
        case .turnCompleted(_, let turnId, _, _, _):
            messageBuffers.removeValue(forKey: threadId)
            dropStream(threadId)
            mutate(threadId) {
                if turnId.isEmpty || $0.currentTurnId == turnId { $0.currentTurnId = nil }
                // 往保守的方向收：任何一轮结束都不再算手机的轮次，下一轮要由手机重新起。
                $0.phoneTurn = false
                // 这一轮挂着的审批已经被 CodexAppServer 丢掉了，任务上也不能再留着。
                $0.pendingKey = nil
                $0.pendingRequest = nil
            }
        case .agentMessageDelta(_, let itemId, let delta):
            accumulate(threadId: threadId, itemId: itemId, delta: delta)
        case .itemStarted(_, _, let item):
            if item.type == "agentMessage" { messageBuffers[threadId]?.removeValue(forKey: item.id) }
        case .itemCompleted(_, _, let item):
            complete(threadId: threadId, item: item)
        case .other(let method, let params) where method == "serverRequest/resolved":
            let id: String?
            if let number = params["requestId"]?.intValue { id = CodexRequestID.number(number).key }
            else if let text = params["requestId"]?.stringValue { id = CodexRequestID.text(text).key }
            else { id = nil }
            if let id { await forgetPendingRequest(threadId: threadId, key: id) }
        case .threadStarted, .threadStatusChanged, .serverError, .other:
            break
        }

        if let transition = notification.statusTransition {
            mutate(threadId) { $0.status = transition }
        }
        // 失败时把错误当作最后一条消息：TaskStore 的 TASK_FAILED 通知正文取的就是 lastMessage。
        if case .turnCompleted(_, _, let status, let error, let errorInfo) = notification {
            mutate(threadId) {
                $0.diagnosis = status == .failed ? Self.diagnosis(errorInfo: errorInfo) : nil
                if status == .failed, let error, !error.isEmpty {
                    $0.lastMessage = CodexThreadReader.truncate(error, limit: Self.messageLimit)
                }
            }
        }

        await publish(threadId)
        if case .turnCompleted = notification {
            // 轮次结束 = 本连接器不再实时驱动它，交还给 CodexObserver。
            await release(threadId)
        }
    }

    private func apply(_ request: CodexServerRequest) async {
        guard let kind = request.kind.pendingRequestKind else {
            if !sharedDesktop { await autoAnswer(request) }
            return
        }
        if sharedDesktop, let threadId = request.threadId, threads[threadId] == nil {
            guard await adoptDesktop(threadId: threadId) else { return }
        }
        // 取元数据期间桌面可能已经回答，或轮次已经结束；不能再补发一条过期审批。
        if sharedDesktop, await server.pendingServerRequest(key: request.key) == nil { return }
        guard let threadId = request.threadId, threads[threadId] != nil else {
            if sharedDesktop { return }
            // 没有任务可挂 = 没人能回答它。不能放着不管（codex 会一直等），只能按最保守的方向拒掉。
            Self.log.error("收到不属于任何实时任务的审批请求 \(request.method, privacy: .public)，按拒绝处理")
            await autoAnswer(request)
            return
        }
        if kind != .input, await autoApprove(request, threadId: threadId) { return }
        let pending = Self.pendingRequest(from: request, kind: kind)
        if sharedDesktop { await claim(threadId) }
        mutate(threadId) {
            $0.pendingKey = request.key
            $0.pendingRequest = pending
            $0.status = kind == .input ? .waitingInput : .waitingApproval
        }
        Self.log.info("挂起审批 \(request.method, privacy: .public) \(request.key, privacy: .public) kind=\(kind.rawValue, privacy: .public)")
        // upsert 之后 TaskStore 自己按状态跃迁产出 TASK_APPROVAL / TASK_INPUT。
        await publish(threadId)
    }

    /// 协议 3.3：手机驱动的轮次里、项目开着自动批准时，审批（不含 `requestUserInput`）直接按「只这一次允许」回掉，
    /// 不挂 pendingRequest。返回 true = 已经回了。
    ///
    /// 「手机驱动」：不共用桌面时，BotBus 自己的 app-server 里只跑手机起的轮次（含重启后自动 resume 的），都算；
    /// 共用桌面时只算 `phoneTurn` 标着的那一轮，桌面自己的轮次照旧交给人。
    private func autoApprove(_ request: CodexServerRequest, threadId: String) async -> Bool {
        guard !sharedDesktop || threads[threadId]?.phoneTurn == true,
              await store.autoApproves(taskId: Self.protocolId(threadId),
                                       workingDirectory: threads[threadId]?.projectPath),
              let result = Self.approvalResult(for: request, decision: .accept) else { return false }
        do {
            try await server.respond(to: request.key, result: result)
            Self.log.info("项目已开自动批准，放行 \(request.method, privacy: .public) \(request.key, privacy: .public)")
        } catch {
            // 回不出去多半是这一轮已经没了（进程退出、轮次结束），挂成卡片也没人能答，只记日志。
            Self.log.error("自动批准 \(request.key, privacy: .public) 失败：\(Self.describe(error), privacy: .public)")
        }
        return true
    }

    /// 子进程没了：这一轮的服务端请求全没了，线程也不在任何一代进程里加载着。
    ///
    /// **不碰 `markControlled`**：`CodexAppServer` 刚刚把"由本机控制且还在跑"的线程记进了重启后的
    /// resume 名单，这里 `releaseControl` 会把那份名单抹掉。状态也不乱改——只读观察从 SQLite 读到的
    /// 才是真相，交还给它就行。
    private func handleProcessExit() async {
        messageBuffers.removeAll()
        dropAllStreams()
        for threadId in order {
            mutate(threadId) {
                $0.pendingKey = nil
                $0.pendingRequest = nil
                $0.currentTurnId = nil
                $0.loadedGeneration = nil
                $0.phoneTurn = false
            }
            await release(threadId, relinquishControl: false)
        }
    }

    // MARK: - 非审批的服务端请求

    /// 不属于四类审批的服务端请求怎么答。**必须答**：不答 codex 就在那条请求上一直等，线程挂死。
    ///
    /// 分两档：
    /// - 协议里本来就有"拒绝"这个取值的（MCP elicitation 的 `action: "decline"`），用协议自己的拒绝，
    ///   对端能当成"用户不同意"正常收尾，而不是当成传输故障。
    /// - 其余的一律回 JSON-RPC 错误。`item/tool/call` 要我们执行一个客户端工具，
    ///   `account/chatgptAuthTokens/refresh` 要我们交出 ChatGPT 访问令牌，`attestation/generate`
    ///   要我们签一份客户端证明——这三样本 Agent 都没有，也**故意不去读** `~/.codex/auth.json`。
    ///   编一个假的比直说不支持危险得多，所以直说。认不得的新方法同理。
    private func autoAnswer(_ request: CodexServerRequest) async {
        do {
            if let refusal = Self.refusalResult(for: request) {
                try await server.respond(to: request.key, result: refusal)
            } else {
                try await server.respond(to: request.key, errorCode: Self.unsupportedRequestCode,
                                         message: "BotBus 不实现 \(request.method)")
            }
            Self.log.info("拒绝服务端请求 \(request.method, privacy: .public) \(request.key, privacy: .public)")
        } catch {
            Self.log.error("回复服务端请求 \(request.key, privacy: .public) 失败：\(Self.describe(error), privacy: .public)")
        }
    }

    /// 能用"协议内的拒绝值"答复的请求。答不上来的返回 nil，由调用方回 JSON-RPC 错误。
    static func refusalResult(for request: CodexServerRequest) -> JSONValue? {
        if let payload = approvalResult(for: request, decision: .decline) { return payload }
        switch request.method {
        case "mcpServer/elicitation/request":
            // McpServerElicitationRequestResponse{action, content, _meta}
            return ["action": .string("decline"), "content": .null, "_meta": .null]
        default:
            return nil
        }
    }

    // MARK: - 审批响应的编码

    /// 按请求种类编出 app-server 期待的响应结构。不是审批的返回 nil。
    static func approvalResult(for request: CodexServerRequest,
                               decision: CodexApprovalDecision) -> JSONValue? {
        switch request.kind {
        case .commandExecution, .fileChange:
            // CommandExecutionRequestApprovalResponse / FileChangeRequestApprovalResponse{decision}
            return ["decision": .string(decision.rawValue)]
        case .permissions:
            // PermissionsRequestApprovalResponse{permissions, scope}：没有 decision 字段，
            // "拒绝"就是一项都不授。同意则把请求里要的那些原样授出去。
            let granted = decision.grantsPermission
                ? grantedPermissions(from: request.params["permissions"])
                : JSONValue.object([:])
            return ["permissions": granted, "scope": .string(decision.permissionScope)]
        case .userInput:
            // ToolRequestUserInputResponse{answers}：同样没有"同意/拒绝"。approve 命令里没有文本通道，
            // 只能回一份空答案把轮次放行；真正的回答走 followUp（见 answerUserInput）。
            return ["answers": .object([:])]
        case .other:
            return nil
        }
    }

    /// 手机点选的答案 → `ToolRequestUserInputResponse{answers: {id: {answers: [...]}}}`。
    /// 只收请求里真有的问题 id 与非空答案；一个都对不上返回 nil（调用方回落成空答案）。
    static func userInputAnswers(_ answers: [String: [String]], for request: CodexServerRequest) -> JSONValue? {
        let ids = Set((request.params["questions"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue })
        var result: [String: JSONValue] = [:]
        for (id, values) in answers where ids.contains(id) {
            let picked = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard !picked.isEmpty else { continue }
            result[id] = ["answers": .array(picked.map { .string($0) })]
        }
        return result.isEmpty ? nil : ["answers": .object(result)]
    }

    /// `RequestPermissionProfile` → `GrantedPermissionProfile`：把非空的那几项原样授出去。
    static func grantedPermissions(from requested: JSONValue?) -> JSONValue {
        var granted: [String: JSONValue] = [:]
        for key in ["network", "fileSystem"] {
            guard let value = requested?[key], !value.isNull else { continue }
            granted[key] = value
        }
        return .object(granted)
    }

    /// 这个线程上挂着的、还活着的 `item/tool/requestUserInput`。
    private func pendingUserInput(threadId: String) async -> CodexServerRequest? {
        guard let key = threads[threadId]?.pendingKey,
              let request = await server.pendingServerRequest(key: key),
              request.kind == .userInput else { return nil }
        return request
    }

    /// 把续聊的文本当成每个问题的答案回过去。没有可回答的问题时返回 false（调用方照常开新轮次）。
    private func answerUserInput(_ request: CodexServerRequest, text: String) async throws -> Bool {
        let ids = (request.params["questions"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue }
        guard !ids.isEmpty else {
            // 一个问题都解不出来：先把请求放行，别让轮次挂着。
            try? await server.respond(to: request.key, result: ["answers": .object([:])])
            return false
        }
        var answers: [String: JSONValue] = [:]
        for id in ids { answers[id] = ["answers": .array([.string(text)])] }
        try await server.respond(to: request.key, result: ["answers": .object(answers)])
        Self.log.info("用 followUp 回答了 \(ids.count, privacy: .public) 个问题 \(request.key, privacy: .public)")
        return true
    }

    // MARK: - PendingRequest 的构造

    /// 把服务端请求翻成协议里的 `PendingRequest`。**只挑要给用户看的**，原始 params 不外泄。
    ///
    /// 电脑写的话（「执行命令：…」「工作目录：…」）先建成短语（协议 3.11），中文的 `summary` / `detail` 由短语拼出来；
    /// agent 的原话（理由、提问）原样放，摘要是原话时不带 `summaryPhrase`，详情里没有电脑写的话时不带 `detailPhrases`。
    static func pendingRequest(from request: CodexServerRequest, kind: PendingRequest.Kind) -> PendingRequest {
        let reason = nonEmpty(request.params["reason"]?.stringValue)
        switch kind {
        case .command:
            let command = nonEmpty(request.params["command"]?.stringValue).map { clampLine($0, limit: summaryLimit) }
            let summaryPhrase = command.map(RequestPhrase.runCommand) ?? (reason == nil ? .requestCommand : nil)
            let detail = [reason.map { RequestPhrase.text(clampBlock($0, limit: detailLimit)) },
                          nonEmpty(request.params["cwd"]?.stringValue).map(RequestPhrase.workingDirectory)]
                .compactMap { $0 }
            return makeRequest(request, kind: .command, summary: summaryPhrase?.chineseText ?? reason ?? "",
                               summaryPhrase: summaryPhrase, detail: detail)
        case .fileChange:
            let paths = request.fileChanges.map { URL(fileURLWithPath: $0.path).lastPathComponent }
            let summaryPhrase = paths.isEmpty ? (reason == nil ? RequestPhrase.requestFileChange : nil) : .editFiles(paths)
            let diffs = request.fileChanges.map { "--- \($0.path) (\($0.kind))\n\($0.diff)" }
                .joined(separator: "\n")
            return PendingRequest(id: request.key, kind: .fileChange,
                                  summary: clampLine(summaryPhrase?.chineseText ?? reason ?? "", limit: summaryLimit),
                                  detail: nonEmpty(diffs).map { clampBlock($0, limit: detailLimit) } ?? reason,
                                  summaryPhrase: summaryPhrase)
        case .permission:
            let summaryPhrase = reason == nil ? RequestPhrase.requestExtraPermissions : nil
            return makeRequest(request, kind: .permission, summary: summaryPhrase?.chineseText ?? reason ?? "",
                               summaryPhrase: summaryPhrase, detail: permissionPhrases(request.params["permissions"]))
        case .input:
            let questions = request.params["questions"]?.arrayValue ?? []
            let first = questions.first
            let question = nonEmpty(first?["question"]?.stringValue)
            let header = nonEmpty(first?["header"]?.stringValue)
            let options = (first?["options"]?.arrayValue ?? [])
                .compactMap { $0["label"]?.stringValue }
            let summaryPhrase = (header ?? question) == nil ? RequestPhrase.awaitingAnswer(agent: "Codex") : nil
            var detail: [RequestPhrase] = []
            if !options.isEmpty { detail.append(.options(options)) }
            if questions.count > 1 { detail.append(.moreQuestions(questions.count - 1)) }
            var pending = makeRequest(request, kind: .input, summary: header ?? question ?? summaryPhrase?.chineseText ?? "",
                                      summaryPhrase: summaryPhrase, detail: detail)
            pending.question = question.map { clampBlock($0, limit: detailLimit) }
            pending.questions = pendingQuestions(questions)
            return pending
        }
    }

    /// 摘要截成一行；详情由短语拼出中文，详情里只有 agent 原话（`text`）时不带短语——原文就是它。
    private static func makeRequest(_ request: CodexServerRequest, kind: PendingRequest.Kind, summary: String,
                                    summaryPhrase: RequestPhrase?, detail: [RequestPhrase]) -> PendingRequest {
        let localizable = detail.contains { $0.kind != .text }
        return PendingRequest(id: request.key, kind: kind,
                              summary: clampLine(summary, limit: summaryLimit),
                              detail: detail.isEmpty ? nil : clampBlock(detail.chineseText, limit: detailLimit),
                              summaryPhrase: summaryPhrase,
                              detailPhrases: localizable ? detail : nil)
    }

    /// `requestUserInput` 的问题 → 协议 2.14 的 `questions`，好让手机点选。Codex 的问题没有多选；
    /// 没有 id 或没有问题文字的跳过（回答要按 id 对上）。一个都不剩返回 nil。
    static func pendingQuestions(_ questions: [JSONValue]) -> [PendingQuestion]? {
        let mapped = questions.prefix(PendingQuestion.maxQuestions).compactMap { item -> PendingQuestion? in
            guard let id = nonEmpty(item["id"]?.stringValue),
                  let question = nonEmpty(item["question"]?.stringValue) ?? nonEmpty(item["header"]?.stringValue)
            else { return nil }
            let options = (item["options"]?.arrayValue ?? []).prefix(PendingQuestion.maxOptions).compactMap { option -> PendingOption? in
                guard let label = nonEmpty(option["label"]?.stringValue) else { return nil }
                return PendingOption(label: label, description: nonEmpty(option["description"]?.stringValue))
            }
            return PendingQuestion(id: id, question: clampBlock(question, limit: detailLimit),
                                   header: nonEmpty(item["header"]?.stringValue), options: Array(options))
        }
        return mapped.isEmpty ? nil : mapped
    }

    /// `RequestPermissionProfile` 的一句人话。只读字段名与路径，不带任何会话内容。
    static func permissionPhrases(_ value: JSONValue?) -> [RequestPhrase] {
        var phrases: [RequestPhrase] = []
        if let network = value?["network"], !network.isNull {
            phrases.append(network["enabled"]?.boolValue == true ? .networkAccess : .networkPolicy)
        }
        if let fileSystem = value?["fileSystem"], !fileSystem.isNull {
            for (phrase, key) in [(RequestPhrase.readPaths, "read"), (RequestPhrase.writePaths, "write")] {
                let paths = (fileSystem[key]?.arrayValue ?? []).compactMap { $0.stringValue }
                guard !paths.isEmpty else { continue }
                phrases.append(phrase(paths))
            }
        }
        return phrases
    }

    // MARK: - agent 消息的累积

    private func accumulate(threadId: String, itemId: String, delta: String) {
        guard threads[threadId]?.hasFinalAnswer != true else { return }
        var buffers = messageBuffers[threadId] ?? [:]
        var text = buffers[itemId] ?? ""
        // 只显示前 messageLimit 个字符，攒过头没有意义，还会让长回答把内存吃掉。
        guard text.count < Self.messageLimit else { return }
        text += delta
        buffers[itemId] = text
        messageBuffers[threadId] = buffers
        let truncated = CodexThreadReader.truncate(text, limit: Self.messageLimit)
        let current = now()
        if let written = streamWrittenAt[threadId], current.timeIntervalSince(written) < streamInterval {
            pendingStreamText[threadId] = truncated
            scheduleStreamFlush(threadId, after: streamInterval - current.timeIntervalSince(written))
            return
        }
        streamWrittenAt[threadId] = current
        mutate(threadId) { $0.lastMessage = truncated }
    }

    private func scheduleStreamFlush(_ threadId: String, after delay: TimeInterval) {
        guard streamFlushes[threadId] == nil else { return }
        streamFlushes[threadId] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, delay)))
            guard !Task.isCancelled else { return }
            await self?.flushStream(threadId)
        }
    }

    /// 间隔到点：把攒下的文本写进记录并发出去。这期间没有新的 delta 就什么都不做。
    private func flushStream(_ threadId: String) async {
        streamFlushes[threadId] = nil
        guard applyPendingStream(threadId) else { return }
        await publish(threadId)
    }

    /// 别的通知到了：取消定时补写，攒下的文本直接写进记录（随这条通知一起发出去）。
    private func settleStream(_ threadId: String) {
        streamFlushes.removeValue(forKey: threadId)?.cancel()
        _ = applyPendingStream(threadId)
    }

    private func applyPendingStream(_ threadId: String) -> Bool {
        guard let text = pendingStreamText.removeValue(forKey: threadId),
              threads[threadId]?.hasFinalAnswer != true else { return false }
        streamWrittenAt[threadId] = now()
        mutate(threadId) { $0.lastMessage = text }
        return true
    }

    private func dropStream(_ threadId: String) {
        streamFlushes.removeValue(forKey: threadId)?.cancel()
        pendingStreamText.removeValue(forKey: threadId)
        streamWrittenAt.removeValue(forKey: threadId)
    }

    private func dropAllStreams() {
        for flush in streamFlushes.values { flush.cancel() }
        streamFlushes.removeAll()
        pendingStreamText.removeAll()
        streamWrittenAt.removeAll()
    }

    private func complete(threadId: String, item: CodexItem) {
        guard item.type == "agentMessage" else { return }
        messageBuffers[threadId]?.removeValue(forKey: item.id)
        guard let text = item.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let isFinal = item.raw["phase"]?.stringValue == "final_answer"
        guard isFinal || threads[threadId]?.hasFinalAnswer != true else { return }
        mutate(threadId) {
            $0.lastMessage = CodexThreadReader.truncate(text, limit: Self.messageLimit)
            if isFinal { $0.hasFinalAnswer = true }
        }
    }

    // MARK: - 线程账本

    private func register(threadId: String, projectPath: String, title: String, origin: TaskOrigin) {
        let current = now()
        if threads[threadId] == nil { order.append(threadId) }
        let existing = threads[threadId]
        threads[threadId] = LiveThread(
            threadId: threadId,
            projectPath: projectPath,
            projectName: URL(fileURLWithPath: projectPath).lastPathComponent,
            title: title,
            status: existing?.status ?? .running,
            lastMessage: existing?.lastMessage,
            pendingRequest: existing?.pendingRequest,
            origin: existing?.origin ?? origin,
            startedAt: existing?.startedAt ?? current,
            updatedAt: current,
            pendingKey: existing?.pendingKey,
            currentTurnId: existing?.currentTurnId,
            loadedGeneration: existing?.loadedGeneration,
            owned: existing?.owned ?? false,
            hasFinalAnswer: existing?.hasFinalAnswer ?? false,
            model: existing?.model,
            effort: existing?.effort,
            phoneTurn: existing?.phoneTurn ?? false)
        evictIfNeeded(keeping: threadId)
    }

    /// 接管一个还没在本连接器里建账的线程（多半来自只读观察看到的桌面线程）。
    /// 已有的 `TaskRecord` 是最好的种子：标题、项目、最后一条消息都别丢。
    private func adopt(threadId: String, resumeResponse: JSONValue?) async {
        if threads[threadId] != nil {
            if let cwd = resumeResponse?["cwd"]?.stringValue, !cwd.isEmpty {
                mutate(threadId) {
                    $0.projectPath = cwd
                    $0.projectName = URL(fileURLWithPath: cwd).lastPathComponent
                }
            }
            if let resumeResponse { applyModel(from: resumeResponse, to: threadId) }
            return
        }
        let existing = await store.task(id: Self.protocolId(threadId))
        let cwd = nonEmpty(resumeResponse?["cwd"]?.stringValue)
            ?? nonEmpty(resumeResponse?.path("thread", "cwd")?.stringValue)
            ?? existing?.workingDirectory ?? ""
        let preview = nonEmpty(resumeResponse?.path("thread", "preview")?.stringValue)
        let title = existing?.title
            ?? preview.map { CodexThreadReader.truncate(CodexThreadReader.singleLine($0), limit: Self.titleLimit) }
            ?? URL(fileURLWithPath: cwd).lastPathComponent
        register(threadId: threadId, projectPath: cwd, title: title, origin: existing?.origin ?? .desktop)
        mutate(threadId) {
            $0.lastMessage = existing?.lastMessage
            if let existing { $0.startedAt = Self.parse(existing.startedAt) ?? $0.startedAt }
            $0.model = existing?.model
            $0.effort = existing?.effort
        }
        if let resumeResponse { applyModel(from: resumeResponse, to: threadId) }
    }

    /// 与数据库观察保持一致：子代理属于主任务内部，不建手机任务、不推审批或完成通知。
    /// 重连接入可能只有轮次/审批，所以没有 thread/started 时先只读元数据；读取失败留给后续事件重试。
    private func adoptDesktop(threadId: String, seed: JSONValue? = nil) async -> Bool {
        guard !ignoredDesktopThreads.contains(threadId) else { return false }
        let response: JSONValue?
        if let seed {
            response = seed
        } else {
            response = try? await server.request("thread/read", params: [
                "threadId": .string(threadId), "includeTurns": .bool(false),
            ])
        }
        guard let response else { return false }
        if response.path("thread", "source")?["subAgent"] != nil {
            ignoredDesktopThreads.append(threadId)
            if ignoredDesktopThreads.count > Self.maxTrackedThreads { ignoredDesktopThreads.removeFirst() }
            return false
        }
        await adopt(threadId: threadId, resumeResponse: response)
        let generation = await server.processGeneration
        mutate(threadId) { $0.loadedGeneration = generation }
        return true
    }

    /// `thread/start` / `thread/resume` 的应答在顶层带 `model` / `reasoningEffort`；
    /// `thread/read` 和 `thread/started` 则放在 `thread` 里。共享桌面接入时两种形状都要读。
    private func applyModel(from response: JSONValue, to threadId: String) {
        let model = (response["model"] ?? response.path("thread", "model"))?.stringValue
            .flatMap { ModelOption.isValidId($0) ? $0 : nil }
        let rawEffort = response["reasoningEffort"] ?? response.path("thread", "reasoningEffort")
        let effort = rawEffort?.stringValue
            .flatMap { ModelOption.isValidEffort($0) ? $0 : nil }
        mutate(threadId) {
            if let model { $0.model = model }
            if rawEffort != nil { $0.effort = effort }
        }
    }

    // MARK: - 模型（协议 3.2）

    /// 问 app-server 有哪些模型（`model/list`，不含 hidden），写进注册表；变了就补发一份快照。
    /// 每代子进程握手完问一次：换了账号或升级了 Codex，列表会变。失败只记日志，手机上就不出现切换入口。
    func refreshModels() async {
        do {
            let response = try await server.request("model/list", params: ["limit": .int(50)])
            let models = Self.modelOptions(from: response)
            if store.connectors.setModels(models, for: .codex) { _ = await store.broadcastSnapshot() }
        } catch {
            Self.log.error("model/list 失败：\(Self.describe(error), privacy: .public)")
        }
    }

    static func modelOptions(from response: JSONValue) -> [ModelOption] {
        (response["data"]?.arrayValue ?? []).compactMap { model -> ModelOption? in
            guard model["hidden"]?.boolValue != true, let id = model["id"]?.stringValue else { return nil }
            let efforts = (model["supportedReasoningEfforts"]?.arrayValue ?? [])
                .compactMap { $0["reasoningEffort"]?.stringValue }
            return ModelOption(id: id,
                               displayName: model["displayName"]?.stringValue ?? id,
                               efforts: efforts.isEmpty ? nil : efforts,
                               defaultEffort: model["defaultReasoningEffort"]?.stringValue)
        }
    }

    /// 手机选的模型与强度对不对得上 `model/list`；列表还没拿到时放行，让 app-server 自己判。
    /// `threadId` 为 nil 是新建任务：只换强度时按列表里的默认模型（排第一的）查。
    private func validate(_ selection: ModelSelection, threadId: String?) throws {
        guard let models = store.connectors.models(for: .codex) else { return }
        let modelId = selection.model ?? threadId.flatMap { threads[$0]?.model } ?? (threadId == nil ? models.first?.id : nil)
        if let requested = selection.model, !models.contains(where: { $0.id == requested }) {
            throw ConnectorError("Codex 没有「\(requested)」这个模型")
        }
        if let effort = selection.effort, let option = models.first(where: { $0.id == modelId }),
           option.efforts?.contains(effort) != true {
            throw ConnectorError("\(option.displayName) 不支持「\(effort)」这档思考强度")
        }
    }

    /// 只淘汰"已经不由本连接器驱动"的线程：正在跑的不能被挤掉。
    private func evictIfNeeded(keeping threadId: String) {
        while order.count > Self.maxTrackedThreads,
              let victim = order.first(where: { $0 != threadId && threads[$0]?.owned != true }) {
            threads.removeValue(forKey: victim)
            messageBuffers.removeValue(forKey: victim)
            dropStream(victim)
            order.removeAll { $0 == victim }
        }
    }

    /// 改一个线程的实时状态。只有**记录里看得见的字段**变了才动 `updatedAt`——
    /// 否则每次认领所有权都会变成一条 `taskUpdated`。
    private func mutate(_ threadId: String, _ body: (inout LiveThread) -> Void) {
        guard var thread = threads[threadId] else { return }
        let before = Self.record(thread, agentId: "")
        body(&thread)
        if Self.record(thread, agentId: "") != before { thread.updatedAt = now() }
        threads[threadId] = thread
    }

    private func publish(_ threadId: String) async {
        guard let thread = threads[threadId] else { return }
        // claimLive 是幂等的：分发器在命令失败路径上会交还所有权，这里每次都补一手，
        // 轮次还在跑的任务就不会被只读观察半路改写。
        if thread.owned { await store.claimLive(Self.protocolId(threadId)) }
        await store.upsert(Self.record(thread, agentId: ""))
    }

    private func claim(_ threadId: String) async {
        guard threads[threadId] != nil else { return }
        threads[threadId]?.owned = true
        updateStatus { _ in } // 只刷新 liveTaskCount
        await store.claimLive(Self.protocolId(threadId))
    }

    /// 交还所有权。先把最终状态写进 store 再放手：`releaseLive` 要看到任务存在才会给宽限期。
    private func release(_ threadId: String, relinquishControl: Bool = true) async {
        guard threads[threadId]?.owned == true else { return }
        threads[threadId]?.owned = false
        updateStatus { _ in } // 只刷新 liveTaskCount
        await publish(threadId)
        await store.releaseLive(Self.protocolId(threadId))
        if relinquishControl { await server.releaseControl(threadId: threadId) }
    }

    private func forgetPendingRequest(threadId: String, key: String) async {
        guard threads[threadId]?.pendingKey == key else { return }
        mutate(threadId) {
            $0.pendingKey = nil
            $0.pendingRequest = nil
            if $0.status == .waitingApproval || $0.status == .waitingInput { $0.status = .running }
        }
        await publish(threadId)
    }

    // MARK: - 编码与小工具

    /// `thread/start` 的参数。注入时多两个键：`developerInstructions` 与 `config`（见 `AgentToolsInjection.codexConfig()`）。
    static func threadStartParams(cwd: String, injection: AgentToolsInjection?) -> JSONValue {
        .object(withInjection(["cwd": .string(cwd)], injection))
    }

    /// `thread/resume` 的参数，注入规则同 `threadStartParams`。
    static func threadResumeParams(threadId: String, injection: AgentToolsInjection?) -> JSONValue {
        .object(withInjection(["threadId": .string(threadId)], injection))
    }

    private static func withInjection(_ base: [String: JSONValue], _ injection: AgentToolsInjection?) -> [String: JSONValue] {
        guard let injection else { return base }
        var params = base
        params["developerInstructions"] = .string(injection.instructions)
        params["config"] = injection.codexConfig()
        return params
    }

    /// `turn/start` 的参数。`UserInput` 的 text 变体带一个 `text_elements`（UI 用的富文本片段），
    /// 我们没有富文本，给空数组。
    ///
    /// 图用 `localImage {path}`（app-server 自己读文件），排在文字后面；只发图时没有 text 块——
    /// 空字符串的 text 块会在对话里留下一条空消息。
    ///
    /// `selection`（协议 3.2）进 `model` / `effort`：app-server 把它们记在线程上，之后的轮次沿用。
    static func turnStartParams(threadId: String, text: String, images: [URL] = [],
                                selection: ModelSelection = ModelSelection()) -> JSONValue {
        var input: [JSONValue] = []
        if !text.isEmpty {
            input.append(["type": .string("text"), "text": .string(text), "text_elements": .array([])])
        }
        input += images.map { ["type": .string("localImage"), "path": .string($0.path)] }
        var params: [String: JSONValue] = [
            "threadId": .string(threadId),
            "input": .array(input),
        ]
        if let model = selection.model { params["model"] = .string(model) }
        if let effort = selection.effort { params["effort"] = .string(effort) }
        return .object(params)
    }

    private static func record(_ thread: LiveThread, agentId: String) -> TaskRecord {
        TaskRecord(id: protocolId(thread.threadId), agentId: agentId, source: .codex,
                   title: thread.title, projectPath: thread.projectPath, projectName: thread.projectName,
                   status: thread.status, lastMessage: thread.lastMessage,
                   pendingRequest: thread.pendingRequest, origin: thread.origin,
                   // 由本连接器实时驱动 = 四条命令都真的能执行。
                   controllable: true,
                   startedAt: ProtocolJSON.timestamp(thread.startedAt),
                   updatedAt: ProtocolJSON.timestamp(thread.updatedAt),
                   model: thread.model, effort: thread.effort,
                   diagnosis: thread.status == .failed ? thread.diagnosis : nil)
    }

    /// Codex 的 `codexErrorInfo` → 协议 3.7 的诊断。`unauthorized` 是 token 不被认（没登录或已失效，手机上都让人重新 `codex login`）。
    static func diagnosis(errorInfo: String?) -> FailureDiagnosis? {
        switch errorInfo {
        case "unauthorized": return .signInExpired
        case "usageLimitExceeded", "rateLimitExceeded": return .usageLimit()
        default: return nil
        }
    }

    /// 和桌面版共用时 app-server 是桌面版起的，BotBus 的文件夹授权说明不了它（`TaskConnector.runsUnderBotBus`）。
    public nonisolated var runsUnderBotBus: Bool { !sharedDesktop }

    static func protocolId(_ threadId: String) -> String { "\(ConnectorKind.codex.rawValue):\(threadId)" }

    /// 从协议 id 取回原生 threadId。分发器给的一定带前缀，手工调用时不带也认。
    static func nativeId(_ taskId: String) throws -> String {
        let prefix = "\(ConnectorKind.codex.rawValue):"
        let native = taskId.hasPrefix(prefix) ? String(taskId.dropFirst(prefix.count)) : taskId
        guard !native.isEmpty, !native.contains(":") else {
            throw ConnectorError("不是 Codex 的任务 id：\(taskId)")
        }
        return native
    }

    private static func parse(_ timestamp: String) -> Date? {
        try? Date(timestamp, strategy: .iso8601)
    }

    /// 摘要必须单行：换行与连续空白压成一个空格，再截断。
    private static func clampLine(_ text: String, limit: Int) -> String {
        CodexThreadReader.truncate(CodexThreadReader.singleLine(text), limit: limit)
    }

    /// 详情保留换行——补丁压成一行就没法看了——只截断。
    private static func clampBlock(_ text: String, limit: Int) -> String {
        CodexThreadReader.truncate(text, limit: limit)
    }

    private static func describe(_ error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty { return localized }
        return String(describing: error)
    }
}

/// 空字符串一律当成"没有"。审批摘要里最怕的就是一行空白。
private func nonEmpty(_ text: String?) -> String? {
    guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return text
}
