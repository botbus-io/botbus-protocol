import Foundation
import os
import BotBusProtocol

/// 一个来源的只读快照：这一轮在磁盘上看到的全部任务与项目。
///
/// 生产实现读各家自己的会话存储（Pi 的 JSONL、Hermes 的 `state.db`），测试用假实现。
/// **读不到**（目录或数据库不存在）要抛 `SessionSourceUnavailable`，不能返回空列表——
/// 空列表会被对账当成"任务都没了"，把手机上的记录全部摘掉。
public protocol SessionSnapshotSource: Sendable {
    func readSnapshot(agentId: String) throws -> (tasks: [TaskRecord], projects: [Project])
}

/// 这一轮读不到数据（不是"数据为空"）。`message` 直接进菜单栏。
public struct SessionSourceUnavailable: Error, Hashable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

/// Hermes / Pi 共用的轮询观察者：定时读一遍会话存储，按来源对账进 `TaskStore`。
///
/// 和 `CodexObserver` 同一套规矩——实时驱动中的任务归 `.live`，`reconcile` 整体跳过它们；
/// 读不到不对账；连续失败到阈值才报错，免得文件写到一半被读到时吓用户一跳。
/// 不复用 `CodexObserver` 是因为那边的菜单文案、待处理计数都是 Codex 专属的。
public actor SessionObserver {
    public static let failureThreshold = 3
    public static let defaultInterval: TimeInterval = 3

    public typealias SourceProvider = @Sendable () -> any SessionSnapshotSource
    public typealias IntervalProvider = @Sendable () async -> TimeInterval

    private static let log = Logger(subsystem: "io.botbus.agent", category: "sessionobserver")

    public let source: TaskSource
    private let store: TaskStore
    private let provider: SourceProvider
    private let interval: IntervalProvider
    private let statusObserver: @Sendable (String) -> Void

    /// 最近一轮给菜单栏的一句话。
    public private(set) var statusText: String
    private var consecutiveFailures = 0
    private var loop: Task<Void, Never>?
    /// 最近排上的一轮。轮询串行执行：定时循环和连接器的 `onRunFinished` 都会催，读取在后台线程挂起，
    /// 两轮若同时在飞，先读的旧快照可能后对账，把刚交还的任务摘掉或把状态退回 running。
    private var tail: Task<Void, Never>?

    public init(source: TaskSource,
                store: TaskStore,
                provider: @escaping SourceProvider,
                interval: @escaping IntervalProvider = { SessionObserver.defaultInterval },
                statusObserver: @escaping @Sendable (String) -> Void = { _ in }) {
        self.source = source
        self.store = store
        self.provider = provider
        self.interval = interval
        self.statusObserver = statusObserver
        self.statusText = "尚未读取 \(source.notificationLabel)"
    }

    /// 幂等：已经在跑就什么都不做。
    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollOnce()
                let seconds = await self.interval()
                if Task.isCancelled { return }
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    public var isRunning: Bool { loop != nil }

    /// 跑一轮。连接器一轮结束后也可以直接催一下，不必等下一个节拍。
    /// 返回时这一轮（以及排在它前面的）都已对账完。
    public func pollOnce() async {
        let previous = tail
        let next = Task { [weak self] in
            await previous?.value
            await self?.performPoll()
        }
        tail = next
        await next.value
    }

    private func performPoll() async {
        let agentId = await store.identity.agentId
        let source = provider()
        let label = self.source.notificationLabel
        do {
            // 文件与 SQLite 读取放到后台线程，actor 不被阻塞。
            let result = try await Task.detached(priority: .utility) {
                try source.readSnapshot(agentId: agentId)
            }.value
            await store.reconcile(source: self.source, tasks: result.tasks, projects: result.projects)
            consecutiveFailures = 0
            report("\(label)：\(result.tasks.count) 个任务（7 天内）")
        } catch let unavailable as SessionSourceUnavailable {
            // 读不到不是"这个来源报告了空列表"：一条都不能摘。
            consecutiveFailures = 0
            report(unavailable.message)
        } catch {
            consecutiveFailures += 1
            Self.log.error("\(label, privacy: .public) poll failed (\(self.consecutiveFailures)): \(String(describing: error))")
            if consecutiveFailures >= Self.failureThreshold { report("读取 \(label) 失败：\(error)") }
        }
    }

    private func report(_ text: String) {
        statusText = text
        statusObserver(text)
    }
}

/// 观察者与消息读取器共用的小工具。
public enum SessionFormatting {
    /// 只看最近 7 天，与 Codex 观察者一致；更老的会话不进快照。
    public static let recentWindow: TimeInterval = 7 * 24 * 3600
    /// 超过这么久没有动静就算 `idle`（协议：超过 24 小时无活动）。
    public static let idleAfter: TimeInterval = 24 * 3600
    public static let titleLimit = 80
    public static let lastMessageLimit = 500
    public static let detailLimit = 2000

    public static func projectName(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return (trimmed as NSString).lastPathComponent
    }

    public static func truncate(_ text: String, _ limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count <= limit ? trimmed : String(trimmed.prefix(limit))
    }

    /// 按每条会话的最近活动时间聚合出项目列表，最近的在前。
    public static func projects(from tasks: [TaskRecord], agentId: String) -> [Project] {
        var latest: [String: String] = [:]
        for task in tasks where !task.projectPath.isEmpty {
            if let existing = latest[task.projectPath], existing >= task.updatedAt { continue }
            latest[task.projectPath] = task.updatedAt
        }
        return latest
            .sorted { $0.value > $1.value }
            .map { Project(agentId: agentId, path: $0.key, name: projectName($0.key), lastUsedAt: $0.value, pinned: false) }
    }
}
