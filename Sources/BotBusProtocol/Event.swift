import Foundation

public struct Notify: Codable, Hashable, Sendable {
    public enum Category: String, Codable, Sendable, CaseIterable {
        case taskApproval = "TASK_APPROVAL"
        case taskInput = "TASK_INPUT"
        case taskDone = "TASK_DONE"
        case taskFailed = "TASK_FAILED"
    }

    public var taskId: String
    public var category: Category
    public var title: String
    public var body: String
    public var requestId: String?
    /// 协议 3.0：发通知的电脑名。整条 Notify 进密文后 Relay 读不到电脑名，由 Mac 自己填进来给通知扩展显示。
    public var agentName: String?

    public init(taskId: String, category: Category, title: String, body: String, requestId: String? = nil,
                agentName: String? = nil) {
        self.taskId = taskId
        self.category = category
        self.title = title
        self.body = body
        self.requestId = requestId
        self.agentName = agentName
    }

    public static func approval(taskId: String, requestId: String, title: String, body: String, agentName: String? = nil) -> Notify {
        Notify(taskId: taskId, category: .taskApproval, title: title, body: body, requestId: requestId, agentName: agentName)
    }
    public static func input(taskId: String, title: String, body: String, agentName: String? = nil) -> Notify {
        Notify(taskId: taskId, category: .taskInput, title: title, body: body, agentName: agentName)
    }
    public static func done(taskId: String, title: String, body: String, agentName: String? = nil) -> Notify {
        Notify(taskId: taskId, category: .taskDone, title: title, body: body, agentName: agentName)
    }
    public static func failed(taskId: String, title: String, body: String, agentName: String? = nil) -> Notify {
        Notify(taskId: taskId, category: .taskFailed, title: title, body: body, agentName: agentName)
    }
}

public struct Event: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case snapshot, taskUpdated, taskRemoved, commandResult, notify, taskMessages
    }

    public var kind: Kind
    public var snapshot: Snapshot?
    public var task: TaskRecord?
    public var taskId: String?
    public var commandResult: CommandResult?
    public var notify: Notify?
    public var taskMessages: TaskMessages?

    public init(kind: Kind, snapshot: Snapshot? = nil, task: TaskRecord? = nil, taskId: String? = nil,
                commandResult: CommandResult? = nil, notify: Notify? = nil,
                taskMessages: TaskMessages? = nil) {
        self.kind = kind
        self.snapshot = snapshot
        self.task = task
        self.taskId = taskId
        self.commandResult = commandResult
        self.notify = notify
        self.taskMessages = taskMessages
    }

    private enum CodingKeys: String, CodingKey {
        case kind, snapshot, task, taskId, commandResult, notify, taskMessages
    }

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

    /// 与 Command 相同：与 kind 配套的字段必须存在，否则解码失败；其余配套字段以 kind 为准被忽略。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(Kind.self, forKey: .kind)
        snapshot = try container.decodeIfPresent(Snapshot.self, forKey: .snapshot)
        task = try container.decodeIfPresent(TaskRecord.self, forKey: .task)
        taskId = try container.decodeIfPresent(String.self, forKey: .taskId)
        commandResult = try container.decodeIfPresent(CommandResult.self, forKey: .commandResult)
        notify = try container.decodeIfPresent(Notify.self, forKey: .notify)
        taskMessages = try container.decodeIfPresent(TaskMessages.self, forKey: .taskMessages)

        guard hasPayloadForKind else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container,
                debugDescription: "payload for kind \(kind.rawValue) is missing")
        }
        if kind != .snapshot { snapshot = nil }
        if kind != .taskUpdated { task = nil }
        if kind != .taskRemoved { taskId = nil }
        if kind != .commandResult { commandResult = nil }
        if kind != .notify { notify = nil }
        if kind != .taskMessages { taskMessages = nil }
    }

    /// 编码方向同样守住这条规则：配套字段缺失直接拒绝编码，与 kind 不符的字段不写出。
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
                codingPath: encoder.codingPath,
                debugDescription: "payload for kind \(kind.rawValue) is missing"))
        }
        return payload
    }

    public static func snapshot(_ snapshot: Snapshot) -> Event { Event(kind: .snapshot, snapshot: snapshot) }
    public static func taskUpdated(_ task: TaskRecord) -> Event { Event(kind: .taskUpdated, task: task) }
    public static func taskRemoved(_ taskId: String) -> Event { Event(kind: .taskRemoved, taskId: taskId) }
    public static func commandResult(_ result: CommandResult) -> Event { Event(kind: .commandResult, commandResult: result) }
    public static func notify(_ notify: Notify) -> Event { Event(kind: .notify, notify: notify) }
    public static func taskMessages(_ messages: TaskMessages) -> Event { Event(kind: .taskMessages, taskMessages: messages) }
}
