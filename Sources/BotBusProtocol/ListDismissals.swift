import Foundation

/// 本地列表可见性，不上 Relay。手机按配对组保存；电脑只保存项目记录。
/// 保存活动基线而非删除任务，旧快照、重连与历史回补不能让它重新出现。
public struct ListDismissals: Codable, Hashable, Sendable {
    public struct Activity: Codable, Hashable, Sendable {
        public var updatedAt: String
        public var message: UInt64

        public init(_ task: TaskRecord) {
            updatedAt = task.updatedAt
            // 稳定的内容指纹，用于秒精度时间内的新消息；不把消息正文写进设置。
            message = (task.lastMessage ?? "").utf8.reduce(14695981039346656037) { ($0 ^ UInt64($1)) &* 1099511628211 }
        }

        public func isNewer(_ task: TaskRecord) -> Bool {
            task.updatedAt > updatedAt || (task.updatedAt == updatedAt && Activity(task).message != message)
        }
    }

    public struct Session: Codable, Hashable, Sendable {
        public var agentId: String
        public var taskId: String
        public var activity: Activity
    }

    public struct ProjectEntry: Codable, Hashable, Sendable {
        public var agentId: String
        public var path: String
        public var activities: [String: Activity]
        public var cutoff: String
    }

    public private(set) var sessions: [Session] = []
    public private(set) var projects: [ProjectEntry] = []

    public init() {}

    public mutating func include(_ other: ListDismissals) {
        for entry in other.sessions {
            sessions.removeAll { $0.agentId == entry.agentId && $0.taskId == entry.taskId }
            sessions.append(entry)
        }
        for entry in other.projects {
            projects.removeAll { $0.agentId == entry.agentId && $0.path == entry.path }
            projects.append(entry)
        }
    }

    public mutating func restore(_ other: ListDismissals) {
        sessions.removeAll { other.sessions.contains($0) }
        projects.removeAll { other.projects.contains($0) }
    }

    public mutating func dismiss(_ task: TaskRecord) {
        sessions.removeAll { $0.agentId == task.agentId && $0.taskId == task.id }
        sessions.append(Session(agentId: task.agentId, taskId: task.id, activity: Activity(task)))
    }

    public mutating func dismissProject(agentId: String, path: String, tasks: [TaskRecord], lastUsedAt: String) {
        projects.removeAll { $0.agentId == agentId && $0.path == path }
        let related = tasks.filter { $0.agentId == agentId && $0.projectPath == path && $0.outsideProject != true }
        projects.append(ProjectEntry(agentId: agentId, path: path,
                                     activities: Dictionary(related.map { ($0.id, Activity($0)) }, uniquingKeysWith: { _, b in b }),
                                     cutoff: max(lastUsedAt, related.map(\.updatedAt).max() ?? lastUsedAt)))
    }

    /// 活动恢复可以由单个实时更新触发；不会因任务从快照暂时消失而清掉删除记录。
    @discardableResult
    public mutating func reconcile(_ tasks: [TaskRecord]) -> Bool {
        let before = self
        sessions.removeAll { entry in
            tasks.contains { $0.agentId == entry.agentId && $0.id == entry.taskId && entry.activity.isNewer($0) }
        }
        projects.removeAll { entry in
            tasks.contains { task in
                guard task.agentId == entry.agentId, task.projectPath == entry.path, task.outsideProject != true else { return false }
                if let activity = entry.activities[task.id] { return activity.isNewer(task) }
                return task.startedAt >= entry.cutoff && task.updatedAt >= entry.cutoff
            }
        }
        return self != before
    }

    public func hides(_ task: TaskRecord) -> Bool {
        sessions.contains { $0.agentId == task.agentId && $0.taskId == task.id }
            || (task.outsideProject != true && hidesProject(agentId: task.agentId, path: task.projectPath))
    }

    public func hidesProject(agentId: String, path: String) -> Bool {
        projects.contains { $0.agentId == agentId && $0.path == path }
    }
}
