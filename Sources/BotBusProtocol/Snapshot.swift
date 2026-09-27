import Foundation

public struct Project: Codable, Hashable, Sendable, Identifiable {
    /// 路径只在其所属电脑上有意义，两台电脑可以有同名路径，因此标识是 (agentId, path)。
    public var id: String { "\(agentId)/\(path)" }
    public var agentId: String
    public var path: String
    public var name: String
    public var lastUsedAt: String
    public var pinned: Bool

    public init(agentId: String, path: String, name: String, lastUsedAt: String, pinned: Bool) {
        self.agentId = agentId
        self.path = path
        self.name = name
        self.lastUsedAt = lastUsedAt
        self.pinned = pinned
    }

    private enum CodingKeys: String, CodingKey { case agentId, path, name, lastUsedAt, pinned }
}

public struct CommandResult: Codable, Hashable, Sendable {
    public var commandId: String
    public var ok: Bool
    public var error: String?
    public var taskId: String?
    public var finishedAt: String
    /// 协议 2.10：失败后检测到的系统授权弹窗证据；任务尚未创建时也可随结果返回。
    public var systemPermission: SystemPermissionNotice?
    /// 协议 2.11：`fetchChanges` 成功时，改动清单（`WorkingChanges` 的 JSON）的产物 id。
    public var artifactId: String?

    public init(commandId: String, ok: Bool, error: String? = nil, taskId: String? = nil, finishedAt: String,
                systemPermission: SystemPermissionNotice? = nil, artifactId: String? = nil) {
        self.commandId = commandId
        self.ok = ok
        self.error = error
        self.taskId = taskId
        self.finishedAt = finishedAt
        self.systemPermission = systemPermission
        self.artifactId = artifactId
    }
}

public struct Snapshot: Codable, Hashable, Sendable {
    /// 客户端看到的是全部电脑的合并结果；Agent 发出时恰好一个元素（自己，`online` 填 true）。
    public var agents: [AgentInfo]
    public var tasks: [TaskRecord]
    public var projects: [Project]
    /// 由 Relay 填写；Agent 发出时填 []。
    public var recentResults: [CommandResult]
    /// 最近一次 `fetchMessages` 的结果，最多一份，且只在 Relay 里留 5 分钟。
    /// 由 Relay 填写；Agent 发出时填 []。客户端收到后应自己缓存，不要指望它一直在。
    public var recentMessages: [TaskMessages]
    /// 由 Relay 填写；Agent 发出时填 0。
    public var seq: Int
    public var generatedAt: String

    public init(agents: [AgentInfo], tasks: [TaskRecord], projects: [Project],
                recentResults: [CommandResult] = [], recentMessages: [TaskMessages] = [],
                seq: Int = 0, generatedAt: String) {
        self.agents = agents
        self.tasks = tasks
        self.projects = projects
        self.recentResults = recentResults
        self.recentMessages = recentMessages
        self.seq = seq
        self.generatedAt = generatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case agents, tasks, projects, recentResults, recentMessages, seq, generatedAt
    }

    /// `recentMessages` 缺省当空数组，其余字段照常必填。
    ///
    /// **这个容错是必要的，不是宽松**：Relay、Agent 与两个客户端各自独立升级，中间必然有
    /// 一段版本不一致的窗口。合成的 Codable 遇到缺键会让**整份快照**解码失败——协议 v2.2
    /// 刚上线时就撞过：客户端连着 v2.1 的 Relay，界面永远停在"正在加载"。
    /// 少一个按需拉取的字段最多是聊天记录看不到，不该把整台电脑的任务一起弄丢。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agents = try container.decode([AgentInfo].self, forKey: .agents)
        tasks = try container.decode([TaskRecord].self, forKey: .tasks)
        projects = try container.decode([Project].self, forKey: .projects)
        recentResults = try container.decode([CommandResult].self, forKey: .recentResults)
        recentMessages = try container.decodeIfPresent([TaskMessages].self, forKey: .recentMessages) ?? []
        seq = try container.decode(Int.self, forKey: .seq)
        generatedAt = try container.decode(String.self, forKey: .generatedAt)
    }
}
