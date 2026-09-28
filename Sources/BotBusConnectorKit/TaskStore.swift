import Foundation
import os
import BotBusProtocol

/// 一个任务当前由谁说了算。
///
/// 阶段二 b 起，同一个 Codex 线程可能同时被两个数据源描述：只读的 SQLite 观察（`.observer`）
/// 与 app-server / hooks 的实时数据（`.live`）。实时优先，而且只读观察**无权**把实时拥有的 id
/// 当成"消失了"——`reconcile` 每 2 秒跑一次，那会变成每 2 秒一次 `taskRemoved`。
public enum TaskOwner: String, Hashable, Sendable {
    case observer
    case live
}

/// 汇总各连接器的任务：按来源对账、产出增量事件、决定通知。所有写入串行经过这个 actor。
///
/// 协议 v2：产出的一切（TaskRecord、Project、Snapshot.agents）都带本机的 `agentId`，
/// 快照里的 `agents` 恰好一个元素——自己。被用户关掉的 Connector 视同"什么都没报"。
///
/// 同步写入事件有两条出口：公开写方法的返回值（调用方与测试用）和 `events()` 的 `AsyncStream`
///（`RelayClient` 用）；后台系统授权诊断完成时只走事件流，并保存在后续快照里。
/// 流只允许一个订阅者，见 `events()`。
public actor TaskStore {
    public static let notifyDedupeInterval: TimeInterval = 30
    /// 同一个系统弹窗可能撞上多条失败任务；额外诊断通知按弹窗 id 全局去重十分钟。
    public static let systemPermissionNotifyDedupeInterval: TimeInterval = 600
    public static let maxRememberedSystemPermissionNotices = 200
    public static let maxProjects = 30
    /// 交还给 observer 之后的宽限期。只读观察落后于实时数据（Codex 要先把线程落盘），
    /// 这段时间里"观察报告中没有这个 id"不算它消失，否则刚跑完的任务会先消失再冒出来。
    public static let liveHandoffGrace: TimeInterval = 30
    /// 事件流的缓冲上限。订阅者落后太多时丢最旧的：重连会重发全量快照，陈旧的增量没有保留价值。
    public static let eventBufferLimit = 256
    /// 最多给多少个任务记产物（内存与 `artifacts.json` 同一个上限）。超了淘汰"最新一件产物最旧"的任务。
    public static let maxArtifactTasks = 200
    /// 产物改动后多久落盘。一次分享常常连着几件（截图 + 预览 + 缩略图），合并成一次写。
    public static let defaultArtifactSaveDelay: TimeInterval = 1
    /// app 用的产物持久化位置。测试一律注入临时文件或不持久化（`artifactsURL: nil`）。
    public static var defaultArtifactsURL: URL {
        LocalHookServer.defaultSupportDirectory.appendingPathComponent("artifacts.json")
    }
    /// 最多记多少个手机发起过的任务（`phone-tasks.json`），超了丢最早见到的。
    public static let maxPhoneStartedTasks = 500
    /// app 用的「手机发起过的任务」持久化位置，见 `PhoneTaskArchive`。
    public static var defaultPhoneTasksURL: URL {
        LocalHookServer.defaultSupportDirectory.appendingPathComponent("phone-tasks.json")
    }
    /// app 用的「开了自动批准的项目」持久化位置（协议 3.3），见 `AutoApproveArchive`。
    public static var defaultAutoApproveURL: URL {
        LocalHookServer.defaultSupportDirectory.appendingPathComponent("auto-approve.json")
    }

    private static let log = Logger(subsystem: "io.botbus.agent", category: "taskstore")

    /// "值得再提醒一次"的身份：状态，加上等待审批/输入时的请求 id（换了请求也要提醒）。
    private struct NotificationKey: Equatable {
        let status: TaskStatus
        let requestId: String?
    }

    /// 探测结果与启用开关。加锁的 class，菜单栏与设置页可以直接读写，不必穿过本 actor。
    public nonisolated let connectors: ConnectorRegistry

    public private(set) var identity: AgentIdentity

    private var tasks: [String: TaskRecord] = [:]
    private var projectsBySource: [TaskSource: [Project]] = [:]
    /// 哪些目录不算项目（协议 2.6）。和产物一样在 `stamped(_:)` 里统一打到外发的任务上，
    /// 连接器与观察者不感知；这些目录也不进 `mergedProjects()`。
    private var outsideProjects: OutsideProjectRule
    /// 开在 git worktree 里的会话归到主仓库（协议 2.7）。同样在 `stamped(_:)` 里统一改写外发的任务与项目，
    /// 连接器与观察者不感知，它们记的仍是真实的工作目录，续聊照旧在那里跑。
    private let worktrees: WorktreeResolver
    private var lastNotified: [String: (key: NotificationKey, at: Date)] = [:]
    /// 只有 reconcile 会写：某来源第一次全量对账是静默基线。
    private var syncedSources: Set<TaskSource> = []
    /// ACP 的通知基线按 agent 走（协议 2.13）：只有上一轮对账时就已建立基线的 agent，这一轮的变化才推通知。
    ///
    /// 哪些 agent 的基线就绪由 `AcpHub` 在每次 `reconcileAcp` 时告诉我们（它成功列过一次 `session/list`，
    /// 或者确定根本列不了）——只看"这一轮带来了任务"不行：重启后本机记录先到，第一次列表拉回来的一批已完成的
    /// 桌面会话会被逐条推成"任务完成"。每轮结束时整个换成"hub 报的就绪集合 ∩ 此刻启用的 agent"，于是
    /// 刚就绪的 agent 先静默一轮；停用、被藏起来、从发现结果里消失的 agent 自动出局，回来后重新静默一轮。
    /// 实时写入（`upsert`）不看这里。`performSetAcpConnectorEnabled` 关掉时也立刻摘掉。
    private var syncedAcpConnectors: Set<String> = []
    /// 只记非默认值：不在表里就是 `.observer`。
    private var owners: [String: TaskOwner] = [:]
    /// `releaseLive` 之后的交接宽限期，见 `liveHandoffGrace`。
    private var handoffDeadlines: [String: Date] = [:]
    private var eventContinuation: AsyncStream<Event>.Continuation?
    /// 订阅代际：老流终止时拿它认领自己，避免把新订阅者的出口一并清掉。
    private var eventSubscription = 0
    private let now: @Sendable () -> Date

    private var systemPermissionInspector: SystemPermissionInspector?
    private let systemPermissionInspectionTimeout: TimeInterval
    /// 与连接器记录分开保存，只属于当前这次 failed；重试、删除、换配对或关闭诊断时清掉。
    private var systemPermissionsByTask: [String: SystemPermissionNotice] = [:]
    private var systemPermissionInspections: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    private var systemPermissionNotifications: [String: Date] = [:]

    /// 任务 id → 产物（新的在前、≤ `TaskRecord.maxArtifacts`）。**和 `tasks` 分开存**：
    /// 连接器与观察者根本不知道产物这回事，它们的 upsert / reconcile 带来的记录没有 `artifacts`，
    /// 由 `stamped(_:)` 在写入与外发时统一合并，所以谁也覆盖不掉它。任务还不在 store 里时也照样记着，
    /// 任务出现（例如重启后观察者读到它）时自然合并上去。
    private var artifactsByTask: [String: [StoredArtifact]] = [:]
    private let artifactsURL: URL?
    private let artifactSaveDelay: TimeInterval
    private var pendingArtifactSave: Task<Void, Never>?

    /// 手机发起过的任务 id → 第一次见到的时间。`apply` 见到 `origin == .watch` 时记下，
    /// 之后任务的 origin 变回 `.desktop`（重启后由观察者读回）也照样认得。只给 Mac 菜单用，不进协议。
    private var phoneStarted: [String: String] = [:]
    private let phoneTasksURL: URL?
    private var pendingPhoneTasksSave: Task<Void, Never>?

    /// 开了「自动批准」的项目路径（协议 3.3，盖章后的 `projectPath`：worktree 记主仓库）。和产物一样在
    /// `stamped(_:)` 与 `mergedProjects()` 里打到外发的任务与项目上，连接器与观察者不感知；
    /// 连接器遇到审批时经 `autoApproves(taskId:workingDirectory:)` 来问。改了立刻落盘，重启后仍在。
    private var autoApproveProjects: Set<String> = []
    private let autoApproveURL: URL?

    /// - Parameters:
    ///   - artifactsURL: 产物持久化文件；nil = 只在内存里（测试默认）。app 传 `defaultArtifactsURL`。
    ///   - autoApproveURL: 自动批准的项目设置；nil = 只在内存里（测试默认）。app 传 `defaultAutoApproveURL`。
    public init(identity: AgentIdentity = AgentIdentity(),
                connectors: ConnectorRegistry = ConnectorRegistry(),
                artifactsURL: URL? = nil,
                phoneTasksURL: URL? = nil,
                autoApproveURL: URL? = nil,
                artifactSaveDelay: TimeInterval = TaskStore.defaultArtifactSaveDelay,
                outsideProjects: OutsideProjectRule = OutsideProjectRule(),
                worktrees: WorktreeResolver = WorktreeResolver(),
                systemPermissionInspector: SystemPermissionInspector? = nil,
                systemPermissionInspectionTimeout: TimeInterval = 10,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.identity = identity
        self.connectors = connectors
        self.outsideProjects = outsideProjects
        self.worktrees = worktrees
        self.artifactsURL = artifactsURL
        self.phoneTasksURL = phoneTasksURL
        self.autoApproveURL = autoApproveURL
        self.artifactSaveDelay = artifactSaveDelay
        self.systemPermissionInspector = systemPermissionInspector
        self.systemPermissionInspectionTimeout = systemPermissionInspectionTimeout
        self.now = now
        if let artifactsURL {
            let loaded = ArtifactArchive.load(from: artifactsURL, now: now())
            self.artifactsByTask = Self.trimArtifactTasks(loaded, limit: Self.maxArtifactTasks, keeping: nil).kept
        }
        if let phoneTasksURL {
            self.phoneStarted = PhoneTaskArchive.trimmed(PhoneTaskArchive.load(from: phoneTasksURL),
                                                         limit: Self.maxPhoneStartedTasks)
        }
        if let autoApproveURL { self.autoApproveProjects = AutoApproveArchive.load(from: autoApproveURL) }
    }

    /// 配对完成后把 Relay 分配的 agentId 填进来，并给已存的任务与项目重新盖章。
    /// 调用方随后会新建 RelayClient，连上时自然会发一份带新归属的全量快照，这里不再额外产出事件。
    public func setAgentId(_ agentId: String) {
        guard identity.agentId != agentId else { return }
        identity.agentId = agentId
        _ = clearSystemPermissionDiagnostics()
        tasks = tasks.mapValues { stamped($0) }
        projectsBySource = projectsBySource.mapValues { $0.map { stamped($0) } }
    }

    /// app 在配对/诊断开关/退出时装配或移除检查器。换配置会使在途结果失效，避免旧配对的截图外发。
    public func setSystemPermissionInspector(_ inspector: SystemPermissionInspector?) {
        systemPermissionInspector = inspector
        publish(clearSystemPermissionDiagnostics())
    }

    // MARK: - 不在项目中（协议 2.6）

    /// 「不在项目中」的新任务在哪里跑：`startTask.projectPath` 为空时的去处。
    public var homeDirectory: String { outsideProjects.homeDirectory }

    /// 某来源的默认工作区变了（OpenClaw 读配置时报上来）。任务的 `outsideProject` 与项目列表都可能跟着变，
    /// 变了就补一份全量快照——项目列表只随快照更新。
    @discardableResult
    public func setAgentWorkspace(_ path: String?, for source: TaskSource) -> [Event] {
        guard outsideProjects.agentWorkspaces[source] != path else { return [] }
        let before = snapshotKey()
        outsideProjects.agentWorkspaces[source] = path
        tasks = tasks.mapValues { stamped($0) }
        guard snapshotKey() != before else { return [] }
        let events = [Event.snapshot(snapshot())]
        publish(events)
        return events
    }

    private func snapshotKey() -> ([TaskRecord], [Project]) { (visibleTasks(), mergedProjects()) }

    /// 手机新建项目时的存放目录（协议 2.6），随快照的 `AgentInfo.projectsRoot` 报给手机。nil = 不接受新建项目。
    public var projectsRoot: String? { outsideProjects.projectsRoot }

    /// 设置里改了新项目的存放目录。这个目录本身算「不在项目中」，所以任务要重新打标；
    /// 手机要从快照里看到新目录，总是补一份全量快照。
    @discardableResult
    public func setProjectsRoot(_ path: String?) -> [Event] {
        guard outsideProjects.projectsRoot != path else { return [] }
        outsideProjects.projectsRoot = path
        tasks = tasks.mapValues { stamped($0) }
        let events = [Event.snapshot(snapshot())]
        publish(events)
        return events
    }

    // MARK: - 自动批准（协议 3.3）

    /// 某个工作目录归到哪个项目下记自动批准：worktree 归主仓库，与 `stamped(_:)` 同一套规则。
    /// 「不在项目中」的目录（空路径、主目录等）返回 nil——它们开不了自动批准。
    public func autoApproveProject(forWorkingDirectory path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let project = worktrees.projectRoot(for: trimmed) ?? trimmed
        return outsideProjects.contains(project) ? nil : project
    }

    /// 打开或关掉一个项目的自动批准（`project` 是盖章后的 `projectPath`）。先落盘再补一份全量快照——
    /// 项目只随快照更新，任务上的 `autoApprove` 也一并带过去。值没变时什么都不做。
    @discardableResult
    public func setAutoApprove(_ enabled: Bool, project: String) -> [Event] {
        guard !project.isEmpty, autoApproveProjects.contains(project) != enabled else { return [] }
        if enabled { autoApproveProjects.insert(project) } else { autoApproveProjects.remove(project) }
        if let autoApproveURL { AutoApproveArchive.save(autoApproveProjects, to: autoApproveURL) }
        tasks = tasks.mapValues { stamped($0) }
        let events = [Event.snapshot(snapshot())]
        publish(events)
        return events
    }

    /// 这个项目开着自动批准没有。Mac 菜单与测试用；连接器用 `autoApproves(taskId:workingDirectory:)`。
    public func isAutoApproveEnabled(project: String) -> Bool { autoApproveProjects.contains(project) }

    /// 连接器遇到审批时问：这个任务所在的项目开着自动批准没有。store 里有这个任务就看它盖过章的 `autoApprove`；
    /// 还没有（新任务的第一轮，连接器还没 upsert）就按工作目录归到项目再查。
    /// 只回答"项目开没开"，是不是手机驱动的轮次由连接器自己判断。
    public func autoApproves(taskId: String, workingDirectory: String?) -> Bool {
        if let task = tasks[taskId] { return task.autoApprove == true }
        guard let workingDirectory, let project = autoApproveProject(forWorkingDirectory: workingDirectory) else {
            return false
        }
        return autoApproveProjects.contains(project)
    }

    // MARK: - 事件流

    /// 增量事件的出口。**只允许一个订阅者**（`RelayClient`）：再调一次会终止上一条流并接管，
    /// 这样重新配对换掉 RelayClient 时事件不会分叉，也不会有人偷偷截走另一半。
    ///
    /// 没有订阅者时事件直接丢弃，不攒历史：客户端连上时拿到的是全量快照，补发陈旧的增量只会添乱。
    public func events() -> AsyncStream<Event> {
        eventSubscription += 1
        let generation = eventSubscription
        eventContinuation?.finish()
        var captured: AsyncStream<Event>.Continuation!
        let stream = AsyncStream<Event>(bufferingPolicy: .bufferingNewest(Self.eventBufferLimit)) { captured = $0 }
        captured.onTermination = { [weak self] _ in
            Task { await self?.forgetSubscription(generation) }
        }
        eventContinuation = captured
        return stream
    }

    /// 主动推一份全量快照。协议里没有"Connector 可用性变了"这类事件，只能靠快照兜住。
    @discardableResult
    public func broadcastSnapshot() -> [Event] {
        let events = [Event.snapshot(snapshot())]
        publish(events)
        return events
    }

    private func forgetSubscription(_ generation: Int) {
        guard eventSubscription == generation else { return }
        eventContinuation = nil
    }

    private func publish(_ events: [Event]) {
        guard let eventContinuation, !events.isEmpty else { return }
        for event in events { eventContinuation.yield(event) }
    }

    // MARK: - 所有权

    public func owner(of id: String) -> TaskOwner { owners[id] ?? .observer }

    /// 把一个 id 交给实时数据源：从此 `reconcile` 对它既不 upsert 也不 remove。
    /// 允许在任务还不存在时先声明（`startTask` 先 claim 再等第一条实时数据）。
    public func claimLive(_ id: String) {
        owners[id] = .live
        handoffDeadlines.removeValue(forKey: id)
    }

    /// 交还给只读观察。**不是简单地翻回 `.observer`**：再给一段 `liveHandoffGrace`，
    /// 期间"观察没报这个 id"不算它消失——SQLite 往往要几轮才追上实时数据，
    /// 少了这段宽限，命令一结束任务就会先被摘掉、下一轮再冒出来，手机上看到的就是闪一下。
    /// 观察真的报到它（或宽限到期）才算交接完成。
    public func releaseLive(_ id: String) {
        guard owners.removeValue(forKey: id) == .live, tasks[id] != nil else { return }
        handoffDeadlines[id] = now().addingTimeInterval(Self.liveHandoffGrace)
    }

    /// 用某个来源的全量列表对账：变化的 upsert，消失的 remove。该来源首次对账只建立基线，不发通知。
    /// 来源对应的 Connector 被禁用时，无论传进来什么都按"该来源报告了空列表"处理。
    /// 由实时数据源拥有（`TaskOwner.live`）的 id 完全不受影响。
    ///
    /// `.acp` 走这里等于"没有哪个 agent 的基线就绪"：全部静默。生产代码用 `reconcileAcp`。
    @discardableResult
    public func reconcile(source: TaskSource, tasks incoming: [TaskRecord], projects incomingProjects: [Project]) -> [Event] {
        let events = performReconcile(source: source, tasks: incoming, projects: incomingProjects)
        publish(events)
        return events
    }

    /// `.acp` 的全量对账（`AcpHub.reconcile()` 调）。`baselined` 是列表基线已就绪的 agent，见 `syncedAcpConnectors`。
    @discardableResult
    public func reconcileAcp(tasks incoming: [TaskRecord], projects incomingProjects: [Project],
                             baselined: Set<String>) -> [Event] {
        let events = performReconcile(source: .acp, tasks: incoming, projects: incomingProjects, acpBaselined: baselined)
        publish(events)
        return events
    }

    private func performReconcile(source: TaskSource, tasks incoming: [TaskRecord], projects incomingProjects: [Project],
                                  acpBaselined: Set<String> = []) -> [Event] {
        // `.acp` 这一层的启用恒为 true（每个 agent 的开关在 `isEnabled(_ task:)` 里单独判），
        // 这里只是沿用"来源级"判断给 reconcile 的整体短路用，不代表按 agent 过滤——那一步在下面的
        // `isEnabled($0)` 里做。
        let enabled = isEnabled(source)
        // 项目先盖章：已删 worktree 按同名归回主仓库时，要先见过这一轮报上来的项目目录。
        let mineProjects = enabled ? incomingProjects.map { stamped($0) } : []
        let mine = enabled ? incoming.filter { $0.source == source && isEnabled($0) }.map { stamped($0) } : []

        let firstSync = !syncedSources.contains(source)
        // 禁用期间不留基线：重新启用后的第一次对账仍是静默的，不会把积压状态一次性推成通知。
        if enabled { syncedSources.insert(source) } else { syncedSources.remove(source) }

        var events: [Event] = []
        let incomingIds = Set(mine.map(\.id))
        for task in mine {
            // 实时数据拥有的 id 轮不到只读观察改写。
            guard owner(of: task.id) == .observer else { continue }
            // ACP 按 agent 单独判：上一轮结束时它的基线已就绪才推（见 `syncedAcpConnectors`）。
            let notifyAllowed = source == .acp
                ? !firstSync && syncedAcpConnectors.contains(task.connectorId ?? "")
                : !firstSync
            events.append(contentsOf: apply(task, notifyAllowed: notifyAllowed))
            // 观察真的看到了它 → 交接完成，下一轮起缺席就是真的消失。
            handoffDeadlines.removeValue(forKey: task.id)
        }
        if source == .acp {
            // 整个换掉而不是往里加：没就绪、已停用、从注册表条目里消失（没发现到、被藏起来、被容量挤掉）的都出局。
            syncedAcpConnectors = acpBaselined.filter { connectors.isAcpEnabled($0) }
        }
        for (id, task) in tasks where task.source == source && !incomingIds.contains(id) {
            // 缺席的 id：live 拥有的不算消失；刚交还的在宽限期内也不算。
            guard owner(of: id) == .observer else { continue }
            if let deadline = handoffDeadlines[id] {
                guard now() >= deadline else { continue }
                handoffDeadlines.removeValue(forKey: id)
            }
            tasks.removeValue(forKey: id)
            clearSystemPermission(for: id)
            lastNotified.removeValue(forKey: id)
            owners.removeValue(forKey: id)
            events.append(.taskRemoved(id))
        }
        // 协议没有单独的项目事件，Relay 只在收到全量 snapshot 时才更新 projects；
        // 所以合并后的项目列表一变就补发一份全量快照，否则手机端的"最近项目"会停在连上那一刻。
        let before = mergedProjects()
        projectsBySource[source] = mineProjects
        if mergedProjects() != before { events.append(.snapshot(snapshot())) }
        return events
    }

    /// 单个任务的实时更新（阶段二 b 的 app-server 通知会用）。不影响 reconcile 的首次基线判断。
    /// 不改所有权：要挡住只读观察，调用方得先 `claimLive(_:)`。
    @discardableResult
    ///
    /// - Parameter notify: false = 静默写入（只发 `taskUpdated`，不推通知）。给"整表灌进来"的场合用，
    ///   例如 OpenClaw 每次连上 Gateway 的首屏——那是基线，不是变化，逐条推送会把几十条旧会话一次性发到手机上。
    public func upsert(_ task: TaskRecord, notify: Bool = true) -> [Event] {
        guard isEnabled(task) else { return [] }
        let events = apply(stamped(task), notifyAllowed: notify)
        publish(events)
        return events
    }

    /// 显式删除，同时把所有权与交接状态一并清掉。
    @discardableResult
    public func remove(id: String) -> [Event] {
        clearSystemPermission(for: id)
        guard tasks.removeValue(forKey: id) != nil else { return [] }
        lastNotified.removeValue(forKey: id)
        owners.removeValue(forKey: id)
        handoffDeadlines.removeValue(forKey: id)
        let events = [Event.taskRemoved(id)]
        publish(events)
        return events
    }

    public func task(id: String) -> TaskRecord? { tasks[id] }

    /// 把一个不改变任务状态的事件推进事件流。目前只有 `taskMessages`——它是一次查询的结果，
    /// 不属于任何任务的状态，所以不走 upsert，也不该影响对账。
    public func emit(_ event: Event) {
        publish([event])
    }

    /// 翻某个 Connector 的启用开关。关掉时把该来源当作报告了空列表对账，并且总要补一份全量快照——
    /// `ConnectorInfo.enabled` 变了，客户端只能从快照里看到。
    @discardableResult
    public func setConnectorEnabled(_ connector: ConnectorKind, enabled: Bool) -> [Event] {
        let events = performSetConnectorEnabled(connector, enabled: enabled)
        publish(events)
        return events
    }

    private func performSetConnectorEnabled(_ connector: ConnectorKind, enabled: Bool) -> [Event] {
        let changed = connectors.setEnabled(enabled, for: connector)
        var events: [Event] = []
        if changed, !enabled, let source = connector.taskSource {
            // 停用 = "这台机器上这个来源什么都没有了"，实时任务也不例外：先收回所有权，
            // 对账才有权把它们摘掉，重新启用时也不会剩下没人认领的 id。
            let prefix = "\(source.rawValue):"
            for id in owners.keys.filter({ $0.hasPrefix(prefix) }) { owners.removeValue(forKey: id) }
            for id in handoffDeadlines.keys.filter({ $0.hasPrefix(prefix) }) { handoffDeadlines.removeValue(forKey: id) }
            // 里面可能也会产出一份快照（项目列表变了），去掉重复的，末尾统一补一份最新的。
            events += performReconcile(source: source, tasks: [], projects: []).filter { $0.kind != .snapshot }
        }
        events.append(.snapshot(snapshot()))
        return events
    }

    /// 翻一个 ACP agent 的开关（协议 2.13）。关掉时直接摘掉它的全部任务（实时的也收回所有权），并总要补一份全量快照。
    @discardableResult
    public func setAcpConnectorEnabled(_ id: String, enabled: Bool) -> [Event] {
        let events = performSetAcpConnectorEnabled(id, enabled: enabled)
        publish(events)
        return events
    }

    private func performSetAcpConnectorEnabled(_ id: String, enabled: Bool) -> [Event] {
        var events: [Event] = []
        if connectors.setAcpEnabled(enabled, for: id), !enabled {
            // 退出静默基线：下次重新启用时这个 agent 要像第一次被看到一样重新静默一轮，
            // 不然积压的旧状态会被当成"变化"批量推通知（见 `syncedAcpConnectors` 的注释）。
            syncedAcpConnectors.remove(id)
            let prefix = "acp:\(id):"
            for taskId in tasks.keys.filter({ $0.hasPrefix(prefix) }).sorted() {
                tasks.removeValue(forKey: taskId)
                owners.removeValue(forKey: taskId)
                handoffDeadlines.removeValue(forKey: taskId)
                lastNotified.removeValue(forKey: taskId)
                clearSystemPermission(for: taskId)
                events.append(.taskRemoved(taskId))
            }
        }
        // 项目不按 agent 记 connectorId（`Project` 没有这个字段），这里没法按 agent 过滤 ACP 项目列表；
        // 开关翻转之后 app 会调 `AcpHub.applyEnabledState()`，它只用"已启用 agent"的任务重算 `.acp` 项目再对账，
        // 本方法不用兜底。
        events.append(.snapshot(snapshot()))
        return events
    }

    /// 执行一条来自客户端的命令。本阶段只实现 `setConnectorEnabled`，其余回 ok:false。
    /// 返回的事件由调用方发给 Relay（`commandResult` 由 RelayClient 自己回，不在这里）。
    public func handle(_ command: Command) -> (result: CommandResult, events: [Event]) {
        let finishedAt = ProtocolJSON.timestamp(now())
        func failure(_ message: String) -> (CommandResult, [Event]) {
            (CommandResult(commandId: command.id, ok: false, error: message, finishedAt: finishedAt), [])
        }
        // Relay 按 agentId 路由，但迟到的帧与将来的 bug 都可能把别人的命令送到这里。
        guard command.agentId == identity.agentId else {
            return failure("命令的目标电脑不是本机")
        }
        switch command.kind {
        case .setConnectorEnabled:
            guard let payload = command.setConnectorEnabled else { return failure("缺少 setConnectorEnabled 载荷") }
            if payload.connector == .acp {
                guard let id = payload.connectorId, connectors.acpIds.contains(id) else {
                    return failure("本机没有这个 ACP agent：\(payload.connectorId ?? "")")
                }
                let events = performSetAcpConnectorEnabled(id, enabled: payload.enabled)
                publish(events)
                return (CommandResult(commandId: command.id, ok: true, finishedAt: finishedAt), events)
            }
            guard connectors.kinds.contains(payload.connector) else {
                return failure("本机没有 \(payload.connector.rawValue) 连接器")
            }
            let events = performSetConnectorEnabled(payload.connector, enabled: payload.enabled)
            publish(events)
            return (CommandResult(commandId: command.id, ok: true, finishedAt: finishedAt), events)
        case .startTask, .followUp, .approve, .interrupt, .fetchMessages, .fetchFile, .fetchChanges, .remoteControl:
            // 这些都归 CommandDispatcher（要连接器或 MessageReader）；走到这里说明调用方绕过了它。
            return failure("这个版本的 Agent 还不支持 \(command.kind.rawValue)")
        }
    }

    /// 协议 v2 的快照：`agents` 恰好一个元素（自己，online 固定 true），任务与项目只含本机的、
    /// 且只含已启用 Connector 的。`recentResults` 与 `seq` 由 Relay 维护，这里留空。
    public func snapshot() -> Snapshot {
        // 过期的产物（预览 2 小时、文件 7 天）在这里顺手摘掉。摘掉产生的 taskUpdated 照常进事件流，
        // 快照调用方不必关心——它拿到的快照本身已经是摘完的。
        publish(performPruneExpiredArtifacts())
        let generatedAt = ProtocolJSON.timestamp(now())
        let visible = visibleTasks()
        var counts: [ConnectorRef: Int] = [:]
        for task in visible { counts[task.connectorRef, default: 0] += 1 }
        let me = AgentInfo(agentId: identity.agentId, name: identity.name, platform: .macos, online: true,
                           lastSeenAt: generatedAt, appVersion: identity.appVersion,
                           connectors: connectors.connectors(taskCounts: counts),
                           projectsRoot: outsideProjects.projectsRoot)
        return Snapshot(agents: [me], tasks: visible, projects: mergedProjects(),
                        recentResults: [], seq: 0, generatedAt: generatedAt)
    }

    /// 快照里处于待处理状态的任务数（菜单栏角标用）。和 `snapshot()` 共用同一套可见性过滤，
    /// 所以它只反映 store 的现状，和某一次轮询读到了什么无关。
    public func pendingCount() -> Int {
        visibleTasks().lazy.filter { $0.status == .waitingApproval || $0.status == .waitingInput }.count
    }

    // MARK: - 产物（协议 2.3，spec 3.4）

    /// 一次产物写入的结果。`displaced` 是被这次写入挤掉的产物（同源预览被替换、超过上限被淘汰、
    /// 整个任务被挤出 200 个的名额）——里面的预览还在转发，调用方要负责去停。
    public struct ArtifactChange: Sendable {
        public var events: [Event]
        public var displaced: [Artifact]
    }

    /// 给任务挂一件产物，放在最前面。同 id 的旧条目被替换；`originKey` 非 nil（预览，`PreviewOrigin.artifactOriginKey`）时，
    /// 同一任务同一端口/目录的旧预览也被替换。超过 `TaskRecord.maxArtifacts` 的最旧几件被挤掉。
    /// 任务已在 store 里时产生 `taskUpdated`。标题在这里按协议上限截断，调用方不必各自记得。
    @discardableResult
    public func addArtifact(taskId: String, _ artifact: Artifact, originKey: String? = nil) -> ArtifactChange {
        var incoming = artifact
        if incoming.title.count > Artifact.maxTitleLength {
            incoming.title = String(incoming.title.prefix(Artifact.maxTitleLength))
        }
        let key = originKey
        var displaced: [Artifact] = []
        var list = artifactsByTask[taskId] ?? []
        list.removeAll { stored in
            let sameId = stored.artifact.id == incoming.id
            let sameOrigin = key != nil && stored.artifact.kind == .preview && stored.origin == key
            if sameOrigin && !sameId { displaced.append(stored.artifact) }
            return sameId || sameOrigin
        }
        list.insert(StoredArtifact(artifact: incoming, origin: key), at: 0)
        if list.count > TaskRecord.maxArtifacts {
            displaced += list[TaskRecord.maxArtifacts...].map(\.artifact)
            list = Array(list.prefix(TaskRecord.maxArtifacts))
        }
        artifactsByTask[taskId] = list

        let trimmed = Self.trimArtifactTasks(artifactsByTask, limit: Self.maxArtifactTasks, keeping: taskId)
        artifactsByTask = trimmed.kept
        var events = restamp(taskId)
        for (evictedId, evicted) in trimmed.evicted {
            displaced += evicted.map(\.artifact)
            events += restamp(evictedId)
        }
        scheduleArtifactSave()
        publish(events)
        return ArtifactChange(events: events, displaced: displaced)
    }

    /// 从任务上摘掉一件产物（停止分享预览、agent 撤回）。不存在就什么都不做。
    @discardableResult
    public func removeArtifact(taskId: String, id: String) -> [Event] {
        guard var list = artifactsByTask[taskId], list.contains(where: { $0.artifact.id == id }) else { return [] }
        list.removeAll { $0.artifact.id == id }
        artifactsByTask[taskId] = list.isEmpty ? nil : list
        let events = restamp(taskId)
        scheduleArtifactSave()
        publish(events)
        return events
    }

    /// 某任务当前的产物，新的在前。没有就是空数组（对外的 `TaskRecord.artifacts` 此时是 nil）。
    public func artifacts(taskId: String) -> [Artifact] {
        artifactsByTask[taskId]?.map(\.artifact) ?? []
    }

    /// 摘掉所有已过期的产物。`snapshot()` 会顺手做一次；app 另有定时器调它，
    /// 保证没人要快照时过期的预览也会从手机上消失。
    @discardableResult
    public func pruneExpiredArtifacts() -> [Event] {
        let events = performPruneExpiredArtifacts()
        publish(events)
        return events
    }

    /// 立刻把待写的产物（与手机任务记录）落盘（app 退出前调用）。没有未落盘的改动就什么都不写。
    public func flushArtifacts() {
        if let pending = pendingPhoneTasksSave {
            pending.cancel()
            savePhoneTasksNow()
        }
        guard let pending = pendingArtifactSave else { return }
        pending.cancel()
        saveArtifactsNow()
    }

    // MARK: - 手机发起的任务

    /// 手机发起过、且当前还在 store 里（来源已启用）的任务，按 updatedAt 降序。Mac 菜单的 Agent 详情用。
    public func phoneStartedTasks() -> [TaskRecord] {
        visibleTasks().filter { phoneStarted[$0.id] != nil }
    }

    private func rememberPhoneStarted(_ taskId: String) {
        guard phoneStarted[taskId] == nil else { return }
        phoneStarted[taskId] = ProtocolJSON.timestamp(now())
        phoneStarted = PhoneTaskArchive.trimmed(phoneStarted, limit: Self.maxPhoneStartedTasks)
        guard phoneTasksURL != nil, pendingPhoneTasksSave == nil else { return }
        let delay = artifactSaveDelay
        pendingPhoneTasksSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.savePhoneTasksNow()
        }
    }

    private func savePhoneTasksNow() {
        pendingPhoneTasksSave = nil
        guard let phoneTasksURL else { return }
        PhoneTaskArchive.save(phoneStarted, to: phoneTasksURL)
    }

    private func performPruneExpiredArtifacts() -> [Event] {
        let current = now()
        var events: [Event] = []
        var changed = false
        for (taskId, list) in artifactsByTask {
            let kept = list.filter { !ArtifactArchive.isExpired($0.artifact, now: current) }
            guard kept.count != list.count else { continue }
            artifactsByTask[taskId] = kept.isEmpty ? nil : kept
            changed = true
            events += restamp(taskId)
        }
        if changed { scheduleArtifactSave() }
        return events
    }

    private func artifactList(for taskId: String) -> [Artifact]? {
        guard let list = artifactsByTask[taskId], !list.isEmpty else { return nil }
        return list.map(\.artifact)
    }

    /// 产物变了之后把已存的任务重新盖章。已停用来源的任务只改不发，与 upsert 的可见性一致。
    private func restamp(_ taskId: String) -> [Event] {
        guard let current = tasks[taskId] else { return [] }
        let updated = stamped(current)
        guard updated != current else { return [] }
        tasks[taskId] = updated
        guard isEnabled(updated) else { return [] }
        return [.taskUpdated(updated)]
    }

    /// 任务数超过上限时，按"最新一件产物的 createdAt"淘汰最旧的任务（`keeping` 除外）。
    public static func trimArtifactTasks(_ artifacts: [String: [StoredArtifact]], limit: Int,
                                  keeping: String?) -> (kept: [String: [StoredArtifact]], evicted: [(String, [StoredArtifact])]) {
        guard artifacts.count > limit else { return (artifacts, []) }
        let ranked = artifacts
            .filter { $0.key != keeping }
            .sorted { lhs, rhs in
                let left = lhs.value.first?.artifact.createdAt ?? ""
                let right = rhs.value.first?.artifact.createdAt ?? ""
                return left == right ? lhs.key < rhs.key : left < right
            }
        var kept = artifacts
        var evicted: [(String, [StoredArtifact])] = []
        for (taskId, list) in ranked where kept.count > limit {
            kept.removeValue(forKey: taskId)
            evicted.append((taskId, list))
        }
        return (kept, evicted)
    }

    private func scheduleArtifactSave() {
        guard artifactsURL != nil, pendingArtifactSave == nil else { return }
        let delay = artifactSaveDelay
        pendingArtifactSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.saveArtifactsNow()
        }
    }

    private func saveArtifactsNow() {
        pendingArtifactSave = nil
        guard let artifactsURL else { return }
        ArtifactArchive.save(artifactsByTask, to: artifactsURL)
    }

    // MARK: - 内部

    /// 已启用来源的任务，按 updatedAt 降序。
    /// 时间戳是秒精度，同一秒的任务很常见；用 id 作次序键保证输出确定。
    private func visibleTasks() -> [TaskRecord] {
        tasks.values
            .filter { isEnabled($0) }
            .sorted { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }
    }

    private func isEnabled(_ source: TaskSource) -> Bool {
        guard let kind = ConnectorKind(source) else { return true }
        return connectors.isEnabled(kind)
    }

    /// 这条任务现在能不能进快照、接写入。ACP 任务看它自己那个 agent 的开关（协议 2.13）。
    private func isEnabled(_ task: TaskRecord) -> Bool {
        guard task.source == .acp else { return isEnabled(task.source) }
        return connectors.isAcpEnabled(task.connectorId ?? "")
    }

    /// 归属一律以本机为准：连接器（以及将来的 app-server 推送）不该有能力把任务记到别的电脑名下。
    /// 产物也在这里合并：连接器带来的 `artifacts`（通常是 nil）一律被 store 自己记的那份顶掉。
    /// 自动批准（协议 3.3）同理，按盖章后的 `projectPath` 查，只写 true 或 nil，「不在项目中」的永远 nil。
    /// `outsideProject` 同理，由本机规则决定，只写 true 或 nil（协议要求在项目里时省略这个键）。
    /// worktree（协议 2.7）也在这里：`projectPath` 换成主仓库，真实工作目录挪进 `worktreePath`。
    /// 工作目录取 `worktreePath ?? projectPath`，所以对盖过章的记录再盖一次结果不变。
    private func stamped(_ task: TaskRecord) -> TaskRecord {
        let artifacts = artifactList(for: task.id)
        let systemPermission = task.status == .failed ? systemPermissionsByTask[task.id] : nil
        let workingDirectory = task.workingDirectory
        let root = worktrees.projectRoot(for: workingDirectory)
        let projectPath = root ?? workingDirectory
        let projectName = root.map(Self.lastPathComponent) ?? task.projectName
        let worktreePath = root == nil ? nil : workingDirectory
        let outside: Bool? = outsideProjects.contains(projectPath) ? true : nil
        let autoApprove: Bool? = outside == nil && autoApproveProjects.contains(projectPath) ? true : nil
        guard task.agentId != identity.agentId || task.artifacts != artifacts || task.outsideProject != outside
                || task.projectPath != projectPath || task.projectName != projectName
                || task.worktreePath != worktreePath || task.systemPermission != systemPermission
                || task.autoApprove != autoApprove else { return task }
        var copy = task
        copy.agentId = identity.agentId
        copy.artifacts = artifacts
        copy.systemPermission = systemPermission
        copy.outsideProject = outside
        copy.autoApprove = autoApprove
        copy.projectPath = projectPath
        copy.projectName = projectName
        copy.worktreePath = worktreePath
        return copy
    }

    /// 连接器报的最近项目里也有 worktree 目录，同样归到主仓库；`mergedProjects()` 再按主仓库去重。
    private func stamped(_ project: Project) -> Project {
        let root = worktrees.projectRoot(for: project.path)
        guard project.agentId != identity.agentId || root != nil else { return project }
        var copy = project
        copy.agentId = identity.agentId
        if let root {
            copy.path = root
            copy.name = Self.lastPathComponent(root)
        }
        return copy
    }

    private static func lastPathComponent(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    private func apply(_ task: TaskRecord, notifyAllowed: Bool) -> [Event] {
        // id 必须带来源前缀，否则不同来源会在同一个字典键上互相覆盖。
        // 这里不能 assertionFailure：upsert 是 public，Debug 构建下一个畸形 id 就会 trap 打死菜单栏进程；
        // 记一条告警后丢弃即可，宁可少一条任务也不要整个 Agent 消失。
        guard task.id.hasPrefix("\(task.source.rawValue):") else {
            Self.log.warning("丢弃 id 前缀不匹配的任务：\(task.id, privacy: .public)，应以 \(task.source.rawValue, privacy: .public): 开头")
            return []
        }
        let previous = tasks[task.id]
        guard previous != task else { return [] }
        if task.status != .failed { clearSystemPermission(for: task.id) }
        tasks[task.id] = task
        if task.origin == .watch { rememberPhoneStarted(task.id) }
        var events: [Event] = [.taskUpdated(task)]
        if notifyAllowed, Self.notificationKey(previous) != Self.notificationKey(task),
           let notify = notification(for: task) {
            events.append(.notify(notify))
        }
        // 初次 reconcile 与静默恢复不扫描；同一次 failed 的文字/时间变化也不重复扫描。
        if notifyAllowed, task.status == .failed, previous?.status != .failed {
            scheduleSystemPermissionInspection(for: task.id)
        }
        return events
    }

    private func clearSystemPermission(for taskId: String) {
        systemPermissionInspections.removeValue(forKey: taskId)?.task.cancel()
        systemPermissionsByTask.removeValue(forKey: taskId)
    }

    private func clearSystemPermissionDiagnostics() -> [Event] {
        for inspection in systemPermissionInspections.values { inspection.task.cancel() }
        systemPermissionInspections.removeAll()
        let affected = Array(systemPermissionsByTask.keys)
        systemPermissionsByTask.removeAll()
        systemPermissionNotifications.removeAll()
        return affected.flatMap { restamp($0) }
    }

    private func scheduleSystemPermissionInspection(for taskId: String) {
        guard let inspector = systemPermissionInspector else { return }
        let id = UUID()
        let timeout = systemPermissionInspectionTimeout
        let inspection = Task { [weak self] in
            let notice = await inspectSystemPermission(using: inspector, timeout: timeout)
            await self?.finishSystemPermissionInspection(notice, taskId: taskId, inspectionId: id)
        }
        systemPermissionInspections[taskId] = (id, inspection)
    }

    private func finishSystemPermissionInspection(_ notice: SystemPermissionNotice?, taskId: String,
                                                 inspectionId: UUID) {
        guard systemPermissionInspections[taskId]?.id == inspectionId else { return }
        systemPermissionInspections.removeValue(forKey: taskId)
        // 这里必须按任务判（ACP 要看它自己那个 agent 的开关），`isEnabled(task.source)` 对 `.acp`
        // 恒为 true（kind 级开关常开），会把已关掉的 agent 的失败任务也算进来。
        guard let notice, let task = tasks[taskId], task.status == .failed, isEnabled(task) else { return }
        systemPermissionsByTask[taskId] = notice
        var events = restamp(taskId)
        if let notification = systemPermissionNotification(for: notice, taskId: taskId) {
            events.append(.notify(notification))
        }
        publish(events)
    }

    /// 命令在创建任务之前失败时也提醒手机。没有任务 ID 的通知仍可展示；点开只进入 App 首页。
    public func notifySystemPermission(_ notice: SystemPermissionNotice, taskId: String?, agentId: String) {
        guard !agentId.isEmpty, identity.agentId == agentId,
              let notification = systemPermissionNotification(for: notice, taskId: taskId ?? "") else { return }
        publish([.notify(notification)])
    }

    private func systemPermissionNotification(for notice: SystemPermissionNotice, taskId: String) -> Notify? {
        let current = now()
        systemPermissionNotifications = systemPermissionNotifications.filter {
            current.timeIntervalSince($0.value) < Self.systemPermissionNotifyDedupeInterval
        }
        guard systemPermissionNotifications[notice.id] == nil else { return nil }
        systemPermissionNotifications[notice.id] = current
        if systemPermissionNotifications.count > Self.maxRememberedSystemPermissionNotices,
           let oldest = systemPermissionNotifications.filter({ $0.key != notice.id })
            .min(by: { $0.value < $1.value })?.key {
            systemPermissionNotifications.removeValue(forKey: oldest)
        }
        let screenshot = notice.screenshot == nil ? "" : " 可在 App 中查看截图。"
        return Notify(taskId: taskId, category: .taskFailed, title: "电脑需要系统授权",
                      body: "任务失败后检测到系统授权弹窗，请到电脑屏幕上查看并处理。" + screenshot,
                      requestId: notice.id)
    }

    /// 此刻电脑上是不是有只有人能填的东西在等（密码框聚焦 → Secure Input 打开）。
    /// 由 app 注入；没注入时自动开启远程操作这条路整体不生效。
    public func setRemoteControlProbe(_ probe: (@Sendable () -> Bool)?) {
        remoteControlProbe = probe
    }

    /// 上面那条成立时触发，由 app 去开远程操作并把预览挂到这个任务上。
    public func setRemoteControlTrigger(_ trigger: (@Sendable (String) -> Void)?) {
        onRemoteControlNeeded = trigger
    }

    private static func notificationKey(_ task: TaskRecord?) -> NotificationKey? {
        guard let task else { return nil }
        let awaiting = task.status == .waitingApproval || task.status == .waitingInput
        return NotificationKey(status: task.status, requestId: awaiting ? task.pendingRequest?.id : nil)
    }

    private var remoteControlProbe: (@Sendable () -> Bool)?
    private var onRemoteControlNeeded: (@Sendable (String) -> Void)?

    /// 只在进入四种值得打扰用户的状态时通知；同一任务同一身份（状态 + 请求）30 秒内不重复。
    private func notification(for task: TaskRecord) -> Notify? {
        let current = now()
        guard let key = Self.notificationKey(task) else { return nil }
        if let last = lastNotified[task.id], last.key == key,
           current.timeIntervalSince(last.at) < Self.notifyDedupeInterval {
            return nil
        }
        let label = notificationLabel(for: task)
        let notify: Notify
        switch task.status {
        case .waitingApproval:
            guard let request = task.pendingRequest else { return nil }
            notify = .approval(taskId: task.id, requestId: request.id, title: "\(label) 等待审批", body: request.summary)
        case .waitingInput:
            // agent 停下来等人，而电脑上此刻正好有个密码框聚焦着——这基本就是「它自己填不了，
            // 要人来输」。这时顺手把远程操作开起来，并在通知里说明可以直接在手机上处理。
            // 判据刻意取 Secure Input 而不是猜消息内容：它由应用自己打开，不会误判，也不分语言。
            let needsHands = remoteControlProbe?() ?? false
            notify = .input(taskId: task.id, title: "\(label) 在等你回答",
                            body: needsHands
                                ? "电脑上有个密码框在等着填，可以直接在手机上操作电脑"
                                : (task.pendingRequest?.question ?? task.pendingRequest?.summary ?? task.title))
            if needsHands { onRemoteControlNeeded?(task.id) }
        case .completed:
            notify = .done(taskId: task.id, title: "\(label) 任务完成", body: task.lastMessage ?? task.title)
        case .failed:
            notify = .failed(taskId: task.id, title: "\(label) 任务失败", body: task.lastMessage ?? task.title)
        case .running, .interrupted, .idle:
            return nil
        }
        lastNotified[task.id] = (key, current)
        return notify
    }

    /// 推送标题里的来源名。ACP agent（协议 2.13）共用一个来源，名字各不相同：用注册表里它的显示名，
    /// 查不到（刚从发现结果里消失）时退回它的 connectorId。
    private func notificationLabel(for task: TaskRecord) -> String {
        guard task.source == .acp else { return task.source.notificationLabel }
        guard let id = task.connectorId else { return task.source.notificationLabel }
        return connectors.acpDisplayName(id) ?? id
    }

    /// 已启用来源的项目按 `(agentId, path)` 去重（保留 lastUsedAt 较新的），按 lastUsedAt 降序，最多 30 个。
    /// 去重键不能只用 path：协议 v2 里两台电脑可以有同名路径，`Project.id` 就是 `"<agentId>/<path>"`。
    /// 不算项目的目录（主目录等，见 `OutsideProjectRule`）先滤掉，不占 30 个的名额。
    private func mergedProjects() -> [Project] {
        var byIdentity: [String: Project] = [:]
        // 这里按来源判是有意的：`Project` 没有 `connectorId`，没法在这一层按单个 ACP agent 过滤；
        // `isEnabled(.acp source)` 恒为 true，`.acp` 的项目列表由 `AcpHub.reconcile()`
        // 在每次某个 agent 开关翻转之后，只用"已启用 agent"的任务重新算一遍再报上来。
        for (source, projects) in projectsBySource where isEnabled(source) {
            for project in projects where !outsideProjects.contains(project.path) {
                if let existing = byIdentity[project.id], existing.lastUsedAt >= project.lastUsedAt { continue }
                byIdentity[project.id] = project
            }
        }
        let sorted = byIdentity.values.sorted {
            $0.lastUsedAt == $1.lastUsedAt ? $0.id < $1.id : $0.lastUsedAt > $1.lastUsedAt
        }
        // 自动批准（协议 3.3）在这里统一打上：连接器报的项目不带它，按路径查本机设置。
        return sorted.prefix(Self.maxProjects).map { project in
            var copy = project
            copy.autoApprove = autoApproveProjects.contains(project.path) ? true : nil
            return copy
        }
    }
}

public extension TaskSource {
    /// 推送标题里的来源名（"Codex 等待审批"）。穷举写，加来源时编译器会提醒这里。
    public var notificationLabel: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .hermes: return "Hermes"
        case .pi: return "Pi"
        case .openclaw: return "OpenClaw"
        case .dsh: return "DeepSeek Harness"
        // ACP agent 没有固定名字，这里只是兜底；真正的推送标题走上面的 `notificationLabel(for:)`。
        case .acp: return "Agent"
        }
    }
}
