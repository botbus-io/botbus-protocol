import Foundation

// 协议 3.0 的线上形状：Relay 需要的字段留明文，其余整个领域对象（`TaskRecord`、`AgentInfo`……的完整 JSON）
// 进 `sealed`。明文字段是密文里同名字段的副本，解开时核对一致（AAD 已把 id 钉死，这里多一道）。
// 领域类型（`Snapshot`、`Event`、`Command`……）本身不变：Mac 与客户端的业务逻辑照旧用它们，
// 只在进出 Relay 的那一层换成这里的类型。

/// 一台电脑的密封快照片段。`sealed` 为空 = 这台电脑还没连上过（刚被认领、没报过快照），客户端显示占位名。
public struct SealedAgent: Codable, Hashable, Sendable, Identifiable {
    public var id: String { agentId }
    public var agentId: String
    /// 由 Relay 按连接状态维护。
    public var online: Bool
    public var lastSeenAt: String
    /// 完整的 `AgentInfo` JSON（其中的 `online` / `lastSeenAt` 以外层为准）。
    public var sealed: Sealed?

    public init(agentId: String, online: Bool, lastSeenAt: String, sealed: Sealed?) {
        self.agentId = agentId
        self.online = online
        self.lastSeenAt = lastSeenAt
        self.sealed = sealed
    }
}

public struct SealedTask: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var agentId: String
    /// Relay 据此排序与截断。
    public var updatedAt: String
    /// 完整的 `TaskRecord` JSON。
    public var sealed: Sealed

    public init(id: String, agentId: String, updatedAt: String, sealed: Sealed) {
        self.id = id
        self.agentId = agentId
        self.updatedAt = updatedAt
        self.sealed = sealed
    }
}

/// 一台电脑的整个项目列表。只随 `snapshot` 事件整体替换，Relay 不再做项目截断。
public struct SealedProjects: Codable, Hashable, Sendable {
    public var agentId: String
    /// `[Project]` 的 JSON。
    public var sealed: Sealed

    public init(agentId: String, sealed: Sealed) {
        self.agentId = agentId
        self.sealed = sealed
    }
}

public struct SealedMessages: Codable, Hashable, Sendable {
    public var taskId: String
    public var agentId: String
    public var fetchedAt: String
    /// 完整的 `TaskMessages` JSON。
    public var sealed: Sealed

    public init(taskId: String, agentId: String, fetchedAt: String, sealed: Sealed) {
        self.taskId = taskId
        self.agentId = agentId
        self.fetchedAt = fetchedAt
        self.sealed = sealed
    }
}

/// 命令结果。Mac 发出的带 `sealed`（完整的 `CommandResult` JSON）；Relay 自己造的（离线队列过期）没有密钥，
/// 只能是明文 `error`，两者互斥。
public struct SealedResult: Codable, Hashable, Sendable {
    public var commandId: String
    public var finishedAt: String
    public var sealed: Sealed?
    public var error: String?

    public init(commandId: String, finishedAt: String, sealed: Sealed? = nil, error: String? = nil) {
        self.commandId = commandId
        self.finishedAt = finishedAt
        self.sealed = sealed
        self.error = error
    }
}

/// 推送。`category` / `requestId` / `taskId` 留明文：Relay 校验 TASK_APPROVAL 必带 requestId，
/// 并把它们放进 APNs 载荷让点开通知能直达任务。`sealed` 用 `K_notify` 封完整的 `Notify` JSON。
public struct SealedNotify: Codable, Hashable, Sendable {
    public var taskId: String
    public var agentId: String
    public var category: Notify.Category
    public var requestId: String?
    public var sealed: Sealed

    public init(taskId: String, agentId: String, category: Notify.Category, requestId: String? = nil, sealed: Sealed) {
        self.taskId = taskId
        self.agentId = agentId
        self.category = category
        self.requestId = requestId
        self.sealed = sealed
    }
}

public struct SealedSnapshot: Codable, Hashable, Sendable {
    public var agents: [SealedAgent]
    public var tasks: [SealedTask]
    public var projects: [SealedProjects]
    public var recentResults: [SealedResult]
    public var recentMessages: [SealedMessages]
    public var seq: Int
    public var generatedAt: String

    public init(agents: [SealedAgent], tasks: [SealedTask], projects: [SealedProjects],
                recentResults: [SealedResult] = [], recentMessages: [SealedMessages] = [],
                seq: Int = 0, generatedAt: String) {
        self.agents = agents
        self.tasks = tasks
        self.projects = projects
        self.recentResults = recentResults
        self.recentMessages = recentMessages
        self.seq = seq
        self.generatedAt = generatedAt
    }
}

