import Foundation
import BotBusProtocol

/// 只读观察的一轮结果。通知上下文只留在电脑端，不进入任务模型或线上协议。
public struct ObservedSessionSnapshot: Sendable {
    public let tasks: [TaskRecord]
    public let projects: [Project]
    public let notifications: [String: ObservedTaskNotification]

    public init(tasks: [TaskRecord], projects: [Project], notifications: [String: ObservedTaskNotification] = [:]) {
        self.tasks = tasks
        self.projects = projects
        self.notifications = notifications
    }
}

/// 不同会话属于同一个定时任务时，用稳定的任务身份合并连续的同类故障提醒。
public struct ObservedTaskNotification: Sendable {
    public let groupID: String
    public let failureFingerprint: String?
    public let failureBody: String?

    public init(groupID: String, failureFingerprint: String? = nil, failureBody: String? = nil) {
        self.groupID = groupID
        self.failureFingerprint = failureFingerprint
        self.failureBody = failureBody
    }
}

/// 按来源隔离的通知记忆；任务删掉或暂时不在观察列表里时，连续故障仍然是同一次故障。
struct ObservedTaskNotifications {
    static let maxGroups = 200

    struct Decision {
        let notify: Bool
        let failureBody: String?
        /// 只有记忆中同一轮的故障身份被修正，才可在任务记录没变时补通知。
        let notifyUnchangedTask: Bool

        init(notify: Bool, failureBody: String?, notifyUnchangedTask: Bool = false) {
            self.notify = notify
            self.failureBody = failureBody
            self.notifyUnchangedTask = notifyUnchangedTask
        }
    }

    private struct Group: Hashable {
        let source: TaskSource
        let id: String
    }

    private struct Terminal {
        let taskID: String
        let startedAt: String
        let updatedAt: String
        let status: TaskStatus
        let fingerprint: String?

        init(_ task: TaskRecord, context: ObservedTaskNotification) {
            taskID = task.id
            startedAt = task.startedAt
            updatedAt = task.updatedAt
            status = task.status
            let value = context.failureFingerprint?.trimmingCharacters(in: .whitespacesAndNewlines)
            fingerprint = value?.isEmpty == false ? value : nil
        }

        /// 开始时间决定轮次顺序。相同轮次只接纳更新时间不倒退的修正。
        func follows(_ previous: Terminal) -> Bool {
            if taskID == previous.taskID { return updatedAt >= previous.updatedAt }
            if startedAt != previous.startedAt { return startedAt > previous.startedAt }
            return taskID > previous.taskID
        }

        func warrantsNotification(after previous: Terminal?) -> Bool {
            guard let previous else { return true }
            if taskID == previous.taskID {
                return status != previous.status || (status == .failed && fingerprint != previous.fingerprint)
            }
            // 没有故障身份时不能把不同轮次的未知错误当作同一种错误。
            return !(status == .failed && previous.status == .failed
                     && fingerprint != nil && fingerprint == previous.fingerprint)
        }
    }

    private var latest: [Group: Terminal] = [:]
    private var baselinedSources: Set<TaskSource> = []

    var groupCount: Int { latest.count }

    mutating func reset(source: TaskSource? = nil) {
        guard let source else {
            latest.removeAll()
            baselinedSources.removeAll()
            return
        }
        latest = latest.filter { $0.key.source != source }
        baselinedSources.remove(source)
    }

    /// 调用方先排除实时拥有、隐藏与已移出项目的任务。每组只为最新的 completed / failed 发通知，
    /// 水位之后的中间结果用于识别恢复；running、interrupted 与老化后的 idle 都不能清掉已知故障。
    mutating func decisions(source: TaskSource, tasks: [TaskRecord],
                            notifications: [String: ObservedTaskNotification], silent: Bool) -> [String: Decision] {
        let baseline = silent || !baselinedSources.contains(source)
        baselinedSources.insert(source)
        var result: [String: Decision] = [:]
        var candidates: [Group: [(terminal: Terminal, context: ObservedTaskNotification)]] = [:]
        for task in tasks where task.status == .completed || task.status == .failed {
            guard let context = notifications[task.id], !context.groupID.isEmpty else { continue }
            let terminal = Terminal(task, context: context)
            let group = Group(source: source, id: context.groupID)
            result[task.id] = Decision(notify: false, failureBody: context.failureBody)
            candidates[group, default: []].append((terminal, context))
        }
        for (group, batch) in candidates {
            let remembered = latest[group]
            var previous = remembered
            var newest: (terminal: Terminal, context: ObservedTaskNotification)?
            var changed = false
            // 离线期间可能经过恢复又失败。只重放水位之后的状态，但仅为最新一轮发一次通知。
            for candidate in batch.sorted(by: { lhs, rhs in
                if lhs.terminal.startedAt != rhs.terminal.startedAt {
                    return lhs.terminal.startedAt < rhs.terminal.startedAt
                }
                if lhs.terminal.taskID != rhs.terminal.taskID { return lhs.terminal.taskID < rhs.terminal.taskID }
                return lhs.terminal.updatedAt < rhs.terminal.updatedAt
            }) {
                guard previous.map({ candidate.terminal.follows($0) }) ?? true else { continue }
                changed = changed || candidate.terminal.warrantsNotification(after: previous)
                previous = candidate.terminal
                newest = candidate
            }
            guard let newest else { continue }
            let correction = remembered.map {
                $0.taskID == newest.terminal.taskID && newest.terminal.warrantsNotification(after: $0)
            } ?? false
            result[newest.terminal.taskID] = Decision(
                notify: !baseline && changed, failureBody: newest.context.failureBody,
                notifyUnchangedTask: correction)
            latest[group] = newest.terminal
        }
        // 不因每轮读到同一份历史刷新淘汰顺序，免得旧组挤掉最近仍有活动的组。
        if latest.count > Self.maxGroups {
            let newest = latest.sorted { lhs, rhs in
                if lhs.value.startedAt != rhs.value.startedAt { return lhs.value.startedAt > rhs.value.startedAt }
                if lhs.value.taskID != rhs.value.taskID { return lhs.value.taskID > rhs.value.taskID }
                if lhs.key.source != rhs.key.source { return lhs.key.source.rawValue > rhs.key.source.rawValue }
                return lhs.key.id > rhs.key.id
            }.prefix(Self.maxGroups)
            latest = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
        }
        return result
    }
}
