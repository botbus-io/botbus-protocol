import Foundation

public struct Notify: Codable, Hashable, Sendable {
    public enum Category: String, Codable, Sendable, CaseIterable {
        case taskApproval = "TASK_APPROVAL"
        case taskInput = "TASK_INPUT"
        case taskDone = "TASK_DONE"
        case taskFailed = "TASK_FAILED"
    }

    /// 协议 3.10：这条通知是哪一种，手机据此按自己的界面语言拼标题与固定说明（见 PROTOCOL「七、通知」）。
    /// 开集：不认得的值原样保留，手机照旧显示 `title` / `body`。每种只配一个 `category`，对不上时同样按不认得处理。
    public enum Kind: RawRepresentable, Codable, Sendable, Hashable {
        /// 等审批：标题「<connectorName> 等待审批」，正文是请求摘要（`body`）。
        case approval
        /// 等回答：标题「<connectorName> 在等你回答」，正文是问题（`body`）。
        case input
        /// 等回答，而电脑上正有密码框聚焦（Secure Input）：标题同 `input`，正文换成「可以在手机上操作电脑」的固定说明。
        case secureInput
        /// 任务完成：标题「<connectorName> 任务完成」，正文是最后一条消息（`body`）。
        case done
        /// 任务失败：标题「<connectorName> 任务失败」，正文是最后一条消息（`body`）。
        case failed
        /// 失败后检测到系统授权弹窗（协议 2.10）：标题与正文都是固定说明，`hasScreenshot` 决定提不提截图。
        case systemPermission
        /// 这个版本还不认得的种类。
        case unknown(String)

        public init(rawValue: String) {
            switch rawValue {
            case "approval": self = .approval
            case "input": self = .input
            case "secureInput": self = .secureInput
            case "done": self = .done
            case "failed": self = .failed
            case "systemPermission": self = .systemPermission
            default: self = .unknown(rawValue)
            }
        }

        public var rawValue: String {
            switch self {
            case .approval: "approval"
            case .input: "input"
            case .secureInput: "secureInput"
            case .done: "done"
            case .failed: "failed"
            case .systemPermission: "systemPermission"
            case .unknown(let value): value
            }
        }

        /// 这一种通知配的类别；不认得的种类为 nil。
        public var category: Category? {
            switch self {
            case .approval: .taskApproval
            case .input, .secureInput: .taskInput
            case .done: .taskDone
            case .failed, .systemPermission: .taskFailed
            case .unknown: nil
            }
        }

        public init(from decoder: Decoder) throws {
            self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    public var taskId: String
    public var category: Category
    /// 电脑写好的标题与正文（简体中文）。3.10 起手机认得 `kind` 时自己拼，这两项留给旧手机与不认得的种类。
    public var title: String
    public var body: String
    public var requestId: String?
    /// 协议 3.0：发通知的电脑名。整条 Notify 进密文后 Relay 读不到电脑名，由 Mac 自己填进来给通知扩展显示。
    public var agentName: String?
    /// 协议 3.10：通知种类，见 `Kind`。3.9 及更早的电脑不写。
    public var kind: Kind?
    /// 协议 3.10：标题里的 agent 名（Codex、Claude、ACP agent 的显示名），随 `systemPermission` 以外的种类。
    public var connectorName: String?
    /// 协议 3.10：只随 `systemPermission`：电脑截到了弹窗，App 里能看。只写 true 或省略。
    public var hasScreenshot: Bool?

    public init(taskId: String, category: Category, title: String, body: String, requestId: String? = nil,
                agentName: String? = nil, kind: Kind? = nil, connectorName: String? = nil, hasScreenshot: Bool? = nil) {
        self.taskId = taskId
        self.category = category
        self.title = title
        self.body = body
        self.requestId = requestId
        self.agentName = agentName
        self.kind = kind
        self.connectorName = connectorName
        self.hasScreenshot = hasScreenshot
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