public struct SealedCommand: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var agentId: String
    public var createdAt: String
    /// 完整的 `Command` JSON（含 `kind` 与载荷）。
    public var sealed: Sealed

    public init(id: String, agentId: String, createdAt: String, sealed: Sealed) {
        self.id = id
        self.agentId = agentId
        self.createdAt = createdAt
        self.sealed = sealed
    }
}

/// 与 `Event` 同一套规则：`kind` 明文（Relay 据此决定存分片、换对话记录还是发推送），配套字段必须存在。
public struct SealedEvent: Codable, Hashable, Sendable {
    public var kind: Event.Kind
    public var snapshot: SealedSnapshot?
    public var task: SealedTask?
    public var taskId: String?
    public var commandResult: SealedResult?
    public var notify: SealedNotify?
    public var taskMessages: SealedMessages?

    public init(kind: Event.Kind, snapshot: SealedSnapshot? = nil, task: SealedTask? = nil, taskId: String? = nil,
                commandResult: SealedResult? = nil, notify: SealedNotify? = nil, taskMessages: SealedMessages? = nil) {
        self.kind = kind
        self.snapshot = snapshot
        self.task = task
        self.taskId = taskId
        self.commandResult = commandResult
        self.notify = notify
        self.taskMessages = taskMessages
    }

    private enum CodingKeys: String, CodingKey { case kind, snapshot, task, taskId, commandResult, notify, taskMessages }

    private var hasPayloadForKind: Bool {
        switch kind {
        case .snapshot: snapshot != nil
        case .taskUpdated: task != nil
        case .taskRemoved: taskId != nil
        case .commandResult: commandResult != nil
        case .notify: notify != nil
        case .taskMessages: taskMessages != nil
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(Event.Kind.self, forKey: .kind)
        snapshot = try container.decodeIfPresent(SealedSnapshot.self, forKey: .snapshot)
        task = try container.decodeIfPresent(SealedTask.self, forKey: .task)
        taskId = try container.decodeIfPresent(String.self, forKey: .taskId)
        commandResult = try container.decodeIfPresent(SealedResult.self, forKey: .commandResult)
        notify = try container.decodeIfPresent(SealedNotify.self, forKey: .notify)
        taskMessages = try container.decodeIfPresent(SealedMessages.self, forKey: .taskMessages)
        guard hasPayloadForKind else {
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container,
                                                   debugDescription: "payload for kind \(kind.rawValue) is missing")
        }
        if kind != .snapshot { snapshot = nil }
        if kind != .taskUpdated { task = nil }
        if kind != .taskRemoved { taskId = nil }
        if kind != .commandResult { commandResult = nil }
        if kind != .notify { notify = nil }
        if kind != .taskMessages { taskMessages = nil }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch kind {
        case .snapshot: try container.encode(required(snapshot, encoder), forKey: .snapshot)
        case .taskUpdated: try container.encode(required(task, encoder), forKey: .task)
        case .taskRemoved: try container.encode(required(taskId, encoder), forKey: .taskId)
        case .commandResult: try container.encode(required(commandResult, encoder), forKey: .commandResult)
        case .notify: try container.encode(required(notify, encoder), forKey: .notify)
        case .taskMessages: try container.encode(required(taskMessages, encoder), forKey: .taskMessages)
        }
    }

    private func required<T>(_ payload: T?, _ encoder: Encoder) throws -> T {
        guard let payload else {
            throw EncodingError.invalidValue(self, EncodingError.Context(
                codingPath: encoder.codingPath, debugDescription: "payload for kind \(kind.rawValue) is missing"))
        }
        return payload
    }
}

// MARK: - 一组的两把密封器

/// 内容与推送各一把（推送用 `K_notify`，iPhone 的通知扩展只持有这一把）。
public struct PairSealer: Sendable {
    public let content: Sealer
    public let notify: Sealer

    public init(pairKey: PairKey, nonce: @escaping Sealer.NonceProvider = Sealer.randomNonce) {
        content = Sealer(pairKey: pairKey, purpose: .content, nonce: nonce)
        notify = Sealer(pairKey: pairKey, purpose: .notify, nonce: nonce)
    }
}

// MARK: - 领域类型 ⇄ 密封形状

extension SealedAgent {
    public init(sealing info: AgentInfo, sealer: Sealer) throws {
        self.init(agentId: info.agentId, online: info.online, lastSeenAt: info.lastSeenAt,
                  sealed: try sealer.seal(info, aad: SealingContext.agent(agentId: info.agentId)))
    }
}

extension AgentInfo {
    /// `sealed` 为空时给一个占位：这台电脑被认领了但还没连上过。
    public init(opening agent: SealedAgent, sealer: Sealer) throws {
        guard let sealed = agent.sealed else {
            self.init(agentId: agent.agentId, name: "", online: agent.online, lastSeenAt: agent.lastSeenAt,
                      appVersion: "", connectors: [])
            return
        }
        var info = try sealer.open(AgentInfo.self, from: sealed, aad: SealingContext.agent(agentId: agent.agentId))
        guard info.agentId == agent.agentId else { throw SealingError.mismatch("agentId") }
        info.online = agent.online
        info.lastSeenAt = agent.lastSeenAt
        self = info
    }
}

