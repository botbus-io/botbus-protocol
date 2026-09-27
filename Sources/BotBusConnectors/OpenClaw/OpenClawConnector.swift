import Foundation
import os
import BotBusProtocol
import BotBusConnectorKit

/// OpenClaw 连接器：一条 Gateway WebSocket 既负责"看见"也负责"动手"。
///
/// - **看见**：连上后 `sessions.subscribe`（顺带取回首屏会话列表）+ `exec.approval.list` 补齐已挂起的审批，
///   之后靠 `sessions.changed`、`chat`、`exec.approval.requested/resolved` 事件实时更新。
/// - **动手**：`sessions.create` + `chat.send` 新建，`chat.send` 续聊，`exec.approval.resolve` 审批，`chat.abort` 中断。
///
/// **所有权一拿就不放**（同 `ClaudeConnector`）：OpenClaw 没有只读观察者——会话在 Gateway 的 SQLite 里，
/// 部分 transcript 行还是 zstd 压缩的，不读文件——本连接器是唯一权威，所有会话都 `claimLive` + `upsert`，
/// 列表里消失的显式 `remove`，项目走 `reconcile(source:tasks:[] …)`（空任务列表只会删 observer 拥有的 id，我们的都是 live）。
///
/// **断线不清任务**：保留最后状态，`controllable` 置 false，经 `onHealth` 报 degraded；
/// 退避（1、2、4……60 秒）重连，每次重读配置（用户可能刚改了 token 或端口）。
public actor OpenClawConnector: TaskConnector {
    public nonisolated var kind: ConnectorKind { .openclaw }

    /// 连接器把运行期健康状况交给 app：app 转给 `ConnectorRegistry.reportRuntime` 并重发快照。
    public typealias HealthHandler = @Sendable (ConnectorInfo.Status, String?) async -> Void
    public typealias Sleeper = @Sendable (TimeInterval) async -> Void

    /// 与分片上限一致：留更多也传不出去。
    static let maxSessions = 200
    static let pendingSummaryLimit = 300

    public struct Timing: Sendable {
        public var initialBackoff: TimeInterval
        public var maxBackoff: TimeInterval
        /// `sessions.changed` 没带行（或是整表失效）时，攒多久再重新拉一次列表。一次改名常常连着几条事件。
        public var refreshDelay: TimeInterval
        public var requestTimeout: TimeInterval
        public var challengeTimeout: TimeInterval
        public var pingInterval: TimeInterval

        public init(initialBackoff: TimeInterval = 1, maxBackoff: TimeInterval = 60, refreshDelay: TimeInterval = 0.5,
                    requestTimeout: TimeInterval = 15, challengeTimeout: TimeInterval = 2, pingInterval: TimeInterval = 30) {
            self.initialBackoff = initialBackoff
            self.maxBackoff = maxBackoff
            self.refreshDelay = refreshDelay
            self.requestTimeout = requestTimeout
            self.challengeTimeout = challengeTimeout
            self.pingInterval = pingInterval
        }
    }

    /// 一个 OpenClaw 会话在本连接器眼里的状态。Task 由它算出来。
    struct Session: Sendable, Equatable {
        var key: String
        var title: String
        var projectPath: String
        /// 运行状态，不含审批——审批单独记在 `approvals`，合成 Task 时再叠上去。
        var runStatus: TaskStatus
        var lastMessage: String?
        var startedAt: Date
        var updatedAt: Date
    }

    struct Approval: Sendable, Equatable {
        var id: String
        var sessionKey: String
        var command: String
        var cwd: String?
        var createdAt: Date
        var expiresAt: Date?
    }

    private static let log = Logger(subsystem: "io.botbus.agent", category: "openclaw")

    private let store: TaskStore
    private let configProvider: @Sendable () -> OpenClawConfig
    private let transport: WebSocketTransport
    private let clientVersion: String
    private let onHealth: HealthHandler
    private let now: @Sendable () -> Date
    private let sleep: Sleeper
    private let timing: Timing

    private var sessions: [String: Session] = [:]
    private var approvals: [String: Approval] = [:]
    /// 我们经 `start` 新建的会话：origin 记 `.watch`。只在内存里，重启后这些会话按桌面会话显示。
    private var ownKeys: Set<String> = []
    /// 上一次推进 store 的任务 id，用来找出"这次没了"的。
    private var published: Set<String> = []
    private var gateway: OpenClawGateway?
    private var loop: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var lastHealth: (status: ConnectorInfo.Status, error: String?)?
    private var address = OpenClawConfig().displayAddress
    private var workspace = OpenClawConfig().workspaceDirectory

    public init(store: TaskStore,
                config: @escaping @Sendable () -> OpenClawConfig = { OpenClawConfig.load() },
                transport: WebSocketTransport = OpenClawWebSocketTransport(),
                clientVersion: String = OpenClawGateway.defaultClientVersion,
                onHealth: @escaping HealthHandler = { _, _ in },
                now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping Sleeper = { seconds in try? await Task.sleep(for: .seconds(seconds)) },
                timing: Timing = Timing()) {
        self.store = store
        self.configProvider = config
        self.transport = transport
        self.clientVersion = clientVersion
        self.onHealth = onHealth
        self.now = now
        self.sleep = sleep
        self.timing = timing
    }

    // MARK: - 生命周期

    /// 开始连 Gateway 并保持连接。幂等。
    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in await self?.runLoop() }
    }

    /// 断开并停止重连。任务留在 store 里但标成不可控——Gateway 还在跑，只是我们不再代管。
    public func stop() {
        loop?.cancel()
        loop = nil
        refreshTask?.cancel()
        refreshTask = nil
        let closing = gateway
        gateway = nil
        Task { [weak self] in
            await closing?.close()
            await self?.publish()
        }
    }

    public var isConnected: Bool { gateway != nil }

    /// 给 `OpenClawMessageReader` 用：复用这条已连上的 Gateway 连接读对话记录，免得每次拉取都重新握手。
    public func chatHistory(sessionKey: String, limit: Int) async throws -> JSONValue {
        let gateway = try connectedGateway()
        return try await gateway.request("chat.history", params: ["sessionKey": .string(sessionKey), "limit": .int(Int64(limit))])
    }

    private func runLoop() async {
        var backoff = timing.initialBackoff
        while !Task.isCancelled {
            let config = configProvider()
            address = config.displayAddress
            workspace = config.workspaceDirectory
            // 落在默认工作区的会话算「不在项目中」（协议 2.6），规则要知道工作区在哪。
            await store.setAgentWorkspace(workspace, for: .openclaw)
            var configuration = OpenClawGateway.Configuration(config: config, clientVersion: clientVersion)
            configuration.requestTimeout = timing.requestTimeout
            configuration.challengeTimeout = timing.challengeTimeout
            configuration.pingInterval = timing.pingInterval
            let gateway = OpenClawGateway(transport: transport, configuration: configuration)

            var failure = "连不上 OpenClaw Gateway（\(address)）"
            do {
                try await gateway.connect()
                guard !Task.isCancelled else { await gateway.close(); return }
                self.gateway = gateway
                try await bootstrap(gateway)
                await report(.ok, nil)
                backoff = timing.initialBackoff
                // 首屏是基线：7 天内的完成 / 失败会话都在里面，逐条推送等于把一串私聊预览一次性发到手机上。
                await publish(silently: true)
                // 握手与首屏期间到达的事件都攒在流里，这里按序补上，再接着实时消费。
                for await event in gateway.events {
                    if Task.isCancelled { break }
                    guard case .event(let name, let payload) = event else { break }
                    await handle(event: name, payload: payload)
                }
            } catch let error as OpenClawGatewayError {
                switch error.kind {
                case .rejected, .protocolMismatch: failure = error.message
                case .requestFailed: failure = "OpenClaw Gateway 拒绝了请求：\(error.message)"
                default: break
                }
                Self.log.error("OpenClaw Gateway 连接失败：\(error.message, privacy: .public)")
            } catch {
                Self.log.error("OpenClaw Gateway 连接失败：\(String(describing: error), privacy: .public)")
            }
            await gateway.close()
            if self.gateway === gateway { self.gateway = nil }
            if Task.isCancelled { return }
            await report(.degraded, failure)
            await publish(silently: true)
            await sleep(backoff)
            backoff = min(backoff * 2, timing.maxBackoff)
        }
    }

    /// 首屏：订阅会话变化并取回列表，再补齐挂起的审批。
    private func bootstrap(_ gateway: OpenClawGateway) async throws {
        var list: JSONValue?
        do {
            // 新版 Gateway 支持"订阅 + 首屏"一次完成，应答是 `{subscribed:true, list}`。
            list = try await gateway.request("sessions.subscribe", params: Self.listParams)["list"]
        } catch let error as OpenClawGatewayError where error.kind == .requestFailed {
            // 老一点的只认空参数的订阅（`ConnectParams` 之类都是闭合对象，多给键就拒）。
            _ = try await gateway.request("sessions.subscribe", params: [:])
        }
        if list == nil || list == .null {
            list = try await gateway.request("sessions.list", params: Self.listParams)
        }
        applyList(list ?? .null)

        do {
            let pending = try await gateway.request("exec.approval.list", params: [:])
            approvals = [:]
            for entry in Self.array(pending, key: "approvals") {
                if let approval = Self.approval(from: entry, now: now()) { approvals[approval.id] = approval }
            }
        } catch let error as OpenClawGatewayError where error.kind == .requestFailed {
            // 没拿到 `operator.approvals` 之类：只是看不到审批，会话照样能看能发。
            Self.log.error("exec.approval.list 失败：\(error.message, privacy: .public)")
        }
    }

    static let listParams: JSONValue = ["limit": .int(Int64(maxSessions)), "includeLastMessage": true, "includeDerivedTitles": true]

    private func report(_ status: ConnectorInfo.Status, _ error: String?) async {
        if let lastHealth, lastHealth.status == status, lastHealth.error == error { return }
        lastHealth = (status, error)
        await onHealth(status, error)
    }

    /// 把最近一次健康状态再报一遍。`ConnectorRegistry.refresh()` 会把运行期状态重置回探测结果，
    /// 而 `report` 按自己记的上一次去重，不重报的话 Gateway 明明连不上，菜单和手机却一直显示正常。
    public func reannounceHealth() async {
        guard let lastHealth else { return }
        await onHealth(lastHealth.status, lastHealth.error)
    }

    // MARK: - 事件

    private func handle(event name: String, payload: JSONValue?) async {
        switch name {
        case "sessions.changed":
            guard let row = payload?["session"], row.objectValue != nil, let key = row["key"]?.stringValue else {
                // 整表失效、删除通知（只带 key 与旧 sessionId）：都靠重新拉列表收敛。
                scheduleRefresh()
                return
            }
            if let session = parse(row: row) {
                merge(session)
            } else {
                sessions.removeValue(forKey: key)
            }
            await publish()
        case "chat":
            guard let payload, let key = payload["sessionKey"]?.stringValue else { return }
            guard var session = sessions[key] else {
                // 列表里还没有（新会话、或超出 7 天窗口的老会话又动了）：让列表去收敛。
                scheduleRefresh()
                return
            }
            let before = session
            switch payload["state"]?.stringValue {
            case "status", "delta":
                session.runStatus = .running
            case "final":
                session.runStatus = .completed
                if let text = OpenClawTranscript.text(from: payload["message"]) {
                    session.lastMessage = SessionFormatting.truncate(text, SessionFormatting.lastMessageLimit)
                }
            case "aborted":
                session.runStatus = .interrupted
            case "error":
                session.runStatus = .failed
                if let text = payload["errorMessage"]?.stringValue, !text.trimmed.isEmpty {
                    session.lastMessage = SessionFormatting.truncate(text, SessionFormatting.lastMessageLimit)
                }
            default:
                return
            }
            // delta 一秒几十条：状态没变就不碰 updatedAt，store 看到的记录不变也就不发事件。
            guard session != before else { return }
            session.updatedAt = now()
            sessions[key] = session
            await publish()
        case "exec.approval.requested":
            guard let payload, let approval = Self.approval(from: payload, now: now()) else { return }
            approvals[approval.id] = approval
            if sessions[approval.sessionKey] == nil { scheduleRefresh() }
            await publish()
        case "exec.approval.resolved":
            guard let id = payload?["id"]?.stringValue, approvals.removeValue(forKey: id) != nil else { return }
            await publish()
        default:
            return
        }
    }

    private func scheduleRefresh() {
        guard refreshTask == nil else { return }
        let delay = timing.refreshDelay
        refreshTask = Task { [weak self, sleep] in
            await sleep(delay)
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    /// 重新拉一次列表。先清掉 `refreshTask` 再发请求：请求期间来的事件会再排一次，
    /// 不会被这次（可能已经过时的）应答吞掉——文档要求的 trailing refresh。
    private func refresh() async {
        refreshTask = nil
        guard let gateway else { return }
        do {
            let list = try await gateway.request("sessions.list", params: Self.listParams)
            applyList(list)
            await publish()
        } catch {
            Self.log.error("sessions.list 刷新失败：\(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - 会话映射

    /// 用一份完整列表替换会话集合：7 天内、最多 200 条。行里没带最后一条消息（后台补齐前的早期应答）时沿用旧值。
    private func applyList(_ payload: JSONValue) {
        let cutoff = now().addingTimeInterval(-SessionFormatting.recentWindow)
        let parsed = Self.array(payload, key: "sessions")
            .compactMap { parse(row: $0) }
            .filter { $0.updatedAt >= cutoff }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(Self.maxSessions)
        var next: [String: Session] = [:]
        for var session in parsed {
            if session.lastMessage == nil { session.lastMessage = sessions[session.key]?.lastMessage }
            next[session.key] = session
        }
        sessions = next
    }

    private func merge(_ incoming: Session) {
        var session = incoming
        if session.lastMessage == nil { session.lastMessage = sessions[session.key]?.lastMessage }
        sessions[session.key] = session
    }

    /// 一行 `SessionRow`（`schema/sessions-row.ts`，开放对象）。缺 `key` 或已归档的不要。
    func parse(row: JSONValue) -> Session? {
        guard let key = row["key"]?.stringValue, !key.isEmpty else { return nil }
        if row["archived"]?.boolValue == true { return nil }
        let updatedAt = Self.date(row["updatedAt"]) ?? Self.date(row["lastActivityAt"])
            ?? Self.date(row["lastInteractionAt"]) ?? now()
        let startedAt = Self.date(row["createdAt"]) ?? updatedAt
        let title = ["label", "displayName", "derivedTitle", "autoLabel"]
            .lazy.compactMap { row[$0]?.stringValue?.trimmed }.first { !$0.isEmpty } ?? key
        // 会话的工作目录：任务 cwd 优先，其次 spawn 时的目录；都没有就是 agent 的默认工作区。
        let projectPath = ["workspaceDir", "spawnedCwd", "execCwd", "spawnedWorkspaceDir"]
            .lazy.compactMap { row[$0]?.stringValue?.trimmed }.first { !$0.isEmpty } ?? workspace
        let runStatus = Self.runStatus(status: row["status"]?.stringValue, hasActiveRun: row["hasActiveRun"]?.boolValue)
        var lastMessage = row["lastMessagePreview"]?.stringValue
        if runStatus == .failed, let error = row["lastRunError"]?.stringValue, !error.trimmed.isEmpty { lastMessage = error }
        return Session(key: key,
                       title: SessionFormatting.truncate(title, SessionFormatting.titleLimit),
                       projectPath: projectPath,
                       runStatus: runStatus,
                       lastMessage: lastMessage.map { SessionFormatting.truncate($0, SessionFormatting.lastMessageLimit) }
                           .flatMap { $0.isEmpty ? nil : $0 },
                       startedAt: startedAt,
                       updatedAt: updatedAt)
    }

    /// `hasActiveRun` 是"这个会话此刻有没有在跑"的总开关；`status` 是最近一轮的生命周期投影
    /// （`queued|running|done|failed|killed|timeout`）。
    static func runStatus(status: String?, hasActiveRun: Bool?) -> TaskStatus {
        if hasActiveRun == true { return .running }
        switch status {
        case "queued", "running":
            // 说在跑、却明确没有活跃的 run：多半是 Gateway 重启丢了那一轮。
            return hasActiveRun == false ? .interrupted : .running
        case "done": return .completed
        case "failed", "timeout": return .failed
        case "killed": return .interrupted
        default: return .idle
        }
    }

    /// `exec.approval.requested` 的 payload，或 `exec.approval.list` 的一项：`{id, request:{command,cwd,sessionKey,…}, createdAtMs, expiresAtMs}`。
    /// 挂不到会话上的（没有 sessionKey）与已过期的不要。
    static func approval(from payload: JSONValue, now: Date) -> Approval? {
        guard let id = payload["id"]?.stringValue, !id.isEmpty else { return nil }
        let request = payload["request"]?.objectValue != nil ? payload["request"]! : payload
        let plan = request["systemRunPlan"]
        guard let sessionKey = [request["sessionKey"], plan?["sessionKey"], payload["sessionKey"]]
            .lazy.compactMap({ $0?.stringValue }).first(where: { !$0.isEmpty }) else { return nil }
        let argv = request["commandArgv"]?.arrayValue?.compactMap(\.stringValue).joined(separator: " ")
        let command = [request["command"]?.stringValue, plan?["commandText"]?.stringValue, argv]
            .lazy.compactMap { $0?.trimmed }.first { !$0.isEmpty } ?? "执行命令"
        let cwd = [request["cwd"]?.stringValue, plan?["cwd"]?.stringValue].lazy.compactMap { $0 }.first { !$0.isEmpty }
        let expiresAt = date(payload["expiresAtMs"])
        if let expiresAt, expiresAt <= now { return nil }
        return Approval(id: id, sessionKey: sessionKey, command: command, cwd: cwd,
                        createdAt: date(payload["createdAtMs"]) ?? now, expiresAt: expiresAt)
    }

    // MARK: - 推进 store

    private func record(_ session: Session, connected: Bool, at current: Date) -> TaskRecord {
        // 同一会话同时挂多条审批时先给最早的，手机上按到达顺序一条条批。
        let approval = approvals.values
            .filter { $0.sessionKey == session.key && ($0.expiresAt.map { $0 > current } ?? true) }
            .min { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        var status = session.runStatus
        if approval != nil {
            status = .waitingApproval
        } else if status == .completed, current.timeIntervalSince(session.updatedAt) > SessionFormatting.idleAfter {
            status = .idle
        }
        let pending = approval.map {
            PendingRequest(id: $0.id, kind: .command,
                           summary: SessionFormatting.truncate($0.command, Self.pendingSummaryLimit),
                           detail: $0.cwd.map { SessionFormatting.truncate("目录：\($0)", SessionFormatting.detailLimit) },
                           questions: [Self.scopeQuestion])
        }
        return TaskRecord(id: taskId(for: session.key),
                          agentId: "",
                          source: .openclaw,
                          title: session.title,
                          projectPath: session.projectPath,
                          projectName: SessionFormatting.projectName(session.projectPath),
                          status: status,
                          lastMessage: session.lastMessage,
                          pendingRequest: pending,
                          origin: ownKeys.contains(session.key) ? .watch : .desktop,
                          // 能不能发命令只取决于 Gateway 连着没有：chat.send 对在跑的会话是排队 / 插话，不会冲突。
                          controllable: connected,
                          startedAt: ProtocolJSON.timestamp(session.startedAt),
                          updatedAt: ProtocolJSON.timestamp(session.updatedAt))
    }

    /// 把当前会话集合整体推进 store。store 对不变的记录不发事件，所以整表推也不会刷屏。
    /// - Parameter silently: 只写状态不推通知（首屏、断线）。平时也只对**之前发布过**的会话推送：
    ///   第一次出现的会话是新基线，不是一次状态变化。
    func publish(silently: Bool = false) async {
        let current = now()
        let connected = gateway != nil
        let records = sessions.values.map { record($0, connected: connected, at: current) }
        let ids = Set(records.map(\.id))
        // 先把"这次推的是哪些"记下来再 await：推的途中再来一次 publish 时，两边算出的删除集合不会打架。
        let removed = published.subtracting(ids)
        let known = published
        published = ids
        for record in records {
            await store.claimLive(record.id)
            await store.upsert(record, notify: !silently && known.contains(record.id))
        }
        for id in removed { await store.remove(id: id) }
        await store.reconcile(source: .openclaw, tasks: [], projects: SessionFormatting.projects(from: records, agentId: ""))
    }

    // MARK: - TaskConnector

    public func start(projectPath: String, prompt: String, images: [URL]) async throws -> ConnectorOutcome {
        // 协议 2.9 的手机发图本期只接了 Codex 与 Claude；明说不支持，别只发文字让用户以为 agent 看过图。
        guard images.isEmpty else { throw ConnectorError("这个 Agent 暂不支持发图") }
        return try await explained { try await performStart(projectPath: projectPath, prompt: prompt) }
    }

    public func followUp(taskId: String, prompt: String, images: [URL]) async throws -> ConnectorOutcome {
        guard images.isEmpty else { throw ConnectorError("这个 Agent 暂不支持发图") }
        return try await explained { try await performFollowUp(taskId: taskId, prompt: prompt) }
    }

    public func approve(taskId: String, requestId: String,
                        decision: Command.Approve.Decision) async throws -> ConnectorOutcome {
        try await approve(taskId: taskId, requestId: requestId, decision: decision, answers: nil)
    }

    public func approve(taskId: String, requestId: String, decision: Command.Approve.Decision,
                        answers: [String: [String]]?) async throws -> ConnectorOutcome {
        try await explained {
            try await performApprove(taskId: taskId, requestId: requestId,
                                     decision: Self.gatewayDecision(decision, answers: answers))
        }
    }

    /// 审批上的「允许范围」（协议 2.14）。第一个是一次性允许：旧手机不带 `answers`，效果和以前一样。
    static let scopeQuestionId = "scope"
    static let allowOnceLabel = "只这一次"
    static let allowAlwaysLabel = "以后都允许"
    static let scopeQuestion = PendingQuestion(
        id: scopeQuestionId, question: "允许范围",
        options: [PendingOption(label: allowOnceLabel),
                  PendingOption(label: allowAlwaysLabel, description: "记进白名单，同样的命令以后不再问")])

    /// 协议的 allow / deny + 手机选的范围 → `exec.approval.resolve` 的 `decision`。
    /// 「以后都允许」要用户明确选中才给：OpenClaw 会把它写成绑定 argv 与工作目录的白名单条目。
    static func gatewayDecision(_ decision: Command.Approve.Decision, answers: [String: [String]]?) -> String {
        guard decision == .allow else { return "deny" }
        return answers?[scopeQuestionId] == [allowAlwaysLabel] ? "allow-always" : "allow-once"
    }

    public func interrupt(taskId: String) async throws -> ConnectorOutcome {
        try await explained { try await performInterrupt(taskId: taskId) }
    }

    /// Gateway 的 `ok:false` 原文多是英文短句，手机上单看不知道是谁说的，补上来源。
    /// 本机这一侧的错误（没连上、超时、断线）本来就是整句中文，原样放过。
    private func explained(_ body: () async throws -> ConnectorOutcome) async throws -> ConnectorOutcome {
        do {
            return try await body()
        } catch let error as OpenClawGatewayError where error.kind == .requestFailed {
            throw ConnectorError("OpenClaw 拒绝了这个操作：\(error.message)")
        }
    }

    private func performStart(projectPath: String, prompt: String) async throws -> ConnectorOutcome {
        let gateway = try connectedGateway()
        let path = projectPath.trimmed
        var created: JSONValue
        var usedPath = path
        if path.isEmpty {
            created = try await gateway.request("sessions.create", params: [:])
            usedPath = workspace
        } else {
            do {
                created = try await gateway.request("sessions.create", params: ["cwd": .string(path)])
            } catch let error as OpenClawGatewayError where error.kind == .requestFailed {
                // 工作区之外的目录要 `operator.admin`，我们只申请了 read/write/approvals。
                // 退回默认工作区照样能跑，只是不在用户选的目录里。
                Self.log.error("sessions.create 带 cwd 失败，改用默认工作区：\(error.message, privacy: .public)")
                created = try await gateway.request("sessions.create", params: [:])
                usedPath = workspace
            }
        }
        guard let key = created["key"]?.stringValue, !key.isEmpty else {
            throw ConnectorError("OpenClaw 没有返回新会话的 key")
        }
        if let reported = created["entry"]?["workspaceDir"]?.stringValue, !reported.trimmed.isEmpty { usedPath = reported }
        ownKeys.insert(key)
        let timestamp = now()
        let title = SessionFormatting.truncate(prompt, SessionFormatting.titleLimit)
        sessions[key] = Session(key: key,
                                title: title.isEmpty ? SessionFormatting.projectName(usedPath) : title,
                                projectPath: usedPath,
                                runStatus: .running,
                                lastMessage: nil,
                                startedAt: timestamp,
                                updatedAt: timestamp)
        do {
            try await send(prompt, to: key, via: gateway)
        } catch {
            sessions[key]?.runStatus = .idle
            await publish()
            throw error
        }
        await publish()
        return ConnectorOutcome(taskId: taskId(for: key), retainsLiveOwnership: true)
    }

    private func performFollowUp(taskId: String, prompt: String) async throws -> ConnectorOutcome {
        let key = try Self.sessionKey(from: taskId)
        let gateway = try connectedGateway()
        try await send(prompt, to: key, via: gateway)
        if sessions[key] != nil {
            sessions[key]?.runStatus = .running
            sessions[key]?.updatedAt = now()
            await publish()
        } else {
            scheduleRefresh()
        }
        return ConnectorOutcome(taskId: self.taskId(for: key), retainsLiveOwnership: true)
    }

    private func performApprove(taskId: String, requestId: String, decision value: String) async throws -> ConnectorOutcome {
        let key = try Self.sessionKey(from: taskId)
        let gateway = try connectedGateway()
        _ = try await gateway.request("exec.approval.resolve", params: ["id": .string(requestId), "decision": .string(value)])
        approvals.removeValue(forKey: requestId)
        await publish()
        return ConnectorOutcome(taskId: self.taskId(for: key), retainsLiveOwnership: true)
    }

    private func performInterrupt(taskId: String) async throws -> ConnectorOutcome {
        let key = try Self.sessionKey(from: taskId)
        let gateway = try connectedGateway()
        _ = try await gateway.request("chat.abort", params: ["sessionKey": .string(key)])
        if sessions[key] != nil {
            sessions[key]?.runStatus = .interrupted
            sessions[key]?.updatedAt = now()
            await publish()
        }
        return ConnectorOutcome(taskId: self.taskId(for: key), retainsLiveOwnership: true)
    }

    private func send(_ prompt: String, to key: String, via gateway: OpenClawGateway) async throws {
        // idempotencyKey 每条新消息一个：Gateway 据此去重传输层重试，同一条命令的重试由分发器按 command.id 去重。
        _ = try await gateway.request("chat.send", params: ["sessionKey": .string(key),
                                                            "message": .string(prompt),
                                                            "idempotencyKey": .string(UUID().uuidString)])
    }

    private func connectedGateway() throws -> OpenClawGateway {
        guard let gateway else { throw ConnectorError("OpenClaw Gateway 没有连上") }
        return gateway
    }

    /// `openclaw:<sessionKey>` → sessionKey。sessionKey 自己带冒号（`agent:main:main`），只切第一个。
    static func sessionKey(from taskId: String) throws -> String {
        let prefix = "\(ConnectorKind.openclaw.rawValue):"
        let key = taskId.hasPrefix(prefix) ? String(taskId.dropFirst(prefix.count)) : taskId
        guard !key.trimmed.isEmpty else { throw ConnectorError("任务 id 不合法：\(taskId)") }
        return key
    }

    // MARK: - JSON 小工具

    /// 列表形状宽松：可能是 `{sessions:[…]}` 这种信封，也可能直接是数组。
    static func array(_ payload: JSONValue, key: String) -> [JSONValue] {
        if let array = payload.arrayValue { return array }
        return payload[key]?.arrayValue ?? []
    }

    /// Gateway 的时间是毫秒整数；也接受 ISO 字符串，免得哪天换了格式整条会话掉时间。
    static func date(_ value: JSONValue?) -> Date? {
        OpenClawTranscript.date(value)
    }
}
