import Foundation
import os
import BotBusProtocol
import BotBusConnectorKit

/// 只读观察的数据来源。生产实现是 `CodexThreadReaderSource`（包着 `CodexThreadReader`），
/// 测试用假实现，不碰 SQLite。
public protocol CodexThreadSource: Sendable {
    func readSnapshot(agentId: String) throws -> (tasks: [TaskRecord], projects: [Project])
}

/// 把只读 reader 包成观察源。
///
/// `@unchecked`：reader 内部有个非 `@Sendable` 的时钟闭包（测试要注入固定时间），
/// 但它本身是不可变的值类型，每次读都重新打开数据库，没有共享可变状态。
public struct CodexThreadReaderSource: CodexThreadSource, @unchecked Sendable {
    private let reader: CodexThreadReader

    public init(_ reader: CodexThreadReader) { self.reader = reader }

    public func readSnapshot(agentId: String) throws -> (tasks: [TaskRecord], projects: [Project]) {
        (try reader.readTasks(agentId: agentId), try reader.readProjects(agentId: agentId))
    }
}

/// Codex 的只读观察者：持有轮询循环、数据源、间隔与连续失败计数，把结果喂给 `TaskStore`。
///
/// 从 UI 层（`AgentModel.pollCodex`）下沉到这里，是因为阶段二 b 之后同一个线程会同时有两个数据源；
/// 观察者只负责 `TaskSource.codex` 的**对账**，实时数据由连接器经 `TaskStore.claimLive(_:)` 接管，
/// 它拥有的 id 对账时会被整体跳过。
///
/// 产出的事件不经这里转发：`TaskStore` 自己有一条事件流，`RelayClient` 订阅那一条。
public actor CodexObserver {
    /// 这一轮能不能读：读不了时 `unavailable` 的文案直接进菜单栏。
    public enum Availability: Sendable {
        case ready(any CodexThreadSource)
        /// 例如"未找到 Codex 数据库：<路径>"。此时**不做对账**——读不到不等于任务没了。
        case unavailable(String)
    }

    /// 每轮之后 UI 需要知道的东西。
    public struct Status: Hashable, Sendable {
        /// 菜单栏那行 Codex 状态。
        public var text: String
        /// 待审批 / 待输入的任务数，来自 `TaskStore.pendingCount()`（不是本轮轮询结果）。
        public var pendingCount: Int
        /// 连续读库失败次数，成功即清零。
        public var consecutiveFailures: Int

        public init(text: String, pendingCount: Int = 0, consecutiveFailures: Int = 0) {
            self.text = text
            self.pendingCount = pendingCount
            self.consecutiveFailures = consecutiveFailures
        }
    }

    /// 连续失败多少次才把菜单栏文案改成报错。WAL 侧文件（-wal/-shm）缺失或损坏时只读打开会偶发失败，
    /// 单次不报警，免得侧文件抖一下就吓用户一跳。
    public static let failureThreshold = 3
    public static let defaultInterval: TimeInterval = 2
    public static let initialStatusText = "尚未读取 Codex"

    /// 每轮现取：设置里换了 Codex 目录，下一轮就该用新路径。
    public typealias AvailabilityProvider = @Sendable () -> Availability
    /// 每轮现取：设置里的轮询间隔改了不需要重启循环。间隔的合法区间由调用方保证（设置页限制在 1…30 秒）。
    public typealias IntervalProvider = @Sendable () async -> TimeInterval

    private static let log = Logger(subsystem: "io.botbus.agent", category: "codexobserver")

    private let store: TaskStore
    private let availability: AvailabilityProvider
    private let interval: IntervalProvider
    private let statusObserver: @Sendable (Status) -> Void

    public private(set) var status = Status(text: CodexObserver.initialStatusText)
    private var consecutiveFailures = 0
    private var loop: Task<Void, Never>?

    public init(store: TaskStore,
                availability: @escaping AvailabilityProvider,
                interval: @escaping IntervalProvider = { CodexObserver.defaultInterval },
                statusObserver: @escaping @Sendable (Status) -> Void = { _ in }) {
        self.store = store
        self.availability = availability
        self.interval = interval
        self.statusObserver = statusObserver
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

    /// 跑一轮。循环在用，设置页改完路径也可以直接催一轮，不必等下一个节拍。
    public func pollOnce() async {
        switch availability() {
        case .unavailable(let message):
            // 读不到库不是"这个来源报告了空列表"：一条都不能摘。
            consecutiveFailures = 0
            await report(text: message)
        case .ready(let source):
            await poll(source)
        }
    }

    private func poll(_ source: any CodexThreadSource) async {
        // 归属最终由 TaskStore 盖章，这里传当前 agentId 只是少一次重写；未配对时是空串。
        let agentId = await store.identity.agentId
        do {
            // SQLite 读取放到后台线程，actor 不被阻塞。
            let result = try await Task.detached(priority: .utility) {
                try source.readSnapshot(agentId: agentId)
            }.value
            // `controllable` 一律沿用数据源给的值（`CodexThreadReader` 按 spec 6.2 定：
            // 仅出现在 SQLite 里的桌面线程，非 running 时可以 resume 接管，所以是 true）。
            // 实时驱动中的线程根本走不到这里——它们归 `.live`，`reconcile` 整体跳过。
            await store.reconcile(source: .codex, tasks: result.tasks, projects: result.projects)
            consecutiveFailures = 0
            await report(text: "Codex：\(result.tasks.count) 个任务（7 天内）")
        } catch {
            consecutiveFailures += 1
            Self.log.error("codex poll failed (\(self.consecutiveFailures)): \(String(describing: error))")
            // 只有连续多次失败才改菜单栏文案，避免侧文件抖动造成误报。
            let text = consecutiveFailures >= Self.failureThreshold ? "读取 Codex 失败：\(error)" : status.text
            await report(text: text)
        }
    }

    private func report(text: String) async {
        status = Status(text: text, pendingCount: await store.pendingCount(),
                        consecutiveFailures: consecutiveFailures)
        statusObserver(status)
    }
}