extension SealedTask {
    public init(sealing task: TaskRecord, sealer: Sealer) throws {
        self.init(id: task.id, agentId: task.agentId, updatedAt: task.updatedAt,
                  sealed: try sealer.seal(task, aad: SealingContext.task(agentId: task.agentId, taskId: task.id)))
    }
}

extension TaskRecord {
    public init(opening task: SealedTask, sealer: Sealer) throws {
        let record = try sealer.open(TaskRecord.self, from: task.sealed,
                                     aad: SealingContext.task(agentId: task.agentId, taskId: task.id))
        guard record.id == task.id, record.agentId == task.agentId else { throw SealingError.mismatch("task id") }
        guard record.updatedAt == task.updatedAt else { throw SealingError.mismatch("updatedAt") }
        self = record
    }
}

extension SealedProjects {
    public init(sealing projects: [Project], agentId: String, sealer: Sealer) throws {
        self.init(agentId: agentId, sealed: try sealer.seal(projects, aad: SealingContext.projects(agentId: agentId)))
    }

    public func opened(sealer: Sealer) throws -> [Project] {
        let projects = try sealer.open([Project].self, from: sealed, aad: SealingContext.projects(agentId: agentId))
        guard projects.allSatisfy({ $0.agentId == agentId }) else { throw SealingError.mismatch("project agentId") }
        return projects
    }
}

extension SealedMessages {
    public init(sealing messages: TaskMessages, sealer: Sealer) throws {
        self.init(taskId: messages.taskId, agentId: messages.agentId, fetchedAt: messages.fetchedAt,
                  sealed: try sealer.seal(messages, aad: SealingContext.messages(agentId: messages.agentId,
                                                                                  taskId: messages.taskId)))
    }
}

extension TaskMessages {
    public init(opening messages: SealedMessages, sealer: Sealer) throws {
        let opened = try sealer.open(TaskMessages.self, from: messages.sealed,
                                     aad: SealingContext.messages(agentId: messages.agentId, taskId: messages.taskId))
        guard opened.taskId == messages.taskId, opened.agentId == messages.agentId else {
            throw SealingError.mismatch("messages id")
        }
        self = opened
    }
}

extension SealedResult {
    public init(sealing result: CommandResult, sealer: Sealer) throws {
        self.init(commandId: result.commandId, finishedAt: result.finishedAt,
                  sealed: try sealer.seal(result, aad: SealingContext.result(commandId: result.commandId)))
    }
}

extension CommandResult {
    /// 没有 `sealed` 的是 Relay 自己造的失败（离线队列过期），照明文 `error` 还原。
    public init(opening result: SealedResult, sealer: Sealer) throws {
        guard let sealed = result.sealed else {
            self.init(commandId: result.commandId, ok: false, error: result.error ?? "relay", finishedAt: result.finishedAt)
            return
        }
        let opened = try sealer.open(CommandResult.self, from: sealed, aad: SealingContext.result(commandId: result.commandId))
        guard opened.commandId == result.commandId else { throw SealingError.mismatch("commandId") }
        self = opened
    }
}

extension SealedNotify {
    /// `sealer` 应是 `PairSealer.notify`。
    public init(sealing notify: Notify, agentId: String, sealer: Sealer) throws {
        self.init(taskId: notify.taskId, agentId: agentId, category: notify.category, requestId: notify.requestId,
                  sealed: try sealer.seal(notify, aad: SealingContext.notify(agentId: agentId, taskId: notify.taskId)))
    }
}

extension Notify {
    public init(opening notify: SealedNotify, sealer: Sealer) throws {
        let opened = try sealer.open(Notify.self, from: notify.sealed,
                                     aad: SealingContext.notify(agentId: notify.agentId, taskId: notify.taskId))
        guard opened.taskId == notify.taskId, opened.category == notify.category else {
            throw SealingError.mismatch("notify")
        }
        self = opened
    }
}

extension SealedSnapshot {
    /// Mac 发出全量快照；`projects` 按 agentId 分组（Mac 只有自己一台，客户端合并结果也可能多台）。
    public init(sealing snapshot: Snapshot, sealer: Sealer) throws {
        var order: [String] = []
        var grouped: [String: [Project]] = [:]
        for project in snapshot.projects {
            if grouped[project.agentId] == nil { order.append(project.agentId) }
            grouped[project.agentId, default: []].append(project)
        }
        // 没有项目的电脑也带一份空列表，让"这台电脑的项目列表是空的"与"还没上报"可区分。
        for agent in snapshot.agents where grouped[agent.agentId] == nil {
            order.append(agent.agentId)
            grouped[agent.agentId] = []
        }
        self.init(
            agents: try snapshot.agents.map { try SealedAgent(sealing: $0, sealer: sealer) },
            tasks: try snapshot.tasks.map { try SealedTask(sealing: $0, sealer: sealer) },
            projects: try order.map { try SealedProjects(sealing: grouped[$0] ?? [], agentId: $0, sealer: sealer) },
            recentResults: try snapshot.recentResults.map { try SealedResult(sealing: $0, sealer: sealer) },
            recentMessages: try snapshot.recentMessages.map { try SealedMessages(sealing: $0, sealer: sealer) },
            seq: snapshot.seq,
            generatedAt: snapshot.generatedAt)
    }
}

extension Snapshot {
    /// 客户端解开 Relay 合并后的快照。任何一段解不开就整份失败：那意味着密钥不对或 Relay 动过手脚，
    /// 界面该说"重新配对"，而不是悄悄少显示几条任务。
    public init(opening snapshot: SealedSnapshot, sealer: Sealer) throws {
        self.init(
            agents: try snapshot.agents.map { try AgentInfo(opening: $0, sealer: sealer) },
            tasks: try snapshot.tasks.map { try TaskRecord(opening: $0, sealer: sealer) },
            projects: try snapshot.projects.flatMap { try $0.opened(sealer: sealer) },
            recentResults: try snapshot.recentResults.map { try CommandResult(opening: $0, sealer: sealer) },
            recentMessages: try snapshot.recentMessages.map { try TaskMessages(opening: $0, sealer: sealer) },
            seq: snapshot.seq,
            generatedAt: snapshot.generatedAt)
    }
}

extension SealedEvent {
    /// Mac 发出事件；`agentId` 是本机的，推送信封要用它钉 AAD。
    public init(sealing event: Event, agentId: String, sealer: PairSealer) throws {
        switch event.kind {
        case .snapshot:
            self.init(kind: .snapshot, snapshot: try SealedSnapshot(sealing: event.snapshot!, sealer: sealer.content))
        case .taskUpdated:
            self.init(kind: .taskUpdated, task: try SealedTask(sealing: event.task!, sealer: sealer.content))
        case .taskRemoved:
            self.init(kind: .taskRemoved, taskId: event.taskId!)
        case .commandResult:
            self.init(kind: .commandResult, commandResult: try SealedResult(sealing: event.commandResult!, sealer: sealer.content))
        case .notify:
            self.init(kind: .notify, notify: try SealedNotify(sealing: event.notify!, agentId: agentId, sealer: sealer.notify))
        case .taskMessages:
            // 分发器发出的 TaskMessages 里 agentId 留空（由 Relay 按连接盖章），但 AAD 钉着 agentId：
            // 必须按本机的封，否则手机按 Relay 盖过章的 agentId 验 AAD，整份快照都解不开。
            var messages = event.taskMessages!
            messages.agentId = agentId
            self.init(kind: .taskMessages, taskMessages: try SealedMessages(sealing: messages, sealer: sealer.content))
        }
    }
}

extension Event {
    public init(opening event: SealedEvent, sealer: PairSealer) throws {
        switch event.kind {
        case .snapshot:
            self.init(kind: .snapshot, snapshot: try Snapshot(opening: event.snapshot!, sealer: sealer.content))
        case .taskUpdated:
            self.init(kind: .taskUpdated, task: try TaskRecord(opening: event.task!, sealer: sealer.content))
        case .taskRemoved:
            self.init(kind: .taskRemoved, taskId: event.taskId!)
        case .commandResult:
            self.init(kind: .commandResult, commandResult: try CommandResult(opening: event.commandResult!, sealer: sealer.content))
        case .notify:
            self.init(kind: .notify, notify: try Notify(opening: event.notify!, sealer: sealer.notify))
        case .taskMessages:
            self.init(kind: .taskMessages, taskMessages: try TaskMessages(opening: event.taskMessages!, sealer: sealer.content))
        }
    }
}

extension SealedCommand {
    public init(sealing command: Command, sealer: Sealer) throws {
        self.init(id: command.id, agentId: command.agentId, createdAt: command.createdAt,
                  sealed: try sealer.seal(command, aad: SealingContext.command(agentId: command.agentId, commandId: command.id)))
    }
}

extension Command {
    public init(opening command: SealedCommand, sealer: Sealer) throws {
        let opened = try sealer.open(Command.self, from: command.sealed,
                                     aad: SealingContext.command(agentId: command.agentId, commandId: command.id))
        guard opened.id == command.id, opened.agentId == command.agentId else { throw SealingError.mismatch("command id") }
        guard opened.createdAt == command.createdAt else { throw SealingError.mismatch("createdAt") }
        self = opened
    }
}
